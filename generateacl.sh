#!/bin/bash
set -euo pipefail

###############################################################################
# CONFIG
###############################################################################

TPROXY_PORT=443
MARK=1

CLIENTS=()

###############################################################################
# LOAD CLIENT LIST
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

RESOLVED=()

for entry in "${CLIENTS[@]}"; do

  if ipcalc -cs "$entry" >/dev/null 2>&1; then
    RESOLVED+=( "$entry" )
    continue
  fi

  while read -r ip; do
    [ -n "$ip" ] && RESOLVED+=( "$ip" )
  done < <(dig +short "$entry" A)

  while read -r ip; do
    [ -n "$ip" ] && RESOLVED+=( "$ip" )
  done < <(dig +short "$entry" AAAA)

done

CLIENTS=( "${RESOLVED[@]}" )

###############################################################################
# POLICY ROUTING FOR TPROXY
###############################################################################

echo "[INFO] Installing fwmark routing rule..."

ip rule add fwmark $MARK table 100 2>/dev/null || true
ip route add local default dev lo table 100 2>/dev/null || true

###############################################################################
# CLEAN OLD RULES
###############################################################################

echo "[INFO] Resetting PREROUTING chain..."

iptables  -t mangle -F PREROUTING
ip6tables -t mangle -F PREROUTING

###############################################################################
# LOOP PROTECTION (CRITICAL)
###############################################################################

echo "[INFO] Installing loop protection rules..."

iptables  -t mangle -I PREROUTING 1 -m mark --mark $MARK -j RETURN
ip6tables -t mangle -I PREROUTING 1 -m mark --mark $MARK -j RETURN

if [ -n "${VPS_IPV4:-}" ]; then
  iptables -t mangle -I PREROUTING 2 -s "$VPS_IPV4" -j RETURN
  iptables -t mangle -I PREROUTING 3 -d "$VPS_IPV4" -j RETURN
fi

if [ -n "${VPS_IPV6:-}" ]; then
  ip6tables -t mangle -I PREROUTING 2 -s "$VPS_IPV6" -j RETURN
  ip6tables -t mangle -I PREROUTING 3 -d "$VPS_IPV6" -j RETURN
fi

###############################################################################
# APPLY CLIENT INTERCEPTION RULES
###############################################################################

echo "[INFO] Applying whitelist interception rules..."

for ip in "${CLIENTS[@]}"; do

  if [[ "$ip" == *":"* ]]; then
    IPT="ip6tables"
    DEST="${VPS_IPV6:-::/0}"
  else
    IPT="iptables"
    DEST="${VPS_IPV4:-0.0.0.0/0}"
  fi

  for port in 80 443; do

    $IPT -t mangle -A PREROUTING \
      -s "$ip" \
      -d "$DEST" \
      -p tcp \
      --dport "$port" \
      -j TPROXY \
      --on-port $TPROXY_PORT \
      --tproxy-mark $MARK

    $IPT -t mangle -A PREROUTING \
      -s "$ip" \
      -d "$DEST" \
      -p udp \
      --dport "$port" \
      -j TPROXY \
      --on-port $TPROXY_PORT \
      --tproxy-mark $MARK

  done

done

echo "[INFO] ACL interception ready."
