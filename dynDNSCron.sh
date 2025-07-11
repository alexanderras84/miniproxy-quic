#!/bin/bash
echo "[INFO] [DynDNSCron] Starting dynamic DNS ACL refresh..."

# Run the ACL generator with a timeout
timeout 40s /bin/bash /generateACL.sh
retVal=$?

if [ $retVal -eq 124 ]; then
  echo "[ERROR] [DynDNSCron] generateACL.sh timed out!"
  exit 1
elif [ $retVal -ne 0 ]; then
  echo "[ERROR] [DynDNSCron] generateACL.sh failed with exit code $retVal!"
  exit 1
else
  echo "[INFO] [DynDNSCron] ACL successfully regenerated."

  echo "[INFO] [DynDNSCron] Restarting sing-box to apply new ACL..."

  # Gracefully stop existing sing-box instances (send SIGTERM)
  pkill -f 'sing-box run'

  # Wait a moment for graceful shutdown
  sleep 2

  # Start sing-box in background as the miniproxy user (optional, if needed)
  # If running as root in container, you might want: su-exec miniproxy sing-box ...
  sing-box run -c /etc/sing-box/config.json &

  echo "[INFO] [DynDNSCron] sing-box restarted."
fi
