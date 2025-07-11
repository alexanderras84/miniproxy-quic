#!/bin/bash -e

echo "[INFO] Generating ACL..."
set +e
source generateACL.sh
set -e

if [ "$DYNDNS_CRON_ENABLED" = true ];
then
  echo "[INFO] DynDNS Address in ALLOWED_CLIENTS detected => Enable cron job"
  echo "$DYNDNS_CRON_SCHEDULE /bin/bash /dynDNSCron.sh" > /etc/miniproxy/dyndns.cron
  supercronic /etc/miniproxy/dyndns.cron &
fi

echo "[INFO] Starting nginx.."
nginx
nginx_processId=$!

sleep 5

echo "==================================================================="
echo "[INFO] Miniproxy started"
echo "==================================================================="
wait $nginx_processId
