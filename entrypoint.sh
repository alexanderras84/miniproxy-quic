#!/bin/bash -e

echo "[INFO] Generating allowlist..."
set +e
source /generateacl.sh
set -e

# -------------------------------------------------------------------
# DynDNS Cron Handling
# -------------------------------------------------------------------
if [ "$DYNDNS_CRON_ENABLED" = true ]; then
  echo "[INFO] DynDNS detected in allowlist => enabling DynDNS cron job"
  echo "$DYNDNS_CRON_SCHEDULE /bin/bash /dyndnscron.sh" > /etc/miniproxy/dyndns.cron
  supercronic /etc/miniproxy/dyndns.cron &
fi

# -------------------------------------------------------------------
# Start sing-box
# -------------------------------------------------------------------
echo "[INFO] Starting sing-box..."
sing-box run -c /etc/sing-box/config.json &
singbox_pid=$!

echo "==================================================================="
echo "[INFO] Miniproxy QUIC started successfully"
echo "==================================================================="

# Keep container alive on sing-box PID
wait $singbox_pid
