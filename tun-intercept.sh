#!/bin/sh
set -eu

TUN_INTERFACE="sb-tun0"
TABLE="100"
MARK="1"
PORT="443"
MARK_RULE_PRIORITY="100"
LOCAL_RULE_PRIORITY="200"

default_interface() {
  ip "$1" route show default 2>/dev/null |
    awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
}

move_local_rule_after_mark_rule() {
  FAMILY="$1"

  # Docker DNATs published ports to the container's local address. Preserve the
  # local table, but move its lookup below the fwmark route rule.
  if ip "$FAMILY" rule show | grep -q '^0:.*lookup local'; then
    if ! ip "$FAMILY" rule show | grep -q "^${LOCAL_RULE_PRIORITY}:.*lookup local"; then
      ip "$FAMILY" rule add priority "$LOCAL_RULE_PRIORITY" lookup local
    fi

    ip "$FAMILY" rule del priority 0
  fi
}

# Override either at runtime if necessary:
# -e INBOUND_INTERFACE_V4=eth0
# -e INBOUND_INTERFACE_V6=eth1
INBOUND_INTERFACE_V4="${INBOUND_INTERFACE_V4:-$(default_interface -4)}"
INBOUND_INTERFACE_V6="${INBOUND_INTERFACE_V6:-$(default_interface -6)}"

[ -n "$INBOUND_INTERFACE_V4" ] || {
  echo "[ERROR] Could not determine the IPv4 inbound interface."
  exit 1
}

# Docker commonly uses the same interface for both families. If there is no
# IPv6 default route, use the IPv4 interface unless explicitly overridden.
if [ -z "$INBOUND_INTERFACE_V6" ]; then
  INBOUND_INTERFACE_V6="$INBOUND_INTERFACE_V4"
fi

# Wait up to 10 seconds for sing-box to create the TUN device.
for i in $(seq 1 20); do
  ip link show "$TUN_INTERFACE" >/dev/null 2>&1 && break
  sleep 0.5
done

ip link show "$TUN_INTERFACE" >/dev/null 2>&1 || {
  echo "[ERROR] TUN interface $TUN_INTERFACE was not created."
  exit 1
}

echo "[INFO] IPv4 ingress interface: $INBOUND_INTERFACE_V4"
echo "[INFO] IPv6 ingress interface: $INBOUND_INTERFACE_V6"
echo "[INFO] Intercepting TCP and UDP port $PORT via $TUN_INTERFACE"

# IPv4: mark incoming HTTPS and QUIC traffic.
iptables -t mangle -C PREROUTING \
  -i "$INBOUND_INTERFACE_V4" -p tcp --dport "$PORT" \
  -j MARK --set-mark "$MARK" 2>/dev/null || \
iptables -t mangle -A PREROUTING \
  -i "$INBOUND_INTERFACE_V4" -p tcp --dport "$PORT" \
  -j MARK --set-mark "$MARK"

iptables -t mangle -C PREROUTING \
  -i "$INBOUND_INTERFACE_V4" -p udp --dport "$PORT" \
  -j MARK --set-mark "$MARK" 2>/dev/null || \
iptables -t mangle -A PREROUTING \
  -i "$INBOUND_INTERFACE_V4" -p udp --dport "$PORT" \
  -j MARK --set-mark "$MARK"

# Route marked IPv4 packets into the TUN before local delivery is considered.
move_local_rule_after_mark_rule -4
ip rule add fwmark "$MARK" lookup "$TABLE" \
  priority "$MARK_RULE_PRIORITY" 2>/dev/null || true
ip route replace default dev "$TUN_INTERFACE" table "$TABLE"

# IPv6: same policy, potentially on a different ingress interface.
ip6tables -t mangle -C PREROUTING \
  -i "$INBOUND_INTERFACE_V6" -p tcp --dport "$PORT" \
  -j MARK --set-mark "$MARK" 2>/dev/null || \
ip6tables -t mangle -A PREROUTING \
  -i "$INBOUND_INTERFACE_V6" -p tcp --dport "$PORT" \
  -j MARK --set-mark "$MARK"

ip6tables -t mangle -C PREROUTING \
  -i "$INBOUND_INTERFACE_V6" -p udp --dport "$PORT" \
  -j MARK --set-mark "$MARK" 2>/dev/null || \
ip6tables -t mangle -A PREROUTING \
  -i "$INBOUND_INTERFACE_V6" -p udp --dport "$PORT" \
  -j MARK --set-mark "$MARK"

# Route marked IPv6 packets into the TUN before local delivery is considered.
move_local_rule_after_mark_rule -6
ip -6 rule add fwmark "$MARK" lookup "$TABLE" \
  priority "$MARK_RULE_PRIORITY" 2>/dev/null || true
ip -6 route replace default dev "$TUN_INTERFACE" table "$TABLE"

echo "[INFO] Dual-stack TUN interception rules installed."
