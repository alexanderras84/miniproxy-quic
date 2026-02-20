#!/bin/bash
set -euo pipefail

CLIENTS=()
export DYNDNS_CRON_ENABLED=false

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

# Load clients
if [ -n "${ALLOWED_CLIENTS_FILE:-}" ]; then
  if [ -f "$ALLOWED_CLIENTS_FILE" ]; then
    mapfile -t client_list < "$ALLOWED_CLIENTS_FILE"
  else
    echo "[ERROR] ALLOWED_CLIENTS_FILE is set but file does not exist!"
    exit 1
  fi
else
  IFS=', ' read -ra client_list <<< "${ALLOWED_CLIENTS:-}"
fi

read_acl

echo "[INFO] Starting ACL generation"

###############################################################################
# MINIMAL TPROXY ADDITION (ONLY WHAT IS REQUIRED)
###############################################################################

# Add policy routing ONLY if not present
ip rule list | grep -q "fwmark 0x1 lookup 100" || \
  ip rule add fwmark 1 lookup 100 priority 10000

ip route show table 100 | grep -q "local 0.0.0.0/0 dev lo" || \
  ip route add local 0.0.0.0/0 dev lo table 100

# Add loop-safe DIVERT rule
iptables -t mangle -N DIVERT 2>/dev/null || true
iptables -t mangle -F DIVERT

iptables -t mangle -A DIVERT -j MARK --set-mark 1
iptables -t mangle -A DIVERT -j ACCEPT

iptables -t mangle -C PREROUTING -p tcp -m socket -j DIVERT 2>/dev/null || \
  iptables -t mangle -I PREROUTING -p tcp -m socket -j DIVERT

###############################################################################
# ORIGINAL LOGIC BELOW (UNCHANGED)
###############################################################################

# --- ENSURE SSH (22) and DNS (53) universally allowed ---
echo "[INFO] Ensuring SSH (22) and DNS (53) always allowed"
for cmd in iptables ip6tables; do
  for port in 22 53; do
    $cmd -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
      $cmd -I INPUT -p tcp --dport "$port" -j ACCEPT
  done

  $cmd -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || \
    $cmd -I INPUT -p udp --dport 53 -j ACCEPT
done

# --- MARK 80/443 IN MANGLE ---
echo "[INFO] Marking TCP/UDP 80,443"
for cmd in iptables ip6tables; do
  $cmd -t mangle -N TPROXY-MARK 2>/dev/null || $cmd -t mangle -F TPROXY-MARK

  $cmd -t mangle -A TPROXY-MARK -p tcp -m multiport --dports 80,443 -j MARK --set-mark 1
  $cmd -t mangle -A TPROXY-MARK -p udp -m multiport --dports 80,443 -j MARK --set-mark 1
  $cmd -t mangle -A TPROXY-MARK -j RETURN

  $cmd -t mangle -C PREROUTING -j TPROXY-MARK 2>/dev/null || \
    $cmd -t mangle -I PREROUTING -j TPROXY-MARK
done

# --- ACCEPT 80/443 for allowed clients ---
echo "[INFO] Adding ACCEPT rules for allowed clients"
for ip in "${CLIENTS[@]}"; do
  for port in 80 443; do
    iptables -C INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT
    iptables -C INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT
  done
done

# --- DROP all other 80/443 ---
for port in 80 443; do
  iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || \
    iptables -A INPUT -p tcp --dport "$port" -j DROP
  iptables -C INPUT -p udp --dport "$port" -j DROP 2>/dev/null || \
    iptables -A INPUT -p udp --dport "$port" -j DROP
done

echo "[INFO] ✅ ACL setup complete"
