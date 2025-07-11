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

  echo "[INFO] [DynDNSCron] Updating firewall rules..."
  /bin/bash /acl_firewall.sh

  echo "[INFO] [DynDNSCron] Firewall rules updated."
fi
