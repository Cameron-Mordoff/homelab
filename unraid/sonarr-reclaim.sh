#!/bin/bash
# =============================================================================
# sonarr-reclaim.sh - paced reclamation of oversized TV files
#
# Each run (intended for hourly cron via the User Scripts plugin):
#   1. Safety guards: Sonarr up? parity check running? inside night window?
#      download queue already busy? daily cap hit?
#   2. Reconcile ledger: mark searched episodes whose replacement has imported,
#      recording actual GB recovered. Give up on ones that never land.
#   3. Pick the next BATCH_SIZE episode files with the biggest GUARANTEED
#      savings, and trigger an EpisodeSearch for them.
#   4. Log everything to an append-only CSV ledger + run log.
#
# WHY THIS DOES NOT USE SONARR'S "CUTOFF UNMET" LIST
# --------------------------------------------------
# Sonarr ranks a file by its POSITION in the quality profile, ignoring the
# allowed flag. Set-SonarrQualityConfig.ps1 puts the disallowed qualities at the
# bottom, so "cutoff unmet" == "in the disallowed block" == remux, 2160p, AND
# SD/DVD/Unknown. Searching the SD half of that set would replace a 0.4 GiB/h
# DVD rip with a 1080p WEB-DL - a perfectly good "upgrade" that makes the
# library BIGGER. That is the opposite of the job.
#
# So candidates are chosen by MEASURED BITRATE instead: an episode is only
# searched when its current file exceeds the profile's target rate by enough
# that even the WORST release we'd accept (the profile's max rate) still saves
# MIN_SAVINGS_GB. Shrink-only, by construction.
#
# Stateless by design: all decisions derive from Sonarr's live state plus the
# CSV ledger. Safe to interrupt at any point.
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
SONARR_URL="${SONARR_URL:-http://localhost:8989}"
SONARR_API_KEY="${SONARR_API_KEY:-}"
API_KEY_FILE="/boot/config/plugins/user.scripts/sonarr-reclaim.key"

# Only episodes on these profiles are ever touched. Must match
# Set-SonarrQualityConfig.ps1.
PROFILE_1080="1080p TV (720p fallback)"
PROFILE_720="720p TV"

# GiB/hour. TARGET = the profile's PREFERRED size (what we expect to land at).
# MAX = the profile's MAX size, i.e. the largest release Sonarr would accept.
#
# THESE MUST MATCH Set-SonarrQualityConfig.ps1's quality definitions. Savings are
# qualified against MAX, not TARGET, so an episode is only ever searched when even
# the worst release the profile permits is still smaller than what's on disk. That
# is what makes this shrink-only.
#
# CONSEQUENCE, and it's an important one: a file already sitting below MAX can
# never qualify, no matter how far above TARGET it is. It's Always Sunny runs at
# 2.45 GiB/h and MAX_720 is 2.5 - so it is NOT reclaimable at these settings, even
# though the report estimates ~70 GB against the 1.5 target. To actually capture
# that, tighten the 720p max in BOTH places (here and the PS1) to ~2.0. The
# realizable total is always less than the report's estimate for this reason.
TARGET_1080="3.0";  MAX_1080="4.5"
TARGET_720="1.5";   MAX_720="2.5"

# Per episode. A 22-minute sitcom episode only saves a few hundred MB, so this is
# deliberately small - the DAILY_CAP and batch size are what pace the work, not
# this. Raise it if you'd rather only chase the big remux wins.
MIN_SAVINGS_GB="0.2"

BATCH_SIZE=10           # episodes searched per run
DAILY_CAP=60            # max episodes searched per calendar day
MAX_QUEUE=20            # skip the run if the download queue is already this deep
MAX_ATTEMPTS=3          # reconcile passes to wait before giving up on an episode
COOLDOWN_DAYS=14        # after giving up, park the episode this long

ENFORCE_WINDOW=true
WINDOW_START=23         # 11 PM
WINDOW_END=9            # 9 AM

DRY_RUN=true            # true = report only, search nothing. FLIP WHEN READY.

DATA_DIR="/mnt/user/appdata/sonarr-reclaim"
# -----------------------------------------------------------------------------

SONARR_URL="${SONARR_URL%/}"
LEDGER="$DATA_DIR/reclaim.csv"
RUNLOG="$DATA_DIR/run.log"
API="$SONARR_URL/api/v3"
NOW() { date '+%Y-%m-%d %H:%M:%S'; }
TODAY=$(date '+%Y-%m-%d')

mkdir -p "$DATA_DIR"
[ -f "$LEDGER" ] || echo "timestamp,action,episode_id,series_id,series,episode,old_size_gb,new_size_gb,note" > "$LEDGER"

log() { echo "[$(NOW)] $*" | tee -a "$RUNLOG"; }

# Every ledger reader is awk -F',' which does not understand quoted fields, so a
# series like "Tom Clancy's Jack Ryan, Season 2" would shift every column after
# it. Strip the delimiter at write time instead.
csv_safe() { printf '%s' "$1" | tr ',' ';' | tr -d '"\r\n'; }
ledger() { # action epid seriesid series episode old new note
    [ "$DRY_RUN" = true ] && return 0   # a dry run must never mutate state
    printf '%s,%s,%s,%s,"%s","%s",%s,%s,"%s"\n' \
        "$(NOW)" "$1" "$2" "$3" "$(csv_safe "$4")" "$(csv_safe "$5")" "$6" "$7" "$(csv_safe "$8")" >> "$LEDGER"
}

if [ -z "$SONARR_API_KEY" ] && [ -r "$API_KEY_FILE" ]; then
    SONARR_API_KEY=$(tr -d ' \t\r\n' < "$API_KEY_FILE")
fi
if [ -z "$SONARR_API_KEY" ]; then
    log "FATAL: no API key. Set SONARR_API_KEY or write it to $API_KEY_FILE"
    exit 1
fi
HDR="X-Api-Key: $SONARR_API_KEY"

api_get()  { curl -sf --max-time "${2:-120}" -H "$HDR" "$API/$1"; }
api_post() { curl -sf --max-time 120 -H "$HDR" -X POST -H 'Content-Type: application/json' -d "$2" "$API/$1"; }

command -v jq   >/dev/null || { log "FATAL: jq not found";   exit 1; }
command -v curl >/dev/null || { log "FATAL: curl not found"; exit 1; }

log "===== Run start (DRY_RUN=$DRY_RUN) ====="

# ------------------------- GUARD 1: Sonarr health ---------------------------
HC_BODY="/tmp/sonarr-reclaim-status.json"
HC_CODE=$(curl -s -o "$HC_BODY" -w '%{http_code}' --max-time 30 -H "$HDR" "$API/system/status")
SONARR_VER=$(jq -r '.version // empty' "$HC_BODY" 2>/dev/null)
if [ -z "$SONARR_VER" ]; then
    case "$HC_CODE" in
        401) log "Sonarr rejected the API key (HTTP 401) - check $API_KEY_FILE." ;;
        000) log "No connection to $SONARR_URL (HTTP 000) - DNS/network/timeout." ;;
        *)   log "Unexpected response from $SONARR_URL (HTTP $HC_CODE) - proxy or URL issue." ;;
    esac
    exit 0
fi
log "Connected to Sonarr $SONARR_VER"

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
    if [ "$WINDOW_START" -gt "$WINDOW_END" ]; then
        { [ "$HOUR" -ge "$WINDOW_START" ] || [ "$HOUR" -lt "$WINDOW_END" ]; } && IN_WINDOW=true
    else
        { [ "$HOUR" -ge "$WINDOW_START" ] && [ "$HOUR" -lt "$WINDOW_END" ]; } && IN_WINDOW=true
    fi
    if [ "$IN_WINDOW" = false ]; then
        log "Outside action window (${WINDOW_START}:00-${WINDOW_END}:00) - skipping run."
        exit 0
    fi
fi

# --------------------- Reconcile: did the replacements land? -----------------
QUEUE=$(api_get "queue?page=1&pageSize=200&includeEpisode=true")
[ -z "$QUEUE" ] && QUEUE='{"records":[]}'
QUEUE_EP_IDS=$(echo "$QUEUE" | jq -c '[.records[].episodeId // empty]' 2>/dev/null)
[ -z "$QUEUE_EP_IDS" ] && QUEUE_EP_IDS="[]"
QUEUE_DEPTH=$(echo "$QUEUE" | jq '.records | length' 2>/dev/null)
QUEUE_DEPTH=${QUEUE_DEPTH:-0}

# A SEARCHED episode is pending until it is REPLACED or ABANDONED.
PENDING=$(awk -F',' '
    $2=="SEARCHED"  { p[$3]=1 }
    $2=="REPLACED"  { done[$3]=1 }
    $2=="ABANDONED" { done[$3]=1 }
    END { for (i in p) if (!(i in done)) print i }' "$LEDGER")

for EPID in $PENDING; do
    EP=$(api_get "episode/$EPID") || continue
    HASFILE=$(echo "$EP" | jq -r '.hasFile')
    NEWFID=$(echo "$EP" | jq -r '.episodeFileId // 0')
    OLDFID=$(awk -F',' -v id="$EPID" '$2=="SEARCHED" && $3==id {gsub(/"/,"",$9); print $9}' "$LEDGER" | tail -1 | grep -oP 'oldFileId=\K[0-9]+' )
    SER=$(awk -F',' -v id="$EPID" '$2=="SEARCHED" && $3==id {gsub(/"/,"",$5); print $5}' "$LEDGER" | tail -1)
    EPN=$(awk -F',' -v id="$EPID" '$2=="SEARCHED" && $3==id {gsub(/"/,"",$6); print $6}' "$LEDGER" | tail -1)
    OLDGB=$(awk -F',' -v id="$EPID" '$2=="SEARCHED" && $3==id {print $7}' "$LEDGER" | tail -1)
    SID=$(echo "$EP" | jq -r '.seriesId')

    if [ "$HASFILE" = "true" ] && [ -n "$NEWFID" ] && [ "$NEWFID" != "0" ] && [ "$NEWFID" != "${OLDFID:-0}" ]; then
        NEWGB=$(api_get "episodefile/$NEWFID" | jq -r '(.size / 1073741824 * 10 | round) / 10')
        SAVED=$(echo "${OLDGB:-0} ${NEWGB:-0}" | awk '{printf "%.1f", $1-$2}')
        ledger "REPLACED" "$EPID" "$SID" "$SER" "$EPN" "${OLDGB:-?}" "${NEWGB:-?}" "recovered ${SAVED} GB"
        log "REPLACED: $SER $EPN - ${OLDGB} GB -> ${NEWGB} GB (saved ${SAVED} GB)"

    elif echo "$QUEUE_EP_IDS" | jq -e --argjson id "$EPID" 'index($id) != null' >/dev/null; then
        :   # still downloading - leave pending, the queue guard paces us

    else
        ATTEMPTS=$(grep -c ",NORESULT,$EPID," "$LEDGER" 2>/dev/null || true)
        ATTEMPTS=${ATTEMPTS:-0}
        if [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; then
            ledger "NORESULT" "$EPID" "$SID" "$SER" "$EPN" "${OLDGB:-}" "" "no replacement yet ($((ATTEMPTS+1))/$MAX_ATTEMPTS)"
        else
            ledger "ABANDONED" "$EPID" "$SID" "$SER" "$EPN" "${OLDGB:-}" "" "no acceptable release after $MAX_ATTEMPTS checks - file untouched"
            log "ABANDONED: $SER $EPN - no acceptable smaller release found. Original file is intact."
        fi
    fi
done

# ------------------------- GUARD 4: queue depth ------------------------------
if [ "$QUEUE_DEPTH" -ge "$MAX_QUEUE" ]; then
    log "Download queue is $QUEUE_DEPTH deep (max $MAX_QUEUE) - letting it drain."
    exit 0
fi

# ------------------------- GUARD 5: daily cap --------------------------------
DONE_TODAY=$(grep -c "^$TODAY.*,SEARCHED," "$LEDGER" 2>/dev/null || true)
DONE_TODAY=${DONE_TODAY:-0}
if [ "$DONE_TODAY" -ge "$DAILY_CAP" ]; then
    log "Daily cap reached ($DONE_TODAY/$DAILY_CAP) - done for today."
    exit 0
fi
ROOM=$((DAILY_CAP - DONE_TODAY))
[ "$BATCH_SIZE" -gt "$ROOM" ] && BATCH_SIZE=$ROOM

# --------------------------- Resolve profiles --------------------------------
PROFILES=$(api_get "qualityprofile")
PID_1080=$(echo "$PROFILES" | jq -r --arg n "$PROFILE_1080" '.[] | select(.name==$n) | .id')
PID_720=$(echo "$PROFILES" | jq -r --arg n "$PROFILE_720" '.[] | select(.name==$n) | .id')
if [ -z "$PID_1080" ] || [ -z "$PID_720" ]; then
    log "FATAL: managed profiles not found. Sonarr reports:"
    echo "$PROFILES" | jq -r '.[].name' | sed 's/^/    - /' | tee -a "$RUNLOG"
    exit 1
fi

# Episodes we've already dealt with, or given up on within the cooldown.
#
# NOTE ON --slurpfile BELOW: everything big is handed to jq through a FILE, never
# through --argjson. --argjson puts the whole JSON blob on the command line, and
# a series with a few hundred episodes blows past ARG_MAX - jq dies with
# "Argument list too long" and that series is silently skipped, contributing zero
# candidates. The ledger's exclude list has the same problem as it grows.
# --slurpfile wraps the file's contents in an array, hence the [0] indexes.
TMP="${TMPDIR:-/tmp}/sonarr-reclaim.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

CUTOFF_DATE=$(date -d "-$COOLDOWN_DAYS days" '+%Y-%m-%d' 2>/dev/null) || CUTOFF_DATE=""
awk -F',' -v cut="$CUTOFF_DATE" '
    $2=="SEARCHED"  { print $3 }
    $2=="REPLACED"  { print $3 }
    $2=="ABANDONED" && (cut=="" || substr($1,1,10) >= cut) { print $3 }' "$LEDGER" \
    | sort -u | jq -Rc -n '[inputs | select(length>0) | tonumber]' > "$TMP/exclude.json"
[ -s "$TMP/exclude.json" ] || echo '[]' > "$TMP/exclude.json"

# --------------------------- Build candidates --------------------------------
ALL_MANAGED=$(api_get "series" | jq -c --argjson a "$PID_1080" --argjson b "$PID_720" \
    '[ .[] | select(.qualityProfileId == $a or .qualityProfileId == $b) ]')
SERIES=$(echo "$ALL_MANAGED" | jq -c \
    '[ .[] | select(.monitored) | {id, title, runtime, pid: .qualityProfileId} ]')
SER_COUNT=$(echo "$SERIES"      | jq 'length')
MANAGED_N=$(echo "$ALL_MANAGED" | jq 'length')
UNMON=$((MANAGED_N - SER_COUNT))
log "Scanning $SER_COUNT monitored series of $MANAGED_N on the managed profiles..."
if [ "$UNMON" -gt 0 ]; then
    log "!! $UNMON managed series are UNMONITORED and can never be reclaimed - Sonarr refuses to"
    log "   search an unmonitored series. Monitor them in Sonarr if you want their space back:"
    echo "$ALL_MANAGED" | jq -r '.[] | select(.monitored | not) | "     - \(.title)"' \
        | head -20 | tee -a "$RUNLOG"
fi

CAND_FILE="$TMP/candidates.jsonl"
: > "$CAND_FILE"
while IFS= read -r S; do
    [ -z "$S" ] && continue
    SID=$(echo "$S" | jq -r '.id')
    SPID=$(echo "$S" | jq -r '.pid')

    if [ "$SPID" = "$PID_1080" ]; then TGT="$TARGET_1080"; MAXR="$MAX_1080"; RES="1080p"
    else                               TGT="$TARGET_720";  MAXR="$MAX_720";  RES="720p"; fi

    api_get "episodefile?seriesId=$SID" > "$TMP/files.json" || continue
    api_get "episode?seriesId=$SID"     > "$TMP/eps.json"   || continue
    [ -s "$TMP/files.json" ] || continue

    FOUND=$(jq -c -n \
        --argjson s "$S" \
        --slurpfile filesw "$TMP/files.json" \
        --slurpfile epsw   "$TMP/eps.json" \
        --slurpfile excw   "$TMP/exclude.json" \
        --argjson tgt "$TGT" --argjson maxr "$MAXR" --arg res "$RES" \
        --argjson minsave "$MIN_SAVINGS_GB" '
        ($filesw[0]) as $files | ($epsw[0]) as $eps | ($excw[0]) as $exclude |
        # mediaInfo.runTime is a string, and Sonarr formats it conditionally:
        # "22:15" under an hour, "1:02:15" at an hour or over. Handle both.
        def mins: if . == null or . == "" then 0
                  else (split(":") | map(tonumber? // 0)
                        | if length == 2 then .[0] + (.[1] / 60)
                          elif length == 3 then (.[0] * 60) + .[1] + (.[2] / 60)
                          else 0 end)
                  end;

        # An episode file carries no back-reference to its episodes, so build the
        # reverse map. A file covering 2 episodes is double length - without this
        # its GiB/h reads twice as bad and it looks like a false positive.
        ($eps | map(select(.episodeFileId != null and .episodeFileId > 0))
              | group_by(.episodeFileId)
              | map({key: (.[0].episodeFileId | tostring),
                     value: {n: length,
                             ids: [.[] | .id],
                             monitored: (any(.[]; .monitored)),
                             label: ([.[] | "S\(.seasonNumber)E\(.episodeNumber)"] | join("+"))}})
              | from_entries) as $map

        | [ $files[]
            | . as $f
            | ($map[($f.id | tostring)]) as $m
            | select($m != null and $m.monitored)
            | (($f.mediaInfo.runTime // "" | mins) as $mi
               | (if $mi > 0 then $mi else ($s.runtime * $m.n) end)) as $minutes
            | select($minutes > 0)
            | ($minutes / 60)                    as $hrs
            | (($f.size // 0) / 1073741824)      as $gb
            | ($hrs * $maxr)                     as $worst
            | ($hrs * $tgt)                      as $est
            | ($gb - $worst)                     as $floor
            | select($floor >= $minsave)
            | select(($m.ids | map(. as $i | $exclude | index($i)) | all(. == null)))
            | { epIds: $m.ids, epId: $m.ids[0], seriesId: $s.id, series: $s.title,
                episode: $m.label, res: $res, fileId: $f.id,
                quality: ($f.quality.quality.name // "?"),
                gb: (($gb*10|round)/10), est: (($est*10|round)/10),
                rate: (($gb/$hrs*10|round)/10),
                save: (($floor*10|round)/10) }
          ]')

    # Append rather than re-passing the whole accumulated list through --argjson,
    # which would hit the same ARG_MAX wall once the candidate list gets long.
    echo "${FOUND:-[]}" >> "$CAND_FILE"
done <<< "$(echo "$SERIES" | jq -c '.[]')"

CANDIDATES=$(jq -c -s 'add // [] | sort_by(-.save)' "$CAND_FILE")
TOTAL=$(echo "$CANDIDATES" | jq 'length')
SAVE_ALL=$(echo "$CANDIDATES" | jq '[.[].save] | add // 0 | (.*10|round)/10')
log "Oversized episodes remaining: $TOTAL, guaranteed savings ~${SAVE_ALL} GB"

# Running total of what this has actually recovered, from the ledger. Report it
# even on a "nothing to do" run - otherwise the early exit hides the imports
# that were reconciled in that very run.
recovered_total() { awk -F',' '$2=="REPLACED" {s+=($7-$8)} END {printf "%.1f", s}' "$LEDGER"; }

if [ "$TOTAL" -eq 0 ]; then
    log "Nothing to do. Library is slim. | total recovered so far: $(recovered_total) GB"
    log "===== Run end ====="
    exit 0
fi

# --------------------------- Search the batch --------------------------------
BATCH=$(echo "$CANDIDATES" | jq -c ".[0:$BATCH_SIZE][]")
SEARCHED=0
while IFS= read -r C; do
    [ -z "$C" ] && continue
    EPID=$(echo "$C"  | jq -r '.epId')
    EPIDS=$(echo "$C" | jq -c '.epIds')
    SID=$(echo "$C"   | jq -r '.seriesId')
    SER=$(echo "$C"   | jq -r '.series')
    EPN=$(echo "$C"   | jq -r '.episode')
    GB=$(echo "$C"    | jq -r '.gb')
    EST=$(echo "$C"   | jq -r '.est')
    SAVE=$(echo "$C"  | jq -r '.save')
    RATE=$(echo "$C"  | jq -r '.rate')
    QUAL=$(echo "$C"  | jq -r '.quality')
    FID=$(echo "$C"   | jq -r '.fileId')

    log "Candidate: $SER $EPN [$QUAL] - ${GB} GB @ ${RATE} GiB/h, est ${EST} GB, save >=${SAVE} GB"

    if [ "$DRY_RUN" = true ]; then
        log "  DRY RUN - would search for a smaller release."
        continue
    fi

    # Note: we do NOT delete the file. Sonarr replaces it on import only if the
    # new release actually wins the comparison - if nothing acceptable is found
    # the original stays exactly where it is. That is the whole safety story.
    if api_post "command" "{\"name\":\"EpisodeSearch\",\"episodeIds\":$EPIDS}" >/dev/null; then
        ledger "SEARCHED" "$EPID" "$SID" "$SER" "$EPN" "$GB" "" "oldFileId=$FID rate=${RATE} expect<=${EST}"
        log "  Search queued."
        SEARCHED=$((SEARCHED+1))
    else
        log "  ERROR: EpisodeSearch command failed - skipping."
    fi
done <<< "$BATCH"

# ------------------------------- Summary -------------------------------------
REC_TOTAL=$(awk -F',' '$2=="REPLACED" {s+=($7-$8)} END {printf "%.1f", s}' "$LEDGER")
GAVE_UP=$(grep -c ",ABANDONED," "$LEDGER" 2>/dev/null || true)
log "Batch complete: $SEARCHED searched | today: $((DONE_TODAY+SEARCHED))/$DAILY_CAP | recovered so far: ${REC_TOTAL:-0} GB | remaining: $((TOTAL-SEARCHED))"
[ "${GAVE_UP:-0}" -gt 0 ] && log "($GAVE_UP episode(s) had no acceptable smaller release - files left intact)"
log "===== Run end ====="
