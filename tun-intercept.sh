#!/bin/bash
set -euo pipefail

TUN_INTERFACE="sb-tun0"
MARK="1"
TABLE="100"
INBOUND_INTERFACE="eth0" # Change if traffic enters through another interface.

# IPv4 TCP and UDP port 443 → sb-tun0
iptables -t mangle -A PREROUTING -i "$INBOUND_INTERFACE" \
  -p tcp --dport 443 -j MARK --set-mark "$MARK"

iptables -t mangle -A PREROUTING -i "$INBOUND_INTERFACE" \
  -p udp --dport 443 -j MARK --set-mark "$MARK"

ip rule add fwmark "$MARK" table "$TABLE" 2>/dev/null || true
ip route replace default dev "$TUN_INTERFACE" table "$TABLE"

# IPv6 TCP and UDP port 443 → sb-tun0
ip6tables -t mangle -A PREROUTING -i "$INBOUND_INTERFACE" \
  -p tcp --dport 443 -j MARK --set-mark "$MARK"

ip6tables -t mangle -A PREROUTING -i "$INBOUND_INTERFACE" \
  -p udp --dport 443 -j MARK --set-mark "$MARK"

ip -6 rule add fwmark "$MARK" table "$TABLE" 2>/dev/null || true
ip -6 route replace default dev "$TUN_INTERFACE" table "$TABLE"
