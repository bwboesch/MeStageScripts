#!/bin/bash

set -euo pipefail

# Configurations
REMOTE_USER="root"
REMOTE_USER2="me_dev"
REMOTE_HOST="120.46.134.70"
REMOTE_PATH="/var/www/vhosts/lautundklar.dev/me-staging.lautundklar.dev/"
LOCAL_PATH="/var/www/clients/client152/web625/web/"
DB_NAME="c152_typo3db"
DB_TARGET="mecn_admin"
DUMP_FILE="/tmp/me_staging.sql"
LOG_FILE="/var/log/sync2china.log"

# Tabellen, die ausgeschlossen werden sollen
EXCLUDE_TABLES=(
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

echo "$(date) Starting file sync..."
#rsync -avz --delete --exclude 'typo3temp/*' --exclude 'typo3conf/LocalConfiguration.php' --exclude 'typo3conf/sites/*' "${LOCAL_PATH}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
rsync -avz --chown=me_dev:psaserv --delete --exclude 'typo3temp/*' --exclude 'typo3conf/sites/*' --exclude 'typo3conf/LocalConfiguration.php' "${LOCAL_PATH}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
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

echo "starting typo3 dumpautoload"
ssh "${REMOTE_USER2}@${REMOTE_HOST}" "/var/www/vhosts/lautundklar.dev/.phpenv/shims/php /var/www/vhosts/lautundklar.dev/me-staging.lautundklar.dev/typo3/sysext/core/bin/typo3 dumpautoload"

echo "starting typo3 cache:flush -g system"
ssh "${REMOTE_USER2}@${REMOTE_HOST}" "/var/www/vhosts/lautundklar.dev/.phpenv/shims/php /var/www/vhosts/lautundklar.dev/me-staging.lautundklar.dev/typo3/sysext/core/bin/typo3 cache:flush -g system"


echo "$(date) Script execution finished successfully."
