#!/bin/bash

################################################################################
# ZFS-Snapshot Rollback
################################################################################
# Verwendung: ./zfs-snapshot-rollback.sh [options] <snapshot-name>
#
# Optionen:
#   --dry-run    Zeigt was ausgeführt würde, ohne Änderungen vorzunehmen
#
# Umgebungsvariablen:
#   DRY_RUN=true  Alternative zum --dry-run Parameter
#
# Beispiel: ./zfs-snapshot-rollback.sh pre-deploy-20250127_143022
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
APACHE_SERVICE="apache2"

# Parameter überprüfen
if [ $# -ne 1 ]; then
    echo "ERROR: Snapshot-Name erforderlich!"
    echo "Verwendung: $0 <snapshot-name>"
    echo ""
    echo "Verfügbare Snapshots anzeigen:"
    echo "  ./zfs-snapshot-list.sh"
    exit 1
fi

SNAPSHOT_NAME="$1"

echo "========================================="
echo "ZFS Snapshot Rollback"
echo "========================================="

if [ "$DRY_RUN" = "true" ]; then
    log_warning "DRY-RUN MODUS AKTIV - Keine Änderungen werden durchgeführt"
    echo ""
fi

echo "WARNUNG: Rollback überschreibt aktuelle Daten!"
echo "Snapshot: ${SNAPSHOT_NAME}"
echo ""
echo "Datasets werden zurückgesetzt:"
echo "  - ${ZFS_POOL}/${DATASET_WWW}"
echo "  - ${ZFS_POOL}/${DATASET_MYSQL}"
echo ""

if [ "$DRY_RUN" != "true" ]; then
    echo "Fortfahren? (yes/no)"
    read -r CONFIRM

    if [ "${CONFIRM}" != "yes" ]; then
        echo "Rollback abgebrochen."
        exit 0
    fi
fi

# Überprüfe, ob Snapshots existieren
echo ""
echo "[1/8] Überprüfe Snapshot-Existenz..."
if ! zfs list -t snapshot "${ZFS_POOL}/${DATASET_WWW}@${SNAPSHOT_NAME}" >/dev/null 2>&1; then
    echo "ERROR: Snapshot ${ZFS_POOL}/${DATASET_WWW}@${SNAPSHOT_NAME} nicht gefunden!"
    echo ""
    echo "Verfügbare Snapshots:"
    zfs list -t snapshot -o name "${ZFS_POOL}/${DATASET_WWW}" 2>/dev/null || echo "  Keine vorhanden"
    exit 1
fi

if ! zfs list -t snapshot "${ZFS_POOL}/${DATASET_MYSQL}@${SNAPSHOT_NAME}" >/dev/null 2>&1; then
    echo "ERROR: Snapshot ${ZFS_POOL}/${DATASET_MYSQL}@${SNAPSHOT_NAME} nicht gefunden!"
    echo ""
    echo "Verfügbare Snapshots:"
    zfs list -t snapshot -o name "${ZFS_POOL}/${DATASET_MYSQL}" 2>/dev/null || echo "  Keine vorhanden"
    exit 1
fi

echo "  ✓ Snapshots gefunden"

# Erstelle Sicherheits-Snapshot des aktuellen Zustands
echo "[2/8] Erstelle Sicherheits-Snapshot vor Rollback..."
SAFETY_SNAPSHOT="before-rollback-$(date +%Y%m%d_%H%M%S)"
run_cmd zfs snapshot "${ZFS_POOL}/${DATASET_WWW}@${SAFETY_SNAPSHOT}"
run_cmd zfs snapshot "${ZFS_POOL}/${DATASET_MYSQL}@${SAFETY_SNAPSHOT}"
log_success "Sicherheits-Snapshot erstellt: ${SAFETY_SNAPSHOT}"

# Stoppe Apache
echo "[3/8] Stoppe Apache-Service..."
run_cmd systemctl stop "${APACHE_SERVICE}"
[ "$DRY_RUN" != "true" ] && sleep 2

# Stoppe MySQL
echo "[4/8] Stoppe MySQL-Service..."
run_cmd systemctl stop "${MYSQL_SERVICE}"
[ "$DRY_RUN" != "true" ] && sleep 2

# Rollback DocumentRoot
echo "[5/8] Rollback DocumentRoot..."
run_cmd zfs rollback -r "${ZFS_POOL}/${DATASET_WWW}@${SNAPSHOT_NAME}"
log_success "DocumentRoot zurückgesetzt"

# Rollback MySQL
echo "[6/8] Rollback MySQL-Datenbank..."
run_cmd zfs rollback -r "${ZFS_POOL}/${DATASET_MYSQL}@${SNAPSHOT_NAME}"
log_success "MySQL-Datenbank zurückgesetzt"

# Starte MySQL
echo "[7/8] Starte MySQL-Service..."
run_cmd systemctl start "${MYSQL_SERVICE}"
if [ "$DRY_RUN" != "true" ]; then
    sleep 3
    if ! systemctl is-active --quiet "${MYSQL_SERVICE}"; then
        log_error "MySQL-Service konnte nicht gestartet werden!"
        echo "Versuche manuelle Wiederherstellung..."
        exit 1
    fi
fi
log_success "MySQL läuft"

# Starte Apache
echo "[8/8] Starte Apache-Service..."
run_cmd systemctl start "${APACHE_SERVICE}"
if [ "$DRY_RUN" != "true" ]; then
    sleep 2
    if ! systemctl is-active --quiet "${APACHE_SERVICE}"; then
        log_error "Apache-Service konnte nicht gestartet werden!"
        echo "MySQL läuft, aber Apache muss manuell geprüft werden."
        exit 1
    fi
fi
log_success "Apache läuft"

# Verifiziere Services
echo ""
echo "========================================="
echo "Service-Status:"
echo "========================================="
if [ "$DRY_RUN" != "true" ]; then
    systemctl status "${MYSQL_SERVICE}" --no-pager -l | head -n 3
    echo ""
    systemctl status "${APACHE_SERVICE}" --no-pager -l | head -n 3
else
    log_info "[DRY-RUN] Service-Status würde hier angezeigt"
fi

echo ""
echo "========================================="
if [ "$DRY_RUN" = "true" ]; then
    log_warning "DRY-RUN abgeschlossen - Keine Änderungen wurden durchgeführt"
else
    log_success "Rollback erfolgreich abgeschlossen!"
fi
echo "========================================="
echo "Zurückgesetzt auf Snapshot: ${SNAPSHOT_NAME}"
echo "Sicherheits-Snapshot erstellt: ${SAFETY_SNAPSHOT}"
echo ""
echo "WICHTIG: Teste die Website sofort!"
echo ""
echo "Falls Probleme auftreten, zurück zum vorherigen Zustand:"
echo "  ./zfs-snapshot-rollback.sh ${SAFETY_SNAPSHOT}"
echo "========================================="