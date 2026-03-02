#!/bin/bash
#
# deploy_cron.sh
# Prüft ob manueller Sync aktiv ist und führt ggf. Deploy-Scripte aus.
# Sendet in jedem Fall eine Status-Mail via swaks.
# Verhindert parallele Ausführung via flock.
# Mail wird IMMER gesendet – auch bei Fehlern, Abbruch oder Signalen.
#

# ============================================================
# Locking – verhindert parallele Ausführung
# ============================================================

LOCKFILE="/var/lock/deploy_cron.lock"

exec 200>"$LOCKFILE"
if ! flock -n 200; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️  deploy_cron.sh läuft bereits (Lock: ${LOCKFILE}) – Abbruch."
    exit 1
fi

# Lock wird automatisch freigegeben wenn das Script endet

# ============================================================
# Konfiguration
# ============================================================

# Empfänger (mehrere durch Leerzeichen getrennt)
RECIPIENTS=(
    "bboesch@innnet.de"
    "fp@innnet.de"
    "Lisa.Toa@micro-epsilon.de"
    "Elisabeth.Bieler@micro-epsilon.de"
    "Judith.Schmaus@micro-epsilon.de"
)

# SMTP-Konfiguration
SMTP_SERVER="smtp55.innnet.de"
MAIL_FROM="admin@micro-epsilon.de"

# Betreff-Präfix
SUBJECT_PREFIX="[Deploy]"

# Flag-Datei
FLAGFILE="/var/www/clients/client152/web625/home/s152_microepsilon_sta/manualsync"

# Deploy-Scripte
SCRIPT_LIVE="/root/bin/deploy2live.sh"
SCRIPT_CHINA="/root/bin/sync2china.sh"

# Hostname für die Mail
HOSTNAME=$(hostname -f)

# ============================================================
# Globaler Mail-Status (wird vom Trap ausgewertet)
# ============================================================

MAIL_SENT=0           # Flag: wurde die Mail bereits gesendet?
MAIL_SUBJECT=""       # Betreff (wird im Lauf gesetzt)
MAIL_BODY=""          # Mail-Body (wird im Lauf aufgebaut)
ERRORS=0              # Fehlerzähler
PHASE="Initialisierung"  # Aktuelle Phase für Abbruch-Mails
CAUGHT_SIGNAL=""      # Welches Signal wurde empfangen?

# ============================================================
# Funktionen
# ============================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_ok() {
    log "✅ $*"
}

log_err() {
    log "❌ $*"
}

log_info() {
    log "ℹ️  $*"
}

log_separator() {
    echo "============================================================"
}

send_mail() {
    local subject="$1"
    local body="$2"

    # Schutz gegen doppelten Versand
    if [ "$MAIL_SENT" -eq 1 ]; then
        log_info "Mail wurde bereits gesendet – überspringe."
        return 0
    fi

    local to_list
    to_list=$(IFS=','; echo "${RECIPIENTS[*]}")

    log_info "Sende Mail an: ${to_list}"
    log_info "Betreff: ${SUBJECT_PREFIX} ${subject}"
    log_info "SMTP-Server: ${SMTP_SERVER}"

    swaks \
        --server "$SMTP_SERVER" \
        --from "$MAIL_FROM" \
        --to "$to_list" \
        --header "Subject: ${SUBJECT_PREFIX} ${subject}" \
        --header "Content-Type: text/plain; charset=UTF-8" \
        --body "$body" \
        --silent 2 \
        --timeout 30

    if [ $? -eq 0 ]; then
        log_ok "Mail erfolgreich versendet"
        MAIL_SENT=1
    else
        log_err "Mailversand fehlgeschlagen!"
    fi
}

format_duration() {
    local seconds=$1
    printf '%02d:%02d:%02d' $((seconds/3600)) $(((seconds%3600)/60)) $((seconds%60))
}

run_script() {
    local label="$1"
    local script="$2"
    local output=""
    local rc=0

    PHASE="$label"

    log_separator
    log_info "Starte: ${label}"
    log_info "Script:  ${script}"

    local start_ts=$(date +%s)
    local start_fmt=$(date '+%Y-%m-%d %H:%M:%S')

    if [ ! -f "$script" ]; then
        log_err "Script nicht gefunden: ${script}"
        rc=1
        output="FEHLER: Script nicht gefunden: ${script}"
    elif [ ! -x "$script" ]; then
        log_err "Script nicht ausführbar: ${script}"
        rc=1
        output="FEHLER: Script nicht ausführbar: ${script}"
    else
        log_info "Ausführung läuft..."
        output=$("$script" 2>&1)
        rc=$?
    fi

    local end_ts=$(date +%s)
    local end_fmt=$(date '+%Y-%m-%d %H:%M:%S')
    local duration=$(format_duration $((end_ts - start_ts)))

    if [ $rc -eq 0 ]; then
        log_ok "${label} abgeschlossen (Exit-Code: ${rc}, Dauer: ${duration})"
    else
        log_err "${label} fehlgeschlagen (Exit-Code: ${rc}, Dauer: ${duration})"
        log_err "Ausgabe:"
        echo "$output" | sed 's/^/    /'
    fi

    # Ergebnis in globale Variablen schreiben
    _RESULT_START_FMT="$start_fmt"
    _RESULT_END_FMT="$end_fmt"
    _RESULT_DURATION="$duration"
    _RESULT_RC=$rc
    _RESULT_OUTPUT="$output"
}

# ============================================================
# Signal-Handler – fängt Abbrüche ab
# ============================================================

handle_signal() {
    CAUGHT_SIGNAL="$1"
    log_separator
    log_err "Signal ${CAUGHT_SIGNAL} empfangen – Script wird abgebrochen!"
    # exit löst den EXIT-Trap aus, der die Mail versendet
    exit 128
}

trap 'handle_signal SIGTERM' SIGTERM
trap 'handle_signal SIGINT'  SIGINT
trap 'handle_signal SIGHUP'  SIGHUP
trap 'handle_signal SIGPIPE' SIGPIPE

# ============================================================
# EXIT-Trap – sendet IMMER eine Mail beim Beenden
# ============================================================

cleanup_and_mail() {
    local exit_code=$?

    # Falls die Mail schon regulär gesendet wurde, nichts tun
    if [ "$MAIL_SENT" -eq 1 ]; then
        log_separator
        log_info "deploy_cron.sh beendet (Exit-Code: ${exit_code})"
        log_separator
        return
    fi

    # Mail wurde noch nicht gesendet → Notfall-Mail zusammenbauen
    log_separator
    log_err "Script wurde unerwartet beendet – sende Notfall-Mail"

    local reason=""
    if [ -n "$CAUGHT_SIGNAL" ]; then
        reason="Script wurde durch Signal ${CAUGHT_SIGNAL} abgebrochen."
    elif [ $exit_code -ne 0 ]; then
        reason="Script wurde mit Exit-Code ${exit_code} unerwartet beendet."
    else
        reason="Script wurde beendet bevor die Mail gesendet werden konnte."
    fi

    MAIL_SUBJECT="ABBRUCH während '${PHASE}' (${HOSTNAME})"
    MAIL_BODY+="

============================================================
⚠️  UNERWARTETER ABBRUCH
============================================================

${reason}

Letzte Phase:   ${PHASE}
Zeitpunkt:      $(date '+%Y-%m-%d %H:%M:%S')
Server:         ${HOSTNAME}
Exit-Code:      ${exit_code}

Bisheriger Status:
${MAIL_BODY}
"

    send_mail "$MAIL_SUBJECT" "$MAIL_BODY"

    log_separator
    log_info "deploy_cron.sh beendet (Exit-Code: ${exit_code})"
    log_separator
}

trap cleanup_and_mail EXIT

# ============================================================
# Hauptlogik
# ============================================================

log_separator
log_info "deploy_cron.sh gestartet"
log_info "Server: ${HOSTNAME}"
log_separator

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
PHASE="Flag-Datei prüfen"

# ---- Flag-Datei prüfen ----
log_info "Prüfe Flag-Datei: ${FLAGFILE}"

if [ -f "$FLAGFILE" ]; then
    log_info "Flag-Datei gefunden → manueller Sync aktiv"
    log_info "Lösche Flag-Datei..."
    rm -f "$FLAGFILE"

    if [ ! -f "$FLAGFILE" ]; then
        log_ok "Flag-Datei gelöscht"
    else
        log_err "Flag-Datei konnte nicht gelöscht werden!"
    fi

    log_info "Kein automatisches Deploy in diesem Lauf."
    log_separator

    MAIL_SUBJECT="Kein Deploy - manualsync aktiv (${HOSTNAME})"
    MAIL_BODY="Zeitpunkt:  ${TIMESTAMP}
Server:     ${HOSTNAME}

Die Datei '${FLAGFILE}' war vorhanden.

Die Flag-Datei wurde gelöscht. Beim nächsten Lauf wird das Deploy
wieder normal ausgeführt, sofern die Datei nicht erneut angelegt wird."

    send_mail "$MAIL_SUBJECT" "$MAIL_BODY"

    log_separator
    log_info "deploy_cron.sh beendet (kein Deploy)"
    log_separator
    exit 0
fi

log_ok "Keine Flag-Datei vorhanden → Deploy wird ausgeführt"

# ============================================================
# Deploy ausführen
# ============================================================

MAIL_BODY="Zeitpunkt:  ${TIMESTAMP}
Server:     ${HOSTNAME}

Automatisches Deploy wurde gestartet.
---------------------------------------------
"

ERRORS=0

# --- deploy2live.sh ---
PHASE="Deploy Live"
run_script "Deploy Live" "$SCRIPT_LIVE"

MAIL_BODY+="
[1] Deploy Live (deploy2live.sh)
    Start:    ${_RESULT_START_FMT}
    Ende:     ${_RESULT_END_FMT}
    Dauer:    ${_RESULT_DURATION}
    Status:   $([ $_RESULT_RC -eq 0 ] && echo 'OK' || echo "FEHLER (Exit-Code: ${_RESULT_RC})")
"

if [ $_RESULT_RC -ne 0 ]; then
    MAIL_BODY+="    Ausgabe:
${_RESULT_OUTPUT}
"
    ERRORS=$((ERRORS + 1))
fi

# --- sync2china.sh ---
PHASE="Sync China"
run_script "Sync China" "$SCRIPT_CHINA"

MAIL_BODY+="
[2] Sync China (sync2china.sh)
    Start:    ${_RESULT_START_FMT}
    Ende:     ${_RESULT_END_FMT}
    Dauer:    ${_RESULT_DURATION}
    Status:   $([ $_RESULT_RC -eq 0 ] && echo 'OK' || echo "FEHLER (Exit-Code: ${_RESULT_RC})")
"

if [ $_RESULT_RC -ne 0 ]; then
    MAIL_BODY+="    Ausgabe:
${_RESULT_OUTPUT}
"
    ERRORS=$((ERRORS + 1))
fi

# ============================================================
# Mail versenden (regulärer Abschluss)
# ============================================================

PHASE="Mailversand"
log_separator

if [ $ERRORS -eq 0 ]; then
    MAIL_SUBJECT="Deploy erfolgreich (${HOSTNAME})"
    log_ok "Alle Scripte erfolgreich durchgelaufen"
else
    MAIL_SUBJECT="Deploy mit FEHLERN (${HOSTNAME})"
    log_err "${ERRORS} Script(e) mit Fehlern"
fi

send_mail "$MAIL_SUBJECT" "$MAIL_BODY"

exit $ERRORS

