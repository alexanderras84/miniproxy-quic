#!/bin/bash

echo "[INFO] [DynDNSCron] Starting dynamic DNS ACL refresh..."

# Regenerate the client list and allowed IPs
timeout 40s /bin/bash /generateACL.sh
retVal=$?

if [ $retVal -eq 124 ]; then
  echo "[ERROR] [DynDNSCron] generateACL.sh timed out!"
elif [ $retVal -ne 0 ]; then
  echo "[ERROR] [DynDNSCron] generateACL.sh failed with exit code $retVal!"
else
  echo "[INFO] [DynDNSCron] ACL list successfully regenerated."

  echo "[INFO] [DynDNSCron] Applying updated firewall rules..."
  /bin/bash /acl_firewall.sh
fi
