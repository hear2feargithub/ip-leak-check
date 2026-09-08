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
# v2.2: run-lock breaks on mtime age (the only guard that survives PID reuse) and
#       verifies PID identity via /proc/<pid>/cmdline; every docker exec is bounded
#       by timeout; dead-man's switch alerts if ip-leak.log stops advancing.
# v2.3: every docker call is bounded, not just exec -- inspect/update/start/stop can
#       hang on a wedged dockerd too. Stop gets a longer budget than control-plane
#       calls because it has its own SIGTERM grace. Timeouts are logged.

CONTAINER="${CONTAINER:?Error: CONTAINER env var must be set}"
DOCKER="${DOCKER:-/usr/local/bin/docker}"

LOCKFILE="/tmp/ipcheck.lock"
RUNLOCK="/tmp/ipcheck-running.lock"
RESTARTSTAMP="/tmp/${CONTAINER}.restart.last"
RESTARTCOUNTFILE="/tmp/${CONTAINER}.restart.count"
RESTARTWINDOWFILE="/tmp/${CONTAINER}.restart.window"

LOGDIR="${LOGDIR:-/volume1/docker/${CONTAINER}}"
LOGFILE="$LOGDIR/ip-leak.log"

MARKER_DIR="${MARKER_DIR:-}"  # optional: set to write Gotify JSON marker files
LAST_LEAK_FILE="$MARKER_DIR/$CONTAINER.last-leak.json"
LAST_RESTART_FILE="$MARKER_DIR/$CONTAINER.last-restart.json"
# NOTE: $CONTAINER.reason.json is no longer written. It existed purely to signal
# an external docker-events watcher, which turned the marker into the leak alert.
# This script now alerts directly via alert(), so writing the marker as well
# would produce two notifications for one event. Dropping it also means an
# external watcher sees a stop with no marker and correctly treats it as
# intentional. $LAST_LEAK_FILE / $LAST_RESTART_FILE remain -- they are state
# records for inspection, not signals to anything.

GRACE_SECONDS="${GRACE_SECONDS:-120}"
RESTART_COOLDOWN="${RESTART_COOLDOWN:-300}"       # 5 minutes between restart attempts
RESTART_WINDOW="${RESTART_WINDOW:-3600}"          # 1 hour rolling window
MAX_RESTARTS_PER_WINDOW="${MAX_RESTARTS_PER_WINDOW:-3}"  # max restart attempts per hour
MAXSIZE="${MAXSIZE:-1048576}"                     # 1 MB
FULL_CHECK_INTERVAL="${FULL_CHECK_INTERVAL:-60}"  # seconds between external IP checks
LAST_FULL_CHECK_FILE="/tmp/${CONTAINER}.last-full-check"

RUNLOCK_MAX_AGE="${RUNLOCK_MAX_AGE:-120}"         # break the run-lock unconditionally past this age
DOCKER_EXEC_TIMEOUT="${DOCKER_EXEC_TIMEOUT:-15}"  # hard cap on any single docker exec
DOCKER_TIMEOUT="${DOCKER_TIMEOUT:-15}"            # hard cap on inspect/update/start
DOCKER_STOP_TIMEOUT="${DOCKER_STOP_TIMEOUT:-30}"  # docker stop has its own 10s SIGTERM grace
TIMEOUT_BIN="${TIMEOUT_BIN:-/usr/bin/timeout}"    # not on PATH under cron on DSM

DEADMAN_MAX_AGE="${DEADMAN_MAX_AGE:-300}"         # alert if the log stops advancing for this long (0 disables)
DEADMAN_REPEAT="${DEADMAN_REPEAT:-1800}"          # re-alert at most this often while still stalled
DEADMAN_STAMP="/tmp/${CONTAINER}.deadman.last"    # last alert time
DEADMAN_STALL_FILE="/tmp/${CONTAINER}.deadman.stall"  # log mtime when the stall was first seen

GOTIFY_URL="${GOTIFY_URL:-}"                      # e.g. http://localhost:8090; empty disables push
GOTIFY_APP_TOKEN="${GOTIFY_APP_TOKEN:-}"

# Path to a shared notify.sh providing notify()/notify_resolve() (see the
# companion `notify` project). Empty leaves this script standalone, logging only.
# Set it from the environment -- under cron that means an explicit export, which
# is exactly what silently disabled the dead-man alert before.
NOTIFY_LIB="${NOTIFY_LIB:-}"

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

# Every docker call goes through here so none can block forever. curl's
# --max-time bounds only what runs *inside* the container, and the docker client
# itself waits indefinitely on an unresponsive dockerd -- that is what produced
# the stuck instance that stranded the run-lock on 2026-09-01.
docker_run() {   # docker_run <timeout-secs> <label> <docker args...>
    local t="$1" label="$2"; shift 2
    local rc
    if [ -n "$TIMEOUT_BIN" ]; then
        $TIMEOUT_BIN "$t" $DOCKER "$@"
        rc=$?
    else
        $DOCKER "$@"
        rc=$?
    fi
    # Sent to stderr so it can never contaminate a captured stdout value; the
    # log file still receives it via tee even when the caller discards stderr.
    [ "$rc" -eq 124 ] && log "Warning: docker $label timed out after ${t}s (dockerd unresponsive?)" >&2
    return $rc
}

set_restart_policy() {
    local policy="$1"
    docker_run "$DOCKER_TIMEOUT" "update --restart $policy" update --restart "$policy" "$CONTAINER" >/dev/null 2>&1
}

gotify_push() {   # gotify_push <title> <priority> <message>
    [ -n "$GOTIFY_URL" ] && [ -n "$GOTIFY_APP_TOKEN" ] || return 0
    curl -s -o /dev/null --max-time 10 \
        -H "X-Gotify-Key: $GOTIFY_APP_TOKEN" \
        -F "title=$1" \
        -F "priority=$2" \
        -F "message=$3" \
        "$GOTIFY_URL/message" 2>/dev/null
}

# Load the shared notifier if one was configured. Sourcing is deliberately NOT
# done with a `VAR=x . lib` prefix: bash discards such an assignment when the
# source returns, leaving the variable unset at call time.
NOTIFY_READY=0
if [ -n "$NOTIFY_LIB" ] && [ -r "$NOTIFY_LIB" ]; then
    # shellcheck source=/dev/null
    if . "$NOTIFY_LIB" 2>/dev/null; then
        command -v notify >/dev/null 2>&1 && NOTIFY_READY=1
    fi
fi

gotify_priority_for() {
    case "$1" in
        CRIT) echo 8 ;;
        HIGH) echo 7 ;;
        LOW)  echo 5 ;;
        *)    echo 3 ;;
    esac
}

# alert <severity> <key> <title> <message>
# Fans out to whichever notifiers are configured, and NEVER fails the caller --
# a watchdog that cannot report must still keep guarding.
alert() {
    [ "$NOTIFY_READY" = "1" ] && notify "$1" "$2" "$3" "$4"
    gotify_push "$3" "$(gotify_priority_for "$1")" "$4"
    return 0
}

# alert_clear <key> <title> <message>
# Silent unless that key had actually alerted, so healthy runs stay quiet.
alert_clear() {
    [ "$NOTIFY_READY" = "1" ] && notify_resolve "$1" "$2" "$3"
    return 0
}

file_age() {   # file_age <path> -> seconds since mtime; non-zero if unreadable
    local mtime now
    mtime="$(stat -c %Y "$1" 2>/dev/null)"
    [ -n "$mtime" ] || return 1
    now="$(date +%s)"
    echo $((now - mtime))
}

# Dead-man's switch: a dead watchdog cannot alert about itself, so check log
# freshness before anything that can exit early. The 2026-09-01 wedge was
# exactly this shape -- cron kept firing, every run returned 0 at the run-lock,
# and nothing logged for 15h without a single alert.
deadman_check() {
    [ "$DEADMAN_MAX_AGE" -gt 0 ] 2>/dev/null || return 0
    [ -f "$LOGFILE" ] || return 0

    local age now stall_mtime stalled_for last
    age="$(file_age "$LOGFILE")" || return 0
    [ "$age" -ge "$DEADMAN_MAX_AGE" ] || return 0

    now="$(date +%s)"

    # Remember when the stall started. The alert line logged below refreshes the
    # log mtime, so without this the reported outage would reset on every alert.
    stall_mtime=""
    [ -f "$DEADMAN_STALL_FILE" ] && stall_mtime="$(cat "$DEADMAN_STALL_FILE" 2>/dev/null)"
    case "$stall_mtime" in
        ''|*[!0-9]*)
            stall_mtime=$((now - age))
            echo "$stall_mtime" > "$DEADMAN_STALL_FILE"
            ;;
    esac
    stalled_for=$((now - stall_mtime))

    # Throttle so a long outage does not spam.
    last=0
    [ -f "$DEADMAN_STAMP" ] && last="$(cat "$DEADMAN_STAMP" 2>/dev/null)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $((now - last)) -ge "$DEADMAN_REPEAT" ] || return 0

    echo "$now" > "$DEADMAN_STAMP"
    log "Warning: dead-man's switch fired -- no new log line for ${stalled_for}s"
    alert CRIT "ipleak-deadman:$CONTAINER" "Leak watchdog stalled" \
        "No log activity for $((stalled_for / 60))m, so the leak check is not running and VPN leak protection for $CONTAINER may be OFF.
Check: $LOGFILE"
}

if [ ! -x "$TIMEOUT_BIN" ]; then
    log "Warning: TIMEOUT_BIN '$TIMEOUT_BIN' is not executable; docker calls will run unbounded"
    TIMEOUT_BIN=""
fi

deadman_check

# --- run-lock: exit if another instance is already running ---
# kill -0 alone is NOT sufficient: across a long stall the recorded PID gets
# reused by an unrelated live process, the liveness check keeps succeeding, and
# the lock is never broken (2026-09-01: silently dead for 15h). Two guards
# below -- an absolute mtime bound, and PID identity via /proc.

SCRIPT_NAME="$(basename "$0")"

runlock_held_by_this_script() {   # runlock_held_by_this_script <pid>
    local pid="$1"
    [ -n "$pid" ] || return 1
    case "$pid" in *[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$SCRIPT_NAME"
}

if ! ( set -C; echo $$ > "$RUNLOCK" ) 2>/dev/null; then
    OLD_PID="$(cat "$RUNLOCK" 2>/dev/null)"
    RUNLOCK_AGE="$(file_age "$RUNLOCK")" || RUNLOCK_AGE="$RUNLOCK_MAX_AGE"

    if [ "$RUNLOCK_AGE" -ge "$RUNLOCK_MAX_AGE" ]; then
        # The only guard that survives PID reuse. Past this age the lock is stale
        # whatever holds the PID; brief overlap beats a permanent deadlock.
        log "Warning: breaking stale run-lock (age ${RUNLOCK_AGE}s >= ${RUNLOCK_MAX_AGE}s, pid '${OLD_PID:-none}')"
    elif runlock_held_by_this_script "$OLD_PID"; then
        exit 0
    else
        log "Warning: breaking orphaned run-lock (pid '${OLD_PID:-none}' is not a live $SCRIPT_NAME)"
    fi

    rm -f "$RUNLOCK"
    ( set -C; echo $$ > "$RUNLOCK" ) 2>/dev/null || exit 0
fi
trap 'rm -f "$RUNLOCK"' EXIT INT TERM

# --- start ---
rotate_logs

# A timeout leaves this empty, which the stopped-path below already handles the
# same way it handles a container that does not exist.
RUNNING="$(docker_run "$DOCKER_TIMEOUT" "inspect(Running)" inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)"

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
            alert HIGH "ipleak-restart:$CONTAINER" "Container restart suppressed" \
                "$CONTAINER hit the restart limit ($MAX_RESTARTS_PER_WINDOW per $((RESTART_WINDOW / 60))m) after a leak stop and will stay down until the window clears.
Check: $LOGFILE"
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

        if docker_run "$DOCKER_TIMEOUT" "start" start "$CONTAINER" >/dev/null 2>&1; then
            log "Container $CONTAINER started successfully; startup grace period will apply"
            write_json_marker "$LAST_RESTART_FILE" "restart_succeeded" "" "" "container started successfully after leak event"
            alert_clear "ipleak-restart:$CONTAINER" "Container restarted" \
                "$CONTAINER started again after a leak stop."
        else
            log "Warning: automatic restart attempt failed for $CONTAINER"
            write_json_marker "$LAST_RESTART_FILE" "restart_failed" "" "" "docker start failed after leak event"
            alert CRIT "ipleak-restart:$CONTAINER" "Container restart failed" \
                "$CONTAINER is stopped after a leak event and the automatic restart failed. Manual action needed.
Check: $LOGFILE"
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
        alert HIGH "ipleak-restart:$CONTAINER" "Container restart suppressed" \
            "$CONTAINER stopped unexpectedly and hit the restart limit ($MAX_RESTARTS_PER_WINDOW per $((RESTART_WINDOW / 60))m). It will stay down until the window clears.
Check: $LOGFILE"
        exit 0
    fi

    log "Warning: container $CONTAINER is not running without leak lockfile; attempting automatic restart"
    date +%s > "$RESTARTSTAMP"
    increment_restart_count

    set_restart_policy "$RESTART_POLICY_SAFE"

    if docker_run "$DOCKER_TIMEOUT" "start" start "$CONTAINER" >/dev/null 2>&1; then
        log "Container $CONTAINER started successfully after unexpected stop; startup grace period will apply"
        write_json_marker "$LAST_RESTART_FILE" "restart_unexpected_stop" "" "" "container restarted after unexpected stop"
        alert_clear "ipleak-restart:$CONTAINER" "Container restarted" \
            "$CONTAINER started again after an unexpected stop."
    else
        log "Warning: automatic restart after unexpected stop failed for $CONTAINER"
        write_json_marker "$LAST_RESTART_FILE" "restart_failed" "" "" "unexpected stop; docker start failed"
        alert CRIT "ipleak-restart:$CONTAINER" "Container restart failed" \
            "$CONTAINER stopped unexpectedly and the automatic restart failed. Manual action needed.
Check: $LOGFILE"
    fi

    exit 0
fi

# --- detect container uptime (grace period) ---
UPTIME="$(docker_run "$DOCKER_TIMEOUT" "inspect(StartedAt)" inspect -f '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null | xargs -I{} date -d {} +%s 2>/dev/null)"
NOWSEC="$(date +%s)"

if [ -n "$UPTIME" ]; then
    ELAPSED=$((NOWSEC - UPTIME))
    if [ "$ELAPSED" -lt "$GRACE_SECONDS" ]; then
        log "Skipping check (container starting, uptime ${ELAPSED}s < ${GRACE_SECONDS}s grace)"
        exit 0
    fi
fi

# --- fast check: VPN tunnel interface (every 10s) ---
# A timeout here is treated as "tunnel not verifiable" and so fails closed
# (container stopped), which is the safe direction for a leak guard.
if ! docker_run "$DOCKER_EXEC_TIMEOUT" "exec(ip link tun0)" exec "$CONTAINER" ip link show tun0 2>/dev/null | grep -q "UP"; then
    if ( set -C; : > "$LOCKFILE" ) 2>/dev/null; then
        log "VPN tunnel down (tun0 not UP); stopping container $CONTAINER"

        alert CRIT "ipleak-tun0:$CONTAINER" "VPN tunnel down - container stopped" \
            "$CONTAINER was stopped because tun0 was not UP. It stays down until the tunnel is healthy again.
Check: $LOGFILE"

        write_json_marker \
            "$LAST_LEAK_FILE" \
            "tun0_down" \
            "" \
            "" \
            "latest tun0-down event"

        set_restart_policy "$RESTART_POLICY_LEAK"

        if docker_run "$DOCKER_STOP_TIMEOUT" "stop" stop "$CONTAINER" >/dev/null 2>&1; then
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
# curl --max-time bounds the inner curl only; docker exec itself can hang
# indefinitely on an unresponsive dockerd, which is what stranded the run-lock.
CONTAINER_IP="$(docker_run "$DOCKER_EXEC_TIMEOUT" "exec(curl ifconfig.me)" exec "$CONTAINER" curl -s --max-time 10 --retry 2 ifconfig.me 2>/dev/null)"

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

        # Deliberately terse: the addresses stay in the log, not in a message
        # that lands on a third party's servers.
        alert CRIT "ipleak-ip:$CONTAINER" "IP leak - container stopped" \
            "$CONTAINER reported the same external IP as the host, so it was stopped to prevent exposure.
Check: $LOGFILE"

        write_json_marker \
            "$LAST_LEAK_FILE" \
            "ip_leak" \
            "$PUBLIC_IP" \
            "$CONTAINER_IP" \
            "latest leak event"

        set_restart_policy "$RESTART_POLICY_LEAK"

        if docker_run "$DOCKER_STOP_TIMEOUT" "stop" stop "$CONTAINER" >/dev/null 2>&1; then
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

    # Each of these is silent unless that key had actually alerted, so a healthy
    # run stays quiet. This is the only branch where the tunnel is confirmed
    # good AND the addresses differ, so it is the only honest place to clear.
    alert_clear "ipleak-ip:$CONTAINER" "IP leak cleared" \
        "$CONTAINER external IP differs from the host again."
    alert_clear "ipleak-tun0:$CONTAINER" "VPN tunnel recovered" \
        "tun0 is UP and $CONTAINER is checking clean."
    alert_clear "ipleak-deadman:$CONTAINER" "Leak watchdog running again" \
        "The leak check is logging normally; VPN leak protection is active."

    [ -f "$LOCKFILE" ] && rm -f "$LOCKFILE"
    [ -f "$RESTARTSTAMP" ] && rm -f "$RESTARTSTAMP"
    [ -f "$RESTARTCOUNTFILE" ] && rm -f "$RESTARTCOUNTFILE"
    [ -f "$RESTARTWINDOWFILE" ] && rm -f "$RESTARTWINDOWFILE"
    [ -f "$DEADMAN_STALL_FILE" ] && rm -f "$DEADMAN_STALL_FILE"
    [ -f "$DEADMAN_STAMP" ] && rm -f "$DEADMAN_STAMP"
fi

exit 0
