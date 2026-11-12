#!/bin/bash
# =============================================================================
# deluge-seed-cleanup.sh - remove torrents that have met their tracker's seed time
#
# Private trackers want a minimum seed time (TorrentLeech: 8 days), after which
# the torrent is just sitting in Deluge. Neither Deluge (ratio-only queue rules)
# nor Radarr/Sonarr (seed-time removal isn't supported for Deluge) clean these up.
#
# A torrent is removed WITH its data only when ALL of these hold:
#   - its tracker matches TRACKER_RE
#   - it has finished and has seeded >= MIN_SEED_DAYS (Deluge's own seeding
#     time - only counts time actually seeding, so it errs on the long side)
#   - it carries an arr label (ARR_LABELS) - unlabeled = manual grab, never touched
#   - every video file over 50 MB has a hardlink elsewhere (st_nlink > 1), i.e.
#     Radarr/Sonarr imported it. Removing the data then only drops the torrent's
#     copy of the link; the library file stays.
# Anything that passes the seed time but is NOT imported (RAR'd release, failed
# import, ...) is left alone and reported to Discord once.
#
# Discord webhook goes in CONF_FILE (never in this repo):
#   DISCORD_SEED_WEBHOOK="https://discord.com/api/webhooks/..."
# Schedule from the User Scripts plugin: custom cron "40 6 * * *".
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
DELUGE_CONTAINER="binhex-delugevpn"
TRACKER_RE='torrentleech\.org|tleechreload\.org'
MIN_SEED_DAYS="${MIN_SEED_DAYS:-8}"
ARR_LABELS="radarr,radarr-4k,tv-sonarr"
MAX_ACTIONS=25              # removals per run (circuit breaker)

DRY_RUN="${DRY_RUN:-true}"  # true = decide + post to Discord, change nothing

CONF_FILE="/boot/config/plugins/user.scripts/deluge-seed-cleanup.conf"
STATE_FILE="/mnt/user/appdata/deluge-seed-cleanup/notified.json"
HC_KEY_FILE="/boot/config/plugins/user.scripts/healthchecks.key"
HC_SLUG="deluge-seed-cleanup"
# -----------------------------------------------------------------------------

set -uo pipefail

log() { echo "[$(date '+%F %T')] $*"; }
hc()  { [[ -r "$HC_KEY_FILE" ]] || return 0
        curl -fsS -m 10 --retry 3 -o /dev/null "https://hc-ping.com/$(<"$HC_KEY_FILE")/$HC_SLUG$1?create=1" || true; }

command -v jq >/dev/null || { log "FATAL: jq not found"; hc /fail; exit 1; }
DISCORD_SEED_WEBHOOK=""
# shellcheck source=/dev/null
[[ -r "$CONF_FILE" ]] && . "$CONF_FILE"

log "===== Run start (DRY_RUN=$DRY_RUN, MIN_SEED_DAYS=$MIN_SEED_DAYS) ====="

# The Deluge client library lives in the container, so the decision + removal
# runs there. It prints one JSON object per candidate torrent.
OUT=$(docker exec -i \
        -e TRACKER_RE="$TRACKER_RE" -e MIN_SEED_DAYS="$MIN_SEED_DAYS" -e ARR_LABELS="$ARR_LABELS" \
        -e MAX_ACTIONS="$MAX_ACTIONS" -e DRY_RUN="$DRY_RUN" \
        "$DELUGE_CONTAINER" python3 - <<'PY'
import json, os, re, sys
from deluge.ui.client import client
from twisted.internet import reactor, defer

TRACKER = re.compile(os.environ["TRACKER_RE"], re.I)
MIN_SECS = float(os.environ["MIN_SEED_DAYS"]) * 86400
LABELS = set(os.environ["ARR_LABELS"].split(","))
MAX_ACTIONS = int(os.environ["MAX_ACTIONS"])
DRY = os.environ["DRY_RUN"] == "true"
VIDEO = re.compile(r"\.(mkv|mp4|avi|m2ts|ts|wmv|mov)$", re.I)
FIELDS = ["name", "tracker_host", "seeding_time", "is_finished", "label", "save_path", "files"]

def emit(**kw):
    print(json.dumps(kw), flush=True)

def imported(s):
    """(ok, why) - every video file > 50 MB is hardlinked elsewhere."""
    vids = [f for f in s["files"] if VIDEO.search(f["path"]) and f["size"] > 50e6
            and "sample" not in f["path"].lower()]
    if not vids:
        return False, "no video files (RAR'd or extras-only release?)"
    for f in vids:
        p = os.path.join(s["save_path"], f["path"])
        try:
            if os.stat(p).st_nlink < 2:
                return False, "not hardlinked into the library: " + f["path"]
        except FileNotFoundError:
            return False, "file missing on disk: " + f["path"]
    return True, ""

@defer.inlineCallbacks
def main():
    try:
        user, pw = open("/config/auth").readline().strip().split(":")[:2]
        yield client.connect("127.0.0.1", 58846, user, pw)
        torrents = yield client.core.get_torrents_status({}, FIELDS)
        actions = 0
        for h, s in sorted(torrents.items(), key=lambda x: -x[1]["seeding_time"]):
            if not TRACKER.search(s["tracker_host"] or "") or not s["is_finished"]:
                continue
            if s["seeding_time"] < MIN_SECS:
                continue
            base = dict(hash=h, name=s["name"], days=round(s["seeding_time"] / 86400, 1), label=s["label"])
            if s["label"] not in LABELS:
                emit(action="skip", why="no arr label (manual grab)", **base); continue
            ok, why = imported(s)
            if not ok:
                emit(action="notify", why=why, **base); continue
            if actions >= MAX_ACTIONS:
                emit(action="capped", why="action cap reached - next run", **base); continue
            if not DRY:
                yield client.core.remove_torrent(h, True)
            actions += 1
            emit(action="remove", why="", **base)
    except Exception as e:
        emit(action="error", why=repr(e), hash="", name="", days=0, label="")
    finally:
        reactor.stop()

reactor.callWhenRunning(main)
reactor.run()
PY
)
RC=$?

FAILED=0
[[ $RC -ne 0 ]] && { log "docker exec failed (rc=$RC) - is $DELUGE_CONTAINER running?"; FAILED=1; }

mkdir -p "$(dirname "$STATE_FILE")"
NOTIFIED=$(jq -c . "$STATE_FILE" 2>/dev/null) || NOTIFIED='[]'
REPORT=()
REMOVED=0

while IFS= read -r L; do
    [[ -z "$L" ]] && continue
    A=$(jq -r .action <<<"$L"); H=$(jq -r .hash <<<"$L")
    LINE="$(jq -r '"`\(.name)` (\(.days)d, \(.label // "-"))"' <<<"$L")"
    WHY=$(jq -r .why <<<"$L")
    case "$A" in
        remove)
            VERB="removed"; [[ "$DRY_RUN" == true ]] && VERB="would remove"
            log "  $VERB $LINE"; REMOVED=$((REMOVED+1))
            REPORT+=("🧹 $VERB $LINE") ;;
        notify)
            log "  NOT IMPORTED $LINE - $WHY"
            if ! jq -e --arg h "$H" 'index($h)' <<<"$NOTIFIED" >/dev/null; then
                REPORT+=("⚠️ $LINE seeded out but kept: $WHY")
                NOTIFIED=$(jq -c --arg h "$H" '. + [$h]' <<<"$NOTIFIED")
            fi ;;
        skip|capped) log "  SKIP $LINE - $WHY" ;;
        error) log "  ERROR: $WHY"; FAILED=1 ;;
    esac
done <<<"$OUT"

# Keep notified hashes only while they're still candidates (dry runs don't
# record removals, so they'd otherwise repost daily).
STILL=$(jq -Rsc '[split("\n")[] | select(length>0) | fromjson | select(.action=="notify") | .hash]' <<<"$OUT" 2>/dev/null || echo '[]')
jq -c --argjson s "$STILL" '[.[] | select(IN($s[]))]' <<<"$NOTIFIED" > "$STATE_FILE"

if (( ${#REPORT[@]} > 0 )); then
    if [[ -z "$DISCORD_SEED_WEBHOOK" ]]; then
        log "No DISCORD_SEED_WEBHOOK in $CONF_FILE - Discord post skipped"
    else
        TITLE="Deluge seed cleanup"; [[ "$DRY_RUN" == true ]] && TITLE="Deluge seed cleanup (dry run - nothing removed)"
        code=$(printf '%s\n' "${REPORT[@]}" | jq -Rsc --arg t "$TITLE" \
                 '{username: "Andromeda", embeds: [{title: $t, color: 3447003, description: (.[0:4000])}]}' \
               | curl -s -m 20 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d @- "$DISCORD_SEED_WEBHOOK")
        [[ "$code" == 2* ]] || { log "Discord post failed (HTTP $code)"; FAILED=1; }
    fi
fi

if [[ "$FAILED" -ne 0 ]]; then hc /fail; log "===== Run end (with errors) ====="; exit 1; fi
hc ""
log "===== Run end ($REMOVED removal(s)$([[ "$DRY_RUN" == true ]] && echo ', dry run')) ====="
