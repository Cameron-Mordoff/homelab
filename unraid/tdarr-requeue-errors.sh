#!/bin/bash
# =============================================================================
# tdarr-requeue-errors.sh - give Tdarr's errored files another go
#
# The language-cleanup plugin (tdarr/Tdarr_Plugin_hl01_Keep_English_And_Original.js)
# throws instead of skipping when a problem is temporary: the file is still
# hardlinked to a seeding torrent, or Radarr/Sonarr couldn't be reached. Tdarr
# parks those files in its transcode error table and never looks at them
# again on its own. This script puts every file in that table back in the
# queue; the ones that are still seeding just error out again until next run.
#
# Health check errors are NOT requeued - those are real problems with the
# file and are posted to Discord by Tdarr itself.
#
# Needs a Tdarr API key (Tdarr has auth on) in TDARR_KEY_FILE.
# Schedule from the User Scripts plugin: custom cron "30 6 * * 0".
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
TDARR_URL="http://localhost:8265"
TDARR_KEY_FILE="/boot/config/plugins/user.scripts/tdarr.key"
MAX_REQUEUE=500             # per run
DRY_RUN=false               # true = log what would be requeued, change nothing

HC_KEY_FILE="/boot/config/plugins/user.scripts/healthchecks.key"   # project ping key
HC_SLUG="tdarr-requeue-errors"
# -----------------------------------------------------------------------------

set -uo pipefail

log() { echo "[$(date '+%F %T')] $*"; }
hc()  { [[ -r "$HC_KEY_FILE" ]] || return 0
        curl -fsS -m 10 --retry 3 -o /dev/null "https://hc-ping.com/$(<"$HC_KEY_FILE")/$HC_SLUG$1" || true; }
die() { log "FATAL: $*"; hc /fail; exit 1; }

# tdarr PATH JSON
tdarr() { curl -sf --max-time 120 -H "x-api-key: $TKEY" -H 'Content-Type: application/json' \
            -X POST -d "$2" "$TDARR_URL/api/v2/$1"; }

command -v jq >/dev/null || die "jq not found"
[[ -r "$TDARR_KEY_FILE" ]] || die "no Tdarr API key at $TDARR_KEY_FILE"
TKEY=$(<"$TDARR_KEY_FILE")
log "===== Run start (DRY_RUN=$DRY_RUN) ====="

# table3 = transcode error/cancelled
ERRORS=$(tdarr client/status-tables "$(jq -nc --argjson n "$MAX_REQUEUE" \
           '{data: {start: 0, pageSize: $n, filters: [], sorts: [], opts: {table: "table3"}}}')") \
    || die "Tdarr API call failed"
log "Error table: $(jq .totalCount <<<"$ERRORS") file(s)"

N=0; FAILED=0
while read -r id; do
    if [[ "$DRY_RUN" == true ]]; then log "  WOULD requeue: $id"; N=$((N+1)); continue; fi
    if tdarr cruddb "$(jq -nc --arg id "$id" \
         '{data: {collection: "FileJSONDB", mode: "update", docID: $id, obj: {TranscodeDecisionMaker: "Queued"}}}')" >/dev/null; then
        log "  requeued: $id"; N=$((N+1))
    else
        log "  requeue FAILED: $id"; FAILED=1
    fi
done < <(jq -r '.array[]._id' <<<"$ERRORS")
log "Requeued $N file(s)"

if [[ "$FAILED" -ne 0 ]]; then hc /fail; exit 1; fi
hc ""
log "===== Run end ====="
