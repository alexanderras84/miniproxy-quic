#!/bin/bash
set -euo pipefail

CLIENTS=()
export DYNDNS_CRON_ENABLED=false

###############################################################################
# READ ACL CLIENTS (UNCHANGED)
###############################################################################

function read_acl () {
  echo "[INFO] Reading allowed clients from source..."
  for i in "${client_list[@]}"
  do
    if timeout 15s /usr/bin/ipcalc -cs "$i" >/dev/null 2>&1; then
      CLIENTS+=( "$i" )
    else
      RESOLVE_IPV4_LIST=$(timeout 5s /usr/bin/dig +short "$i" A 2>/dev/null)
      RESOLVE_IPV6_LIST=$(timeout 5s /usr/bin/dig +short "$i" AAAA 2>/dev/null)

      if [ -n "$RESOLVE_IPV4_LIST" ] || [ -n "$RESOLVE_IPV6_LIST" ]; then
        while read -r ip4; do
          [ -n "$ip4" ] && CLIENTS+=( "$ip4" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV4_LIST"

        while read -r ip6; do
          [ -n "$ip6" ] && CLIENTS+=( "$ip6" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV6_LIST"
      else
        echo "[ERROR] Could not resolve A or AAAA records for '$i' (timeout or failure), skipping"
      fi
    fi
  done

  if ! printf '%s\n' "${client_list[@]}" | grep -q '127.0.0.1'; then
    if [ "$DYNDNS_CRON_ENABLED" = true ]; then
      echo "[INFO] Adding '127.0.0.1' to allowed clients to prevent reload issues"
      CLIENTS+=( "127.0.0.1" )
    fi
  fi

  echo "[INFO] Final resolved clients:"
  printf '%s\n' "${CLIENTS[@]}"
}

###############################################################################
# LOAD CLIENT SOURCE (UNCHANGED)
###############################################################################

if [ -n "${ALLOWED_CLIENTS_FILE:-}" ]; then
  if [ -f "$ALLOWED_CLIENTS_FILE" ]; then
    echo "[INFO] Reading allowed clients from file: $ALLOWED_CLIENTS_FILE"
    mapfile -t client_list < "$ALLOWED_CLIENTS_FILE"
  else
    echo "[ERROR] ALLOWED_CLIENTS_FILE is set but file does not exist!"
    exit 1
  fi
else
  echo "[INFO] Reading allowed clients from environment variable ALLOWED_CLIENTS"
  IFS=', ' read -ra client_list <<< "${ALLOWED_CLIENTS:-}"
fi

read_acl

echo "[INFO] Starting ACL generation"

###############################################################################
# MINIMAL TPROXY ROUTING ADDITION (ONLY WHAT IS REQUIRED)
###############################################################################

# Safe ip rule (won't crash if exists)
ip rule add fwmark 1 lookup 100 priority 10000 2>/dev/null || true

# Safe route (replace avoids RTNETLINK error)
ip route replace local 0.0.0.0/0 dev lo table 100

# Loop protection (safe + idempotent)
iptables -t mangle -N DIVERT 2>/dev/null || true
iptables -t mangle -F DIVERT
iptables -t mangle -A DIVERT -j MARK --set-mark 1
iptables -t mangle -A DIVERT -j ACCEPT
iptables -t mangle -C PREROUTING -p tcp -m socket -j DIVERT 2>/dev/null || \
  iptables -t mangle -I PREROUTING -p tcp -m socket -j DIVERT

###############################################################################
# ORIGINAL FIREWALL LOGIC (UNCHANGED)
###############################################################################

# --- ENSURE SSH (22) and DNS (53) universally allowed ---
echo "[INFO] Ensuring SSH (22) and DNS (53) ports are always allowed"
for cmd in iptables ip6tables; do
  for port in 22 53; do
    $cmd -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
      $cmd -I INPUT -p tcp --dport "$port" -j ACCEPT
  done

  $cmd -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || \
    $cmd -I INPUT -p udp --dport 53 -j ACCEPT
done

# --- MARK 80/443 FOR TPROXY ---
echo "[INFO] Marking TCP/UDP traffic on ports 80 and 443"
for cmd in iptables ip6tables; do
  $cmd -t mangle -N TPROXY-MARK 2>/dev/null || $cmd -t mangle -F TPROXY-MARK

  $cmd -t mangle -A TPROXY-MARK -p tcp -m multiport --dports 80,443 -j MARK --set-mark 1
  $cmd -t mangle -A TPROXY-MARK -p udp -m multiport --dports 80,443 -j MARK --set-mark 1
  $cmd -t mangle -A TPROXY-MARK -j RETURN

  $cmd -t mangle -C PREROUTING -j TPROXY-MARK 2>/dev/null || \
    $cmd -t mangle -I PREROUTING -j TPROXY-MARK
done

# --- ACCEPT rules for allowed clients ---
echo "[INFO] Adding ACCEPT rules for ports 80/443 for allowed clients"
for ip in "${CLIENTS[@]}"; do
  for port in 80 443; do
    iptables -C INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT
    iptables -C INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT
  done
done

# --- DROP all other 80/443 traffic ---
for port in 80 443; do
  iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || \
    iptables -A INPUT -p tcp --dport "$port" -j DROP
  iptables -C INPUT -p udp --dport "$port" -j DROP 2>/dev/null || \
    iptables -A INPUT -p udp --dport "$port" -j DROP
done

echo "[INFO] ✅ ACL setup complete"
