# IP Leak Watchdog

A watchdog script for Synology DSM 7.2.x that runs every 10 seconds and stops a Transmission+VPN Docker container if your real IP address is exposed. This covers two failure modes: the VPN tunnel dropping inside the container (detected instantly via `tun0`), and the VPN provider itself leaking your real IP despite an active tunnel (detected via external IP comparison). Automatically restarts the container once the VPN recovers.

## How it works

The script runs every 10 seconds via a cron loop. Each run:

1. Checks if the container is running — if not, attempts an automatic restart (with cooldown and rate limiting)
2. Skips checks during the startup grace period (first 120 seconds after container start)
3. **Fast check (every 10s):** verifies `tun0` is UP inside the container — if not, stops immediately
4. **Full check (every 60s):** fetches the host's public IP and the container's IP via `ifconfig.me`, validates both are real IPv4 addresses, and compares them
5. If IPs match, the VPN is leaking — stops the container, sets restart policy to `no`, and writes JSON marker files
6. If IPs differ, logs OK and clears any leak state

On recovery (container stopped after a detected leak), the script re-enables the `unless-stopped` restart policy before starting the container.

## Requirements

- Synology DSM 7.2.x
- Docker package installed (Container Manager)
- `haugene/transmission-openvpn` container running with a VPN provider (tested with PIA)
- SSH access to the NAS with a user that has Docker permissions

## Transmission + VPN container setup

This script is designed for use with [haugene/transmission-openvpn](https://github.com/haugene/docker-transmission-openvpn), which bundles Transmission and an OpenVPN client in a single container. The VPN tunnel is established inside the container — if it drops, all traffic falls back to the host's real IP.

### docker run example (PIA)

```bash
docker run -d \
  --name transmission-new \
  --cap-add NET_ADMIN \
  --dns 8.8.8.8 \
  --dns 8.8.4.4 \
  -e OPENVPN_PROVIDER=PIA \
  -e OPENVPN_CONFIG=us_east \
  -e OPENVPN_USERNAME=your_pia_username \
  -e OPENVPN_PASSWORD=your_pia_password \
  -e LOCAL_NETWORK=192.168.1.0/24 \
  -e TRANSMISSION_WEB_UI=flood-for-transmission \
  -p 9091:9091 \
  -v /path/to/transmission/config:/config \
  -v /path/to/transmission/data:/data \
  -v /path/to/downloads:/downloads \
  --restart unless-stopped \
  haugene/transmission-openvpn
```

Key points:

- **`--cap-add NET_ADMIN`** — required for OpenVPN to manage the network interface inside the container
- **`LOCAL_NETWORK`** — must match your LAN subnet so the Transmission web UI remains accessible while the VPN is active; without this, LAN traffic is also routed through the VPN tunnel and the UI becomes unreachable
- **`--restart unless-stopped`** — the watchdog depends on this being the default policy; it temporarily sets it to `no` during a leak to prevent Docker auto-restarting into a leaked state, then restores it before a clean restart

### Why a watchdog is needed

DSM 7.2.x runs a Linux 4.4 kernel. OpenVPN tunnels can drop silently under this kernel without the container restarting — the container stays up and Transmission keeps downloading, but all traffic goes out over the host's real IP. The watchdog catches this within one minute and stops the container before further exposure.

### PIA server list

Available `OPENVPN_CONFIG` values for PIA are listed in the [haugene config repo](https://github.com/haugene/vpn-configs-contrib/tree/main/openvpn/pia). Examples: `us_east`, `us_west`, `netherlands`, `uk_london`.

## Installation

1. Copy `ip-leak-check.sh` to your NAS:

```bash
scp ip-leak-check.sh your_user@your-nas:/path/to/transmission/ip-leak-check.sh
ssh your_user@your-nas "chmod +x /path/to/transmission/ip-leak-check.sh"
```

2. Add a cron entry by editing `/etc/crontab` directly as root, passing your paths as environment variables:

```
* * * * * root /bin/sh -c 'export CONTAINER=your-container LOGDIR=/path/to/transmission; i=0; while [ $i -lt 6 ]; do /path/to/transmission/ip-leak-check.sh; i=$((i+1)); [ $i -lt 6 ] && sleep 10; done'
```

This runs the script every 10 seconds (6 times per minute). The fast `tun0` check fires on every run; the external IP check is throttled internally to once per minute.

> **Note:** Do not add a log redirect (`>> logfile`) to the cron entry — the script handles its own logging internally via `tee`.

## Configuration

All variables can be set as environment variables before the script runs. Each falls back to a sensible default if not set.

| Variable | Default | Description |
|---|---|---|
| `CONTAINER` | _(required)_ | Docker container name |
| `LOGDIR` | `/volume1/docker/$CONTAINER` | Directory for log files |
| `MARKER_DIR` | _(unset)_ | Directory for Gotify JSON marker files — omit to disable marker output entirely |
| `GRACE_SECONDS` | `120` | Seconds to skip checks after container start |
| `RESTART_COOLDOWN` | `300` | Seconds between restart attempts |
| `RESTART_WINDOW` | `3600` | Rolling window for restart rate limiting (seconds) |
| `MAX_RESTARTS_PER_WINDOW` | `3` | Max restart attempts per window |
| `FULL_CHECK_INTERVAL` | `60` | Seconds between external IP checks |
| `MAXSIZE` | `1048576` | Log rotation threshold (1 MB) |
| `RUNLOCK_MAX_AGE` | `120` | Seconds after which the run-lock is broken unconditionally, whatever holds the PID |
| `DOCKER_EXEC_TIMEOUT` | `15` | Hard cap in seconds on any single `docker exec` |
| `DOCKER_TIMEOUT` | `15` | Hard cap in seconds on `docker inspect` / `update` / `start` |
| `DOCKER_STOP_TIMEOUT` | `30` | Hard cap in seconds on `docker stop` (it has its own 10s SIGTERM grace) |
| `TIMEOUT_BIN` | `/usr/bin/timeout` | Path to `timeout` (not on `PATH` under cron on DSM) |
| `DEADMAN_MAX_AGE` | `300` | Alert if the log stops advancing for this many seconds (`0` disables) |
| `DEADMAN_REPEAT` | `1800` | Minimum seconds between repeat dead-man alerts |
| `GOTIFY_URL` | _(unset)_ | Gotify base URL, e.g. `http://localhost:8090` — omit to disable push |
| `GOTIFY_APP_TOKEN` | _(unset)_ | Gotify application token |

Set env vars inline in the cron entry (see Installation) or export them from a config file sourced before the script.

## Gotify notifications (optional)

If you use [Gotify](https://gotify.net/) for push notifications, set `MARKER_DIR` to a directory that your Gotify notification script watches. The watchdog will write JSON marker files there whenever a leak or restart event occurs.

Set it in your cron entry:

```
MARKER_DIR=/path/to/gotify/markers
```

### Marker files written

| File | Written when |
|---|---|
| `$CONTAINER.last-leak.json` | IP leak or tun0-down detected |
| `$CONTAINER.last-restart.json` | Restart attempted (any reason) |
| `$CONTAINER.reason.json` | Container stopped due to leak |

Each file contains:

```json
{"reason":"ip_leak","host_ip":"203.0.113.1","container_ip":"203.0.113.1","ts":"2026-05-22T15:11:01+00:00","note":"container stopped due to IP leak"}
```

Fields: `reason`, `host_ip`, `container_ip`, `ts` (ISO 8601), `note`.

If `MARKER_DIR` is not set, no marker files are written and Gotify integration is fully disabled.

### Dead-man's switch

Marker files only get written when the script is *running*. A watchdog that has
stopped running cannot report its own death — in September 2026 this script sat
wedged on a stale run-lock for 15 hours with leak protection off and never sent a
single alert, because the process that sends alerts was the one that had died.

The dead-man's switch closes that gap. On every invocation, before any logic that
can exit early, it compares the age of `ip-leak.log` against `DEADMAN_MAX_AGE`
(default 300s). A healthy watchdog appends a line at least once per
`FULL_CHECK_INTERVAL`, so a log that has not advanced in five minutes means the
checks are not happening.

When it trips, the switch writes a warning to the log and — if `GOTIFY_URL` and
`GOTIFY_APP_TOKEN` are both set — pushes a high-priority Gotify message. Repeat
alerts are throttled to one per `DEADMAN_REPEAT` (default 30 min), and the reported
outage is measured from when the stall began, not from the last alert.

```
GOTIFY_URL=http://localhost:8090
GOTIFY_APP_TOKEN=your-app-token
```

Leave both unset to keep the log warning without the push. Note this covers a
script that runs but cannot check; it cannot cover cron itself being stopped,
since nothing in the script runs in that case.

## Log files

Logs are written to `$LOGDIR/ip-leak.log` and rotated at 1 MB (keeps `.1`, `.2`, `.3`).

```
2026-05-22 15:10:01 - OK (Host=203.0.113.1, Container=198.51.100.42)
2026-05-22 15:11:01 - IP leak detected! Host=203.0.113.1, Container=203.0.113.1
2026-05-22 15:11:01 - Container transmission-new stopped due to IP leak
2026-05-22 15:16:02 - Container transmission-new is stopped after leak event; attempting automatic restart
2026-05-22 15:16:03 - Container transmission-new started successfully; startup grace period will apply
```

## Behavior reference

| Situation | Action |
|---|---|
| VPN healthy | Log OK, clear any leak state |
| IP leak detected | Stop container, set restart policy to `no`, write markers, create lockfile |
| Leak lockfile present, cooldown active | Log cooldown remaining, skip restart |
| Leak lockfile present, cooldown elapsed, internet healthy | Re-enable restart policy, start container |
| Max restarts reached in window | Suppress restart, log warning |
| Container stopped unexpectedly (no lockfile) | Attempt restart if internet healthy and under rate limit |
| `ifconfig.me` returns non-IP / blank | Skip check, log warning |

## Testing

Uncomment the test override lines near the bottom of the script to simulate a leak without actually having one:

```bash
# PUBLIC_IP=1.2.3.4
# CONTAINER_IP=1.2.3.4
```

Run manually to verify behavior:

```bash
bash /path/to/transmission/ip-leak-check.sh
```

## Changelog

### v2.3 (2026-09-01)
- **Every docker call is now bounded, not just `docker exec`.** `inspect`, `update`,
  `start` and `stop` block on an unresponsive dockerd exactly the way `exec` does, so
  bounding only `exec` left the same hang available through six other call sites — and
  the very first thing the script does is a `docker inspect`.
- All docker invocations route through a single `docker_run` helper, so a timeout is
  **logged** (`docker inspect(Running) timed out after 15s`) instead of silently looking
  like "container absent". The warning goes to stderr so it can never contaminate a
  captured stdout value such as `$RUNNING`.
- `docker stop` gets its own longer budget (`DOCKER_STOP_TIMEOUT`, 30s) because it has a
  10s SIGTERM grace of its own; sharing the 15s control-plane cap would have produced
  false "failed to stop container" warnings on a perfectly normal stop.
- If `TIMEOUT_BIN` is missing, the script logs a warning and runs docker unbounded rather
  than failing every docker call — previously only the two `exec` calls depended on it.

### v2.2 (2026-09-01)
- **Run-lock no longer deadlocks on PID reuse.** `kill -0` on a bare PID only proves
  *something* holds that PID, not that it is this script. Over a long stall the PID was
  reused by an unrelated live process, so the staleness check kept succeeding and the
  lock was never broken — self-healing logic became a permanent deadlock (silently dead
  for 15h on 2026-09-01, with leak protection off the whole time).
  The lock is now broken unconditionally once it is older than `RUNLOCK_MAX_AGE`
  (default 120s), which is the only guard that survives PID reuse.
- **PID identity is verified before a live PID is trusted**, via `/proc/<pid>/cmdline`.
  A live PID that is not this script no longer holds the lock.
- **Every `docker exec` is bounded by `timeout`** (`DOCKER_EXEC_TIMEOUT`, default 15s).
  `curl --max-time` bounds only the inner curl; `docker exec` itself hangs indefinitely
  against an unresponsive dockerd, which is what stranded the lock in the first place.
  A timed-out tunnel check fails closed (container stopped), the safe direction.
- **Added a dead-man's switch**: if `ip-leak.log` stops advancing for `DEADMAN_MAX_AGE`
  (default 300s), the script logs a warning and pushes a high-priority Gotify alert when
  `GOTIFY_URL` / `GOTIFY_APP_TOKEN` are set. A dead watchdog previously failed silently,
  because the script that raises alerts was the script that had died.
- Run-lock breaks are now logged rather than silent, so the condition is visible in
  `ip-leak.log` instead of only inferable from missing output.

### v2.1 (2026-05-22)
- Gotify marker output is now optional — set `MARKER_DIR` env var to enable, omit to disable
- `write_json_marker` is a no-op when `MARKER_DIR` is unset — no marker directory is created or written to
- `mkdir` for marker directory only runs when `MARKER_DIR` is set

### v2.0 (2026-05-22)
- All configuration variables (`CONTAINER`, `LOGDIR`, `MARKER_DIR`, `GRACE_SECONDS`, `RESTART_COOLDOWN`, `RESTART_WINDOW`, `MAX_RESTARTS_PER_WINDOW`, `FULL_CHECK_INTERVAL`, `MAXSIZE`) now read from environment variables with sensible defaults — no need to edit the script for different deployments
- `LOGDIR` defaults to `/volume1/docker/$CONTAINER` so it automatically follows the container name

### v1.9 (2026-05-22)
- Hybrid check: fast `tun0` interface check every 10 seconds, full external IP comparison every 60 seconds
- `tun0` down is now treated as a leak event — container stopped immediately, markers written, same recovery flow
- Cron entry updated to loop 6× per minute with 10-second intervals via `/bin/sh -c`
- External IP checks no longer hammered on every run — throttled via `LAST_FULL_CHECK_FILE` timestamp

### v1.8 (2026-05-22)
- Added `is_ipv4()` validation — prevents false positive leak detection if `ifconfig.me` returns an error page or non-IP string
- Atomic lockfile creation using `set -C` subshell — prevents duplicate stop attempts on concurrent runs
- Removed `docker exec -i` flag — unnecessary for non-interactive use, can hang in environments with no TTY
- Removed dead timeout case patterns — `curl -s` returns empty on timeout, already caught by blank-response guard

### v1.7 (2026-04-20)
- Initial release
