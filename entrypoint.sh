#!/bin/bash -e

echo "[INFO] Generating ACL..."
set +e
source /generateacl.sh
set -e

if [ "$DYNDNS_CRON_ENABLED" = true ]; then
  echo "[INFO] DynDNS Address in ALLOWED_CLIENTS detected => Enable cron job"
  echo "$DYNDNS_CRON_SCHEDULE /bin/bash /dyndnscron.sh" > /etc/miniproxy/dyndns.cron
  supercronic /etc/miniproxy/dyndns.cron &
fi

echo "[INFO] Starting sing-box.."
sing-box run -c /etc/sing-box/config.json &
singbox_pid=$!

sleep 5

echo "==================================================================="
echo "[INFO] Miniproxy QUIC started"
echo "==================================================================="
wait $singbox_pid
