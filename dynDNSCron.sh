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
fi

echo "[INFO] [DynDNSCron] ACL successfully regenerated."

# Apply new firewall ACL rules
if /etc/miniproxy/acl_firewall.sh; then
  echo "[INFO] [DynDNSCron] Firewall ACL rules applied successfully."
else
  echo "[ERROR] [DynDNSCron] Failed to apply firewall ACL rules!"
  exit 1
fi
