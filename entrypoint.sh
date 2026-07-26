#!/bin/bash -e

echo "[INFO] Starting sing-box..."
sing-box run -c /etc/sing-box/config.json &
singbox_pid=$!

until ip link show sb-tun0 >/dev/null 2>&1; do
  sleep 0.2
done

echo "[INFO] Installing TUN interception rules..."
/bin/bash /tun-intercept.sh

wait "$singbox_pid"
