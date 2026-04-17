#!/bin/bash
set -euo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

TPROXY_PORT=443
MARK=1

VPS_IPV4="193.161.200.70"
VPS_IPV6="2a11:fc0:0:a:250:56ff:fe9b:37a0"

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
# ENABLE REQUIRED KERNEL SETTINGS
###############################################################################

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null

###############################################################################
# POLICY ROUTING (SAFE, NON-DUPLICATE)
###############################################################################

ip rule | grep -q "fwmark $MARK lookup 100" || \
  ip rule add fwmark $MARK table 100

ip route show table 100 | grep -q "local default" || \
  ip route add local default dev lo table 100

###############################################################################
# REMOVE ONLY OUR OWN RULES
###############################################################################

iptables -t mangle -F PREROUTING 2>/dev/null || true
ip6tables -t mangle -F PREROUTING 2>/dev/null || true

###############################################################################
# APPLY SMARTDNS + ACL INTERCEPTION RULES
###############################################################################

echo "[INFO] Applying SmartDNS interception rules with ACL..."

for ip in "${CLIENTS[@]}"; do

  if [[ "$ip" =~ ":" ]]; then
    CMD="ip6tables"
    VPS="$VPS_IPV6"
  else
    CMD="iptables"
    VPS="$VPS_IPV4"
  fi

  for port in 80 443; do
    $CMD -t mangle -A PREROUTING \
      -s "$ip" \
      -d "$VPS" \
      -p tcp --dport "$port" \
      -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"

    $CMD -t mangle -A PREROUTING \
      -s "$ip" \
      -d "$VPS" \
      -p udp --dport "$port" \
      -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"
  done

done

###############################################################################
# PREVENT LOOPBACK INTERCEPTION
###############################################################################

iptables -t mangle -C OUTPUT -m addrtype --src-type LOCAL -j RETURN 2>/dev/null || \
iptables -t mangle -I OUTPUT -m addrtype --src-type LOCAL -j RETURN

###############################################################################
# OPEN REQUIRED INPUT PORTS
###############################################################################

for cmd in iptables ip6tables; do

  $cmd -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
  $cmd -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  $cmd -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || \
  $cmd -A INPUT -p tcp --dport 80 -j ACCEPT

  $cmd -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || \
  $cmd -A INPUT -p tcp --dport 443 -j ACCEPT

  $cmd -C INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || \
  $cmd -A INPUT -p udp --dport 443 -j ACCEPT

done

echo "[INFO] ✅ SmartDNS interception with ACL whitelist applied."
