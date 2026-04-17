#!/bin/bash
set -euo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

TPROXY_PORT=443
MARK=1

# Your VPS addresses (SmartDNS interception target)
VPS_IPV4="193.161.200.70"
VPS_IPV6="2a11:fc0:0:a:250:56ff:fe9b:37a0"

###############################################################################
# ENABLE REQUIRED KERNEL FEATURES
###############################################################################

echo "[INFO] Enabling kernel routing requirements..."

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null

###############################################################################
# ENSURE POLICY ROUTING EXISTS (WITHOUT DUPLICATES)
###############################################################################

echo "[INFO] Ensuring policy routing table exists..."

ip rule | grep -q "fwmark $MARK lookup 100" || \
    ip rule add fwmark $MARK table 100

ip route show table 100 | grep -q "local default" || \
    ip route add local default dev lo table 100

###############################################################################
# CLEAN ONLY OUR OWN RULES (NOT EVERYTHING)
###############################################################################

echo "[INFO] Removing old SmartDNS interception rules..."

iptables -t mangle -D PREROUTING -d "$VPS_IPV4" -p tcp --dport 443 \
    -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK 2>/dev/null || true

iptables -t mangle -D PREROUTING -d "$VPS_IPV4" -p udp --dport 443 \
    -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK 2>/dev/null || true

iptables -t mangle -D PREROUTING -d "$VPS_IPV4" -p tcp --dport 80 \
    -j TPROXY --on-port 80 --tproxy-mark $MARK 2>/dev/null || true

ip6tables -t mangle -D PREROUTING -d "$VPS_IPV6" -p tcp --dport 443 \
    -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK 2>/dev/null || true

ip6tables -t mangle -D PREROUTING -d "$VPS_IPV6" -p udp --dport 443 \
    -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK 2>/dev/null || true


###############################################################################
# APPLY SMARTDNS INTERCEPTION RULES
###############################################################################

echo "[INFO] Applying SmartDNS interception rules..."

iptables -t mangle -A PREROUTING \
    -d "$VPS_IPV4" -p tcp --dport 443 \
    -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK

iptables -t mangle -A PREROUTING \
    -d "$VPS_IPV4" -p udp --dport 443 \
    -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK

iptables -t mangle -A PREROUTING \
    -d "$VPS_IPV4" -p tcp --dport 80 \
    -j TPROXY --on-port 80 --tproxy-mark $MARK


###############################################################################
# IPV6 SUPPORT (IMPORTANT FOR APPLE / NETFLIX / PRIME)
###############################################################################

ip6tables -t mangle -A PREROUTING \
    -d "$VPS_IPV6" -p tcp --dport 443 \
    -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK

ip6tables -t mangle -A PREROUTING \
    -d "$VPS_IPV6" -p udp --dport 443 \
    -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK


###############################################################################
# PREVENT LOCAL TRAFFIC INTERCEPTION LOOPS
###############################################################################

echo "[INFO] Preventing interception loops..."

iptables -t mangle -C OUTPUT -m addrtype --src-type LOCAL -j RETURN \
    2>/dev/null || \
iptables -t mangle -I OUTPUT -m addrtype --src-type LOCAL -j RETURN


###############################################################################
# ENSURE INPUT ACCEPT RULES EXIST
###############################################################################

echo "[INFO] Ensuring required INPUT rules exist..."

for cmd in iptables ip6tables; do
    $cmd -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT \
        2>/dev/null || \
    $cmd -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    $cmd -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || \
    $cmd -A INPUT -p tcp --dport 80 -j ACCEPT

    $cmd -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || \
    $cmd -A INPUT -p tcp --dport 443 -j ACCEPT

    $cmd -C INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || \
    $cmd -A INPUT -p udp --dport 443 -j ACCEPT
done


###############################################################################
# FINAL STATUS OUTPUT
###############################################################################

echo "[INFO] ✅ SmartDNS-mode TPROXY interception configured successfully."
