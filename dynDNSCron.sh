#!/bin/bash
echo "[INFO] [DynDNSCron] Regenerating ACL and config..."

timeout 40s /bin/bash /generateACL.sh
retVal=$?
if [ $retVal -eq 124 ]; then
  echo "[ERROR] [DynDNSCron] generateACL.sh timed out!"
elif [ $retVal -ne 0 ]; then
  echo "[ERROR] [DynDNSCron] generateACL.sh failed with exit code $retVal!"
else
  echo "[INFO] [DynDNSCron] ACL and config regenerated!"
fi

echo "[INFO] [DynDNSCron] Please restart sing-box to apply changes."
