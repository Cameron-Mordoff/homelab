#!/bin/bash
# =============================================================================
# boot-restart.sh - restart containers that come up broken after a reboot
#
# Docker autostart runs before the host's resolver is ready. Containers that
# start in that window can stay broken until restarted:
#   binhex-plex - started with an empty resolv.conf, so items stayed unmatched
#   Doplarr     - hung after "Starting messaging process" and never reached
#                 the Discord gateway (offline ~37h after the 2026-11-23 boot)
# This waits until the host resolves DNS and each container is running, waits
# another SETTLE seconds, then restarts each container once. It logs to syslog
# under the tag "boot-restart".
#
# Schedule from the User Scripts plugin: "At Startup of Array"
# =============================================================================

CONTAINERS=(binhex-plex Doplarr)
SETTLE=180          # seconds after DNS + containers are up before restarting
MAX_WAIT=1200       # give up waiting after this many seconds
DNS_TEST="discord.com"

set -uo pipefail

# Run detached so the array-start event isn't held up by the waits below.
if [[ "${BOOT_RESTART_BG:-}" != 1 ]]; then
    BOOT_RESTART_BG=1 setsid nohup "$0" "$@" >/dev/null 2>&1 &
    echo "boot-restart: running in background, see syslog"
    exit 0
fi

log() { logger -t boot-restart "$*"; }

waited=0
until getent hosts "$DNS_TEST" >/dev/null; do
    (( waited >= MAX_WAIT )) && { log "DNS still failing after ${MAX_WAIT}s, restarting anyway"; break; }
    sleep 10; (( waited += 10 ))
done

for c in "${CONTAINERS[@]}"; do
    until [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == true ]]; do
        (( waited >= MAX_WAIT )) && break
        sleep 10; (( waited += 10 ))
    done
done

sleep "$SETTLE"

for c in "${CONTAINERS[@]}"; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != true ]]; then
        log "$c not running, skipped"
        continue
    fi
    if docker restart "$c" >/dev/null 2>&1; then
        log "restarted $c"
    else
        log "restart of $c FAILED"
    fi
done
