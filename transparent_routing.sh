#!/bin/bash

# Config
INBOUND_PORT=15001
MARK=1
ROUTE_TABLE=100

echo "[INFO] Applying transparent proxy routing rules..."

# --- IPv4 ---

# Create DIVERT chain if not exists
iptables -t mangle -N DIVERT 2>/dev/null || true
iptables -t mangle -F DIVERT

# Flush PREROUTING mangle rules related to TCP/UDP port 443 to avoid duplicates
iptables -t mangle -D PREROUTING -p tcp --dport 443 -j TPROXY --on-port $INBOUND_PORT --tproxy-mark $MARK 2>/dev/null || true
iptables -t mangle -D PREROUTING -p tcp -m socket -j DIVERT 2>/dev/null || true
iptables -t mangle -D PREROUTING -p udp --dport 443 -m socket -j DIVERT 2>/dev/null || true

# Add rules back

# DIVERT chain rules for TCP & UDP
iptables -t mangle -A PREROUTING -p tcp -m socket -j DIVERT
iptables -t mangle -A PREROUTING -p udp --dport 443 -m socket -j DIVERT

iptables -t mangle -A DIVERT -j MARK --set-mark $MARK
iptables -t mangle -A DIVERT -j ACCEPT

# TPROXY for TCP port 443
iptables -t mangle -A PREROUTING -p tcp --dport 443 -j TPROXY --on-port $INBOUND_PORT --tproxy-mark $MARK

# --- IPv6 ---

# Create DIVERT chain for ip6tables if not exists
ip6tables -t mangle -N DIVERT 2>/dev/null || true
ip6tables -t mangle -F DIVERT

# Flush PREROUTING mangle rules related to TCP/UDP port 443 in IPv6
ip6tables -t mangle -D PREROUTING -p tcp --dport 443 -j TPROXY --on-port $INBOUND_PORT --tproxy-mark $MARK 2>/dev/null || true
ip6tables -t mangle -D PREROUTING -p tcp -m socket -j DIVERT 2>/dev/null || true
ip6tables -t mangle -D PREROUTING -p udp --dport 443 -m socket -j DIVERT 2>/dev/null || true

# Add rules back

# DIVERT chain rules for TCP & UDP IPv6
ip6tables -t mangle -A PREROUTING -p tcp -m socket -j DIVERT
ip6tables -t mangle -A PREROUTING -p udp --dport 443 -m socket -j DIVERT

ip6tables -t mangle -A DIVERT -j MARK --set-mark $MARK
ip6tables -t mangle -A DIVERT -j ACCEPT

# TPROXY for TCP port 443 IPv6
ip6tables -t mangle -A PREROUTING -p tcp --dport 443 -j TPROXY --on-port $INBOUND_PORT --tproxy-mark $MARK

# --- Setup routing rules for marked packets ---

# IPv4 ip rule and route
ip rule add fwmark $MARK lookup $ROUTE_TABLE 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table $ROUTE_TABLE 2>/dev/null || true

# IPv6 ip rule and route
ip -6 rule add fwmark $MARK lookup $ROUTE_TABLE 2>/dev/null || true
ip -6 route add local ::/0 dev lo table $ROUTE_TABLE 2>/dev/null || true

echo "[INFO] Transparent routing rules applied."