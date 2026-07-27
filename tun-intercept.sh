#!/bin/sh
set -eu

TABLE="100"
MARK="1"
PORT="443"
TPROXY_PORT="10889"

default_interface() {
  ip "$1" route show default 2>/dev/null |
    awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
}

INBOUND_INTERFACE_V4="${INBOUND_INTERFACE_V4:-$(default_interface -4)}"
INBOUND_INTERFACE_V6="${INBOUND_INTERFACE_V6:-$(default_interface -6)}"

[ -n "$INBOUND_INTERFACE_V4" ] || { echo "[ERROR] No IPv4 interface."; exit 1; }
[ -z "$INBOUND_INTERFACE_V6" ] && INBOUND_INTERFACE_V6="$INBOUND_INTERFACE_V4"

echo "[INFO] Intercepting port $PORT on $INBOUND_INTERFACE_V4 / $INBOUND_INTERFACE_V6 -> TPROXY port $TPROXY_PORT"

# 1. Setup Policy Routing (Route marked packets to local delivery for TPROXY)
ip rule add fwmark "$MARK" lookup "$TABLE" 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table "$TABLE" 2>/dev/null || true

ip -6 rule add fwmark "$MARK" lookup "$TABLE" 2>/dev/null || true
ip -6 route add local ::/0 dev lo table "$TABLE" 2>/dev/null || true

# 2. IPv4 TPROXY Rules (TCP & UDP/QUIC)
iptables -t mangle -N SINGBOX_IN 2>/dev/null || iptables -t mangle -F SINGBOX_IN
iptables -t mangle -A SINGBOX_IN -p tcp --dport "$PORT" -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"
iptables -t mangle -A SINGBOX_IN -p udp --dport "$PORT" -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"

iptables -t mangle -C PREROUTING -i "$INBOUND_INTERFACE_V4" -j SINGBOX_IN 2>/dev/null || \
iptables -t mangle -A PREROUTING -i "$INBOUND_INTERFACE_V4" -j SINGBOX_IN

# 3. IPv6 TPROXY Rules (TCP & UDP/QUIC)
ip6tables -t mangle -N SINGBOX_IN 2>/dev/null || ip6tables -t mangle -F SINGBOX_IN
ip6tables -t mangle -A SINGBOX_IN -p tcp --dport "$PORT" -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"
ip6tables -t mangle -A SINGBOX_IN -p udp --dport "$PORT" -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"

ip6tables -t mangle -C PREROUTING -i "$INBOUND_INTERFACE_V6" -j SINGBOX_IN 2>/dev/null || \
ip6tables -t mangle -A PREROUTING -i "$INBOUND_INTERFACE_V6" -j SINGBOX_IN

echo "[INFO] TPROXY interception successfully installed."
