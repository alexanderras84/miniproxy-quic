#!/bin/bash
set -euo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

TPROXY_PORT=443
MARK=1

VPS_IPV4="${VPS_IPV4:-}"
VPS_IPV6="${VPS_IPV6:-}"

CLIENTS=()

###############################################################################
# VALIDATE ENVIRONMENT
###############################################################################

if [ -z "$VPS_IPV4" ] && [ -z "$VPS_IPV6" ]; then
  echo "[ERROR] VPS_IPV4 or VPS_IPV6 must be provided via environment variables."
  exit 1
fi

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
# RESOLVE HOSTNAMES → IP ADDRESSES
###############################################################################

echo "[INFO] Resolving dynamic ACL entries..."

RESOLVED_CLIENTS=()

for entry in "${CLIENTS[@]}"; do

  if ipcalc -cs "$entry" >/dev/null 2>&1; then
    RESOLVED_CLIENTS+=( "$entry" )
    continue
  fi

  IPV4_LIST=$(dig +short "$entry" A || true)
  IPV6_LIST=$(dig +short "$entry" AAAA || true)

  for ip in $IPV4_LIST; do
    RESOLVED_CLIENTS+=( "$ip" )
  done

  for ip in $IPV6_LIST; do
    RESOLVED_CLIENTS+=( "$ip" )
  done

done

CLIENTS=( "${RESOLVED_CLIENTS[@]}" )

###############################################################################
# VERIFY HOST KERNEL SETTINGS (DO NOT MODIFY)
###############################################################################

echo "[INFO] Verifying host routing prerequisites..."

if ! sysctl net.ipv4.conf.all.route_localnet | grep -q "= 1"; then
  echo "[WARN] route_localnet is disabled on host — SmartDNS interception may fail"
fi

###############################################################################
# ENSURE POLICY ROUTING EXISTS
###############################################################################

echo "[INFO] Ensuring policy routing table exists..."

if ! ip rule | grep -q "fwmark $MARK lookup 100"; then
  ip rule add fwmark $MARK table 100
fi

if ! ip route show table 100 | grep -q "local default"; then
  ip route add local default dev lo table 100
fi

###############################################################################
# CLEAN PREVIOUS RULES SAFELY
###############################################################################

echo "[INFO] Cleaning previous SmartDNS interception rules..."

iptables -t mangle -F PREROUTING 2>/dev/null || true
ip6tables -t mangle -F PREROUTING 2>/dev/null || true

###############################################################################
# APPLY SMARTDNS + ACL INTERCEPTION RULES
###############################################################################

echo "[INFO] Applying SmartDNS interception rules with ACL whitelist..."

for ip in "${CLIENTS[@]}"; do

  if [[ "$ip" =~ ":" ]]; then

    [ -z "$VPS_IPV6" ] && continue

    CMD="ip6tables"
    VPS="$VPS_IPV6"

  else

    [ -z "$VPS_IPV4" ] && continue

    CMD="iptables"
    VPS="$VPS_IPV4"

  fi


  for port in 80 443; do

    # TCP interception
    $CMD -t mangle -A PREROUTING \
      -s "$ip" \
      -d "$VPS" \
      -p tcp --dport "$port" \
      -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"


    # UDP interception (QUIC)
    $CMD -t mangle -A PREROUTING \
      -s "$ip" \
      -d "$VPS" \
      -p udp --dport "$port" \
      -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"


  done

done

###############################################################################
# PREVENT LOCAL INTERCEPTION LOOPS
###############################################################################

echo "[INFO] Preventing interception loops..."

if ! iptables -t mangle -C OUTPUT -m addrtype --src-type LOCAL -j RETURN 2>/dev/null; then
  iptables -t mangle -I OUTPUT -m addrtype --src-type LOCAL -j RETURN
fi

###############################################################################
# OPEN REQUIRED INPUT PORTS
###############################################################################

echo "[INFO] Ensuring INPUT accept rules exist..."

for cmd in iptables ip6tables; do

  $cmd -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
    || $cmd -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT


  $cmd -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null \
    || $cmd -A INPUT -p tcp --dport 80 -j ACCEPT


  $cmd -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null \
    || $cmd -A INPUT -p tcp --dport 443 -j ACCEPT


  $cmd -C INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null \
    || $cmd -A INPUT -p udp --dport 443 -j ACCEPT


done

###############################################################################
# COMPLETE
###############################################################################

echo "[INFO] ✅ SmartDNS interception with ACL whitelist successfully configured."
