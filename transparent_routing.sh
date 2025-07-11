#!/bin/bash

# Config
INBOUND_PORT=15001
MARK=1
ROUTE_TABLE=100

echo "[INFO] Applying transparent proxy routing rules..."

# --- Flush old rules and chains if they exist ---

# IPv4 mangle DIVERT chain
iptables -t mangle -F DIVERT 2>/dev/null || iptables -t mangle -N DIVERT
iptables -t mangle -F PREROUTING

# Create DIVERT chain if not exists
iptables -t mangle -N DIVERT 2>/dev/null || true

# --- TCP handling ---

# DIVERT chain rules for TCP
iptables -t mangle -A PREROUTING -p tcp -m socket -j DIVERT
iptables -t mangle -A DIVERT -j MARK --set-mark $MARK
iptables -t mangle -A DIVERT -j ACCEPT

# TPROXY rule for TCP port 443
iptables -t mangle -C PREROUTING -p tcp --dport 443 -j TPROXY --on-port $INBOUND_PORT --tproxy-mark $MARK 2>/dev/null || \
iptables -t mangle -A PREROUTING -p tcp --dport 443 -j TPROXY --on-port $INBOUND_PORT --tproxy-mark $MARK

# --- UDP handling (QUIC) ---

# DIVERT chain rules for UDP port 443
iptables -t mangle -A PREROUTING -p udp --dport 443 -m socket -j DIVERT
iptables -t mangle -A DIVERT -j MARK --set-mark $MARK
iptables -t mangle -A DIVERT -j ACCEPT

# --- Setup routing rules for marked packets ---

# Add IP rule (ignore error if exists)
ip rule add fwmark $MARK lookup $ROUTE_TABLE 2>/dev/null || true

# Add local route for marked packets (ignore error if exists)
ip route add local 0.0.0.0/0 dev lo table $ROUTE_TABLE 2>/dev/null || true

echo "[INFO] Transparent routing rules applied."