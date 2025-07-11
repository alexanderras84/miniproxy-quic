#!/bin/bash -e

echo "[INFO] [Entrypoint] Generating ACL and firewall rules..."

# Run ACL and firewall setup
set +e
/bin/bash /generateACL.sh
retVal=$?
set -e

if [ $retVal -ne 0 ]; then
  echo "[ERROR] [Entrypoint] generateACL.sh failed (exit code $retVal)!"
  exit $retVal
fi

# If DynDNS entries were detected, start cron job
if [ "$DYNDNS_CRON_ENABLED" = true ]; then
  echo "[INFO] [Entrypoint] DynDNS detected — enabling cron job..."
  echo "$DYNDNS_CRON_SCHEDULE /bin/bash /dynDNSCron.sh" > /etc/miniproxy/dyndns.cron
  supercronic /etc/miniproxy/dyndns.cron &
fi

echo "[INFO] [Entrypoint] Starting sing-box..."
exec sing-box run -c /etc/sing-box/config.json
