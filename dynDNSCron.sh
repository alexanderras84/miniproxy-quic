#!/bin/bash
echo "[INFO] [DynDNSCron] Starting dynamic DNS ACL refresh..."

timeout 40s /bin/bash /generateACL.sh
retVal=$?

if [ $retVal -eq 124 ]; then
  echo "[ERROR] [DynDNSCron] generateACL.sh timed out!"
elif [ $retVal -ne 0 ]; then
  echo "[ERROR] [DynDNSCron] generateACL.sh failed with exit code $retVal!"
else
  echo "[INFO] [DynDNSCron] ACL successfully regenerated."

  echo "[INFO] [DynDNSCron] Applying firewall ACL updates..."
  timeout 20s /bin/bash /acl_firewall.sh
  fwRetVal=$?

  if [ $fwRetVal -eq 0 ]; then
    echo "[INFO] [DynDNSCron] Firewall ACL updated successfully."
  else
    echo "[ERROR] [DynDNSCron] Firewall ACL update failed with exit code $fwRetVal."
  fi
fi
