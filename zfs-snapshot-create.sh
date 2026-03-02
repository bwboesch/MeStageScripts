#!/bin/bash

################################################################################
# ZFS-Snapshot manuell erstellen
################################################################################
# Verwendung: ./zfs-snapshot-create.sh [options] [description]
#
# Optionen:
#   --dry-run    Zeigt was ausgeführt würde, ohne Änderungen vorzunehmen
#
# Umgebungsvariablen:
#   DRY_RUN=true  Alternative zum --dry-run Parameter
#
# Beispiel: ./zfs-snapshot-create.sh "before-major-update"
################################################################################

set -e
set -u

# Dry-Run Modus (Standard: false)
DRY_RUN="${DRY_RUN:-false}"

# Parameter parsen
POSITIONAL_ARGS=()
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN="true"
            ;;
        *)
            POSITIONAL_ARGS+=("$arg")
            ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]:-}"

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging-Funktionen
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Wrapper für destruktive Befehle
run_cmd() {
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Würde ausführen: $*"
        return 0
    else
        "$@"
    fi
}

# Konfiguration
ZFS_POOL="tank"
DATASET_WWW="typo3/www"
DATASET_MYSQL="typo3/mysql"
MYSQL_SERVICE="mysql"

# Snapshot-Name generieren
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DESCRIPTION="${1:-manual}"
SNAPSHOT_NAME="manual-${DESCRIPTION}-${TIMESTAMP}"

echo "========================================="
echo "ZFS Manual Snapshot Creator"
echo "========================================="

if [ "$DRY_RUN" = "true" ]; then
    log_warning "DRY-RUN MODUS AKTIV - Keine Änderungen werden durchgeführt"
    echo ""
fi

echo "Snapshot-Name: ${SNAPSHOT_NAME}"
echo "Datasets: ${ZFS_POOL}/${DATASET_WWW}, ${ZFS_POOL}/${DATASET_MYSQL}"
echo ""

# Überprüfe ZFS-Pool-Status
echo "[1/5] Überprüfe ZFS-Pool-Status..."
if ! zpool list "${ZFS_POOL}" >/dev/null 2>&1; then
    echo "ERROR: ZFS Pool '${ZFS_POOL}' nicht gefunden!"
    exit 1
fi

POOL_HEALTH=$(zpool list -H -o health "${ZFS_POOL}")
if [ "${POOL_HEALTH}" != "ONLINE" ]; then
    echo "WARNING: ZFS Pool Status ist ${POOL_HEALTH} (nicht ONLINE)"
    echo "Fortfahren? (yes/no)"
    read -r CONTINUE
    if [ "${CONTINUE}" != "yes" ]; then
        echo "Abgebrochen."
        exit 1
    fi
fi

# MySQL stoppen für konsistenten DB-Snapshot
echo "[2/5] Stoppe MySQL-Service..."
run_cmd systemctl stop "${MYSQL_SERVICE}"

# Warte kurz, damit alle Writes abgeschlossen sind
[ "$DRY_RUN" != "true" ] && sleep 2

# Erstelle Snapshots
echo "[3/5] Erstelle ZFS-Snapshots..."
run_cmd zfs snapshot "${ZFS_POOL}/${DATASET_WWW}@${SNAPSHOT_NAME}"
log_success "Snapshot erstellt: ${ZFS_POOL}/${DATASET_WWW}@${SNAPSHOT_NAME}"

run_cmd zfs snapshot "${ZFS_POOL}/${DATASET_MYSQL}@${SNAPSHOT_NAME}"
log_success "Snapshot erstellt: ${ZFS_POOL}/${DATASET_MYSQL}@${SNAPSHOT_NAME}"

# MySQL wieder starten
echo "[4/5] Starte MySQL-Service..."
run_cmd systemctl start "${MYSQL_SERVICE}"

# Warte auf MySQL-Verfügbarkeit
if [ "$DRY_RUN" != "true" ]; then
    sleep 3
    if ! systemctl is-active --quiet "${MYSQL_SERVICE}"; then
        log_error "MySQL-Service konnte nicht gestartet werden!"
        exit 1
    fi
fi

# Überprüfe Snapshot-Erstellung
echo "[5/5] Verifiziere Snapshots..."
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Würde Snapshot-Erstellung verifizieren"
else
    if zfs list -t snapshot | grep -q "${SNAPSHOT_NAME}"; then
        log_success "Snapshots erfolgreich erstellt"
    else
        log_error "Snapshots nicht gefunden!"
        exit 1
    fi
fi

echo ""
echo "========================================="
if [ "$DRY_RUN" = "true" ]; then
    log_warning "DRY-RUN abgeschlossen - Keine Änderungen wurden durchgeführt"
else
    log_success "Snapshot-Erstellung abgeschlossen!"
fi
echo "========================================="
echo "Snapshot-Name: ${SNAPSHOT_NAME}"
echo ""
echo "Snapshots anzeigen:"
echo "  ./zfs-snapshot-list.sh"
echo ""
echo "Zu diesem Snapshot zurückkehren:"
echo "  ./zfs-snapshot-rollback.sh ${SNAPSHOT_NAME}"
echo "========================================="