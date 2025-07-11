#!/bin/bash -e

echo "[INFO] Generating ACL and config..."
set +e
/bin/bash /generateACL.sh
set -e

if [ "$DYNDNS_CRON_ENABLED" = true ]; then
  echo "[INFO] DynDNS detected — enabling cron job"
  echo "$DYNDNS_CRON_SCHEDULE /bin/bash /dynDNSCron.sh" > /etc/miniproxy/dyndns.cron
  supercronic /etc/miniproxy/dyndns.cron &
fi

echo "[INFO] Starting sing-box..."
sing-box run -c /etc/sing-box/config.json
