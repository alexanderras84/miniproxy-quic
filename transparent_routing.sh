#!/bin/bash

echo "[INFO] Applying transparent proxy routing rules..."

# === Redirect TCP traffic on ports 80 and 443 to sing-box ===
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 80
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 443

# === UDP traffic (QUIC) to sing-box with TPROXY ===

# Create and configure mangle table
iptables -t mangle -N DIVERT 2>/dev/null || true
iptables -t mangle -F DIVERT

iptables -t mangle -A PREROUTING -p udp --dport 443 -m socket -j DIVERT
iptables -t mangle -A DIVERT -j MARK --set-mark 1
iptables -t mangle -A DIVERT -j ACCEPT

# Set up routing table for marked packets
ip rule add fwmark 1 lookup 100 || true
ip route add local 0.0.0.0/0 dev lo table 100 || true

echo "[INFO] Transparent routing rules applied."
