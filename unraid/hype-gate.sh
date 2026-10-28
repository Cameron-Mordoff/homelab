#!/bin/bash
# =============================================================================
# hype-gate.sh - add trending movies/shows, but only ones that are actually good
#
# Source lists are MDBList dynamic lists (popular, recent, rating-filtered).
# MDBList filters on its own cached ratings, which lag behind: a film that
# opened at IMDb 7.4 and has since settled at 6.2 is still on the list. So the
# lists only nominate titles - this script re-checks each one against LIVE
# ratings and adds the ones that pass:
#
#   IMDb rating + vote count - IMDb's own daily dataset (title.ratings.tsv.gz,
#                              free for personal use), downloaded once a day
#   Rotten Tomatoes (movies) - Radarr's metadata, only enforced when present
#   Language / genres        - Radarr/Sonarr metadata (English original
#                              language; no horror/anime/reality etc.)
#
# Movies come from Radarr's own copy of the list (an import list with auto-add
# OFF), so Radarr has already resolved them and flagged existing/excluded ones.
# Shows come straight from the MDBList JSON, since Sonarr has no equivalent.
#
# Added titles are monitored, tagged HYPE_TAG and searched. TV is added with the
# first season only and future seasons unmonitored; monitor the rest by hand for
# shows that stick. Anything deleted with "add exclusion" is never re-added.
#
# Schedule from the User Scripts plugin: custom cron "45 7 * * *".
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
RADARR_URL="http://localhost:7878"
SONARR_URL="http://localhost:8989"
RADARR_CONFIG="/mnt/user/appdata/radarr/config.xml"
SONARR_CONFIG="/mnt/user/appdata/sonarr/config.xml"

RADARR_LIST="Hype - MDBList Movies"     # Radarr import list (auto-add off)
TV_LIST_URL="https://mdblist.com/lists/cameronmordoff/hype-tv/json"

MOVIE_MIN_IMDB="7.0"; MOVIE_MIN_VOTES=10000; MOVIE_MIN_RT=75
TV_MIN_IMDB="7.8";    TV_MIN_VOTES=10000
MOVIE_BAD_GENRES='["Horror"]'
TV_BAD_GENRES='["Horror","Anime","Animation","Reality","Talk Show","Game Show","News","Soap"]'
REQUIRE_ENGLISH=true

MOVIE_PROFILE="1080p (720p fallback)"; MOVIE_ROOT="/data/media/movies/shd"
TV_PROFILE="1080p TV (720p fallback)"; TV_ROOT="/data/media/tv/shd"
HYPE_TAG="hype"
MAX_ADDS=5                  # per app per run
DRY_RUN=false               # true = log decisions, add nothing

IMDB_URL="https://datasets.imdbws.com/title.ratings.tsv.gz"
IMDB_CACHE="/tmp/hype-gate/title.ratings.tsv.gz"   # RAM; re-fetched when >20h old

HC_KEY_FILE="/boot/config/plugins/user.scripts/healthchecks.key"   # project ping key
HC_SLUG="hype-gate"
# -----------------------------------------------------------------------------

set -uo pipefail

log() { echo "[$(date '+%F %T')] $*"; }
hc()  { [[ -r "$HC_KEY_FILE" ]] || return 0
        curl -fsS -m 10 --retry 3 -o /dev/null "https://hc-ping.com/$(<"$HC_KEY_FILE")/$HC_SLUG$1" || true; }
die() { log "FATAL: $*"; hc /fail; exit 1; }
key() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$1" 2>/dev/null; }

# get URL KEY PATH / post URL KEY PATH JSON
get()  { curl -sf --max-time 120 -H "X-Api-Key: $2" "$1/api/v3/$3"; }
post() { curl -sf --max-time 120 -H "X-Api-Key: $2" -H 'Content-Type: application/json' \
           -X POST -d "$4" "$1/api/v3/$3" >/dev/null; }

# imdb_lookup FILE_OF_TT_IDS -> "tt<TAB>rating<TAB>votes" for each id found
imdb_lookup() {
    zcat "$IMDB_CACHE" | awk -F'\t' 'NR==FNR {want[$1]=1; next} ($1 in want)' "$1" -
}

command -v jq >/dev/null || die "jq not found"
log "===== Run start (DRY_RUN=$DRY_RUN) ====="
FAILED=0; WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

mkdir -p "$(dirname "$IMDB_CACHE")"
if [[ ! -s "$IMDB_CACHE" ]] || [[ -n $(find "$IMDB_CACHE" -mmin +1200) ]]; then
    curl -sf --max-time 300 -o "$IMDB_CACHE.part" "$IMDB_URL" && mv "$IMDB_CACHE.part" "$IMDB_CACHE" \
        || { rm -f "$IMDB_CACHE.part"; [[ -s "$IMDB_CACHE" ]] || die "IMDb ratings download failed"; log "IMDb download failed - using cached copy"; }
fi

# ------------------------------- MOVIES -------------------------------------
RKEY=$(key "$RADARR_CONFIG")
if [[ -z "$RKEY" ]]; then
    log "Radarr: no ApiKey in $RADARR_CONFIG"; FAILED=1
elif ! LISTS=$(get "$RADARR_URL" "$RKEY" importlist) \
     || ! ITEMS=$(get "$RADARR_URL" "$RKEY" "importlist/movie?includeRecommendations=false&includeTrending=false&includePopular=false") \
     || ! PROFILES=$(get "$RADARR_URL" "$RKEY" qualityprofile) || ! TAGS=$(get "$RADARR_URL" "$RKEY" tag); then
    log "Radarr: API call failed"; FAILED=1
else
    LID=$(jq --arg n "$RADARR_LIST" '.[] | select(.name==$n) | .id' <<<"$LISTS")
    PID=$(jq --arg n "$MOVIE_PROFILE" '.[] | select(.name==$n) | .id' <<<"$PROFILES")
    TID=$(jq --arg n "$HYPE_TAG" '.[] | select(.label==$n) | .id' <<<"$TAGS")
    if [[ -z "$LID" || -z "$PID" || -z "$TID" ]]; then
        log "Radarr: list/profile/tag not found (list='$LID' profile='$PID' tag='$TID')"; FAILED=1
    else
        jq -c --argjson lid "$LID" '[.[] | select((.lists|index($lid)) and (.isExisting|not) and (.isExcluded|not))]' <<<"$ITEMS" > "$WORK/movies.json"
        jq -r '.[].imdbId // empty' "$WORK/movies.json" > "$WORK/movie-ids"
        imdb_lookup "$WORK/movie-ids" | jq -R 'split("\t") | {(.[0]): {r: (.[1]|tonumber), v: (.[2]|tonumber)}}' | jq -s 'add // {}' > "$WORK/movie-imdb.json"
        jq -c --slurpfile imdb "$WORK/movie-imdb.json" --argjson minr "$MOVIE_MIN_IMDB" --argjson minv "$MOVIE_MIN_VOTES" \
              --argjson minrt "$MOVIE_MIN_RT" --argjson bad "$MOVIE_BAD_GENRES" --argjson eng "$REQUIRE_ENGLISH" '
            .[] | ($imdb[0][.imdbId // ""] // {r: 0, v: 0}) as $i | .ratings.rottenTomatoes.value as $rt |
            {tmdbId, label: "\(.title) (\(.year)) IMDb \($i.r)/\($i.v) RT \($rt // "-")",
             why: ([ (if $i.r < $minr then "IMDb \($i.r)" else empty end),
                     (if $i.v < $minv then "\($i.v) votes" else empty end),
                     (if $rt != null and $rt < $minrt then "RT \($rt)" else empty end),
                     (if ($eng and .originalLanguage.name != "English") then (.originalLanguage.name // "no language") else empty end),
                     (.genres // [] | map(select(. as $g | $bad | index($g))) | .[]) ] | join(", "))}' \
              "$WORK/movies.json" > "$WORK/movie-decisions"
        ADDED=0
        while read -r d; do
            label=$(jq -r .label <<<"$d"); why=$(jq -r .why <<<"$d")
            if [[ -n "$why" ]]; then log "  movie skip: $label - $why"; continue; fi
            if (( ADDED >= MAX_ADDS )); then log "  movie defer (cap): $label"; continue; fi
            if [[ "$DRY_RUN" == true ]]; then log "  movie WOULD ADD: $label"; ADDED=$((ADDED+1)); continue; fi
            body=$(get "$RADARR_URL" "$RKEY" "movie/lookup/tmdb?tmdbId=$(jq -r .tmdbId <<<"$d")" | jq -c \
                   --argjson p "$PID" --argjson t "$TID" --arg root "$MOVIE_ROOT" \
                   '. + {qualityProfileId: $p, rootFolderPath: $root, monitored: true, minimumAvailability: "released",
                         tags: [$t], addOptions: {searchForMovie: true, monitor: "movieOnly"}}')
            if [[ -n "$body" ]] && post "$RADARR_URL" "$RKEY" movie "$body"; then
                log "  movie ADDED: $label"; ADDED=$((ADDED+1))
            else
                log "  movie add FAILED: $label"; FAILED=1
            fi
        done < "$WORK/movie-decisions"
        log "Radarr: $(wc -l < "$WORK/movie-decisions") candidate(s), $ADDED added"
    fi
fi

# --------------------------------- TV ---------------------------------------
SKEY=$(key "$SONARR_CONFIG")
if [[ -z "$SKEY" ]]; then
    log "Sonarr: no ApiKey in $SONARR_CONFIG"; FAILED=1
elif ! LIST=$(curl -sf --max-time 60 "$TV_LIST_URL") \
     || ! SERIES=$(get "$SONARR_URL" "$SKEY" series) \
     || ! EXCL=$(get "$SONARR_URL" "$SKEY" "importlistexclusion/paged?page=1&pageSize=10000") \
     || ! PROFILES=$(get "$SONARR_URL" "$SKEY" qualityprofile) || ! TAGS=$(get "$SONARR_URL" "$SKEY" tag); then
    log "Sonarr: API or list fetch failed"; FAILED=1
else
    PID=$(jq --arg n "$TV_PROFILE" '.[] | select(.name==$n) | .id' <<<"$PROFILES")
    TID=$(jq --arg n "$HYPE_TAG" '.[] | select(.label==$n) | .id' <<<"$TAGS")
    if [[ -z "$PID" || -z "$TID" ]]; then
        log "Sonarr: profile/tag not found (profile='$PID' tag='$TID')"; FAILED=1
    else
        jq -c --argjson have "$(jq '[.[].tvdbId]' <<<"$SERIES")" --argjson ex "$(jq '[.records[].tvdbId]' <<<"$EXCL")" \
           '[.[] | select(.tvdbid != null and (.tvdbid as $t | ($have|index($t)) == null and ($ex|index($t)) == null))]' \
           <<<"$LIST" > "$WORK/shows.json"
        jq -r '.[].imdb_id // empty' "$WORK/shows.json" > "$WORK/show-ids"
        imdb_lookup "$WORK/show-ids" | jq -R 'split("\t") | {(.[0]): {r: (.[1]|tonumber), v: (.[2]|tonumber)}}' | jq -s 'add // {}' > "$WORK/show-imdb.json"
        ADDED=0; N=0
        while read -r s; do
            N=$((N+1))
            tvdb=$(jq -r .tvdbid <<<"$s")
            if ! look=$(get "$SONARR_URL" "$SKEY" "series/lookup?term=tvdb:$tvdb" | jq -c '.[0] // empty') || [[ -z "$look" ]]; then
                log "  show skip: tvdb $tvdb - Sonarr lookup failed"; continue
            fi
            d=$(jq -c --slurpfile imdb "$WORK/show-imdb.json" --argjson minr "$TV_MIN_IMDB" --argjson minv "$TV_MIN_VOTES" \
                      --argjson bad "$TV_BAD_GENRES" --argjson eng "$REQUIRE_ENGLISH" --arg tt "$(jq -r '.imdb_id // ""' <<<"$s")" '
                ($imdb[0][$tt] // {r: 0, v: 0}) as $i |
                {label: "\(.title) (\(.year)) IMDb \($i.r)/\($i.v)",
                 why: ([ (if $i.r < $minr then "IMDb \($i.r)" else empty end),
                         (if $i.v < $minv then "\($i.v) votes" else empty end),
                         (if ($eng and .originalLanguage.name != "English") then (.originalLanguage.name // "no language") else empty end),
                         (.genres // [] | map(select(. as $g | $bad | index($g))) | .[]) ] | join(", "))}' <<<"$look")
            label=$(jq -r .label <<<"$d"); why=$(jq -r .why <<<"$d")
            if [[ -n "$why" ]]; then log "  show skip: $label - $why"; continue; fi
            if (( ADDED >= MAX_ADDS )); then log "  show defer (cap): $label"; continue; fi
            if [[ "$DRY_RUN" == true ]]; then log "  show WOULD ADD: $label"; ADDED=$((ADDED+1)); continue; fi
            body=$(jq -c --argjson p "$PID" --argjson t "$TID" --arg root "$TV_ROOT" \
                   '. + {qualityProfileId: $p, rootFolderPath: $root, seasonFolder: true, monitored: true,
                         monitorNewItems: "none", tags: [$t],
                         addOptions: {monitor: "firstSeason", searchForMissingEpisodes: true, searchForCutoffUnmetEpisodes: false}}' <<<"$look")
            if post "$SONARR_URL" "$SKEY" series "$body"; then
                log "  show ADDED: $label"; ADDED=$((ADDED+1))
            else
                log "  show add FAILED: $label"; FAILED=1
            fi
        done < <(jq -c '.[]' "$WORK/shows.json")
        log "Sonarr: $N candidate(s), $ADDED added"
    fi
fi

if [[ "$FAILED" -ne 0 ]]; then hc /fail; exit 1; fi
hc ""
log "===== Run end ====="
