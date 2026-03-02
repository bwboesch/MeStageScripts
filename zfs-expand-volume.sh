#!/bin/bash
set -e
set -u

################################################################################
# ZFS Volume Expansion Script (Hetzner Cloud)
################################################################################
# Dieses Script erweitert den ZFS Pool nach einer Volume-Vergrößerung
# bei Hetzner Cloud. Das Volume ist immer als /dev/sdb eingehängt.
#
# WICHTIG: Vor der Ausführung muss das Volume in der Hetzner Cloud Console
#          vergrößert werden!
#
# Usage: ./zfs-expand-volume.sh [options]
#
# Optionen:
#   --dry-run    Zeigt was ausgeführt würde, ohne Änderungen vorzunehmen
#
# Umgebungsvariablen:
#   DRY_RUN=true  Alternative zum --dry-run Parameter
#
# Voraussetzungen:
# - Volume wurde in Hetzner Cloud vergrößert
# - Volume ist als /dev/sdb gemountet
# - Script wird als root ausgeführt
################################################################################

# Dry-Run Modus (Standard: false)
DRY_RUN="${DRY_RUN:-false}"

# Parameter parsen
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN="true"
            ;;
    esac
done

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Wrapper für destruktive Befehle
run_cmd() {
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Würde ausführen: $*"
        return 0
    else
        "$@"
    fi
}

# Root-Check
if [ "$EUID" -ne 0 ]; then
    log_error "Dieses Script muss als root ausgeführt werden!"
    exit 1
fi

# Konstanten
POOL_NAME="tank"
DEVICE="/dev/sdb"

log_info "ZFS Volume Expansion für Hetzner Cloud"
echo "=================================================="
echo ""

if [ "$DRY_RUN" = "true" ]; then
    log_warning "DRY-RUN MODUS AKTIV - Keine Änderungen werden durchgeführt"
    echo ""
fi

# 1. Prüfe ob ZFS Pool existiert
log_info "Prüfe ZFS Pool '$POOL_NAME'..."
if ! zpool list "$POOL_NAME" &>/dev/null; then
    log_error "ZFS Pool '$POOL_NAME' existiert nicht!"
    log_error "Bitte zuerst ZFS-Setup durchführen."
    exit 1
fi
log_success "ZFS Pool '$POOL_NAME' gefunden"
echo ""

# 2. Prüfe ob Device existiert
log_info "Prüfe Device '$DEVICE'..."
if [ ! -b "$DEVICE" ]; then
    log_error "Device '$DEVICE' nicht gefunden!"
    log_error "Stelle sicher, dass das Hetzner Volume eingehängt ist."
    exit 1
fi
log_success "Device '$DEVICE' gefunden"
echo ""

# 3. Zeige aktuelle Pool-Größe
log_info "Aktuelle Pool-Informationen:"
echo "----------------------------"
zpool list "$POOL_NAME"
echo ""

# 4. Zeige Device-Größe
log_info "Aktuelle Device-Größe:"
echo "----------------------------"
lsblk "$DEVICE" -o NAME,SIZE,TYPE
echo ""

# 5. Bestätigung vom Benutzer
log_warning "WICHTIG: Stelle sicher, dass das Volume in der Hetzner Cloud Console"
log_warning "         bereits vergrößert wurde, bevor du fortfährst!"
echo ""
if [ "$DRY_RUN" != "true" ]; then
    read -p "Möchtest du den Pool jetzt erweitern? (yes/no): " -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Abgebrochen durch Benutzer"
        exit 0
    fi
else
    log_info "[DRY-RUN] Benutzerbestätigung würde hier erfolgen"
    echo ""
fi

# 6. Erstelle Pre-Expansion Snapshot zur Sicherheit
SNAPSHOT_NAME="pre-expand-$(date +%Y%m%d_%H%M%S)"
log_info "Erstelle Sicherheits-Snapshot: $SNAPSHOT_NAME"

if zfs list -t snapshot "${POOL_NAME}/typo3/www@${SNAPSHOT_NAME}" &>/dev/null; then
    log_warning "Snapshot existiert bereits, überspringe..."
else
    run_cmd zfs snapshot -r "${POOL_NAME}/typo3@${SNAPSHOT_NAME}"
    log_success "Snapshot erstellt"
fi
echo ""

# 7. Führe Pool-Expansion durch
log_info "Erweitere ZFS Pool..."
log_info "Befehl: zpool online -e $POOL_NAME $DEVICE"
echo ""

if run_cmd zpool online -e "$POOL_NAME" "$DEVICE"; then
    log_success "Pool erfolgreich erweitert!"
else
    log_error "Fehler bei der Pool-Erweiterung!"
    log_error "Snapshot '$SNAPSHOT_NAME' steht für Rollback zur Verfügung"
    exit 1
fi
echo ""

# 8. Zeige neue Pool-Größe
log_info "Neue Pool-Informationen:"
echo "----------------------------"
zpool list "$POOL_NAME"
echo ""

# 9. Prüfe Pool-Status
log_info "Prüfe Pool-Integrität..."
if zpool status "$POOL_NAME" | grep -q "state: ONLINE"; then
    log_success "Pool ist ONLINE und gesund"
else
    log_warning "Pool-Status sollte überprüft werden:"
    zpool status "$POOL_NAME"
fi
echo ""

# 10. Zeige Dataset-Informationen
log_info "Dataset-Nutzung nach Expansion:"
echo "----------------------------"
zfs list -o name,used,avail,refer,mountpoint "$POOL_NAME" -r
echo ""

# 11. Zusammenfassung
echo "=================================================="
if [ "$DRY_RUN" = "true" ]; then
    log_warning "DRY-RUN abgeschlossen - Keine Änderungen wurden durchgeführt"
else
    log_success "ZFS Pool-Expansion erfolgreich abgeschlossen!"
fi
echo ""
log_info "Nächste Schritte:"
echo "  1. Überprüfe die neuen Pool-Größen oben"
echo "  2. Teste ob die Datasets korrekt funktionieren"
echo "  3. Optional: Lösche Sicherheits-Snapshot nach erfolgreicher Verifikation:"
echo "     zfs destroy -r ${POOL_NAME}/typo3@${SNAPSHOT_NAME}"
echo ""
log_info "Pool-Status jederzeit prüfbar mit:"
echo "  zpool status $POOL_NAME"
echo "  zpool list $POOL_NAME"
echo "  zfs list -r $POOL_NAME"
echo "=================================================="