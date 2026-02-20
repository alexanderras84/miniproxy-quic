#!/bin/bash
set -euo pipefail

CLIENTS=()
export DYNDNS_CRON_ENABLED=false
TPROXY_PORT=443  # Must match your sing-box listen_port
MARK=1

###############################################################################
# READ ACL CLIENTS (YOUR ORIGINAL LOGIC)
###############################################################################
function read_acl () {
  echo "[INFO] Reading allowed clients from source..."
  for i in "${client_list[@]}"; do
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
  [[ ! " ${CLIENTS[*]} " =~ " 127.0.0.1 " ]] && CLIENTS+=( "127.0.0.1" )
}

# Load sources (Existing logic)
if [ -n "${ALLOWED_CLIENTS_FILE:-}" ] && [ -f "$ALLOWED_CLIENTS_FILE" ]; then
  mapfile -t client_list < "$ALLOWED_CLIENTS_FILE"
else
  IFS=', ' read -ra client_list <<< "${ALLOWED_CLIENTS:-}"
fi
read_acl

###############################################################################
# TPROXY ROUTING SETUP
###############################################################################
echo "[INFO] Setting up TProxy Routing Table..."
# Create a routing policy that sends 'marked' packets to the local loopback
ip rule add fwmark $MARK table 100 2>/dev/null || true
ip route add local default dev lo table 100 2>/dev/null || true

# Flush Mangle table to prevent stale rules
iptables -t mangle -F PREROUTING 2>/dev/null || true

###############################################################################
# APPLY TPROXY + ACL LOGIC
###############################################################################
echo "[INFO] Applying TProxy Mangle rules for whitelisted clients..."

for ip in "${CLIENTS[@]}"; do
  # Determine if IPv4 or IPv6
  CMD="iptables"
  [[ "$ip" =~ .*:.* ]] && CMD="ip6tables"

  for port in 80 443; do
    # TCP TProxy
    $CMD -t mangle -A PREROUTING -s "$ip" -p tcp --dport "$port" -j TPROXY \
      --on-port $TPROXY_PORT --tproxy-mark $MARK
    
    # UDP TProxy
    $CMD -t mangle -A PREROUTING -s "$ip" -p udp --dport "$port" -j TPROXY \
      --on-port $TPROXY_PORT --tproxy-mark $MARK
  done
done

# Essential: Open ports in the INPUT chain so the packets aren't dropped locally
for cmd in iptables ip6tables; do
  $cmd -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  $cmd -A INPUT -p tcp --dport 22 -j ACCEPT
  $cmd -A INPUT -p tcp --dport 80 -j ACCEPT
  $cmd -A INPUT -p tcp --dport 443 -j ACCEPT
  $cmd -A INPUT -p udp --dport 443 -j ACCEPT
done

echo "[INFO] ✅ TProxy logic applied. Whitelisted clients will be intercepted."
