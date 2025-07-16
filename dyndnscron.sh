#!/bin/bash
echo "[INFO] [DynDNSCron] Regenerating ACL..."

# Apply timeout to the generateacl.sh script (adjust as needed)
timeout 40s /bin/bash /generateacl.sh
retVal=$?
if [ $retVal -eq 124 ]; then
  echo "[ERROR] [DynDNSCron] generateacl.sh timed out!"
elif [ $retVal -ne 0 ]; then
  echo "[ERROR] [DynDNSCron] generateacl.sh failed with exit code $retVal!"
else
  echo "[INFO] [DynDNSCron] ACL regenerated!"
fi