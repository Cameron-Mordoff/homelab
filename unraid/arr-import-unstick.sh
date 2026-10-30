#!/bin/bash
# =============================================================================
# arr-import-unstick.sh - clear Radarr/Sonarr downloads stuck on "Manual Import"
#
# A finished download that Radarr/Sonarr won't import sits in the queue as
# importBlocked/importFailed until somebody clicks through Manual Import. This
# script handles those, but it never forces in something it can't prove is
# right: on 2026-10-30 an indexer filed "Love Streams" under Ghostbusters' id,
# and "just import it" would have shelved the wrong film. Every stuck item
# lands in exactly one bucket:
#
#   IMPORT    Radarr only. Matched by ID but the name didn't parse, the movie has
#             NO file (someone is waiting on it), and ALL of these hold:
#               - the release name's title shares >= half its words with the
#                 movie's title / original title / an alternate title
#               - the release year is within 1 of the movie's
#               - exactly one main video file, and its runtime (ffprobe) is
#                 within RUNTIME_TOLERANCE_PCT of the movie's
#             -> Manual Import of that one file.
#   RESEARCH  Anything provably wrong or unverifiable (wrong runtime, sample
#             only, no video, a TV episode matched by ID, ...).
#             -> remove from client + blocklist + search again.
#   DROP      "Not an upgrade" and the item already has a file: nothing missing.
#             -> remove from client, no blocklist, no search.
#   NOTIFY    Disk/permission trouble, unknown items with no movie/series, and
#             Sonarr's "TBA title" wait. -> Discord only, a human looks.
#
# An item is only touched after it has been stuck STUCK_MINUTES (first seen by
# this script), so normal import races are left alone. Movies that
# radarr-regrab.sh has in flight are skipped - that script owns them.
#
# Discord webhook goes in CONF_FILE (never in this repo):
#   DISCORD_UNSTICK_WEBHOOK="https://discord.com/api/webhooks/..."
# Schedule from the User Scripts plugin: custom cron "*/15 * * * *".
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
SONARR_URL="http://localhost:8989"
RADARR_URL="http://localhost:7878"
SONARR_CONFIG="/mnt/user/appdata/sonarr/config.xml"
RADARR_CONFIG="/mnt/user/appdata/radarr/config.xml"

RADARR_CONTAINER="radarr"   # docker container, used to ffprobe the download
FFPROBE="/app/bin/ffprobe"  # ffprobe path inside that container (hotio image)
RUNTIME_TOLERANCE_PCT=5     # file runtime must be within this % of the movie's
STUCK_MINUTES=30            # leave an item alone until it's been stuck this long
MAX_ACTIONS=10              # removals/imports per run (circuit breaker)
REGRAB_LEDGER="/mnt/user/appdata/radarr-regrab/report.csv"

DRY_RUN=true                # true = decide + post to Discord, change nothing

CONF_FILE="/boot/config/plugins/user.scripts/arr-import-unstick.conf"
STATE_FILE="/mnt/user/appdata/arr-import-unstick/state.json"
HC_KEY_FILE="/boot/config/plugins/user.scripts/healthchecks.key"   # project ping key
HC_SLUG="arr-import-unstick"
# -----------------------------------------------------------------------------

set -uo pipefail

log() { echo "[$(date '+%F %T')] $*"; }
hc()  { [[ -r "$HC_KEY_FILE" ]] || return 0
        curl -fsS -m 10 --retry 3 -o /dev/null "https://hc-ping.com/$(<"$HC_KEY_FILE")/$HC_SLUG$1" || true; }
key() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$1" 2>/dev/null; }

# app_get URL KEY PATH / app_post URL KEY PATH JSON / app_del URL KEY PATH
app_get()  { curl -sf --max-time 120 -H "X-Api-Key: $2" "$1/api/v3/$3"; }
app_post() { curl -sf --max-time 60 -H "X-Api-Key: $2" -H 'Content-Type: application/json' \
               -X POST -d "$4" "$1/api/v3/$3" >/dev/null; }
app_del()  { curl -sf --max-time 60 -H "X-Api-Key: $2" -X DELETE "$1/api/v3/$3" >/dev/null; }

command -v jq >/dev/null || { log "FATAL: jq not found"; hc /fail; exit 1; }
DISCORD_UNSTICK_WEBHOOK=""
# shellcheck source=/dev/null
[[ -r "$CONF_FILE" ]] && . "$CONF_FILE"

log "===== Run start (DRY_RUN=$DRY_RUN) ====="
NOW=$(date +%s)
FAILED=0
ACTIONS=0
REPORT=()      # Discord lines for this run

mkdir -p "$(dirname "$STATE_FILE")"
STATE=$(jq -c . "$STATE_FILE" 2>/dev/null) || STATE='{}'
SEEN='[]'      # state keys still in a queue this run (the rest get pruned)

# Message classes shared by both apps.
TRANSIENT_RE='access|permission|denied|disk|space|locked|in use|does not exist|not found on disk'
UPGRADE_RE='upgrade'

# stuck_minutes KEY -> sets AGE to minutes since the item was first seen stuck
# (records it if new). Sets a global rather than echoing: a $(...) subshell
# would throw the STATE update away.
stuck_minutes() {
    local t
    t=$(jq -r --arg k "$1" '.[$k].first // empty' <<<"$STATE")
    if [[ -z "$t" ]]; then
        t=$NOW
        STATE=$(jq -c --arg k "$1" --argjson t "$t" '.[$k] = {first: $t}' <<<"$STATE")
    fi
    SEEN=$(jq -c --arg k "$1" '. + [$k]' <<<"$SEEN")
    AGE=$(( (NOW - t) / 60 ))
}
# flag KEY NAME / has_flag KEY NAME -> per-item markers in STATE
flag()     { STATE=$(jq -c --arg k "$1" --arg f "$2" '.[$k][$f] = true' <<<"$STATE"); }
has_flag() { [[ "$(jq -r --arg k "$1" --arg f "$2" '.[$k][$f] // false' <<<"$STATE")" == true ]]; }
# notified_once KEY -> true the first time per item, so dry runs and NOTIFY
# items post to Discord once instead of every 15 minutes
notified_once() {
    has_flag "$1" notified && return 1
    flag "$1" notified
}
# report KEY LINE -> log always, Discord once per item and outcome (callers
# pass "<item>:<outcome>", so a failed import that turns into a re-search still
# gets its own post)
report() {
    log "  $2"
    notified_once "$1" && REPORT+=("$2")
}

# title_matches PARSED_JSON MOVIE_JSON -> parsed title shares >= half its words
# with any known title, and the year is within 1
title_matches() {
    jq -en --argjson p "$1" --argjson m "$2" '
        def words: ascii_downcase | gsub("[^a-z0-9]+"; " ") | split(" ")
                   | map(select(length > 0 and (IN("the","a","an","and","of") | not))) | unique;
        def overlap($a; $b): if ($a|length) == 0 or ($b|length) == 0 then 0
                             else ([$a[] | select(IN($b[]))] | length) / ([$a, $b] | add | unique | length) end;
        ($p.year // 0) as $py
        | ($py > 0 and ($py - $m.year | if . < 0 then -. else . end) <= 1)
          and ([ ($p.movieTitles // [])[] | words ] as $pt
               | [ ([$m.title, $m.originalTitle] + [$m.alternateTitles[]?.title])[] | select(.) | words ] as $kt
               | [ $pt[] as $a | $kt[] as $b | overlap($a; $b) ] | max // 0) >= 0.5' >/dev/null
}

# ------------------------------- RADARR -------------------------------------
radarr() {
    local K Q REGRAB RECS
    K=$(key "$RADARR_CONFIG")
    [[ -z "$K" ]] && { log "Radarr: no ApiKey in $RADARR_CONFIG"; FAILED=1; return; }
    Q=$(app_get "$RADARR_URL" "$K" "queue?page=1&pageSize=1000&includeUnknownMovieItems=true") \
        || { log "Radarr: queue call failed"; FAILED=1; return; }

    # Movies radarr-regrab.sh has in flight (same reading as that script).
    REGRAB='[]'
    [[ -r "$REGRAB_LEDGER" ]] && REGRAB=$(awk -F',' '
        $2=="GRABBED" || $2=="DELETED" { g[$3]=1 }
        $2=="IMPORTED" || $2=="FAILED_GRAB" || $2=="ABANDONED" { delete g[$3] }
        END { for (i in g) print i }' "$REGRAB_LEDGER" | jq -Rcn '[inputs | select(length>0) | tonumber]')

    RECS=$(jq -c '.records[] | select(.trackedDownloadState == "importBlocked" or .trackedDownloadState == "importFailed")
                  | {id, movieId, downloadId, title, msgs: ([.statusMessages[]?.messages[]?] | join(" / "))}' <<<"$Q")
    [[ -z "$RECS" ]] && { log "Radarr: nothing stuck"; return; }

    local R QID MID DID RNAME MSGS SKEY AGE MOVIE LABEL HASFILE
    while IFS= read -r R; do
        QID=$(jq -r .id <<<"$R"); MID=$(jq -r '.movieId // empty' <<<"$R")
        DID=$(jq -r .downloadId <<<"$R"); RNAME=$(jq -r .title <<<"$R"); MSGS=$(jq -r .msgs <<<"$R")
        SKEY="radarr:$DID"
        stuck_minutes "$SKEY"
        log "Radarr: stuck ${AGE}m: $RNAME - $MSGS"

        if [[ -n "$MID" ]] && jq -e --argjson id "$MID" 'index($id)' <<<"$REGRAB" >/dev/null; then
            log "  owned by radarr-regrab.sh - skipping"; continue
        fi
        if [[ -z "$MID" ]]; then
            report "$SKEY:notify" "❓ **Radarr** \`$RNAME\` - no movie linked ($MSGS). Needs a look."; continue
        fi
        if grep -qiE "$TRANSIENT_RE" <<<"$MSGS"; then
            report "$SKEY:notify" "⚠️ **Radarr** \`$RNAME\` - import error, not touched: $MSGS"; continue
        fi
        (( AGE < STUCK_MINUTES )) && { log "  waiting (${STUCK_MINUTES}m grace)"; continue; }
        (( ACTIONS >= MAX_ACTIONS )) && { log "  action cap ($MAX_ACTIONS) reached - next run"; continue; }

        MOVIE=$(app_get "$RADARR_URL" "$K" "movie/$MID") || { FAILED=1; continue; }
        LABEL="$(jq -r '"\(.title) (\(.year))"' <<<"$MOVIE")"
        HASFILE=$(jq -r .hasFile <<<"$MOVIE")

        # DROP: not an upgrade over a file we already have - nothing is missing.
        if [[ "$HASFILE" == true ]] && grep -qiE "$UPGRADE_RE" <<<"$MSGS"; then
            report "$SKEY:drop" "🧹 **$LABEL** - dropped \`$RNAME\` (not an upgrade over the existing file)."
            [[ "$DRY_RUN" == false ]] && { app_del "$RADARR_URL" "$K" "queue/$QID?removeFromClient=true&blocklist=false&skipRedownload=true" || FAILED=1; }
            ACTIONS=$((ACTIONS+1)); continue
        fi

        # IMPORT: try to prove it. Any failed check leaves a reason in WHY.
        local WHY="" FILES="" MAIN="" NMAIN=0 SECS="" MINS="" PARSED=""
        if [[ "$HASFILE" == true ]]; then
            WHY="movie already has a file - not forcing an import over it"
        elif has_flag "$SKEY" import_sent; then
            WHY="a Manual Import was already sent and didn't take"
        elif ! grep -qiE 'matched to movie by ID|manual import required' <<<"$MSGS"; then
            WHY="not an ID-match block ($MSGS)"
        else
            PARSED=$(curl -sf --max-time 30 -G -H "X-Api-Key: $K" "$RADARR_URL/api/v3/parse" \
                       --data-urlencode "title=$RNAME" | jq -c '.parsedMovieInfo // {}')
            [[ -z "$PARSED" ]] && PARSED='{}'
            FILES=$(app_get "$RADARR_URL" "$K" "manualimport?downloadId=$DID&movieId=$MID&filterExistingFiles=false") || FILES='[]'
            FILES=$(jq -c '[.[] | select((.path // "") | test("sample"; "i") | not)
                            | select((.path // "") | test("\\.(mkv|mp4|avi|m2ts|ts|wmv|mov)$"; "i"))]' <<<"$FILES")
            # Main features: anything at least 30% the size of the biggest file.
            MAIN=$(jq -c '(map(.size) | max // 0) as $big | [.[] | select(.size >= $big * 0.3)]' <<<"$FILES")
            NMAIN=$(jq length <<<"$MAIN")
            if ! title_matches "$PARSED" "$MOVIE"; then
                WHY="release title/year don't match $LABEL"
            elif [[ "$NMAIN" -ne 1 ]]; then
                WHY="$NMAIN main video files (need exactly 1)"
            elif jq -e '.[0].rejections[]?.reason | test("sample|corrupt|unsupported|unknown"; "i")' <<<"$MAIN" >/dev/null; then
                WHY="Radarr rejects the file: $(jq -r '[.[0].rejections[]?.reason] | join(" / ")' <<<"$MAIN")"
            else
                SECS=$(docker exec "$RADARR_CONTAINER" "$FFPROBE" -v quiet -show_entries format=duration \
                         -of csv=p=0 "$(jq -r '.[0].path' <<<"$MAIN")" 2>/dev/null | tail -1)
                if [[ ! "$SECS" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    WHY="couldn't read the file's runtime"
                else
                    MINS=$(awk -v s="$SECS" 'BEGIN {printf "%.0f", s/60}')
                    awk -v s="$SECS" -v rt="$(jq -r '.runtime // 0' <<<"$MOVIE")" -v tol="$RUNTIME_TOLERANCE_PCT" \
                        'BEGIN { m = s/60; d = m - rt; if (d < 0) d = -d; exit !(rt > 0 && d <= rt * tol / 100) }' \
                        || WHY="runtime ${MINS} min vs $(jq -r .runtime <<<"$MOVIE") expected"
                fi
            fi
        fi

        if [[ -z "$WHY" ]]; then
            report "$SKEY:import" "✅ **$LABEL** - imported \`$RNAME\` (name, year and runtime ${MINS}/$(jq -r .runtime <<<"$MOVIE") min all check out)."
            if [[ "$DRY_RUN" == false ]]; then
                app_post "$RADARR_URL" "$K" "command" "$(jq -c --argjson mid "$MID" --arg did "$DID" '
                    {name: "ManualImport", importMode: "auto",
                     files: [.[0] | {path, movieId: $mid, downloadId: $did, quality, languages,
                                     releaseGroup, indexerFlags: (.indexerFlags // 0)}]}' <<<"$MAIN")" || FAILED=1
                flag "$SKEY" import_sent
            fi
        else
            # RESEARCH: provably wrong or unverifiable - bin it, search again.
            report "$SKEY:research" "🔁 **$LABEL** - blocklisted \`$RNAME\` and searching again: $WHY."
            if [[ "$DRY_RUN" == false ]]; then
                app_del "$RADARR_URL" "$K" "queue/$QID?removeFromClient=true&blocklist=true&skipRedownload=true" \
                  && app_post "$RADARR_URL" "$K" "command" "{\"name\":\"MoviesSearch\",\"movieIds\":[$MID]}" || FAILED=1
            fi
        fi
        ACTIONS=$((ACTIONS+1))
    done <<<"$RECS"
}

# ------------------------------- SONARR -------------------------------------
# No IMPORT bucket here: episodes of one show run about the same length, so a
# runtime check can't tell E02 from E03. Stuck episodes are re-searched instead.
sonarr() {
    local K Q STUCK
    K=$(key "$SONARR_CONFIG")
    [[ -z "$K" ]] && { log "Sonarr: no ApiKey in $SONARR_CONFIG"; FAILED=1; return; }
    Q=$(app_get "$SONARR_URL" "$K" "queue?page=1&pageSize=1000&includeUnknownSeriesItems=true&includeSeries=true&includeEpisode=true") \
        || { log "Sonarr: queue call failed"; FAILED=1; return; }

    # One download can be many queue rows (season packs) - group by downloadId.
    STUCK=$(jq -c '[.records[] | select(.trackedDownloadState == "importBlocked" or .trackedDownloadState == "importFailed")]
                    | group_by(.downloadId)[]
                    | {id: .[0].id, seriesId: .[0].seriesId, downloadId: .[0].downloadId, title: .[0].title,
                       series: (.[0].series.title // "?"),
                       eps: [.[] | select(.episodeId and ((.episode.hasFile // false) | not)) | .episodeId],
                       allHaveFiles: (all(.[]; .episode.hasFile // false)),
                       msgs: ([.[].statusMessages[]?.messages[]?] | unique | join(" / "))}' <<<"$Q")
    [[ -z "$STUCK" ]] && { log "Sonarr: nothing stuck"; return; }

    local G QID SID DID RNAME MSGS SKEY AGE LABEL
    while IFS= read -r G; do
        QID=$(jq -r .id <<<"$G"); SID=$(jq -r '.seriesId // empty' <<<"$G")
        DID=$(jq -r .downloadId <<<"$G"); RNAME=$(jq -r .title <<<"$G"); MSGS=$(jq -r .msgs <<<"$G")
        LABEL=$(jq -r .series <<<"$G")
        SKEY="sonarr:$DID"
        stuck_minutes "$SKEY"
        log "Sonarr: stuck ${AGE}m: $RNAME - $MSGS"

        if [[ -z "$SID" ]]; then
            report "$SKEY:notify" "❓ **Sonarr** \`$RNAME\` - no series linked ($MSGS). Needs a look."; continue
        fi
        if grep -qiE "$TRANSIENT_RE" <<<"$MSGS"; then
            report "$SKEY:notify" "⚠️ **$LABEL** \`$RNAME\` - import error, not touched: $MSGS"; continue
        fi
        if grep -qiE 'TBA|recently aired' <<<"$MSGS"; then
            log "  Sonarr is waiting on an episode title - it retries on its own"; continue
        fi
        (( AGE < STUCK_MINUTES )) && { log "  waiting (${STUCK_MINUTES}m grace)"; continue; }
        (( ACTIONS >= MAX_ACTIONS )) && { log "  action cap ($MAX_ACTIONS) reached - next run"; continue; }

        if [[ "$(jq -r .allHaveFiles <<<"$G")" == true ]] && grep -qiE "$UPGRADE_RE|already imported" <<<"$MSGS"; then
            report "$SKEY:drop" "🧹 **$LABEL** - dropped \`$RNAME\` (episodes already have files)."
            [[ "$DRY_RUN" == false ]] && { app_del "$SONARR_URL" "$K" "queue/$QID?removeFromClient=true&blocklist=false&skipRedownload=true" || FAILED=1; }
        else
            report "$SKEY:research" "🔁 **$LABEL** - blocklisted \`$RNAME\` and searching again: $MSGS"
            if [[ "$DRY_RUN" == false ]]; then
                # Search only the episodes still missing a file.
                if app_del "$SONARR_URL" "$K" "queue/$QID?removeFromClient=true&blocklist=true&skipRedownload=true"; then
                    [[ "$(jq '.eps | length' <<<"$G")" -gt 0 ]] \
                      && { app_post "$SONARR_URL" "$K" "command" "$(jq -c '{name: "EpisodeSearch", episodeIds: .eps}' <<<"$G")" || FAILED=1; }
                else
                    FAILED=1
                fi
            fi
        fi
        ACTIONS=$((ACTIONS+1))
    done <<<"$STUCK"
}

radarr
sonarr

# Forget items that have left both queues.
STATE=$(jq -c --argjson seen "$SEEN" 'with_entries(select(.key | sub(":(notify|drop|import|research)$"; "") | IN($seen[])))' <<<"$STATE")
echo "$STATE" > "$STATE_FILE"

if (( ${#REPORT[@]} > 0 )); then
    if [[ -z "$DISCORD_UNSTICK_WEBHOOK" ]]; then
        log "No DISCORD_UNSTICK_WEBHOOK in $CONF_FILE - Discord post skipped"
    else
        TITLE="Stuck imports"; [[ "$DRY_RUN" == true ]] && TITLE="Stuck imports (dry run - nothing changed)"
        code=$(printf '%s\n' "${REPORT[@]}" | jq -Rsc --arg t "$TITLE" \
                 '{username: "Andromeda", embeds: [{title: $t, color: 15105570, description: (.[0:4000])}]}' \
               | curl -s -m 20 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d @- "$DISCORD_UNSTICK_WEBHOOK")
        [[ "$code" == 2* ]] || { log "Discord post failed (HTTP $code)"; FAILED=1; }
    fi
fi

if [[ "$FAILED" -ne 0 ]]; then hc /fail; log "===== Run end (with errors) ====="; exit 1; fi
hc ""
log "===== Run end ($ACTIONS action(s)) ====="
