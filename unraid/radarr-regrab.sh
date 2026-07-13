#!/bin/bash
# =============================================================================
# radarr-regrab.sh - automated library slimming for Radarr on unRAID
#
# GRAB FIRST, DELETE LAST.
# ------------------------
# The old file is only removed once the replacement has FINISHED DOWNLOADING and
# is sitting in the download client waiting to import. At no point is a movie
# left with nothing.
#
# Why it has to work this way. Radarr will not import a file that isn't an
# upgrade, and our targets are oversized Bluray-1080p files being replaced by
# smaller Bluray-1080p files - the SAME quality. UpgradeSpecification rejects
# that ("Not an upgrade for existing movie file"), so we cannot simply grab and
# let Radarr swap it. The old file genuinely has to go before the import can
# land. The question is only WHEN - and the answer is: after the new bits are
# safely on disk, not before.
#
# The earlier delete-first version cost 5 movies in one batch: it deleted, then
# pushed the NZB, and SABnzbd silently discarded every one as a duplicate. The
# movies were simply gone. Under this design that same failure is a no-op - the
# download never completes, so the delete never happens.
#
# Each run (intended for hourly cron via the User Scripts plugin):
#   1. Safety guards: Radarr up? parity check? night window? daily cap?
#   2. Reconcile every in-flight movie:
#        downloading      -> wait
#        download done    -> DELETE the old file, kick Radarr to import
#        imported         -> record actual GB recovered
#        download vanished-> FAILED_GRAB. File untouched. Nothing lost.
#   3. Pick the next BATCH_SIZE movies (biggest guaranteed savings first),
#      verify a qualifying release exists, and push it to the download client.
#   4. Log everything to an append-only CSV ledger + run log.
#
# Stateless by design: all decisions derive from Radarr's live state plus the
# CSV ledger. Safe to interrupt at any point (power loss, reboot, etc).
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
RADARR_URL="${RADARR_URL:-http://localhost:7878}"
RADARR_API_KEY="${RADARR_API_KEY:-}"
API_KEY_FILE="/boot/config/plugins/user.scripts/radarr-regrab.key"

PROFILE_NAME="1080p (720p fallback)"      # only movies on this profile are touched
SKIP_TAG="regrab-skip"                    # Radarr tag to exempt favorites (optional)

MIN_SIZE_GB=16          # only consider files at least this big
MIN_SAVINGS_GB=5        # ...and only if the WORST release we'd accept still saves this much

# Size policy, GiB per hour. Keep these in sync with Set-RadarrQualityConfig.ps1.
TARGET_GIBH="6.5"       # what we aim for (used for the "est new size" display)
BLURAY_LO=3             # accepted release window for Bluray-1080p
BLURAY_HI=8
WEB_LO=2                # ...and for WEBDL/WEBRip-1080p
WEB_HI=6
# The largest rate we'd ever accept. Savings must clear MIN_SAVINGS_GB even in
# that worst case, so a "save 5 GB" candidate can never actually save less.
WORST_GIBH="$BLURAY_HI"

BATCH_SIZE=5            # movies grabbed per run
DAILY_CAP=30            # max deletions per calendar day (circuit breaker)
MAX_INFLIGHT=5          # don't grab more if this many are already in flight

MAX_GRAB_WAIT=8         # runs to wait for a download to appear/finish before
                        # writing it off. The file is NEVER touched in this state.
MAX_IMPORT_WAIT=6       # runs to wait for the import after we deleted the old file.
                        # Exceeding this is the ONLY way to end up fileless, and it
                        # means the bits are still in the download client - recover
                        # with Radarr > Activity > Queue > Manual Import.
SKIP_COOLDOWN_DAYS=7    # park a movie this long after a failed grab / no release,
                        # so it stops burning an indexer search and a batch slot
                        # every single run.

ENFORCE_WINDOW=true     # only act between WINDOW_START and WINDOW_END
WINDOW_START=23         # 11 PM
WINDOW_END=9            # 9 AM

RELEASE_TIMEOUT=300     # seconds; interactive indexer search can be slow

DRY_RUN=true            # true = report only, grab/delete nothing. FLIP WHEN READY.

DATA_DIR="/mnt/user/appdata/radarr-regrab"
# -----------------------------------------------------------------------------

RADARR_URL="${RADARR_URL%/}"
LEDGER="$DATA_DIR/report.csv"
RUNLOG="$DATA_DIR/run.log"
API="$RADARR_URL/api/v3"
NOW() { date '+%Y-%m-%d %H:%M:%S'; }
TODAY=$(date '+%Y-%m-%d')

mkdir -p "$DATA_DIR"
[ -f "$LEDGER" ] || echo "timestamp,action,movie_id,title,year,old_size_gb,new_size_gb,note" > "$LEDGER"

log() { echo "[$(NOW)] $*" | tee -a "$RUNLOG"; }

# Every ledger reader below is awk -F',' which does NOT understand quoted fields,
# so a title like "Good Night, and Good Luck" would shift every column after it.
# Strip the delimiter and quotes at write time instead.
csv_safe() { printf '%s' "$1" | tr ',' ';' | tr -d '"\r\n'; }
ledger() { # action id title year old new note
    [ "$DRY_RUN" = true ] && return 0   # a dry run must never mutate state
    printf '%s,%s,%s,"%s",%s,%s,%s,"%s"\n' \
        "$(NOW)" "$1" "$2" "$(csv_safe "$3")" "$4" "$5" "$6" "$(csv_safe "$7")" >> "$LEDGER"
}
recovered_total() { awk -F',' '$2=="IMPORTED" {gsub(/"/,"",$6); gsub(/"/,"",$7); s+=($6-$7)} END {printf "%.1f", s}' "$LEDGER"; }

if [ -z "$RADARR_API_KEY" ] && [ -r "$API_KEY_FILE" ]; then
    RADARR_API_KEY=$(tr -d ' \t\r\n' < "$API_KEY_FILE")
fi
if [ -z "$RADARR_API_KEY" ]; then
    log "FATAL: no API key. Set RADARR_API_KEY or write it to $API_KEY_FILE"
    exit 1
fi
HDR="X-Api-Key: $RADARR_API_KEY"

api_get()  { curl -sf --max-time "${2:-180}" -H "$HDR" "$API/$1"; }
api_del()  { curl -sf --max-time 60  -H "$HDR" -X DELETE "$API/$1"; }
api_post() { curl -sf --max-time 180 -H "$HDR" -X POST -H 'Content-Type: application/json' -d "$2" "$API/$1"; }

command -v jq   >/dev/null || { log "FATAL: jq not found";   exit 1; }
command -v curl >/dev/null || { log "FATAL: curl not found"; exit 1; }

log "===== Run start (DRY_RUN=$DRY_RUN) ====="

# ------------------------- GUARD 1: Radarr health ---------------------------
HC_BODY="/tmp/radarr-regrab-status.json"
HC_CODE=$(curl -s -o "$HC_BODY" -w '%{http_code}' --max-time 30 -H "$HDR" "$API/system/status")
RADARR_VER=$(jq -r '.version // empty' "$HC_BODY" 2>/dev/null)
if [ -z "$RADARR_VER" ]; then
    case "$HC_CODE" in
        401) log "Radarr rejected the API key (HTTP 401) - check RADARR_API_KEY / $API_KEY_FILE." ;;
        000) log "No connection to $RADARR_URL (HTTP 000) - DNS/network/timeout from the unRAID host." ;;
        *)   log "Unexpected response from $RADARR_URL (HTTP $HC_CODE, body not Radarr JSON) - proxy or URL issue." ;;
    esac
    exit 0
fi
log "Connected to Radarr $RADARR_VER"

# ------------------------- GUARD 2: parity check ----------------------------
if command -v mdcmd >/dev/null; then
    MD_STATUS=$(mdcmd status 2>/dev/null)
    RESYNC=$(echo "$MD_STATUS" | grep -oP 'mdResync=\K[0-9]+' | head -1)
    [ -z "$RESYNC" ] && RESYNC=$(echo "$MD_STATUS" | grep -oP 'mdResyncPos=\K[0-9]+' | head -1)
    if [ -n "$RESYNC" ] && [ "$RESYNC" -gt 0 ]; then
        log "Parity check/sync in progress - skipping run."
        exit 0
    fi
fi

# ------------------------- GUARD 3: night window ----------------------------
HOUR=$((10#$(date '+%H')))
if [ "$ENFORCE_WINDOW" = true ]; then
    IN_WINDOW=false
    if [ "$WINDOW_START" -gt "$WINDOW_END" ]; then   # window crosses midnight
        { [ "$HOUR" -ge "$WINDOW_START" ] || [ "$HOUR" -lt "$WINDOW_END" ]; } && IN_WINDOW=true
    else
        { [ "$HOUR" -ge "$WINDOW_START" ] && [ "$HOUR" -lt "$WINDOW_END" ]; } && IN_WINDOW=true
    fi
    if [ "$IN_WINDOW" = false ]; then
        log "Outside action window (${WINDOW_START}:00-${WINDOW_END}:00) - skipping run."
        exit 0
    fi
fi

# =============================================================================
# Reconcile everything in flight
# =============================================================================
QUEUE=$(api_get "queue?page=1&pageSize=500")
[ -z "$QUEUE" ] && QUEUE='{"records":[]}'

# A movie is in flight from GRABBED until it reaches a terminal state.
#
# DELETED is also treated as a start state, purely for backward compatibility:
# the previous delete-first version of this script wrote DELETED with no
# preceding GRABBED. Without this, any movie left mid-flight by that version
# would be orphaned - its import would never be reconciled and its recovered GB
# never counted. Harmless for new-style rows, where DELETED always follows a
# GRABBED for the same movie.
INFLIGHT=$(awk -F',' '
    $2=="GRABBED"     { g[$3]=1 }
    $2=="DELETED"     { g[$3]=1 }
    $2=="IMPORTED"    { fin[$3]=1 }
    $2=="FAILED_GRAB" { fin[$3]=1 }
    $2=="ABANDONED"   { fin[$3]=1 }
    END { for (i in g) if (!(i in fin)) print i }' "$LEDGER")

INFLIGHT_N=0
for MID in $INFLIGHT; do
    MOVIE=$(api_get "movie/$MID") || continue
    TITLE=$(echo "$MOVIE"   | jq -r '.title')
    YEAR=$(echo "$MOVIE"    | jq -r '.year')
    HASFILE=$(echo "$MOVIE" | jq -r '.hasFile')
    CURFID=$(echo "$MOVIE"  | jq -r '.movieFile.id // 0')

    # What we recorded when we pushed the grab. Fall back to the DELETED row so
    # movies left in flight by the old delete-first version still report their
    # original size (and therefore their recovered GB) correctly.
    OLDFID=$(awk -F',' -v id="$MID" '$2=="GRABBED" && $3==id {print $8}' "$LEDGER" | tail -1 | grep -oP 'oldFileId=\K[0-9]+')
    OLDGB=$(awk -F',' -v id="$MID" '($2=="GRABBED" || $2=="DELETED") && $3==id && $6 != "" {print $6}' "$LEDGER" | tail -1)
    DELETED_ALREADY=$(grep -c ",DELETED,$MID," "$LEDGER" 2>/dev/null || true)

    # Is Radarr's download client still holding something for this movie, and is
    # it finished? trackedDownloadState goes downloading -> importPending /
    # importBlocked once the bytes are on disk.
    Q=$(echo "$QUEUE" | jq -c --argjson id "$MID" '[.records[] | select(.movieId == $id)] | .[0] // empty')
    Q_DONE=false; Q_PRESENT=false
    if [ -n "$Q" ]; then
        Q_PRESENT=true
        if [ "$(echo "$Q" | jq -r '((.status // "") == "completed")
                                   or (((.sizeleft // 1) | tonumber) == 0)
                                   or (((.trackedDownloadState // "") | test("importPending|importBlocked|importing")))')" = "true" ]; then
            Q_DONE=true
        fi
    fi

    # ---- 1. The replacement landed -----------------------------------------
    if [ "$HASFILE" = "true" ] && [ -n "$CURFID" ] && [ "$CURFID" != "0" ] && [ "$CURFID" != "${OLDFID:-0}" ]; then
        NEWGB=$(echo "$MOVIE" | jq -r '(.movieFile.size / 1073741824 * 10 | round) / 10')
        SAVED=$(echo "${OLDGB:-0} $NEWGB" | awk '{printf "%.1f", $1-$2}')
        ledger "IMPORTED" "$MID" "$TITLE" "$YEAR" "${OLDGB:-?}" "$NEWGB" "recovered ${SAVED} GB"
        log "IMPORTED: $TITLE ($YEAR) - ${OLDGB} GB -> ${NEWGB} GB (recovered ${SAVED} GB)"
        continue
    fi

    # ---- 2. Old file already deleted, movie currently has NO file ------------
    # Two very different situations, and they need different medicine:
    #   (a) the download is in the client -> just nudge Radarr to import it
    #   (b) nothing is downloading -> the movie is simply GONE and needs a fresh
    #       search. This is the state the old delete-first script stranded movies
    #       in, and it's where anything mid-flight during the upgrade lands.
    if [ "${DELETED_ALREADY:-0}" -gt 0 ] && [ "$HASFILE" != "true" ]; then
        WAITED=$(grep -c ",WAIT_IMPORT,$MID," "$LEDGER" 2>/dev/null || true)
        if [ "${WAITED:-0}" -lt "$MAX_IMPORT_WAIT" ]; then
            if [ "$Q_PRESENT" = true ]; then
                ledger "WAIT_IMPORT" "$MID" "$TITLE" "$YEAR" "${OLDGB:-}" "" "download present, awaiting import ($((WAITED+1))/$MAX_IMPORT_WAIT)"
                log "WAIT: $TITLE ($YEAR) - no file, download in client, nudging import ($((WAITED+1))/$MAX_IMPORT_WAIT)"
                [ "$DRY_RUN" = false ] && api_post "command" '{"name":"RefreshMonitoredDownloads"}' >/dev/null
            else
                ledger "WAIT_IMPORT" "$MID" "$TITLE" "$YEAR" "${OLDGB:-}" "" "no file and nothing downloading - re-searching ($((WAITED+1))/$MAX_IMPORT_WAIT)"
                log "!! $TITLE ($YEAR) has NO FILE and nothing is downloading - re-searching ($((WAITED+1))/$MAX_IMPORT_WAIT)"
                [ "$DRY_RUN" = false ] && { api_post "command" "{\"name\":\"MoviesSearch\",\"movieIds\":[$MID]}" >/dev/null \
                    || log "   WARNING: re-search failed."; }
            fi
            INFLIGHT_N=$((INFLIGHT_N+1))
        else
            ledger "ABANDONED" "$MID" "$TITLE" "$YEAR" "${OLDGB:-}" "" "still no file after $MAX_IMPORT_WAIT attempts - NEEDS MANUAL ATTENTION"
            log "!! ABANDONED: $TITLE ($YEAR) still has NO FILE. Check Radarr > Activity > Queue (manual import) or search it by hand."
        fi
        continue
    fi

    # ---- 3. Download finished -> NOW it is safe to delete the old file ------
    if [ "$Q_DONE" = true ] && [ "$HASFILE" = "true" ]; then
        RNAME=$(echo "$Q" | jq -r '.title // "?"')
        log "Download complete for $TITLE ($YEAR): $RNAME"
        if [ "$DRY_RUN" = true ]; then
            log "  DRY RUN - would delete the old file (${OLDGB} GB) and let Radarr import."
            INFLIGHT_N=$((INFLIGHT_N+1))
            continue
        fi
        if ! api_del "moviefile/${OLDFID:-$CURFID}" >/dev/null; then
            log "  ERROR: failed to delete old file - leaving everything alone, will retry next run."
            INFLIGHT_N=$((INFLIGHT_N+1))
            continue
        fi
        ledger "DELETED" "$MID" "$TITLE" "$YEAR" "${OLDGB:-}" "" "download complete, old file removed - importing $RNAME"
        log "  Old file deleted (${OLDGB} GB). Kicking Radarr to import."
        api_post "command" '{"name":"RefreshMonitoredDownloads"}' >/dev/null \
            || log "  WARNING: could not trigger import; Radarr will retry on its own schedule."
        INFLIGHT_N=$((INFLIGHT_N+1))
        continue
    fi

    # ---- 4. Still downloading ----------------------------------------------
    if [ "$Q_PRESENT" = true ]; then
        PCT=$(echo "$Q" | jq -r 'if (.size // 0) > 0 then (((.size - (.sizeleft // 0)) / .size * 100) | floor) else 0 end')
        log "Downloading: $TITLE ($YEAR) - ${PCT}% (old file still intact)"
        INFLIGHT_N=$((INFLIGHT_N+1))
        continue
    fi

    # ---- 5. Nothing in the queue and the old file is still there ------------
    # The grab never landed - rejected by the download client, discarded as a
    # duplicate, whatever. THIS IS THE FAILURE THE OLD SCRIPT TURNED INTO A
    # MISSING MOVIE. Here it costs nothing: the file was never touched.
    WAITED=$(grep -c ",WAIT_GRAB,$MID," "$LEDGER" 2>/dev/null || true)
    if [ "${WAITED:-0}" -lt "$MAX_GRAB_WAIT" ]; then
        ledger "WAIT_GRAB" "$MID" "$TITLE" "$YEAR" "${OLDGB:-}" "" "download not in queue yet ($((WAITED+1))/$MAX_GRAB_WAIT)"
        log "WAIT: $TITLE ($YEAR) - grab not in the download queue ($((WAITED+1))/$MAX_GRAB_WAIT). File intact."
        INFLIGHT_N=$((INFLIGHT_N+1))
    else
        ledger "FAILED_GRAB" "$MID" "$TITLE" "$YEAR" "${OLDGB:-}" "" "download never appeared - ORIGINAL FILE UNTOUCHED. Check the download client (SAB duplicate detection?)"
        log "FAILED_GRAB: $TITLE ($YEAR) - the download never appeared. Original file is intact; nothing was lost."
        log "             If this keeps happening, check SABnzbd > Config > Switches > Detect Duplicate Downloads."
    fi
done

# ------------------ GUARD 4: don't pile up in-flight work -------------------
if [ "$INFLIGHT_N" -ge "$MAX_INFLIGHT" ]; then
    log "$INFLIGHT_N movie(s) still in flight (max $MAX_INFLIGHT) - not grabbing more this run."
    log "Total recovered so far: $(recovered_total) GB"
    log "===== Run end ====="
    exit 0
fi
SLOTS=$((MAX_INFLIGHT - INFLIGHT_N))
[ "$BATCH_SIZE" -gt "$SLOTS" ] && BATCH_SIZE=$SLOTS

# ------------------------- GUARD 5: daily cap --------------------------------
DONE_TODAY=$(grep -c "^$TODAY.*,GRABBED," "$LEDGER" 2>/dev/null || true)
DONE_TODAY=${DONE_TODAY:-0}
if [ "$DONE_TODAY" -ge "$DAILY_CAP" ]; then
    log "Daily cap reached ($DONE_TODAY/$DAILY_CAP) - done for today."
    log "===== Run end ====="
    exit 0
fi
ROOM=$((DAILY_CAP - DONE_TODAY))
[ "$BATCH_SIZE" -gt "$ROOM" ] && BATCH_SIZE=$ROOM

# --------------------------- Resolve profile & tag ---------------------------
PROFILES_JSON=$(api_get "qualityprofile")
PROFILE_ID=$(echo "$PROFILES_JSON" | jq -r --arg n "$PROFILE_NAME" '.[] | select(.name==$n) | .id' 2>/dev/null)
if [ -z "$PROFILE_ID" ]; then
    log "FATAL: profile '$PROFILE_NAME' not found. Profiles Radarr reports:"
    echo "$PROFILES_JSON" | jq -r '.[].name' 2>/dev/null | sed 's/^/    - /' | tee -a "$RUNLOG" \
        || log "    (response was not valid JSON - URL/proxy problem, not a profile problem)"
    exit 1
fi
SKIP_TAG_ID=$(api_get "tag" | jq -r --arg t "$SKIP_TAG" '.[] | select(.label==$t) | .id // empty')

# Movies parked: no qualifying release, or a grab that never materialised.
# Without this they sit at the top of the queue burning an indexer search and a
# batch slot every single run, and nothing else ever gets processed.
SKIP_CUTOFF=$(date -d "-$SKIP_COOLDOWN_DAYS days" '+%Y-%m-%d' 2>/dev/null) || SKIP_CUTOFF=""
if [ -n "$SKIP_CUTOFF" ]; then
    COOLDOWN_IDS=$(awk -F',' -v cut="$SKIP_CUTOFF" \
        '($2=="SKIP_NO_RELEASE" || $2=="FAILED_GRAB") && substr($1,1,10) >= cut {print $3}' "$LEDGER" \
        | sort -u | jq -Rc -n '[inputs | select(length>0) | tonumber]')
else
    COOLDOWN_IDS="[]"   # no GNU date - disable the cooldown rather than guess
fi
[ -z "$COOLDOWN_IDS" ] && COOLDOWN_IDS="[]"
COOLDOWN_N=$(echo "$COOLDOWN_IDS" | jq 'length')

# In-flight movies must never be picked again while they're in flight.
INFLIGHT_JSON=$(printf '%s\n' $INFLIGHT | jq -Rc -n '[inputs | select(length>0) | tonumber]')
[ -z "$INFLIGHT_JSON" ] && INFLIGHT_JSON="[]"

# ...and neither must anything already in the download queue, even if we didn't
# put it there (a manual grab by you, an RSS grab by Radarr).
QUEUE_IDS=$(echo "$QUEUE" | jq -c '[.records[].movieId | select(. != null)]')
[ -z "$QUEUE_IDS" ] && QUEUE_IDS="[]"

# --------------------------- Select candidates -------------------------------
CANDIDATES=$(api_get "movie" | jq -c \
    --argjson pid "$PROFILE_ID" \
    --argjson skiptag "${SKIP_TAG_ID:-null}" \
    --argjson minsize "$MIN_SIZE_GB" \
    --argjson minsave "$MIN_SAVINGS_GB" \
    --argjson target "$TARGET_GIBH" \
    --argjson worst "$WORST_GIBH" \
    --argjson cooldown "$COOLDOWN_IDS" \
    --argjson inflight "$INFLIGHT_JSON" \
    --argjson queue "$QUEUE_IDS" '
    [ .[]
      | select(.hasFile and .monitored and .qualityProfileId == $pid)
      | select($skiptag == null or ((.tags // []) | index($skiptag)) == null)
      | select((.runtime // 0) > 0 and ((.movieFile.size // 0) > 0))
      | . as $m
      | ($m.movieFile.size / 1073741824) as $gb
      | ($m.runtime / 60)               as $hrs
      | ($hrs * $target)                as $est
      | ($hrs * $worst)                 as $floor
      | select($gb >= $minsize and ($gb - $floor) >= $minsave)
      | select(($inflight | index($m.id)) == null)
      | select(($queue    | index($m.id)) == null)
      | select(($cooldown | index($m.id)) == null)
      | { id: $m.id, title: $m.title, year: $m.year, runtime: $m.runtime,
          fileId: $m.movieFile.id,
          gb: (($gb*10|round)/10), est: (($est*10|round)/10),
          save: ((($gb-$est)*10|round)/10),
          minsave: ((($gb-$floor)*10|round)/10) }
    ] | sort_by(-.minsave)')

TOTAL_Q=$(echo "$CANDIDATES" | jq 'length' 2>/dev/null)
if [ -z "$TOTAL_Q" ]; then
    log "FATAL: candidate selection failed - movie list response was not valid JSON."
    exit 1
fi
SAVE_TOTAL=$(echo "$CANDIDATES" | jq '[.[].save] | add // 0 | (.*10|round)/10')
log "Qualifying movies remaining: $TOTAL_Q, potential savings ~${SAVE_TOTAL} GB (threshold: >=${MIN_SIZE_GB} GB and >=${MIN_SAVINGS_GB} GB guaranteed savings)"
[ "${COOLDOWN_N:-0}" -gt 0 ] && log "($COOLDOWN_N movie(s) parked - no qualifying release / failed grab within the last ${SKIP_COOLDOWN_DAYS}d)"

if [ "$TOTAL_Q" -eq 0 ]; then
    log "Nothing to do. Library is slim. | in flight: $INFLIGHT_N | total recovered so far: $(recovered_total) GB"
    log "===== Run end ====="
    exit 0
fi

BATCH=$(echo "$CANDIDATES" | jq -c ".[0:$BATCH_SIZE][]")

# --------------------------- Grab the batch ----------------------------------
GRABBED=0
while IFS= read -r M; do
    [ -z "$M" ] && continue
    MID=$(echo "$M"     | jq -r '.id')
    TITLE=$(echo "$M"   | jq -r '.title')
    YEAR=$(echo "$M"    | jq -r '.year')
    GB=$(echo "$M"      | jq -r '.gb')
    EST=$(echo "$M"     | jq -r '.est')
    SAVE=$(echo "$M"    | jq -r '.save')
    MINSAVE=$(echo "$M" | jq -r '.minsave')
    FILEID=$(echo "$M"  | jq -r '.fileId')
    RUNTIME=$(echo "$M" | jq -r '.runtime')

    log "Candidate: $TITLE ($YEAR) - ${GB} GB, est new ${EST} GB, save ~${SAVE} GB (>=${MINSAVE} GB guaranteed)"

    # NOTE: we deliberately ignore each release's `rejected` flag - the old file
    # is still on disk at search time, so Radarr rejects most candidates with
    # "existing file has better quality". Pushing by guid bypasses that check.
    RELEASES=$(api_get "release?movieId=$MID" "$RELEASE_TIMEOUT")
    if [ -z "$RELEASES" ]; then
        log "  Release search failed or timed out (>${RELEASE_TIMEOUT}s) - skipping, file untouched."
        ledger "SKIP_NO_RELEASE" "$MID" "$TITLE" "$YEAR" "$GB" "" "release search failed or timed out"
        continue
    fi

    BEST=$(echo "$RELEASES" | jq -c \
        --argjson rt "$RUNTIME" --argjson target "$TARGET_GIBH" \
        --argjson blo "$BLURAY_LO" --argjson bhi "$BLURAY_HI" \
        --argjson wlo "$WEB_LO"    --argjson whi "$WEB_HI" '
        ($rt / 60) as $hrs
        | ($hrs * $target) as $prefgb
        | [ .[]
            | (.quality.quality.name) as $q
            | select($q == "Bluray-1080p" or $q == "WEBDL-1080p" or $q == "WEBRip-1080p")
            | select((.title // "") | test("commentary|extras[ .-]only|sample"; "i") | not)
            | ((.languages // []) | map(.name)) as $langs
            | select(($langs | length) == 0 or ($langs | index("English")) != null)
            | (if ($langs | index("English")) != null and ($langs | length) == 1 then 0 else 1 end) as $langpen
            | ((.size // 0) / 1073741824) as $gb
            | (if $q == "Bluray-1080p" then {lo: $blo, hi: $bhi} else {lo: $wlo, hi: $whi} end) as $b
            | select($gb >= ($b.lo * $hrs) and $gb <= ($b.hi * $hrs))
            | select((.customFormatScore // 0) >= 0)
            | { guid, indexerId, gb: (($gb*10|round)/10), score: (.customFormatScore // 0),
                langpen: $langpen,
                dist: (($gb - $prefgb) | if . < 0 then -. else . end), rtitle: .title }
          ]
        | sort_by(-.score, .langpen, .dist) | .[0] // empty')

    if [ -z "$BEST" ]; then
        log "  No qualifying 1080p release found - skipping, file untouched."
        ledger "SKIP_NO_RELEASE" "$MID" "$TITLE" "$YEAR" "$GB" "" "no release met size/quality/score requirements"
        continue
    fi

    RGB=$(echo "$BEST"    | jq -r '.gb')
    RSCORE=$(echo "$BEST" | jq -r '.score')
    RTITLE=$(echo "$BEST" | jq -r '.rtitle')
    log "  Verified release: $RTITLE (${RGB} GB, CF score $RSCORE)"

    if [ "$DRY_RUN" = true ]; then
        log "  DRY RUN - would grab the above. The old file would stay until the download completes."
        continue
    fi

    # Push the release. The old file is NOT touched here - it is deleted on a
    # later run, once the download has actually finished.
    GRAB_BODY=$(echo "$BEST" | jq -c '{guid, indexerId}')
    if api_post "release" "$GRAB_BODY" >/dev/null; then
        ledger "GRABBED" "$MID" "$TITLE" "$YEAR" "$GB" "" "oldFileId=$FILEID grabbing: $RTITLE (${RGB} GB)"
        log "  Grab sent to download client. Old file stays until the bits land."
        GRABBED=$((GRABBED+1))
    else
        log "  ERROR: grab was rejected by Radarr - skipping, file untouched."
        ledger "SKIP_NO_RELEASE" "$MID" "$TITLE" "$YEAR" "$GB" "" "Radarr refused the push (stale guid?)"
    fi
done <<< "$BATCH"

# ------------------------------- Summary -------------------------------------
NEEDS_HELP=$(grep -c ",ABANDONED," "$LEDGER" 2>/dev/null || true)
log "Batch complete: $GRABBED grabbed | in flight: $((INFLIGHT_N+GRABBED)) | today: $((DONE_TODAY+GRABBED))/$DAILY_CAP | total recovered so far: $(recovered_total) GB | remaining candidates: $((TOTAL_Q-GRABBED))"
[ "${NEEDS_HELP:-0}" -gt 0 ] && log "!! $NEEDS_HELP movie(s) ABANDONED mid-import - grep ABANDONED $LEDGER"
log "===== Run end ====="
