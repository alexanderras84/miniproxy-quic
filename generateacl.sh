#!/bin/bash
set -euo pipefail

CLIENTS=()
export DYNDNS_CRON_ENABLED=false

###############################################################################
# READ ACL CLIENTS
###############################################################################

function read_acl () {
  echo "[INFO] Reading allowed clients from source..."
  for i in "${client_list[@]}"
  do
    if timeout 15s /usr/bin/ipcalc -cs "$i" >/dev/null 2>&1; then
      CLIENTS+=( "$i" )
    else
      RESOLVE_IPV4_LIST=$(timeout 5s /usr/bin/dig +short "$i" A 2>/dev/null || true)
      RESOLVE_IPV6_LIST=$(timeout 5s /usr/bin/dig +short "$i" AAAA 2>/dev/null || true)

      if [ -n "$RESOLVE_IPV4_LIST" ] || [ -n "$RESOLVE_IPV6_LIST" ]; then
        while read -r ip4; do
          [ -n "$ip4" ] && CLIENTS+=( "$ip4" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV4_LIST"

        while read -r ip6; do
          [ -n "$ip6" ] && CLIENTS+=( "$ip6" ) && DYNDNS_CRON_ENABLED=true
        done <<< "$RESOLVE_IPV6_LIST"
      else
        echo "[WARN] Could not resolve '$i'"
      fi
    fi
  done

  if ! printf '%s\n' "${client_list[@]}" | grep -q '127.0.0.1'; then
    if [ "$DYNDNS_CRON_ENABLED" = true ]; then
      CLIENTS+=( "127.0.0.1" )
    fi
  fi

  echo "[INFO] Final resolved clients:"
  printf '%s\n' "${CLIENTS[@]}"
}

###############################################################################
# LOAD CLIENT SOURCE
###############################################################################

if [ -n "${ALLOWED_CLIENTS_FILE:-}" ]; then
  if [ -f "$ALLOWED_CLIENTS_FILE" ]; then
    mapfile -t client_list < "$ALLOWED_CLIENTS_FILE"
  else
    echo "[ERROR] ALLOWED_CLIENTS_FILE missing"
    exit 1
  fi
else
  IFS=', ' read -ra client_list <<< "${ALLOWED_CLIENTS:-}"
fi

read_acl

echo "[INFO] Starting ACL generation"

###############################################################################
# TPROXY POLICY ROUTING (REQUIRED FOR TRUE TRANSPARENT MODE)
###############################################################################

# Add fwmark rule safely
ip rule add fwmark 1 lookup 100 priority 10000 2>/dev/null || true

# Route marked packets to loopback
ip route replace local 0.0.0.0/0 dev lo table 100

###############################################################################
# CLEAN EXISTING TPROXY RULES (IDEMPOTENT)
###############################################################################

iptables -t mangle -D PREROUTING -p tcp --dport 443 -j TPROXY --on-port 443 --tproxy-mark 0x1/0x1 2>/dev/null || true
iptables -t mangle -D PREROUTING -p udp --dport 443 -j TPROXY --on-port 443 --tproxy-mark 0x1/0x1 2>/dev/null || true
iptables -t mangle -D PREROUTING -p tcp --dport 80  -j TPROXY --on-port 80  --tproxy-mark 0x1/0x1 2>/dev/null || true

###############################################################################
# TRUE TPROXY INTERCEPTION
###############################################################################

iptables -t mangle -A PREROUTING -p tcp --dport 443 \
  -j TPROXY --on-port 443 --tproxy-mark 0x1/0x1

iptables -t mangle -A PREROUTING -p udp --dport 443 \
  -j TPROXY --on-port 443 --tproxy-mark 0x1/0x1

iptables -t mangle -A PREROUTING -p tcp --dport 80 \
  -j TPROXY --on-port 80 --tproxy-mark 0x1/0x1

###############################################################################
# FILTER ACL
###############################################################################

echo "[INFO] Applying filter ACL"

# Always allow SSH + DNS
for cmd in iptables ip6tables; do
  for port in 22 53; do
    $cmd -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
      $cmd -I INPUT -p tcp --dport "$port" -j ACCEPT
  done

  $cmd -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || \
    $cmd -I INPUT -p udp --dport 53 -j ACCEPT
done

# Allow 80/443 only for allowed clients
for ip in "${CLIENTS[@]}"; do
  for port in 80 443; do
    iptables -C INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT
    iptables -C INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT
  done
done

# Drop all other 80/443 traffic
for port in 80 443; do
  iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || \
    iptables -A INPUT -p tcp --dport "$port" -j DROP
  iptables -C INPUT -p udp --dport "$port" -j DROP 2>/dev/null || \
    iptables -A INPUT -p udp --dport "$port" -j DROP
done

echo "[INFO] ✅ TRUE TRANSPARENT ACL + TPROXY setup complete"
