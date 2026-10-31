#!/bin/bash
# =============================================================================
# npm-log-rotate.sh - rotate Nginx Proxy Manager's per-host logs
#
# The jlesage/nginx-proxy-manager image ships a logrotate config for
# /data/logs (= /config/logs), but nginx writes every proxy host's access and
# error log to /config/log - a different directory. Those files have never
# been rotated and grew to ~6 GB on the cache NVMe. This rotates them from the
# host with copytruncate, so nginx needs no signal and keeps its open handles.
#
# Weekly, or sooner once a file passes MAX_SIZE (checked every run).
# Schedule from the User Scripts plugin: custom cron "40 4 * * *"
# =============================================================================

LOG_DIR="/mnt/user/appdata/NginxProxyManager/log"
KEEP=4                   # rotated copies per file (compressed)
MAX_SIZE="100M"
STATE="/mnt/user/appdata/npm-log-rotate/logrotate.state"

HC_KEY_FILE="/boot/config/plugins/user.scripts/healthchecks.key"   # project ping key
HC_SLUG="npm-log-rotate"

set -uo pipefail

hc() { [[ -r "$HC_KEY_FILE" ]] || return 0
       curl -fsS -m 10 --retry 3 -o /dev/null "https://hc-ping.com/$(<"$HC_KEY_FILE")/$HC_SLUG$1" || true; }

[[ -d "$LOG_DIR" ]] || { echo "no $LOG_DIR"; hc /fail; exit 1; }
mkdir -p "$(dirname "$STATE")"
CONF=$(mktemp); trap 'rm -f "$CONF"' EXIT
cat > "$CONF" <<EOF
$LOG_DIR/*.log {
    su nobody users
    weekly
    maxsize $MAX_SIZE
    rotate $KEEP
    compress
    missingok
    notifempty
    copytruncate
}
EOF

if logrotate -s "$STATE" "$CONF"; then
    echo "rotated; $LOG_DIR now $(du -sh "$LOG_DIR" | cut -f1)"; hc ""
else
    echo "logrotate failed"; hc /fail; exit 1
fi
