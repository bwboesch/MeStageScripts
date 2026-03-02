# MeStageScripts

Deployment- und Management-Skripte für die **Micro-Epsilon** Webserver-Infrastruktur. Die Skripte verwalten das TYPO3-basierte Webprojekt über mehrere Umgebungen hinweg (Stage, Live, Fallback, China) und stellen ZFS-Snapshot-basierte Backup- und Rollback-Funktionen bereit.

## Architektur-Übersicht

```
┌──────────────┐    deploy2live.sh     ┌──────────────┐
│  Stage-Server│ ───────────────────►  │  Live-Server  │
│  (lokal)     │    rsync + mysqldump  │  (Hetzner)    │
└──────┬───────┘                       └───────┬───────┘
       │                                       │
       │  sync2china.sh                        │  live2fallback.sh
       │  rsync + mysqldump                    │  (auf Remote)
       ▼                                       ▼
┌──────────────┐                       ┌──────────────┐
│ China-Server │                       │Fallback-Server│
│ (Huawei Cloud│                       │  (Hetzner)    │
└──────────────┘                       └───────────────┘
```

### Server

| Rolle      | Host               | Beschreibung                              |
|------------|--------------------|-------------------------------------------|
| Stage      | lokal              | Staging-Umgebung, Quelle für Deployments  |
| Live       | `46.224.118.2`     | Produktiv-Server (Hetzner)                |
| Fallback   | `46.224.118.2`     | Fallback-Instanz auf dem gleichen Server  |
| China      | `120.46.134.70`    | China-Mirror (Huawei Cloud)               |

### DNS-Umschaltung (ISPConfig)

Web-Aliase werden über die ISPConfig-API zwischen Live und Fallback verschoben:

| Domain                                  | Rolle    |
|-----------------------------------------|----------|
| `mep-www-live-01.micro-epsilon.de`      | Live     |
| `mep-www-fallback-01.micro-epsilon.de`  | Fallback |
| `mep-www-stage-01.micro-epsilon.de`     | Stage    |
| `mep-www-dev-01.micro-epsilon.de`       | Dev      |

---

## Setup

```bash
./setup.sh
```

Erstellt ein Python-venv, installiert Abhängigkeiten (`requests`, `zeep`) und prüft ob `config.json` vorhanden ist.

### Konfiguration

`config.json` (aus `config.example.json` erstellen):

```json
{
    "ispconfig_url": "https://your-server/remote/index.php",
    "ispconfig_user": "your_ispconfig_user",
    "ispconfig_pass": "your_ispconfig_password",
    "bunny_net_api_key": "your_bunny_net_api_key"
}
```

Alternativ über Umgebungsvariablen: `ISPCONFIG_URL`, `ISPCONFIG_USER`, `ISPCONFIG_PASS`, `BUNNY_API_KEY`.

---

## Skript-Referenz

### Deployment

#### `deploy_cron.sh` — Automatisches Deployment (Cron-Job)

Hauptskript, das per Cron ausgeführt wird. Orchestriert den gesamten Deploy-Prozess und sendet Status-Mails.

```bash
# Wird typischerweise per Cron aufgerufen
/root/bin/deploy_cron.sh
```

**Ablauf:**
1. Prüft Lock-Datei (`/var/lock/deploy_cron.lock`) — verhindert parallele Ausführung via `flock`
2. Prüft Flag-Datei (`manualsync`) — wenn vorhanden, wird Deploy übersprungen und Flag gelöscht
3. Führt `deploy2live.sh` aus
4. Führt `sync2china.sh` aus
5. Sendet Status-Mail an konfigurierte Empfänger via `swaks`

**Besonderheiten:**
- Signal-Handler für SIGTERM/SIGINT/SIGHUP/SIGPIPE — sendet Notfall-Mail bei Abbruch
- EXIT-Trap garantiert Mailversand auch bei unerwartetem Abbruch
- Detailliertes Reporting mit Start-/Endzeit und Dauer pro Schritt

**Flag-Datei:** Wenn `/var/www/.../manualsync` existiert, wird kein Deploy durchgeführt. Die Datei wird automatisch gelöscht.

#### `deploy_cron_old.sh` — Ältere Version des Cron-Deploy

Vereinfachte Version ohne Locking, ohne Signal-Handler und mit weniger Empfängern. Wird als Referenz aufbewahrt.

#### `deploy2live.sh` — Stage nach Live deployen

```bash
./deploy2live.sh
```

**Ablauf:**
1. Erstellt ZFS-Snapshots auf dem Remote-Server (`pre-deploy`)
2. Synchronisiert Dateien via `rsync` (mit Ausnahmen für `typo3temp`, `LocalConfiguration.php`, `sites`, `.htaccess`, `.htpasswd`)
3. Erstellt MySQL-Dump (exklusive Session-, Log-, Cache-Tabellen und weitere)
4. Überträgt und importiert Dump auf dem Live-Server
5. Setzt Dateibesitzer (`web626`)
6. Führt TYPO3-Kommandos aus: `dumpautoload`, `cache:flush -g system`
7. Leert Bunny.net CDN-Cache

**Ausgeschlossene Tabellen:** `be_users`, `be_sessions`, `fe_sessions`, `sys_history`, `sys_log`, `tx_googlejobs_domain_model_application`, `tx_powermail_domain_model_answer`, `tx_staticfilecache_queue`, `tx_webp_failed`, sowie alle `cache_*`-Tabellen.

**Log:** `/var/log/deploy2live.log`

#### `sync2china.sh` — Stage nach China synchronisieren

```bash
./sync2china.sh
```

Identischer Ablauf wie `deploy2live.sh`, aber mit China-Server als Ziel:
- Ziel: `120.46.134.70` (`me-staging.lautundklar.dev`)
- DB-Ziel: `mecn_admin`
- Dateibesitzer: `me_dev:psaserv`
- Gleiche Tabellenausnahmen (ohne `be_users`)

**Log:** `/var/log/sync2china.log`

#### `live2fallback.sh` — Live-System auf Fallback kopieren

```bash
./live2fallback.sh
```

Ruft `/root/bin/live2fallback.sh` auf dem Remote-Server (`46.224.118.2`) via SSH auf. Kopiert die aktuelle Live-Instanz auf die Fallback-Instanz.

**Log:** `/var/log/live2fallback.log`

---

### DNS / Alias-Verwaltung (ISPConfig)

#### `get_web_aliases.py` — Web-Aliase auslesen

```bash
source venv/bin/activate
./get_web_aliases.py                        # Alle Aliase anzeigen
./get_web_aliases.py example.com            # Nach Domain filtern
./get_web_aliases.py --json                 # JSON-Ausgabe
```

Verbindet sich mit der ISPConfig JSON-API und listet alle Web-Aliase auf, gruppiert nach den vier Parent-Domains (Live, Stage, Dev, Fallback).

#### `switch_to_fallback.py` — Aliase auf Fallback umschalten

```bash
./switch_to_fallback.py              # Dry-Run (nur Vorschau)
./switch_to_fallback.py --execute    # Änderungen ausführen
```

Verschiebt alle Web-Aliase von `mep-www-live-01` auf `mep-www-fallback-01` über die ISPConfig-API. Standardmäßig Dry-Run.

#### `switch_to_live.py` — Aliase zurück auf Live umschalten

```bash
./switch_to_live.py              # Dry-Run (nur Vorschau)
./switch_to_live.py --execute    # Änderungen ausführen
```

Gegenstück zu `switch_to_fallback.py` — verschiebt Aliase von `mep-www-fallback-01` zurück auf `mep-www-live-01`.

---

### CDN

#### `wipe_bunny.net_cache.py` — Bunny.net CDN-Cache leeren

```bash
./wipe_bunny.net_cache.py
```

Leert den Cache aller Bunny.net Pull-Zones. Wird automatisch am Ende von `deploy2live.sh` aufgerufen.

**Konfiguration:** API-Key aus `BUNNY_API_KEY` Umgebungsvariable oder `config.json` (`bunny_net_api_key`).

---

### Backup

#### `borgmatic-backup.sh` — Borgmatic Backup ausführen

```bash
./borgmatic-backup.sh create           # Backup erstellen
./borgmatic-backup.sh prune            # Alte Backups aufräumen
./borgmatic-backup.sh -v 2 create      # Mit Verbose-Level
```

Wrapper für `borgmatic`, unterstützt die Operationen `create` und `prune` mit optionalem Verbose-Parameter.

---

### ZFS-Snapshot-Verwaltung

Alle ZFS-Skripte arbeiten mit dem Pool `tank` und den Datasets `typo3/www` (DocumentRoot) und `typo3/mysql` (Datenbank). Alle unterstützen `--dry-run`.

#### `zfs-snapshot-create.sh` — Snapshot erstellen

```bash
./zfs-snapshot-create.sh                        # Standard (Name: manual-manual-TIMESTAMP)
./zfs-snapshot-create.sh "before-major-update"  # Mit Beschreibung
./zfs-snapshot-create.sh --dry-run "test"       # Dry-Run
```

**Ablauf:**
1. Prüft ZFS-Pool-Status
2. Stoppt MySQL für konsistenten Snapshot
3. Erstellt Snapshots für `typo3/www` und `typo3/mysql`
4. Startet MySQL neu und verifiziert

#### `zfs-snapshot-list.sh` — Snapshots anzeigen

```bash
./zfs-snapshot-list.sh
```

Zeigt alle Snapshots beider Datasets mit Speicherverbrauch und Erstellungsdatum.

#### `zfs-snapshot-rollback.sh` — Rollback auf einen Snapshot

```bash
./zfs-snapshot-rollback.sh <snapshot-name>
./zfs-snapshot-rollback.sh --dry-run <snapshot-name>
```

**Ablauf:**
1. Prüft ob Snapshot existiert
2. Erstellt Sicherheits-Snapshot des aktuellen Zustands (`before-rollback-TIMESTAMP`)
3. Stoppt Apache und MySQL
4. Führt Rollback für beide Datasets durch
5. Startet MySQL und Apache neu
6. Verifiziert Service-Status

#### `zfs-snapshot-cleanup.sh` — Alte Snapshots löschen

```bash
./zfs-snapshot-cleanup.sh              # Behält die 10 neuesten
./zfs-snapshot-cleanup.sh 5            # Behält die 5 neuesten
./zfs-snapshot-cleanup.sh --dry-run    # Dry-Run
```

Löscht alte Snapshots pro Dataset und behält die N neuesten (Standard: 10). Erfordert Bestätigung.

#### `zfs-expand-volume.sh` — ZFS Pool nach Volume-Vergrößerung erweitern

```bash
./zfs-expand-volume.sh              # Interaktiv mit Bestätigung
./zfs-expand-volume.sh --dry-run    # Dry-Run
```

Erweitert den ZFS-Pool `tank` nach einer Volume-Vergrößerung in der Hetzner Cloud Console. Erstellt vorher einen Sicherheits-Snapshot und prüft Pool-Integrität.

---

## Typischer Workflow

### Reguläres Deployment (automatisch)

```
Cron → deploy_cron.sh → deploy2live.sh → sync2china.sh → Status-Mail
```

### Manuelles Deploy unterdrücken

```bash
# Flag-Datei anlegen
touch /var/www/clients/client152/web625/home/s152_microepsilon_sta/manualsync
# → Nächster Cron-Lauf überspringt Deploy und löscht Flag
```

### Deployment mit Fallback-Umschaltung

```bash
# 1. Traffic auf Fallback umleiten
./switch_to_fallback.py --execute

# 2. Warten bis DNS propagiert (~15s)
sleep 15

# 3. Deploy durchführen
./deploy2live.sh

# 4. Traffic zurück auf Live
./switch_to_live.py --execute
```

### Rollback bei Problemen

```bash
# Snapshots anzeigen
./zfs-snapshot-list.sh

# Rollback auf pre-deploy Snapshot
./zfs-snapshot-rollback.sh pre-deploy-20250127_143022
```

---

## Voraussetzungen

- **Server:** Root-Zugriff auf Stage-Server
- **SSH:** Schlüsselbasierter Zugriff auf Live- und China-Server
- **Software:** `rsync`, `mysql`/`mysqldump`, `swaks` (Mail), `zfs`/`zpool`, `borgmatic`
- **Python:** 3.x mit `requests` und `zeep` (via venv)
- **ISPConfig:** API-Zugang für Alias-Verwaltung
- **Bunny.net:** API-Key für CDN-Cache-Management
