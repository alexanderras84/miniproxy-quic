#!/bin/sh
set -eu

TUN_INTERFACE="sb-tun0"
TABLE="100"
MARK="1"
PORT="443"

# Use an explicit interface when supplied; otherwise use the container's
# IPv4 default-route interface (normally eth0 in Docker).
INBOUND_INTERFACE="${INBOUND_INTERFACE:-$(
  ip -4 route show default |
    awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
)}"

[ -n "$INBOUND_INTERFACE" ] || {
  echo "[ERROR] Could not determine the container inbound interface."
  exit 1
}

# Wait up to 10 seconds for sing-box to create the TUN device.
for i in $(seq 1 20); do
  ip link show "$TUN_INTERFACE" >/dev/null 2>&1 && break
  sleep 0.5
done

ip link show "$TUN_INTERFACE" >/dev/null 2>&1 || {
  echo "[ERROR] TUN interface $TUN_INTERFACE was not created."
  exit 1
}

echo "[INFO] Intercepting inbound port $PORT traffic on $INBOUND_INTERFACE"
echo "[INFO] Routing marked packets through $TUN_INTERFACE"

# IPv4: mark inbound HTTPS and QUIC traffic.
iptables -t mangle -C PREROUTING \
  -i "$INBOUND_INTERFACE" -p tcp --dport "$PORT" \
  -j MARK --set-mark "$MARK" 2>/dev/null || \
iptables -t mangle -A PREROUTING \
  -i "$INBOUND_INTERFACE" -p tcp --dport "$PORT" \
  -j MARK --set-mark "$MARK"

iptables -t mangle -C PREROUTING \
  -i "$INBOUND_INTERFACE" -p udp --dport "$PORT" \
  -j MARK --set-mark "$MARK" 2>/dev/null || \
iptables -t mangle -A PREROUTING \
  -i "$INBOUND_INTERFACE" -p udp --dport "$PORT" \
  -j MARK --set-mark "$MARK"

ip rule add fwmark "$MARK" lookup "$TABLE" priority 100 2>/dev/null || true
ip route replace default dev "$TUN_INTERFACE" table "$TABLE"

# IPv6: apply the same policy.
ip6tables -t mangle -C PREROUTING \
  -i "$INBOUND_INTERFACE" -p tcp --dport "$PORT" \
  -j MARK --set-mark "$MARK" 2>/dev/null || \
ip6tables -t mangle -A PREROUTING \
  -i "$INBOUND_INTERFACE" -p tcp --dport "$PORT" \
  -j MARK --set-mark "$MARK"

ip6tables -t mangle -C PREROUTING \
  -i "$INBOUND_INTERFACE" -p udp --dport "$PORT" \
  -j MARK --set-mark "$MARK" 2>/dev/null || \
ip6tables -t mangle -A PREROUTING \
  -i "$INBOUND_INTERFACE" -p udp --dport "$PORT" \
  -j MARK --set-mark "$MARK"

ip -6 rule add fwmark "$MARK" lookup "$TABLE" priority 100 2>/dev/null || true
ip -6 route replace default dev "$TUN_INTERFACE" table "$TABLE"

echo "[INFO] TUN interception rules installed."
