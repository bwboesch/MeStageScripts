#!/bin/bash
#
# deploy_cron.sh
# Prüft ob manueller Sync aktiv ist und führt ggf. Deploy-Scripte aus.
# Sendet in jedem Fall eine Status-Mail via swaks.
#

# ============================================================
# Konfiguration
# ============================================================

# Empfänger (mehrere durch Leerzeichen getrennt)
RECIPIENTS=(
    "bboesch@innnet.de"
    "fp@innnet.de"
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
# Hauptlogik
# ============================================================

log_separator
log_info "deploy_cron.sh gestartet"
log_info "Server: ${HOSTNAME}"
log_separator

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

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

    SUBJECT="Kein Deploy - manualsync aktiv (${HOSTNAME})"
    BODY="Zeitpunkt:  ${TIMESTAMP}
Server:     ${HOSTNAME}

Die Datei '${FLAGFILE}' war vorhanden.
Automatisches Deploy wurde NICHT durchgeführt.

Die Flag-Datei wurde gelöscht. Beim nächsten Lauf wird das Deploy
wieder normal ausgeführt, sofern die Datei nicht erneut angelegt wird."

    send_mail "$SUBJECT" "$BODY"

    log_separator
    log_info "deploy_cron.sh beendet (kein Deploy)"
    log_separator
    exit 0
fi

log_ok "Keine Flag-Datei vorhanden → Deploy wird ausgeführt"

# ============================================================
# Deploy ausführen
# ============================================================

BODY="Zeitpunkt:  ${TIMESTAMP}
Server:     ${HOSTNAME}

Automatisches Deploy wurde gestartet.
---------------------------------------------
"

ERRORS=0

# --- deploy2live.sh ---
run_script "Deploy Live" "$SCRIPT_LIVE"

BODY+="
[1] Deploy Live (deploy2live.sh)
    Start:    ${_RESULT_START_FMT}
    Ende:     ${_RESULT_END_FMT}
    Dauer:    ${_RESULT_DURATION}
    Status:   $([ $_RESULT_RC -eq 0 ] && echo 'OK' || echo "FEHLER (Exit-Code: ${_RESULT_RC})")
"

if [ $_RESULT_RC -ne 0 ]; then
    BODY+="    Ausgabe:
${_RESULT_OUTPUT}
"
    ERRORS=$((ERRORS + 1))
fi

# --- sync2china.sh ---
run_script "Sync China" "$SCRIPT_CHINA"

BODY+="
[2] Sync China (sync2china.sh)
    Start:    ${_RESULT_START_FMT}
    Ende:     ${_RESULT_END_FMT}
    Dauer:    ${_RESULT_DURATION}
    Status:   $([ $_RESULT_RC -eq 0 ] && echo 'OK' || echo "FEHLER (Exit-Code: ${_RESULT_RC})")
"

if [ $_RESULT_RC -ne 0 ]; then
    BODY+="    Ausgabe:
${_RESULT_OUTPUT}
"
    ERRORS=$((ERRORS + 1))
fi

# ============================================================
# Mail versenden
# ============================================================

log_separator

if [ $ERRORS -eq 0 ]; then
    SUBJECT="Deploy erfolgreich (${HOSTNAME})"
    log_ok "Alle Scripte erfolgreich durchgelaufen"
else
    SUBJECT="Deploy mit FEHLERN (${HOSTNAME})"
    log_err "${ERRORS} Script(e) mit Fehlern"
fi

send_mail "$SUBJECT" "$BODY"

log_separator
log_info "deploy_cron.sh beendet (Fehler: ${ERRORS})"
log_separator

exit $ERRORS
