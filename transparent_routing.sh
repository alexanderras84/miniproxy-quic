#!/bin/bash

# Config
TCP_INBOUND_PORT=15001
UDP_INBOUND_PORT=15002
MARK=1
ROUTE_TABLE=100

echo "[INFO] Applying transparent proxy routing rules..."

# --- IPv4 ---

# Create DIVERT chain if not exists
iptables -t mangle -N DIVERT 2>/dev/null || true
iptables -t mangle -F DIVERT

# Flush previous rules to avoid duplicates
iptables -t mangle -D PREROUTING -p tcp --dport 443 -j TPROXY --on-port $TCP_INBOUND_PORT --tproxy-mark $MARK 2>/dev/null || true
iptables -t mangle -D PREROUTING -p udp --dport 443 -j TPROXY --on-port $UDP_INBOUND_PORT --tproxy-mark $MARK 2>/dev/null || true
iptables -t mangle -D PREROUTING -p tcp -m socket -j DIVERT 2>/dev/null || true
iptables -t mangle -D PREROUTING -p udp --dport 443 -m socket -j DIVERT 2>/dev/null || true

# Add rules back

# DIVERT chain rules for TCP & UDP
iptables -t mangle -A PREROUTING -p tcp -m socket -j DIVERT
iptables -t mangle -A PREROUTING -p udp --dport 443 -m socket -j DIVERT

iptables -t mangle -A DIVERT -j MARK --set-mark $MARK
iptables -t mangle -A DIVERT -j ACCEPT

# TPROXY rules for TCP and UDP port 443
iptables -t mangle -A PREROUTING -p tcp --dport 443 -j TPROXY --on-port $TCP_INBOUND_PORT --tproxy-mark $MARK
iptables -t mangle -A PREROUTING -p udp --dport 443 -j TPROXY --on-port $UDP_INBOUND_PORT --tproxy-mark $MARK

# --- IPv6 ---

# Create DIVERT chain if not exists
ip6tables -t mangle -N DIVERT 2>/dev/null || true
ip6tables -t mangle -F DIVERT

# Flush previous rules
ip6tables -t mangle -D PREROUTING -p tcp --dport 443 -j TPROXY --on-port $TCP_INBOUND_PORT --tproxy-mark $MARK 2>/dev/null || true
ip6tables -t mangle -D PREROUTING -p udp --dport 443 -j TPROXY --on-port $UDP_INBOUND_PORT --tproxy-mark $MARK 2>/dev/null || true
ip6tables -t mangle -D PREROUTING -p tcp -m socket -j DIVERT 2>/dev/null || true
ip6tables -t mangle -D PREROUTING -p udp --dport 443 -m socket -j DIVERT 2>/dev/null || true

# Add rules back

# DIVERT chain rules for TCP & UDP IPv6
ip6tables -t mangle -A PREROUTING -p tcp -m socket -j DIVERT
ip6tables -t mangle -A PREROUTING -p udp --dport 443 -m socket -j DIVERT

ip6tables -t mangle -A DIVERT -j MARK --set-mark $MARK
ip6tables -t mangle -A DIVERT -j ACCEPT

# TPROXY rules for TCP and UDP port 443 IPv6
ip6tables -t mangle -A PREROUTING -p tcp --dport 443 -j TPROXY --on-port $TCP_INBOUND_PORT --tproxy-mark $MARK
ip6tables -t mangle -A PREROUTING -p udp --dport 443 -j TPROXY --on-port $UDP_INBOUND_PORT --tproxy-mark $MARK

# --- Setup routing rules for marked packets ---

# IPv4 ip rule and route
ip rule add fwmark $MARK lookup $ROUTE_TABLE 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table $ROUTE_TABLE 2>/dev/null || true

# IPv6 ip rule and route
ip -6 rule add fwmark $MARK lookup $ROUTE_TABLE 2>/dev/null || true
ip -6 route add local ::/0 dev lo table $ROUTE_TABLE 2>/dev/null || true

echo "[INFO] Transparent routing rules applied."