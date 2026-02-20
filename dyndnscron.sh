#!/bin/bash
set -euxo pipefail

echo "[INFO] [DynDNSCron] Regenerating ACL..."

# Explicit PATH for cron environment
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Log start time
echo "[INFO] Starting at $(date)"

# Source generateacl.sh instead of running it, with a timeout wrapper
timeout 40s bash -c 'source /generateacl.sh'
retVal=$?

if [ $retVal -eq 124 ]; then
  echo "[ERROR] [DynDNSCron] generateacl.sh timed out!"
elif [ $retVal -ne 0 ]; then
  echo "[ERROR] [DynDNSCron] generateacl.sh failed with exit code $retVal!"
else
  echo "[INFO] [DynDNSCron] ACL regenerated successfully!"
fi

echo "[INFO] Finished at $(date)"
