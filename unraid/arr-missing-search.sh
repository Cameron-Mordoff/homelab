#!/bin/bash
# =============================================================================
# arr-missing-search.sh - safety net for releases that RSS sync missed
#
# Sonarr and Radarr only grab new releases from RSS. They never re-search a
# monitored item on their own, so if a release falls between RSS polls, or an
# indexer was down or the grab failed, the item can sit missing until somebody
# clicks Search. This script does that click for recent items only:
#
#   Sonarr - monitored episodes of monitored series that aired between
#            LOOKBACK_DAYS ago and MIN_AGE_HOURS ago with no file
#   Radarr - monitored, available movies with no file whose latest release
#            date (digital/physical/cinema) is within RADARR_LOOKBACK_DAYS
#
# Items already in the download queue are skipped. Each run is capped so a bad
# day can't hammer the indexers. Old missing items are left alone on purpose:
# this only catches recent releases.
#
# API keys are read from each app's config.xml, so there's no key file to manage.
# Schedule from the User Scripts plugin: custom cron "20 */4 * * *".
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
SONARR_URL="http://localhost:8989"
RADARR_URL="http://localhost:7878"
SONARR_CONFIG="/mnt/user/appdata/sonarr/config.xml"
RADARR_CONFIG="/mnt/user/appdata/radarr/config.xml"

LOOKBACK_DAYS=14            # Sonarr: how far back an air date can be
MIN_AGE_HOURS=4             # Sonarr: give RSS this long after air before searching
RADARR_LOOKBACK_DAYS=60     # Radarr: how far back the latest release date can be
MAX_EPISODES=25             # per run
MAX_MOVIES=10               # per run
DRY_RUN=false               # true = log what would be searched, search nothing

HC_KEY_FILE="/boot/config/plugins/user.scripts/healthchecks.key"   # project ping key
HC_SLUG="arr-missing-search"
# -----------------------------------------------------------------------------

set -uo pipefail

log() { echo "[$(date '+%F %T')] $*"; }
hc()  { [[ -r "$HC_KEY_FILE" ]] || return 0
        curl -fsS -m 10 --retry 3 -o /dev/null "https://hc-ping.com/$(<"$HC_KEY_FILE")/$HC_SLUG$1" || true; }
key() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$1" 2>/dev/null; }

# app_get URL KEY PATH / app_cmd URL KEY JSON
app_get() { curl -sf --max-time 120 -H "X-Api-Key: $2" "$1/api/v3/$3"; }
app_cmd() { curl -sf --max-time 60 -H "X-Api-Key: $2" -H 'Content-Type: application/json' \
              -X POST -d "$3" "$1/api/v3/command" >/dev/null; }

command -v jq >/dev/null || { log "FATAL: jq not found"; hc /fail; exit 1; }

log "===== Run start (DRY_RUN=$DRY_RUN) ====="
NOW=$(date +%s)
FAILED=0

# ------------------------------- SONARR -------------------------------------
SKEY=$(key "$SONARR_CONFIG")
if [[ -z "$SKEY" ]]; then
    log "Sonarr: no ApiKey in $SONARR_CONFIG"; FAILED=1
elif ! MISSING=$(app_get "$SONARR_URL" "$SKEY" \
        "wanted/missing?page=1&pageSize=500&monitored=true&includeSeries=true&sortKey=episodes.airDateUtc&sortDirection=descending") \
     || ! QUEUE=$(app_get "$SONARR_URL" "$SKEY" "queue?page=1&pageSize=1000"); then
    log "Sonarr: API call failed"; FAILED=1
else
    PICK=$(jq -c --argjson now "$NOW" --argjson lb "$LOOKBACK_DAYS" --argjson age "$MIN_AGE_HOURS" \
              --argjson max "$MAX_EPISODES" --argjson q "$QUEUE" '
        ([$q.records[]?.episodeId] | map(tostring)) as $queued
        | [.records[]
           | select(.airDateUtc and .series.monitored)
           | (.airDateUtc | sub("\\.[0-9]+"; "") | fromdateiso8601) as $air
           | select($air >= $now - $lb*86400 and $air <= $now - $age*3600)
           | select((.id | tostring) as $i | $queued | index($i) | not)
           | {id, label: "\(.series.title) S\(.seasonNumber)E\(.episodeNumber)"}]
        | .[:$max]' <<<"$MISSING")
    N=$(jq length <<<"$PICK")
    if [[ "$N" -eq 0 ]]; then
        log "Sonarr: nothing recent missing"
    else
        jq -r '.[].label' <<<"$PICK" | sed 's/^/  Sonarr: /'
        if [[ "$DRY_RUN" == true ]]; then
            log "Sonarr: DRY_RUN - would search $N episode(s)"
        elif app_cmd "$SONARR_URL" "$SKEY" "$(jq -c '{name: "EpisodeSearch", episodeIds: map(.id)}' <<<"$PICK")"; then
            log "Sonarr: EpisodeSearch queued for $N episode(s)"
        else
            log "Sonarr: EpisodeSearch command failed"; FAILED=1
        fi
    fi
fi

# ------------------------------- RADARR -------------------------------------
RKEY=$(key "$RADARR_CONFIG")
if [[ -z "$RKEY" ]]; then
    log "Radarr: no ApiKey in $RADARR_CONFIG"; FAILED=1
elif ! MISSING=$(app_get "$RADARR_URL" "$RKEY" "wanted/missing?page=1&pageSize=500&monitored=true") \
     || ! QUEUE=$(app_get "$RADARR_URL" "$RKEY" "queue?page=1&pageSize=1000"); then
    log "Radarr: API call failed"; FAILED=1
else
    PICK=$(jq -c --argjson now "$NOW" --argjson lb "$RADARR_LOOKBACK_DAYS" \
              --argjson max "$MAX_MOVIES" --argjson q "$QUEUE" '
        [$q.records[]?.movieId] as $queued
        | [.records[]
           | select(.isAvailable and .monitored)
           | ([.digitalRelease, .physicalRelease, .inCinemas]
              | map(select(.) | sub("\\.[0-9]+"; "") | fromdateiso8601) | max) as $rel
           | select($rel == null or $rel >= $now - $lb*86400)
           | select(.id as $i | $queued | index($i) | not)
           | {id, label: "\(.title) (\(.year))"}]
        | .[:$max]' <<<"$MISSING")
    N=$(jq length <<<"$PICK")
    if [[ "$N" -eq 0 ]]; then
        log "Radarr: nothing recent missing"
    else
        jq -r '.[].label' <<<"$PICK" | sed 's/^/  Radarr: /'
        if [[ "$DRY_RUN" == true ]]; then
            log "Radarr: DRY_RUN - would search $N movie(s)"
        elif app_cmd "$RADARR_URL" "$RKEY" "$(jq -c '{name: "MoviesSearch", movieIds: map(.id)}' <<<"$PICK")"; then
            log "Radarr: MoviesSearch queued for $N movie(s)"
        else
            log "Radarr: MoviesSearch command failed"; FAILED=1
        fi
    fi
fi

if [[ "$FAILED" -ne 0 ]]; then hc /fail; exit 1; fi
hc ""
log "===== Run end ====="
