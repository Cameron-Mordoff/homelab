#!/bin/bash
# =============================================================================
# smart-selftest.sh - start a SMART extended self-test on every array disk
#
# Unraid never schedules self-tests on its own, and SMART attributes only show
# damage the disk has already tripped over. The extended test reads every
# sector, so it finds weak areas before a rebuild has to. It runs inside the
# drive firmware: the array stays usable (a bit slower) and a 12 TB HGST takes
# ~20 h. Disks must not spin down mid-test, or it aborts - spindown is off here.
#
# This only STARTS the tests. health-report.sh (Mondays) reports the result of
# each disk's newest test and warns when one is older than ~100 days.
#
# Schedule from the User Scripts plugin: custom cron "0 2 15 1,4,7,10 *"
# (mid-month, the month BEFORE each quarterly parity check, so they never overlap).
# =============================================================================

HC_KEY_FILE="/boot/config/plugins/user.scripts/healthchecks.key"   # project ping key
HC_SLUG="smart-selftest"

set -uo pipefail

log() { echo "[$(date '+%F %T')] $*"; }
hc()  { [[ -r "$HC_KEY_FILE" ]] || return 0
        curl -fsS -m 10 --retry 3 -o /dev/null "https://hc-ping.com/$(<"$HC_KEY_FILE")/$HC_SLUG$1" || true; }

# Parity + data disks: disks.ini sections with a device and type Parity/Data
DEVS=$(awk -F= '/^\[/{if(d!=""&&(t=="Parity"||t=="Data"))print d; d=t=""} {v=$2; gsub(/"/,"",v)} $1=="device"{d=v} $1=="type"{t=v}
                END{if(d!=""&&(t=="Parity"||t=="Data"))print d}' /var/local/emhttp/disks.ini)
[[ -n "$DEVS" ]] || { log "FATAL: no array disks found"; hc /fail; exit 1; }

FAILED=0
for dev in $DEVS; do
    if smartctl -c "/dev/$dev" | grep -q 'Self-test routine in progress'; then
        log "$dev: a self-test is already running - skipped"; continue
    fi
    if smartctl -t long "/dev/$dev" >/dev/null; then log "$dev: extended self-test started"
    else log "$dev: FAILED to start self-test"; FAILED=1; fi
done

[[ $FAILED -eq 0 ]] && hc "" || hc /fail
exit $FAILED
