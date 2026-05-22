# IP Leak Watchdog

A watchdog script for Synology DSM 7.2.x that runs every minute via cron and stops a Transmission+VPN Docker container if the VPN leaks the host's real IP address. Automatically restarts the container once the VPN recovers.

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
* * * * * root /bin/sh -c 'CONTAINER=your-container LOGDIR=/path/to/transmission MARKER_DIR=/path/to/gotify/markers; i=0; while [ $i -lt 6 ]; do /path/to/transmission/ip-leak-check.sh; i=$((i+1)); [ $i -lt 6 ] && sleep 10; done'
```

This runs the script every 10 seconds (6 times per minute). The fast `tun0` check fires on every run; the external IP check is throttled internally to once per minute.

> **Note:** Do not add a log redirect (`>> logfile`) to the cron entry — the script handles its own logging internally via `tee`.

## Configuration

All variables can be set as environment variables before the script runs. Each falls back to a sensible default if not set.

| Variable | Default | Description |
|---|---|---|
| `CONTAINER` | `transmission-new` | Docker container name |
| `LOGDIR` | `/volume1/docker/$CONTAINER` | Directory for log files |
| `MARKER_DIR` | _(unset)_ | Directory for Gotify JSON marker files — omit to disable marker output entirely |
| `GRACE_SECONDS` | `120` | Seconds to skip checks after container start |
| `RESTART_COOLDOWN` | `300` | Seconds between restart attempts |
| `RESTART_WINDOW` | `3600` | Rolling window for restart rate limiting (seconds) |
| `MAX_RESTARTS_PER_WINDOW` | `3` | Max restart attempts per window |
| `FULL_CHECK_INTERVAL` | `60` | Seconds between external IP checks |
| `MAXSIZE` | `1048576` | Log rotation threshold (1 MB) |

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
