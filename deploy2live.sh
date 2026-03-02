#!/bin/bash

set -euo pipefail

# Configurations
REMOTE_USER="root"
REMOTE_USER2="s152_innnet_liv"
REMOTE_HOST="46.224.118.2" #mep-www-stage-01.hetzner.innnet.de
REMOTE_PATH="/var/www/clients/client152/web626/web/"
LOCAL_PATH="/var/www/clients/client152/web625/web/"
DB_NAME="c152_typo3db"
DB_TARGET="c152_typo3db"
DUMP_FILE="/tmp/me_staging.sql"
LOG_FILE="/var/log/deploy2live.log"

# Tabellen, die ausgeschlossen werden sollen
EXCLUDE_TABLES=(
    "be_users"
    "be_sessions"
    "fe_sessions"
    "sys_history"
    "sys_log"
    "tx_googlejobs_domain_model_application"
    "tx_powermail_domain_model_answer"
    "tx_staticfilecache_queue"
    "tx_webp_failed"
)

# Function to handle errors
function handle_error {
    echo "An error occurred on line $1 while executing $2" | tee -a "$LOG_FILE"
    exit 1
}
trap 'handle_error $LINENO $BASH_COMMAND' ERR

# Redirect stdout and stderr to the log file
exec > >(tee -a "$LOG_FILE") 2>&1

#echo "Switching webaliase to fallback"
#sudo /root/bin/switch_to_fallback.py --execute
#echo "Waiting for 15s. for the alias changes to be deployed to the Live Server"
#sleep 15

echo "$(date) creating ZFS snapshots..."
ssh "${REMOTE_USER}@${REMOTE_HOST}" "/root/bin/zfs-snapshot-create-zerodowntime.sh pre-deploy"
echo "$(date) ZFS snapshots completed..."

#echo "$(date) Moving old Live System to Fallback..."
#ssh "${REMOTE_USER}@${REMOTE_HOST}" "/root/bin/live2fallback.sh"
#echo "$(date) Live2Fallback completed..."

echo "$(date) Starting file sync..."
#rsync -avz --delete --exclude 'typo3temp/*' --exclude 'typo3conf/LocalConfiguration.php' --exclude 'typo3conf/sites/*' "${LOCAL_PATH}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
rsync -avz --delete --exclude 'typo3temp/*' --exclude 'typo3conf/LocalConfiguration.php'  --exclude 'typo3conf/sites/*' --exclude='.htaccess' --exclude='.htpasswd' "${LOCAL_PATH}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
echo "$(date) File sync completed."

# Fetch cache tables and add to exclude list
CACHE_TABLES=$(mysql -Nse "SHOW TABLES LIKE 'cache_%'" "${DB_NAME}")
EXCLUDE_TABLES+=($CACHE_TABLES)

# Create exclude options for mysqldump
EXCLUDE_TABLES_STRING=""
for TABLE in "${EXCLUDE_TABLES[@]}"; do
    EXCLUDE_TABLES_STRING+=" --ignore-table=${DB_NAME}.${TABLE}"
done

echo $EXCLUDE_TABLES_STRING

echo "Starting database dump..."
mysqldump "${DB_NAME}" ${EXCLUDE_TABLES_STRING} |tail +2 > "${DUMP_FILE}"
echo "Database dump completed."

echo "Transferring database dump to remote server..."
rsync -avz -e ssh "${DUMP_FILE}" "${REMOTE_USER}@${REMOTE_HOST}:${DUMP_FILE}"
echo "Database dump transferred."

echo "Importing database dump on remote server..."
ssh "${REMOTE_USER}@${REMOTE_HOST}" "mysql ${DB_TARGET} < ${DUMP_FILE}"
echo "Database import completed."

echo "Cleaning up local dump file..."
rm -f "${DUMP_FILE}"
echo "Cleanup completed."

echo "setting owner on remote server..."
ssh "${REMOTE_USER}@${REMOTE_HOST}" "chown -R web626 /var/www/clients/client152/web626/web"
echo "owner set."

echo "starting typo3 dumpautoload"
ssh "${REMOTE_USER2}@${REMOTE_HOST}" "/var/www/clients/client152/web626/home/s152_innnet_liv/.local/bin/php /var/www/clients/client152/web626/home/s152_innnet_liv/web/typo3/sysext/core/bin/typo3 dumpautoload"

#echo "update typo3 db shema"
#ssh "${REMOTE_USER2}@${REMOTE_HOST}" "/var/www/clients/client152/web626/home/s152_innnet_liv/.local/bin/php /var/www/clients/client152/web626/home/s152_innnet_liv/web/typo3/sysext/core/bin/typo3 database:updateschema"

echo "starting typo3 cache:flush -g system"
ssh "${REMOTE_USER2}@${REMOTE_HOST}" "/var/www/clients/client152/web626/home/s152_innnet_liv/.local/bin/php /var/www/clients/client152/web626/home/s152_innnet_liv/web/typo3/sysext/core/bin/typo3 cache:flush -g system"

#echo "Switching webaliase to fallback"
#/root/bin/switch_to_live.py --execute

echo "Wipe Bunny.net Caches"
/root/bin/wipe_bunny.net_cache.py
echo "Bunny.net caches wiped"

echo "$(date) Script execution finished successfully."
