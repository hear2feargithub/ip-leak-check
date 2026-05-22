#!/bin/bash
# IP Leak Watchdog v2.1 – Last updated 2026-05-22
# Checks every 10 seconds if Transmission+VPN container leaks the host IP.
# Fast check: verifies tun0 interface is UP inside the container (every 10s).
# Full check: compares external IPs via ifconfig.me (every 60s).
# Stops container and logs warning if leak detected.
# On real leak: disables Docker restart policy before stopping container.
# On recovery: re-enables Docker restart policy before starting container.
# Auto-restarts after cooldown, only if host internet is healthy.
# Caps restart attempts per hour and writes separate last-leak / last-restart markers.

CONTAINER="${CONTAINER:?Error: CONTAINER env var must be set}"
DOCKER="${DOCKER:-/usr/local/bin/docker}"

LOCKFILE="/tmp/ipcheck.lock"
RESTARTSTAMP="/tmp/${CONTAINER}.restart.last"
RESTARTCOUNTFILE="/tmp/${CONTAINER}.restart.count"
RESTARTWINDOWFILE="/tmp/${CONTAINER}.restart.window"

LOGDIR="${LOGDIR:-/volume1/docker/${CONTAINER}}"
LOGFILE="$LOGDIR/ip-leak.log"

MARKER_DIR="${MARKER_DIR:-}"  # optional: set to write Gotify JSON marker files
LAST_LEAK_FILE="$MARKER_DIR/$CONTAINER.last-leak.json"
LAST_RESTART_FILE="$MARKER_DIR/$CONTAINER.last-restart.json"
REASON_FILE="$MARKER_DIR/$CONTAINER.reason.json"

GRACE_SECONDS="${GRACE_SECONDS:-120}"
RESTART_COOLDOWN="${RESTART_COOLDOWN:-300}"       # 5 minutes between restart attempts
RESTART_WINDOW="${RESTART_WINDOW:-3600}"          # 1 hour rolling window
MAX_RESTARTS_PER_WINDOW="${MAX_RESTARTS_PER_WINDOW:-3}"  # max restart attempts per hour
MAXSIZE="${MAXSIZE:-1048576}"                     # 1 MB
FULL_CHECK_INTERVAL="${FULL_CHECK_INTERVAL:-60}"  # seconds between external IP checks
LAST_FULL_CHECK_FILE="/tmp/${CONTAINER}.last-full-check"

RESTART_POLICY_SAFE="unless-stopped"
RESTART_POLICY_LEAK="no"

mkdir -p "$LOGDIR"
[ -n "$MARKER_DIR" ] && mkdir -p "$MARKER_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

ts_iso() {
    if date -Is >/dev/null 2>&1; then
        date -Is
    else
        date -u +"%Y-%m-%dT%H:%M:%SZ"
    fi
}

write_json_marker() {
    [ -z "$MARKER_DIR" ] && return 0
    local file="$1"
    local reason="$2"
    local host_ip="$3"
    local container_ip="$4"
    local note="$5"

    printf '{"reason":"%s","host_ip":"%s","container_ip":"%s","ts":"%s","note":"%s"}\n' \
        "${reason:-unknown}" \
        "${host_ip:-unknown}" \
        "${container_ip:-unknown}" \
        "$(ts_iso)" \
        "${note:-}" \
        > "$file"
}

host_internet_healthy() {
    local ip
    ip="$(curl -s --max-time 5 --retry 2 ifconfig.me 2>/dev/null)"

    case "$ip" in
      ""|*timeout*|*"timed out"*|*"upstream request timeout"*)
        return 1
        ;;
    esac

    return 0
}

rotate_logs() {
    if [ -f "$LOGFILE" ] && [ "$(stat -c%s "$LOGFILE")" -ge "$MAXSIZE" ]; then
        [ -f "$LOGFILE.2" ] && mv "$LOGFILE.2" "$LOGFILE.3"
        [ -f "$LOGFILE.1" ] && mv "$LOGFILE.1" "$LOGFILE.2"
        mv "$LOGFILE" "$LOGFILE.1"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Log rotated" > "$LOGFILE"
    fi
}

restart_window_reset_if_needed() {
    local now window_start
    now="$(date +%s)"

    if [ ! -f "$RESTARTWINDOWFILE" ] || [ ! -f "$RESTARTCOUNTFILE" ]; then
        echo "$now" > "$RESTARTWINDOWFILE"
        echo "0" > "$RESTARTCOUNTFILE"
        return
    fi

    window_start="$(cat "$RESTARTWINDOWFILE" 2>/dev/null)"
    [ -z "$window_start" ] && window_start=0

    if [ $((now - window_start)) -ge "$RESTART_WINDOW" ]; then
        echo "$now" > "$RESTARTWINDOWFILE"
        echo "0" > "$RESTARTCOUNTFILE"
    fi
}

get_restart_count() {
    if [ -f "$RESTARTCOUNTFILE" ]; then
        cat "$RESTARTCOUNTFILE" 2>/dev/null
    else
        echo "0"
    fi
}

increment_restart_count() {
    local count
    count="$(get_restart_count)"
    [ -z "$count" ] && count=0
    count=$((count + 1))
    echo "$count" > "$RESTARTCOUNTFILE"
}

set_restart_policy() {
    local policy="$1"
    $DOCKER update --restart "$policy" "$CONTAINER" >/dev/null 2>&1
}

# --- start ---
rotate_logs

RUNNING="$($DOCKER inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)"

# --- container stopped path ---
if [ "$RUNNING" != "true" ]; then
    NOWSEC="$(date +%s)"

    # intentional leak-stop recovery path
    if [ -f "$LOCKFILE" ]; then
        LASTTRY=0

        if [ -f "$RESTARTSTAMP" ]; then
            LASTTRY="$(cat "$RESTARTSTAMP" 2>/dev/null)"
            [ -z "$LASTTRY" ] && LASTTRY=0
        fi

        restart_window_reset_if_needed
        RESTART_COUNT="$(get_restart_count)"
        [ -z "$RESTART_COUNT" ] && RESTART_COUNT=0

        ELAPSED_SINCE_RESTART_TRY=$((NOWSEC - LASTTRY))

        if [ "$RESTART_COUNT" -ge "$MAX_RESTARTS_PER_WINDOW" ]; then
            log "Container $CONTAINER restart suppressed: reached $RESTART_COUNT attempts in current ${RESTART_WINDOW}s window"
            write_json_marker "$LAST_RESTART_FILE" "restart_suppressed" "" "" "max restart attempts reached"
            exit 0
        fi

        if [ "$ELAPSED_SINCE_RESTART_TRY" -lt "$RESTART_COOLDOWN" ]; then
            log "Container $CONTAINER still in restart cooldown (${ELAPSED_SINCE_RESTART_TRY}s < ${RESTART_COOLDOWN}s)"
            exit 0
        fi

        if ! host_internet_healthy; then
            log "Container $CONTAINER restart skipped: host internet check failed"
            write_json_marker "$LAST_RESTART_FILE" "restart_skipped" "" "" "host internet unhealthy"
            exit 0
        fi

        log "Container $CONTAINER is stopped after leak event; attempting automatic restart"
        date +%s > "$RESTARTSTAMP"
        increment_restart_count

        set_restart_policy "$RESTART_POLICY_SAFE"

        if $DOCKER start "$CONTAINER" >/dev/null 2>&1; then
            log "Container $CONTAINER started successfully; startup grace period will apply"
            write_json_marker "$LAST_RESTART_FILE" "restart_succeeded" "" "" "container started successfully after leak event"
        else
            log "Warning: automatic restart attempt failed for $CONTAINER"
            write_json_marker "$LAST_RESTART_FILE" "restart_failed" "" "" "docker start failed after leak event"
        fi

        exit 0
    fi

    # unexpected stop recovery path
    if ! host_internet_healthy; then
        log "Warning: container $CONTAINER is not running, and host internet check failed; restart skipped"
        write_json_marker "$LAST_RESTART_FILE" "restart_skipped" "" "" "container stopped unexpectedly and host internet unhealthy"
        exit 0
    fi

    restart_window_reset_if_needed
    RESTART_COUNT="$(get_restart_count)"
    [ -z "$RESTART_COUNT" ] && RESTART_COUNT=0

    if [ "$RESTART_COUNT" -ge "$MAX_RESTARTS_PER_WINDOW" ]; then
        log "Warning: container $CONTAINER is not running; unexpected-stop restart suppressed after $RESTART_COUNT attempts in current ${RESTART_WINDOW}s window"
        write_json_marker "$LAST_RESTART_FILE" "restart_suppressed" "" "" "unexpected stop; max restart attempts reached"
        exit 0
    fi

    log "Warning: container $CONTAINER is not running without leak lockfile; attempting automatic restart"
    date +%s > "$RESTARTSTAMP"
    increment_restart_count

    set_restart_policy "$RESTART_POLICY_SAFE"

    if $DOCKER start "$CONTAINER" >/dev/null 2>&1; then
        log "Container $CONTAINER started successfully after unexpected stop; startup grace period will apply"
        write_json_marker "$LAST_RESTART_FILE" "restart_unexpected_stop" "" "" "container restarted after unexpected stop"
    else
        log "Warning: automatic restart after unexpected stop failed for $CONTAINER"
        write_json_marker "$LAST_RESTART_FILE" "restart_failed" "" "" "unexpected stop; docker start failed"
    fi

    exit 0
fi

# --- detect container uptime (grace period) ---
UPTIME="$($DOCKER inspect -f '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null | xargs -I{} date -d {} +%s 2>/dev/null)"
NOWSEC="$(date +%s)"

if [ -n "$UPTIME" ]; then
    ELAPSED=$((NOWSEC - UPTIME))
    if [ "$ELAPSED" -lt "$GRACE_SECONDS" ]; then
        log "Skipping check (container starting, uptime ${ELAPSED}s < ${GRACE_SECONDS}s grace)"
        exit 0
    fi
fi

# --- fast check: VPN tunnel interface (every 10s) ---
if ! $DOCKER exec "$CONTAINER" ip link show tun0 2>/dev/null | grep -q "UP"; then
    if ( set -C; : > "$LOCKFILE" ) 2>/dev/null; then
        log "VPN tunnel down (tun0 not UP); stopping container $CONTAINER"

        write_json_marker \
            "$REASON_FILE" \
            "tun0_down" \
            "" \
            "" \
            "container stopped due to VPN tunnel down"

        write_json_marker \
            "$LAST_LEAK_FILE" \
            "tun0_down" \
            "" \
            "" \
            "latest tun0-down event"

        set_restart_policy "$RESTART_POLICY_LEAK"

        if $DOCKER stop "$CONTAINER" >/dev/null 2>&1; then
            log "Container $CONTAINER stopped due to VPN tunnel down"
        else
            log "Warning: failed to stop container $CONTAINER after tun0-down detection"
        fi

        date +%s > "$RESTARTSTAMP"
        exit 1
    else
        log "VPN tunnel still down, lockfile already exists"
        exit 1
    fi
fi

# --- full check: external IP comparison (throttled to once per FULL_CHECK_INTERVAL seconds) ---
NOWSEC="$(date +%s)"
LAST_FULL=0
[ -f "$LAST_FULL_CHECK_FILE" ] && LAST_FULL="$(cat "$LAST_FULL_CHECK_FILE" 2>/dev/null)"
[ -z "$LAST_FULL" ] && LAST_FULL=0

if [ $((NOWSEC - LAST_FULL)) -lt "$FULL_CHECK_INTERVAL" ]; then
    exit 0
fi

echo "$NOWSEC" > "$LAST_FULL_CHECK_FILE"

PUBLIC_IP="$(curl -s --max-time 5 --retry 2 ifconfig.me 2>/dev/null)"
CONTAINER_IP="$($DOCKER exec "$CONTAINER" curl -s --max-time 10 --retry 2 ifconfig.me 2>/dev/null)"

if [ -z "$PUBLIC_IP" ] || [ -z "$CONTAINER_IP" ]; then
    log "Warning: IP check skipped (blank response)"
    exit 0
fi

is_ipv4() { echo "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; }

if ! is_ipv4 "$PUBLIC_IP" || ! is_ipv4 "$CONTAINER_IP"; then
    log "Warning: IP check skipped (non-IP response: host='$PUBLIC_IP' container='$CONTAINER_IP')"
    exit 0
fi

# --- TEST OVERRIDE (uncomment only for testing) ---
# PUBLIC_IP=1.2.3.4
# CONTAINER_IP=1.2.3.4

# --- main comparison ---
if [ "$PUBLIC_IP" = "$CONTAINER_IP" ]; then
    if ( set -C; : > "$LOCKFILE" ) 2>/dev/null; then
        log "IP leak detected! Host=$PUBLIC_IP, Container=$CONTAINER_IP"

        write_json_marker \
            "$REASON_FILE" \
            "ip_leak" \
            "$PUBLIC_IP" \
            "$CONTAINER_IP" \
            "container stopped due to IP leak"

        write_json_marker \
            "$LAST_LEAK_FILE" \
            "ip_leak" \
            "$PUBLIC_IP" \
            "$CONTAINER_IP" \
            "latest leak event"

        set_restart_policy "$RESTART_POLICY_LEAK"

        if $DOCKER stop "$CONTAINER" >/dev/null 2>&1; then
            log "Container $CONTAINER stopped due to IP leak"
        else
            log "Warning: failed to stop container $CONTAINER after leak detection"
        fi

        date +%s > "$RESTARTSTAMP"
        exit 1
    else
        log "Leak condition still present, but lockfile already exists"
        exit 1
    fi
else
    log "OK (Host=$PUBLIC_IP, Container=$CONTAINER_IP)"
    [ -f "$LOCKFILE" ] && rm -f "$LOCKFILE"
    [ -f "$RESTARTSTAMP" ] && rm -f "$RESTARTSTAMP"
    [ -f "$RESTARTCOUNTFILE" ] && rm -f "$RESTARTCOUNTFILE"
    [ -f "$RESTARTWINDOWFILE" ] && rm -f "$RESTARTWINDOWFILE"
fi

exit 0