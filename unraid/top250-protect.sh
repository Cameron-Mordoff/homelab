#!/bin/bash
# =============================================================================
# top250-protect.sh - keep radarr-regrab.sh away from the IMDb Top 250
#
# radarr-regrab.sh replaces oversized Bluray-1080p files with smaller releases
# and ignores custom-format scores, so it will happily swap a top-tier encode
# of a classic for a mediocre 6 GiB/h one. It skips any movie tagged
# regrab-skip. This script adds that tag to every movie in the library that is
# on the IMDb Top 250.
#
# The list comes from Radarr's own list API (the same source Radarr's
# "IMDb Lists" import list uses for listId top250), matched by IMDb id, then
# TMDb id as a fallback. A Radarr import list can't do this: list tags only
# apply to movies the list ADDS, never to ones already in the library.
#
# Add-only: tags are never removed, so a film dropping off the chart stays
# protected, and hand-tagged favorites are untouched.
#
# Schedule from the User Scripts plugin: custom cron "15 0 * * *" (daily,
# before radarr-regrab's 01:00 window opens).
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
RADARR_URL="${RADARR_URL:-http://localhost:7878}"
API_KEY_FILE="/boot/config/plugins/user.scripts/radarr-regrab.key"
LIST_URL="https://api.radarr.video/v1/list/imdb/top250"
SKIP_TAG="regrab-skip"      # must match SKIP_TAG in radarr-regrab.sh
MIN_LIST_SIZE=200           # refuse to act on a truncated/broken list
DRY_RUN=false               # true = log what would be tagged, change nothing
# -----------------------------------------------------------------------------

set -uo pipefail

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "FATAL: $*"; exit 1; }

api() { curl -sf --max-time 60 -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' "$@"; }

command -v jq >/dev/null || die "jq not found"
[[ -r "$API_KEY_FILE" ]] || die "no Radarr API key at $API_KEY_FILE"
KEY=$(<"$API_KEY_FILE")
log "===== Run start (DRY_RUN=$DRY_RUN) ====="

LIST=$(curl -sf --max-time 60 "$LIST_URL") || die "couldn't fetch $LIST_URL"
LIST_N=$(jq 'length' <<<"$LIST" 2>/dev/null) || die "list isn't JSON"
(( LIST_N >= MIN_LIST_SIZE )) || die "list has only $LIST_N entries (< $MIN_LIST_SIZE), not trusting it"
log "Top 250 list: $LIST_N entries"
# Keep only the ids - the full list (overviews etc.) is too big for a jq --argjson.
LIST=$(jq -c 'map({ImdbId, TmdbId})' <<<"$LIST")

TAG_ID=$(api "$RADARR_URL/api/v3/tag" | jq -r --arg t "$SKIP_TAG" '.[] | select(.label==$t) | .id // empty') \
    || die "Radarr unreachable"
[[ -n "$TAG_ID" ]] || die "tag '$SKIP_TAG' doesn't exist in Radarr"

MOVIES=$(api "$RADARR_URL/api/v3/movie") || die "couldn't read Radarr movies"

# Library movies on the list, split into already-tagged and to-tag.
MATCH=$(jq -c --argjson list "$LIST" --argjson tag "$TAG_ID" '
    ($list | map(.ImdbId // empty) | map({key: ., value: 1}) | from_entries) as $imdb
  | ($list | map(.TmdbId // empty | tostring) | map({key: ., value: 1}) | from_entries) as $tmdb
  | [ .[] | select(($imdb[.imdbId // ""] // $tmdb[.tmdbId | tostring]) != null)
          | {id, title, year, tagged: (.tags | index($tag) != null)} ]' <<<"$MOVIES") \
    || die "matching failed"

log "In library: $(jq 'length' <<<"$MATCH") of $LIST_N, already tagged: $(jq '[.[] | select(.tagged)] | length' <<<"$MATCH")"

TODO=$(jq -c '[.[] | select(.tagged | not)]' <<<"$MATCH")
if [[ $(jq 'length' <<<"$TODO") -eq 0 ]]; then
    log "Nothing to tag"
else
    jq -r --arg dry "$DRY_RUN" '.[] | "  \(if $dry == "true" then "WOULD tag" else "tag" end): \(.title) (\(.year))"' <<<"$TODO" \
        | while read -r line; do log "$line"; done
    if [[ "$DRY_RUN" != true ]]; then
        api -X PUT "$RADARR_URL/api/v3/movie/editor" \
            -d "$(jq -c --argjson tag "$TAG_ID" '{movieIds: map(.id), tags: [$tag], applyTags: "add"}' <<<"$TODO")" \
            >/dev/null || die "tagging failed"
        log "Tagged $(jq 'length' <<<"$TODO") movie(s)"
    fi
fi
log "===== Run end ====="
