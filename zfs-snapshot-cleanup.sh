#!/bin/bash

################################################################################
# ZFS-Snapshot Cleanup - Alte Snapshots löschen
################################################################################
# Verwendung: ./zfs-snapshot-cleanup.sh [options] [keep_count]
#
# Optionen:
#   --dry-run    Zeigt was ausgeführt würde, ohne Änderungen vorzunehmen
#
# Umgebungsvariablen:
#   DRY_RUN=true  Alternative zum --dry-run Parameter
#
# Standard: Behält die 10 neuesten Snapshots
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
KEEP_COUNT="${1:-10}"

echo "========================================="
echo "ZFS Snapshot Cleanup"
echo "========================================="

if [ "$DRY_RUN" = "true" ]; then
    log_warning "DRY-RUN MODUS AKTIV - Keine Änderungen werden durchgeführt"
    echo ""
fi

echo "Behalte die ${KEEP_COUNT} neuesten Snapshots pro Dataset"
echo ""

# Überprüfe ZFS-Pool
if ! zpool list "${ZFS_POOL}" >/dev/null 2>&1; then
    echo "ERROR: ZFS Pool '${ZFS_POOL}' nicht gefunden!"
    exit 1
fi

# Funktion zum Cleanup eines Datasets
cleanup_dataset() {
    local DATASET="$1"
    local FULL_PATH="${ZFS_POOL}/${DATASET}"
    
    echo "========================================="
    echo "Dataset: ${FULL_PATH}"
    echo "========================================="
    
    # Zähle Snapshots
    TOTAL_SNAPSHOTS=$(zfs list -t snapshot -H -o name "${FULL_PATH}" 2>/dev/null | wc -l)
    
    if [ "${TOTAL_SNAPSHOTS}" -eq 0 ]; then
        echo "  Keine Snapshots vorhanden"
        return 0
    fi
    
    echo "Gefundene Snapshots: ${TOTAL_SNAPSHOTS}"
    
    if [ "${TOTAL_SNAPSHOTS}" -le "${KEEP_COUNT}" ]; then
        echo "  Alle Snapshots werden behalten (${TOTAL_SNAPSHOTS} <= ${KEEP_COUNT})"
        return 0
    fi
    
    # Berechne, wie viele gelöscht werden müssen
    DELETE_COUNT=$((TOTAL_SNAPSHOTS - KEEP_COUNT))
    echo "Zu löschen: ${DELETE_COUNT} Snapshot(s)"
    echo ""
    
    # Liste die zu löschenden Snapshots
    echo "Folgende Snapshots werden gelöscht:"
    zfs list -t snapshot -H -o name -s creation "${FULL_PATH}" 2>/dev/null | head -n "${DELETE_COUNT}"
    echo ""
    
    # Bestätigung erforderlich (außer im Dry-Run Modus)
    if [ "$DRY_RUN" != "true" ]; then
        echo "Fortfahren? (yes/no)"
        read -r CONFIRM

        if [ "${CONFIRM}" != "yes" ]; then
            echo "  Cleanup für ${FULL_PATH} übersprungen"
            return 0
        fi
    fi

    # Lösche alte Snapshots
    DELETED=0
    while IFS= read -r SNAPSHOT; do
        echo "  Lösche: ${SNAPSHOT}"
        if run_cmd zfs destroy "${SNAPSHOT}"; then
            DELETED=$((DELETED + 1))
        else
            echo "    WARNING: Konnte ${SNAPSHOT} nicht löschen"
        fi
    done < <(zfs list -t snapshot -H -o name -s creation "${FULL_PATH}" 2>/dev/null | head -n "${DELETE_COUNT}")

    log_success "${DELETED} Snapshot(s) gelöscht"
    echo ""
}

# Cleanup für DocumentRoot
cleanup_dataset "${DATASET_WWW}"

# Cleanup für MySQL
cleanup_dataset "${DATASET_MYSQL}"

# Zeige finalen Status
echo "========================================="
echo "Cleanup abgeschlossen - Aktueller Status:"
echo "========================================="

WWW_REMAINING=$(zfs list -t snapshot -H "${ZFS_POOL}/${DATASET_WWW}" 2>/dev/null | wc -l)
MYSQL_REMAINING=$(zfs list -t snapshot -H "${ZFS_POOL}/${DATASET_MYSQL}" 2>/dev/null | wc -l)

echo "Verbleibende Snapshots:"
echo "  DocumentRoot (${ZFS_POOL}/${DATASET_WWW}): ${WWW_REMAINING}"
echo "  MySQL (${ZFS_POOL}/${DATASET_MYSQL}): ${MYSQL_REMAINING}"

# Zeige Speicherplatz-Ersparnis
echo ""
echo "Disk-Space-Status:"
zpool list "${ZFS_POOL}" | tail -n +2

echo ""
echo "========================================="
echo "Snapshots anzeigen:"
echo "  ./zfs-snapshot-list.sh"
echo "========================================="