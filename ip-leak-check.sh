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
# v2.4: one incident, two messages. Stops, failed restarts and restart limits
#       join a single incident (key ipleak:<container>): one HIGH message when
#       it opens, one recovery after RECOVERY_HOLD of clean checks, and one CRIT
#       only if the container stays down ESCALATE_AFTER without a break. A
#       timed-out tun0 check needs TUN_TIMEOUT_STRIKES in a row before it stops
#       the container and is reported as "dockerd unresponsive", not "tunnel
#       down". A timed-out inspect skips the run instead of attempting a restart.
#       An actual IP match stays its own CRIT alert. (2026-10-05: one Hyper
#       Backup run produced 10 Telegram messages under v2.3.)

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

RECOVERY_HOLD="${RECOVERY_HOLD:-600}"             # clean checks needed before an incident is called recovered
ESCALATE_AFTER="${ESCALATE_AFTER:-1800}"          # CRIT once if the container stays down this long without a break
TUN_TIMEOUT_STRIKES="${TUN_TIMEOUT_STRIKES:-2}"   # consecutive tun0-check timeouts before a precautionary stop
TUN_STRIKE_WINDOW="${TUN_STRIKE_WINDOW:-60}"      # a strike older than this no longer counts as consecutive
INCIDENT_FILE="/tmp/${CONTAINER}.incident"        # start|cycles|down_since|clean_since|escalated|cause
TUN_STRIKE_FILE="/tmp/${CONTAINER}.tun0-timeouts" # count|last

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

fmt_dur() {   # fmt_dur <seconds> -> "47m" / "2h05m"
    local s="$1"
    [ "$s" -ge 3600 ] && printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60)) || printf '%dm' $(((s + 59) / 60))
}

# --- incident: one open message, one recovery, one escalation at most --------
# Everything that takes the container down (a precautionary or tun0 stop, a
# failed restart, the restart limit) joins ONE incident. v2.3 alerted on each of
# those separately, and every recovery message re-armed the next alert, so a
# dockerd stall that flapped the container three times sent ten messages.
INC_START=0 INC_CYCLES=0 INC_DOWN=0 INC_CLEAN=0 INC_ESC=0 INC_CAUSE=""

incident_load() {
    INC_START=0 INC_CYCLES=0 INC_DOWN=0 INC_CLEAN=0 INC_ESC=0 INC_CAUSE=""
    [ -f "$INCIDENT_FILE" ] || return 1
    IFS='|' read -r INC_START INC_CYCLES INC_DOWN INC_CLEAN INC_ESC INC_CAUSE < "$INCIDENT_FILE" 2>/dev/null
    case "$INC_START" in ''|*[!0-9]*) INC_START=0; return 1 ;; esac
    for v in INC_CYCLES INC_DOWN INC_CLEAN INC_ESC; do
        case "${!v}" in ''|*[!0-9]*) printf -v "$v" 0 ;; esac
    done
    return 0
}

incident_save() {
    printf '%s|%s|%s|%s|%s|%s\n' "$INC_START" "$INC_CYCLES" "$INC_DOWN" "$INC_CLEAN" "$INC_ESC" "$INC_CAUSE" > "$INCIDENT_FILE"
}

# incident_event <stopped:0|1> <notify:0|1> <cause>
# stopped=1 means the container is down as of now. notify=0 opens the incident
# silently (an IP match already sent its own CRIT, so its restart churn must not
# add a second message).
incident_event() {
    local stopped="$1" notify_open="$2" cause="${3//|//}" now
    now="$(date +%s)"
    if incident_load; then
        [ "$stopped" = "1" ] && [ "$INC_DOWN" -eq 0 ] && { INC_CYCLES=$((INC_CYCLES + 1)); INC_DOWN="$now"; }
        INC_CLEAN=0
        incident_save
        return 0
    fi
    INC_START="$now" INC_CYCLES=0 INC_DOWN=0 INC_CLEAN=0 INC_ESC=0 INC_CAUSE="$cause"
    [ "$stopped" = "1" ] && { INC_CYCLES=1; INC_DOWN="$now"; }
    incident_save
    # The incident does its own dedupe, so the notifier's cooldown must not
    # swallow an open that follows a recovery inside its window.
    [ "$notify_open" = "1" ] && NOTIFY_COOLDOWN=0 alert HIGH "ipleak:$CONTAINER" "$CONTAINER held stopped" \
        "$cause
Auto-restart is on. You get one more message when it has checked clean for $((RECOVERY_HOLD / 60))m, or if it stays down $((ESCALATE_AFTER / 60))m.
Check: $LOGFILE"
    return 0
}

incident_running() {   # the container is up: end the current down period
    incident_load || return 0
    [ "$INC_DOWN" -eq 0 ] && return 0
    INC_DOWN=0
    incident_save
}

incident_escalate_if_stuck() {   # called while the container is stopped
    incident_load || return 0
    [ "$INC_ESC" -eq 0 ] && [ "$INC_DOWN" -gt 0 ] || return 0
    local down_for=$(( $(date +%s) - INC_DOWN ))
    [ "$down_for" -ge "$ESCALATE_AFTER" ] || return 0
    INC_ESC=1
    incident_save
    log "Incident escalated: $CONTAINER down for ${down_for}s"
    NOTIFY_COOLDOWN=0 alert CRIT "ipleak:$CONTAINER" "$CONTAINER still down" \
        "Down $(fmt_dur "$down_for") without a break and automatic restarts have not brought it back. Manual action needed.
Cause: $INC_CAUSE
Check: $LOGFILE"
}

incident_clean_check() {   # called on a fully clean check; resolves after RECOVERY_HOLD
    incident_load || return 0
    local now
    now="$(date +%s)"
    if [ "$INC_CLEAN" -eq 0 ]; then
        INC_CLEAN="$now"
        INC_DOWN=0
        incident_save
        return 0
    fi
    [ $((now - INC_CLEAN)) -ge "$RECOVERY_HOLD" ] || return 0
    log "Incident resolved: $INC_CYCLES stop(s) over $((INC_CLEAN - INC_START))s; clean since $(date -d "@$INC_CLEAN" '+%H:%M:%S')"
    alert_clear "ipleak:$CONTAINER" "$CONTAINER recovered" \
        "Back to normal after $(fmt_dur $((INC_CLEAN - INC_START))) ($INC_CYCLES stop/start cycle(s)), checking clean for $((RECOVERY_HOLD / 60))m.
Cause: $INC_CAUSE"
    rm -f "$INCIDENT_FILE"
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

RUNNING="$(docker_run "$DOCKER_TIMEOUT" "inspect(Running)" inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)"
RUNNING_RC=$?

# A timeout says nothing about the container. v2.3 read the empty result as
# "stopped" and tried a restart, which also timed out and raised a false
# "restart failed" (2026-10-05 06:52) while the container was in fact running.
if [ "$RUNNING_RC" -eq 124 ]; then
    log "Warning: skipping run, container state unknown (dockerd unresponsive)"
    exit 0
fi

# --- container stopped path ---
if [ "$RUNNING" != "true" ]; then
    NOWSEC="$(date +%s)"
    incident_escalate_if_stuck

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
            incident_event 1 1 "Hit the restart limit ($MAX_RESTARTS_PER_WINDOW per $((RESTART_WINDOW / 60))m) after a leak stop; stays down until the window clears."
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
            incident_running
        else
            # The next attempt follows after RESTART_COOLDOWN; only a long
            # unbroken outage escalates (incident_escalate_if_stuck).
            log "Warning: automatic restart attempt failed for $CONTAINER"
            write_json_marker "$LAST_RESTART_FILE" "restart_failed" "" "" "docker start failed after leak event"
            incident_event 1 1 "Stopped after a leak event and the automatic restart failed; retrying."
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
        incident_event 1 1 "Stopped unexpectedly and hit the restart limit ($MAX_RESTARTS_PER_WINDOW per $((RESTART_WINDOW / 60))m); stays down until the window clears."
        exit 0
    fi

    log "Warning: container $CONTAINER is not running without leak lockfile; attempting automatic restart"
    date +%s > "$RESTARTSTAMP"
    increment_restart_count

    set_restart_policy "$RESTART_POLICY_SAFE"

    if docker_run "$DOCKER_TIMEOUT" "start" start "$CONTAINER" >/dev/null 2>&1; then
        log "Container $CONTAINER started successfully after unexpected stop; startup grace period will apply"
        write_json_marker "$LAST_RESTART_FILE" "restart_unexpected_stop" "" "" "container restarted after unexpected stop"
        incident_running
    else
        log "Warning: automatic restart after unexpected stop failed for $CONTAINER"
        write_json_marker "$LAST_RESTART_FILE" "restart_failed" "" "" "unexpected stop; docker start failed"
        incident_event 1 1 "Stopped unexpectedly and the automatic restart failed; retrying."
    fi

    exit 0
fi

incident_running

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
# A timeout means "tunnel not verifiable", not "tunnel down". It still fails
# closed, but only after TUN_TIMEOUT_STRIKES in a row (~10s apart): one slow
# dockerd answer under disk load is common, and the container's own iptables
# kill switch covers the gap. A tun0 that answers but is not UP stops at once.
TUN_OUT="$(docker_run "$DOCKER_EXEC_TIMEOUT" "exec(ip link tun0)" exec "$CONTAINER" ip link show tun0 2>/dev/null)"
TUN_RC=$?
TUN_CAUSE=""
if [ "$TUN_RC" -eq 124 ]; then
    NOWSEC="$(date +%s)"
    STRIKES=0 STRIKE_LAST=0
    [ -f "$TUN_STRIKE_FILE" ] && IFS='|' read -r STRIKES STRIKE_LAST < "$TUN_STRIKE_FILE"
    case "$STRIKES" in ''|*[!0-9]*) STRIKES=0 ;; esac
    case "$STRIKE_LAST" in ''|*[!0-9]*) STRIKE_LAST=0 ;; esac
    [ $((NOWSEC - STRIKE_LAST)) -gt "$TUN_STRIKE_WINDOW" ] && STRIKES=0
    STRIKES=$((STRIKES + 1))
    echo "$STRIKES|$NOWSEC" > "$TUN_STRIKE_FILE"
    if [ "$STRIKES" -lt "$TUN_TIMEOUT_STRIKES" ]; then
        log "Warning: tun0 check unverifiable (dockerd unresponsive), strike $STRIKES/$TUN_TIMEOUT_STRIKES; retrying next run"
        exit 0
    fi
    TUN_CAUSE="dockerd unresponsive: the tun0 check timed out ${STRIKES}x in a row, so it was stopped as a precaution. The VPN was not confirmed down."
elif ! printf '%s\n' "$TUN_OUT" | grep -q "UP"; then
    TUN_CAUSE="VPN tunnel down: tun0 was not UP."
fi
[ -z "$TUN_CAUSE" ] && rm -f "$TUN_STRIKE_FILE"

if [ -n "$TUN_CAUSE" ]; then
    rm -f "$TUN_STRIKE_FILE"
    if ( set -C; : > "$LOCKFILE" ) 2>/dev/null; then
        log "Stopping container $CONTAINER -- $TUN_CAUSE"

        incident_event 1 1 "$TUN_CAUSE"

        write_json_marker \
            "$LAST_LEAK_FILE" \
            "tun0_down" \
            "" \
            "" \
            "$TUN_CAUSE"

        set_restart_policy "$RESTART_POLICY_LEAK"

        if docker_run "$DOCKER_STOP_TIMEOUT" "stop" stop "$CONTAINER" >/dev/null 2>&1; then
            log "Container $CONTAINER stopped"
        else
            log "Warning: failed to stop container $CONTAINER after tun0-down detection"
        fi

        date +%s > "$RESTARTSTAMP"
        exit 1
    else
        # A restart brought the container back but the tunnel still fails. v2.3
        # only logged here and left it running on the image's kill switch alone;
        # stop it again (silently -- the incident already reported it).
        log "Stopping container $CONTAINER again (lock held) -- $TUN_CAUSE"
        incident_event 1 0 "$TUN_CAUSE"
        set_restart_policy "$RESTART_POLICY_LEAK"
        docker_run "$DOCKER_STOP_TIMEOUT" "stop" stop "$CONTAINER" >/dev/null 2>&1 || \
            log "Warning: failed to stop container $CONTAINER (lock held)"
        date +%s > "$RESTARTSTAMP"
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
        # Opened silently: the CRIT above is the message. This only keeps the
        # restart churn that follows from sending anything more.
        incident_event 1 0 "IP leak: container IP matched the host."

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
    incident_clean_check
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
