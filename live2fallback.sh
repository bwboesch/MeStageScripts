#!/bin/bash

set -euo pipefail

# Configurations
REMOTE_USER="root"
REMOTE_HOST="46.224.118.2"
LOG_FILE="/var/log/live2fallback.log"

function handle_error {
    echo "An error occurred on line $1 while executing $2" | tee -a "$LOG_FILE"
    exit 1
}

trap 'handle_error $LINENO $BASH_COMMAND' ERR

# Redirect stdout and stderr to the log file
exec > >(tee -a "$LOG_FILE") 2>&1

echo "$(date) Moving old Live System to Fallback..."
ssh "${REMOTE_USER}@${REMOTE_HOST}" "/root/bin/live2fallback.sh"
#echo "$(date) Live2Fallback completed..."

echo "$(date) Script execution finished successfully."
