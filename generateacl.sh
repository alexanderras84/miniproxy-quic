#!/bin/bash
set -euo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

TPROXY_PORT=443
MARK=1

CLIENTS=()

###############################################################################
# LOAD CLIENT ACL LIST
###############################################################################

echo "[INFO] Loading allowed clients..."

if [ -n "${ALLOWED_CLIENTS_FILE:-}" ] && [ -f "$ALLOWED_CLIENTS_FILE" ]; then
  mapfile -t CLIENTS < "$ALLOWED_CLIENTS_FILE"
else
  IFS=', ' read -ra CLIENTS <<< "${ALLOWED_CLIENTS:-}"
fi

CLIENTS+=( "127.0.0.1" )

###############################################################################
# RESOLVE HOSTNAMES → IPs
###############################################################################

echo "[INFO] Resolving dynamic ACL entries..."

RESOLVED_CLIENTS=()

for entry in "${CLIENTS[@]}"; do
  if ipcalc -cs "$entry" >/dev/null 2>&1; then
    RESOLVED_CLIENTS+=( "$entry" )
  else
    while read -r ip; do
      [ -n "$ip" ] && RESOLVED_CLIENTS+=( "$ip" )
    done < <(dig +short "$entry" A)

    while read -r ip; do
      [ -n "$ip" ] && RESOLVED_CLIENTS+=( "$ip" )
    done < <(dig +short "$entry" AAAA)
  fi
done

CLIENTS=( "${RESOLVED_CLIENTS[@]}" )

###############################################################################
# ROUTING TABLE FOR TPROXY
###############################################################################

echo "[INFO] Configuring routing table..."

ip rule add fwmark $MARK table 100 2>/dev/null || true
ip route add local default dev lo table 100 2>/dev/null || true

###############################################################################
# CLEAN OLD RULES
###############################################################################

echo "[INFO] Resetting PREROUTING rules..."

iptables -t mangle -F PREROUTING
ip6tables -t mangle -F PREROUTING

###############################################################################
# LOOP PREVENTION RULES (CRITICAL)
###############################################################################

echo "[INFO] Installing loop-prevention guards..."

iptables -t mangle -I PREROUTING 1 -m mark --mark $MARK -j RETURN

if [ -n "${VPS_IPV4:-}" ]; then
  iptables -t mangle -I PREROUTING 2 -s "$VPS_IPV4" -j RETURN
  iptables -t mangle -I PREROUTING 3 -d "$VPS_IPV4" -j RETURN
fi

###############################################################################
# APPLY TPROXY RULES
###############################################################################

echo "[INFO] Applying interception rules..."

for ip in "${CLIENTS[@]}"; do

  if [[ "$ip" == *":"* ]]; then
    CMD="ip6tables"
  else
    CMD="iptables"
  fi

  for port in 80 443; do

    $CMD -t mangle -A PREROUTING \
      -s "$ip" \
      -p tcp \
      -d "${VPS_IPV4:-0.0.0.0/0}" \
      --dport "$port" \
      -j TPROXY \
      --on-port $TPROXY_PORT \
      --tproxy-mark $MARK

    $CMD -t mangle -A PREROUTING \
      -s "$ip" \
      -p udp \
      -d "${VPS_IPV4:-0.0.0.0/0}" \
      --dport "$port" \
      -j TPROXY \
      --on-port $TPROXY_PORT \
      --tproxy-mark $MARK

  done
done

echo "[INFO] ACL + TPROXY setup complete"
