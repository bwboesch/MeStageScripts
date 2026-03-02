#!/bin/bash
# ZFS-Snapshots anzeigen
# Verwendung: ./zfs-snapshot-list.sh

set -e
set -u

# Konfiguration
ZFS_POOL="tank"
DATASET_WWW="typo3/www"
DATASET_MYSQL="typo3/mysql"

echo "========================================="
echo "ZFS Snapshot Übersicht"
echo "========================================="
echo ""

# Überprüfe ZFS-Pool
if ! zpool list "${ZFS_POOL}" >/dev/null 2>&1; then
    echo "ERROR: ZFS Pool '${ZFS_POOL}' nicht gefunden!"
    exit 1
fi

# Zeige Pool-Status
echo "Pool-Status:"
zpool list "${ZFS_POOL}" | tail -n +2
echo ""

# Zeige Snapshots für DocumentRoot
echo "========================================="
echo "Snapshots für DocumentRoot (${ZFS_POOL}/${DATASET_WWW}):"
echo "========================================="
WWW_SNAPSHOTS=$(zfs list -t snapshot -o name,used,creation -s creation "${ZFS_POOL}/${DATASET_WWW}" 2>/dev/null | tail -n +2)
if [ -z "${WWW_SNAPSHOTS}" ]; then
    echo "  Keine Snapshots vorhanden"
else
    echo "${WWW_SNAPSHOTS}"
fi
echo ""

# Zeige Snapshots für MySQL
echo "========================================="
echo "Snapshots für MySQL (${ZFS_POOL}/${DATASET_MYSQL}):"
echo "========================================="
MYSQL_SNAPSHOTS=$(zfs list -t snapshot -o name,used,creation -s creation "${ZFS_POOL}/${DATASET_MYSQL}" 2>/dev/null | tail -n +2)
if [ -z "${MYSQL_SNAPSHOTS}" ]; then
    echo "  Keine Snapshots vorhanden"
else
    echo "${MYSQL_SNAPSHOTS}"
fi
echo ""

# Zeige zusammengefasste Statistiken
echo "========================================="
echo "Zusammenfassung:"
echo "========================================="

WWW_COUNT=$(zfs list -t snapshot -H "${ZFS_POOL}/${DATASET_WWW}" 2>/dev/null | wc -l)
MYSQL_COUNT=$(zfs list -t snapshot -H "${ZFS_POOL}/${DATASET_MYSQL}" 2>/dev/null | wc -l)

echo "Anzahl Snapshots für DocumentRoot: ${WWW_COUNT}"
echo "Anzahl Snapshots für MySQL: ${MYSQL_COUNT}"

# Berechne Gesamtgröße der Snapshots
WWW_USED=$(zfs list -t snapshot -H -o used "${ZFS_POOL}/${DATASET_WWW}" 2>/dev/null | awk '{sum+=$1} END {print sum}')
MYSQL_USED=$(zfs list -t snapshot -H -o used "${ZFS_POOL}/${DATASET_MYSQL}" 2>/dev/null | awk '{sum+=$1} END {print sum}')

if [ -n "${WWW_USED}" ] && [ "${WWW_USED}" -gt 0 ]; then
    echo "Speicherplatz durch DocumentRoot-Snapshots: $(numfmt --to=iec-i --suffix=B ${WWW_USED} 2>/dev/null || echo \"${WWW_USED} Bytes\")"
fi

if [ -n "${MYSQL_USED}" ] && [ "${MYSQL_USED}" -gt 0 ]; then
    echo "Speicherplatz durch MySQL-Snapshots: $(numfmt --to=iec-i --suffix=B ${MYSQL_USED} 2>/dev/null || echo \"${MYSQL_USED} Bytes\")"
fi

echo ""
echo "========================================="
echo "Aktionen:"
echo "========================================="
echo "Neuen Snapshot erstellen:"
echo "  ./zfs-snapshot-create.sh [description]"
echo ""
echo "Zu Snapshot zurückkehren:"
echo "  ./zfs-snapshot-rollback.sh <snapshot-name>"
echo ""
echo "Alte Snapshots löschen:"
echo "  ./zfs-snapshot-cleanup.sh"
echo "========================================="