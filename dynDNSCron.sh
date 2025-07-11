#!/bin/bash
echo "[INFO] [DynDNSCron] Regenerating ACL.."

# Apply timeout to the generateACL.sh script (5 seconds or adjust as needed)
timeout 40s /bin/bash /generateACL.sh
retVal=$?
if [ $retVal -eq 124 ]; then
  echo "[ERROR] [DynDNSCron] generateACL.sh timed out!"
elif [ $retVal -ne 0 ]; then
  echo "[ERROR] [DynDNSCron] generateACL.sh failed with exit code $retVal!"
else
  echo "[INFO] [DynDNSCron] ACL regenerated!"
fi

echo "[INFO] [DynDNSCron] reloading nginx..."
timeout 10s /usr/sbin/nginx -s reload
echo "[INFO] [DynDNSCron] nginx successfully reloaded"
