#!/bin/bash
# =============================================================================
# sonarr-reclaim.sh - paced reclamation of oversized TV files
#
# SEARCH -> PUSH A SPECIFIC RELEASE -> DELETE ONLY IF THE IMPORT IS BLOCKED
# ------------------------------------------------------------------------
# For each oversized episode: run an interactive search, pick the release we
# actually want (right quality, right size, genuinely smaller), and push it to
# the download client by guid. The old file is left alone. Sonarr swaps it on
# import. Only if the import turns out to be BLOCKED - and only once the new
# bits are already on disk - is the old file removed to let the import through.
#
# WHY THE guid PUSH, RATHER THAN AN EpisodeSearch COMMAND
# -------------------------------------------------------
# EpisodeSearch runs the full decision engine, and UpgradeDiskSpecification
# rejects every release with DiskCutoffMet when the existing file already meets
# the profile cutoff. Our targets include oversized files of an ALLOWED quality
# (a 36 GB Bluray-1080p documentary episode) - those sit ABOVE the cutoff, so
# an EpisodeSearch finds releases and then refuses all of them. It would search
# forever and reclaim nothing.
#
# POST /api/v3/release {guid, indexerId} bypasses the decision engine entirely
# (ReleaseController -> DownloadService.DownloadReport, no specs at all). That
# means THIS SCRIPT is now solely responsible for vetting the release: quality,
# size window, and that it actually saves MIN_SAVINGS_GB. It does all three.
#
# The guid must come from a search against the same running Sonarr, and Sonarr
# caches it for 30 minutes - hence search-then-push, back to back.
#
# WHY NOT SONARR'S "CUTOFF UNMET" LIST
# ------------------------------------
# Sonarr ranks a file by its POSITION in the profile and ignores the allowed
# flag, so "cutoff unmet" == the disallowed block == remux, 2160p, AND SD/DVD.
# Searching the SD half of that would replace a 0.4 GiB/h DVD rip with a 1080p
# WEB-DL - a real "upgrade" that makes the library BIGGER. Candidates are chosen
# by MEASURED BITRATE instead, and every grab is checked to be smaller than what
# it replaces. Shrink-only, by construction.
#
# Stateless: all decisions derive from Sonarr's live state plus the CSV ledger.
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
SONARR_URL="${SONARR_URL:-http://localhost:8989}"
SONARR_API_KEY="${SONARR_API_KEY:-}"
API_KEY_FILE="/boot/config/plugins/user.scripts/sonarr-reclaim.key"

PROFILE_1080="1080p TV (720p fallback)"
PROFILE_720="720p TV"

# TARGET = the profile's preferred rate. A file above this is a candidate.
#
# Note this is the TARGET, not the max. The old version qualified candidates
# against the profile's MAX rate, which meant a file already under the ceiling
# could never qualify no matter how far above target it was (It's Always Sunny
# at 2.45 GiB/h vs a 2.5 max). That is no longer necessary: because we now pick
# the exact release, the savings guarantee comes from checking the chosen
# release's real size, not from a worst-case estimate.
TARGET_1080="3.0"
TARGET_720="1.5"

# Accepted release size windows, GiB/hour. Keep in sync with the quality
# definitions in Set-SonarrQualityConfig.ps1 - a release outside these would be
# rejected by Sonarr on a normal grab, and we are bypassing that check.
BLURAY_1080_LO="1.0"; BLURAY_1080_HI="4.5"
WEB_1080_LO="0.8";    WEB_1080_HI="4.0"
HDTV_1080_LO="0.8";   HDTV_1080_HI="3.5"
BLURAY_720_LO="0.5";  BLURAY_720_HI="2.5"
WEB_720_LO="0.4";     WEB_720_HI="2.2"
HDTV_720_LO="0.4";    HDTV_720_HI="2.0"

MIN_SAVINGS_GB="0.2"    # per episode, and now a HARD guarantee: the release we
                        # push is verified to be at least this much smaller than
                        # the file it replaces.

BATCH_SIZE=10           # episodes grabbed per run
DAILY_CAP=60            # max grabs per calendar day
MAX_INFLIGHT=15         # don't grab more while this many are already in flight
MAX_QUEUE=25            # skip the run if the download queue is already this deep

MAX_GRAB_WAIT=8         # runs to wait for a download to appear/finish. The file
                        # is NEVER touched in this state - a failed grab is free.
MAX_DL_WAIT=2           # runs to give Sonarr to import on its own after the
                        # download completes, before we delete the old file to
                        # unblock it.
MAX_IMPORT_WAIT=6       # runs to wait for the import AFTER we deleted the old
                        # file. The only state that can leave an episode fileless.
COOLDOWN_DAYS=14        # park an episode this long after a failed/absent grab

ENFORCE_WINDOW=true
WINDOW_START=23
WINDOW_END=9

RELEASE_TIMEOUT=300     # seconds; interactive indexer search can be slow

DRY_RUN=true            # true = report only, grab nothing. FLIP WHEN READY.

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
recovered_total() { awk -F',' '$2=="IMPORTED" {gsub(/"/,"",$7); gsub(/"/,"",$8); s+=($7-$8)} END {printf "%.1f", s}' "$LEDGER"; }

if [ -z "$SONARR_API_KEY" ] && [ -r "$API_KEY_FILE" ]; then
    SONARR_API_KEY=$(tr -d ' \t\r\n' < "$API_KEY_FILE")
fi
if [ -z "$SONARR_API_KEY" ]; then
    log "FATAL: no API key. Set SONARR_API_KEY or write it to $API_KEY_FILE"
    exit 1
fi
HDR="X-Api-Key: $SONARR_API_KEY"

api_get()  { curl -sf --max-time "${2:-120}" -H "$HDR" "$API/$1"; }
api_del()  { curl -sf --max-time 60  -H "$HDR" -X DELETE "$API/$1"; }
api_post() { curl -sf --max-time 180 -H "$HDR" -X POST -H 'Content-Type: application/json' -d "$2" "$API/$1"; }

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

TMP="${TMPDIR:-/tmp}/sonarr-reclaim.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

# =============================================================================
# Reconcile everything in flight
# =============================================================================
QUEUE=$(api_get "queue?page=1&pageSize=500&includeEpisode=true")
[ -z "$QUEUE" ] && QUEUE='{"records":[]}'
QUEUE_DEPTH=$(echo "$QUEUE" | jq '.records | length' 2>/dev/null)
QUEUE_DEPTH=${QUEUE_DEPTH:-0}

INFLIGHT=$(awk -F',' '
    $2=="GRABBED"     { g[$3]=1 }
    $2=="IMPORTED"    { fin[$3]=1 }
    $2=="FAILED_GRAB" { fin[$3]=1 }
    $2=="ABANDONED"   { fin[$3]=1 }
    END { for (i in g) if (!(i in fin)) print i }' "$LEDGER")

INFLIGHT_N=0
for EPID in $INFLIGHT; do
    EP=$(api_get "episode/$EPID") || continue
    HASFILE=$(echo "$EP" | jq -r '.hasFile')
    CURFID=$(echo "$EP" | jq -r '.episodeFileId // 0')
    SID=$(echo "$EP"    | jq -r '.seriesId')

    OLDFID=$(awk -F',' -v id="$EPID" '$2=="GRABBED" && $3==id {print $9}' "$LEDGER" | tail -1 | grep -oP 'oldFileId=\K[0-9]+')
    OLDGB=$(awk -F',' -v id="$EPID"  '$2=="GRABBED" && $3==id {print $7}' "$LEDGER" | tail -1)
    SER=$(awk -F',' -v id="$EPID"    '$2=="GRABBED" && $3==id {gsub(/"/,"",$5); print $5}' "$LEDGER" | tail -1)
    EPN=$(awk -F',' -v id="$EPID"    '$2=="GRABBED" && $3==id {gsub(/"/,"",$6); print $6}' "$LEDGER" | tail -1)
    DELETED_ALREADY=$(grep -c ",DELETED,$EPID," "$LEDGER" 2>/dev/null || true)

    Q=$(echo "$QUEUE" | jq -c --argjson id "$EPID" '[.records[] | select(.episodeId == $id)] | .[0] // empty')
    Q_PRESENT=false; Q_DONE=false; Q_BLOCKED=false
    if [ -n "$Q" ]; then
        Q_PRESENT=true
        STATE=$(echo "$Q" | jq -r '.trackedDownloadState // ""')
        [ "$(echo "$Q" | jq -r '((.status // "") == "completed") or (((.sizeleft // 1) | tonumber) == 0)
                                 or (((.trackedDownloadState // "") | test("import")))')" = "true" ] && Q_DONE=true
        [ "$STATE" = "importBlocked" ] && Q_BLOCKED=true
    fi

    # ---- 1. The replacement imported ---------------------------------------
    if [ "$HASFILE" = "true" ] && [ "$CURFID" != "0" ] && [ "$CURFID" != "${OLDFID:-0}" ]; then
        NEWGB=$(api_get "episodefile/$CURFID" | jq -r '(.size / 1073741824 * 10 | round) / 10')
        SAVED=$(echo "${OLDGB:-0} ${NEWGB:-0}" | awk '{printf "%.1f", $1-$2}')
        ledger "IMPORTED" "$EPID" "$SID" "$SER" "$EPN" "${OLDGB:-?}" "${NEWGB:-?}" "recovered ${SAVED} GB"
        log "IMPORTED: $SER $EPN - ${OLDGB} GB -> ${NEWGB} GB (recovered ${SAVED} GB)"
        continue
    fi

    # ---- 2. Old file already deleted, still no file -------------------------
    if [ "${DELETED_ALREADY:-0}" -gt 0 ] && [ "$HASFILE" != "true" ]; then
        WAITED=$(grep -c ",WAIT_IMPORT,$EPID," "$LEDGER" 2>/dev/null || true)
        if [ "${WAITED:-0}" -lt "$MAX_IMPORT_WAIT" ]; then
            ledger "WAIT_IMPORT" "$EPID" "$SID" "$SER" "$EPN" "${OLDGB:-}" "" "awaiting import ($((WAITED+1))/$MAX_IMPORT_WAIT)"
            log "WAIT: $SER $EPN - old file removed, import pending ($((WAITED+1))/$MAX_IMPORT_WAIT)"
            [ "$DRY_RUN" = false ] && api_post "command" '{"name":"RefreshMonitoredDownloads"}' >/dev/null
            INFLIGHT_N=$((INFLIGHT_N+1))
        else
            ledger "ABANDONED" "$EPID" "$SID" "$SER" "$EPN" "${OLDGB:-}" "" "no file after $MAX_IMPORT_WAIT attempts - recover via Activity > Queue > Manual Import"
            log "!! ABANDONED: $SER $EPN has NO FILE. The download is in the client - Sonarr > Activity > Queue > Manual Import."
        fi
        continue
    fi

    # ---- 3. Download finished but the file has NOT changed ------------------
    # Sonarr's import UpgradeSpecification rejects anything it doesn't consider
    # an upgrade - and it never looks at size. A same-quality-but-smaller file
    # normally imports fine; a quality change downward does not. When that
    # happens the download just sits there "importBlocked".
    #
    # The bits are already on disk at this point, so removing the old file to let
    # the import through is safe. We give Sonarr MAX_DL_WAIT runs to do it by
    # itself first, so we don't delete during a normal import race.
    if [ "$Q_DONE" = true ] && [ "$HASFILE" = "true" ]; then
        WAITED=$(grep -c ",WAIT_DL,$EPID," "$LEDGER" 2>/dev/null || true)
        if [ "$Q_BLOCKED" = false ] && [ "${WAITED:-0}" -lt "$MAX_DL_WAIT" ]; then
            ledger "WAIT_DL" "$EPID" "$SID" "$SER" "$EPN" "${OLDGB:-}" "" "download done, giving Sonarr time to import ($((WAITED+1))/$MAX_DL_WAIT)"
            log "WAIT: $SER $EPN - download complete, waiting for Sonarr to import ($((WAITED+1))/$MAX_DL_WAIT)"
            INFLIGHT_N=$((INFLIGHT_N+1))
            continue
        fi

        RNAME=$(echo "$Q" | jq -r '.title // "?"')
        log "Import blocked for $SER $EPN ($RNAME) - the new file is on disk; removing the old one."
        if [ "$DRY_RUN" = true ]; then
            log "  DRY RUN - would delete the old file (${OLDGB} GB) and let Sonarr import."
            INFLIGHT_N=$((INFLIGHT_N+1))
            continue
        fi
        if ! api_del "episodefile/${OLDFID:-$CURFID}" >/dev/null; then
            log "  ERROR: failed to delete old file - leaving everything alone, will retry."
            INFLIGHT_N=$((INFLIGHT_N+1))
            continue
        fi
        ledger "DELETED" "$EPID" "$SID" "$SER" "$EPN" "${OLDGB:-}" "" "import was blocked; old file removed - importing $RNAME"
        log "  Old file deleted (${OLDGB} GB). Kicking Sonarr to import."
        api_post "command" '{"name":"RefreshMonitoredDownloads"}' >/dev/null \
            || log "  WARNING: could not trigger import; Sonarr will retry on its own."
        INFLIGHT_N=$((INFLIGHT_N+1))
        continue
    fi

    # ---- 4. Still downloading ----------------------------------------------
    if [ "$Q_PRESENT" = true ]; then
        PCT=$(echo "$Q" | jq -r 'if (.size // 0) > 0 then (((.size - (.sizeleft // 0)) / .size * 100) | floor) else 0 end')
        log "Downloading: $SER $EPN - ${PCT}% (old file still intact)"
        INFLIGHT_N=$((INFLIGHT_N+1))
        continue
    fi

    # ---- 5. Nothing in the queue, old file still there ----------------------
    # The grab never landed. Costs nothing: the file was never touched.
    WAITED=$(grep -c ",WAIT_GRAB,$EPID," "$LEDGER" 2>/dev/null || true)
    if [ "${WAITED:-0}" -lt "$MAX_GRAB_WAIT" ]; then
        ledger "WAIT_GRAB" "$EPID" "$SID" "$SER" "$EPN" "${OLDGB:-}" "" "download not in queue yet ($((WAITED+1))/$MAX_GRAB_WAIT)"
        log "WAIT: $SER $EPN - grab not in the download queue ($((WAITED+1))/$MAX_GRAB_WAIT). File intact."
        INFLIGHT_N=$((INFLIGHT_N+1))
    else
        ledger "FAILED_GRAB" "$EPID" "$SID" "$SER" "$EPN" "${OLDGB:-}" "" "download never appeared - ORIGINAL FILE UNTOUCHED"
        log "FAILED_GRAB: $SER $EPN - the download never appeared. Original file intact; nothing lost."
    fi
done

# ------------------------- GUARD 4: in flight / queue -----------------------
if [ "$INFLIGHT_N" -ge "$MAX_INFLIGHT" ]; then
    log "$INFLIGHT_N episode(s) in flight (max $MAX_INFLIGHT) - not grabbing more."
    log "Total recovered so far: $(recovered_total) GB"
    log "===== Run end ====="
    exit 0
fi
if [ "$QUEUE_DEPTH" -ge "$MAX_QUEUE" ]; then
    log "Download queue is $QUEUE_DEPTH deep (max $MAX_QUEUE) - letting it drain."
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

# --------------------------- Resolve profiles --------------------------------
PROFILES=$(api_get "qualityprofile")
PID_1080=$(echo "$PROFILES" | jq -r --arg n "$PROFILE_1080" '.[] | select(.name==$n) | .id')
PID_720=$(echo "$PROFILES"  | jq -r --arg n "$PROFILE_720"  '.[] | select(.name==$n) | .id')
if [ -z "$PID_1080" ] || [ -z "$PID_720" ]; then
    log "FATAL: managed profiles not found. Sonarr reports:"
    echo "$PROFILES" | jq -r '.[].name' | sed 's/^/    - /' | tee -a "$RUNLOG"
    exit 1
fi

# Episodes already dealt with, in flight, or parked.
CUTOFF_DATE=$(date -d "-$COOLDOWN_DAYS days" '+%Y-%m-%d' 2>/dev/null) || CUTOFF_DATE=""
awk -F',' -v cut="$CUTOFF_DATE" '
    $2=="GRABBED"        { print $3 }
    $2=="IMPORTED"       { print $3 }
    ($2=="FAILED_GRAB" || $2=="SKIP_NO_RELEASE" || $2=="ABANDONED") \
        && (cut=="" || substr($1,1,10) >= cut) { print $3 }' "$LEDGER" \
    | sort -u | jq -Rc -n '[inputs | select(length>0) | tonumber]' > "$TMP/exclude.json"
[ -s "$TMP/exclude.json" ] || echo '[]' > "$TMP/exclude.json"
echo "$QUEUE" | jq -c '[.records[].episodeId | select(. != null)]' > "$TMP/queue.json"
[ -s "$TMP/queue.json" ] || echo '[]' > "$TMP/queue.json"

# --------------------------- Build candidates --------------------------------
# NOT filtering on .monitored: verified against Sonarr v4.0.19, monitored gates
# exactly one thing - unattended RSS sync. Interactive search, the guid push, and
# import are all ungated. Filtering on it just hid most of the library.
SERIES=$(api_get "series" | jq -c --argjson a "$PID_1080" --argjson b "$PID_720" \
    '[ .[] | select(.qualityProfileId == $a or .qualityProfileId == $b)
       | {id, title, runtime, pid: .qualityProfileId} ]')
SER_COUNT=$(echo "$SERIES" | jq 'length')
log "Scanning $SER_COUNT managed series for oversized files (monitored or not)..."

CAND_FILE="$TMP/candidates.jsonl"
: > "$CAND_FILE"
while IFS= read -r S; do
    [ -z "$S" ] && continue
    SID=$(echo "$S" | jq -r '.id')
    SPID=$(echo "$S" | jq -r '.pid')
    if [ "$SPID" = "$PID_1080" ]; then TGT="$TARGET_1080"; RES="1080p"
    else                               TGT="$TARGET_720";  RES="720p"; fi

    # Everything large goes to jq via a FILE. --argjson puts it on the command
    # line, and a few hundred episodes blows past ARG_MAX: jq dies with
    # "Argument list too long" and the whole series is silently skipped.
    api_get "episodefile?seriesId=$SID" > "$TMP/files.json" || continue
    api_get "episode?seriesId=$SID"     > "$TMP/eps.json"   || continue
    [ -s "$TMP/files.json" ] || continue

    FOUND=$(jq -c -n \
        --argjson s "$S" \
        --slurpfile filesw "$TMP/files.json" \
        --slurpfile epsw   "$TMP/eps.json" \
        --slurpfile excw   "$TMP/exclude.json" \
        --slurpfile quew   "$TMP/queue.json" \
        --argjson tgt "$TGT" --arg res "$RES" --argjson minsave "$MIN_SAVINGS_GB" '
        ($filesw[0]) as $files | ($epsw[0]) as $eps
        | ($excw[0]) as $exclude | ($quew[0]) as $queue |

        # mediaInfo.runTime is a string, formatted conditionally by Sonarr:
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
                     value: {n: length, ids: [.[] | .id],
                             label: ([.[] | "S\(.seasonNumber)E\(.episodeNumber)"] | join("+"))}})
              | from_entries) as $map

        | [ $files[]
            | . as $f
            | ($map[($f.id | tostring)]) as $m
            | select($m != null)
            | (($f.mediaInfo.runTime // "" | mins) as $mi
               | (if $mi > 0 then $mi else ($s.runtime * $m.n) end)) as $minutes
            | select($minutes > 0)
            | ($minutes / 60)               as $hrs
            | (($f.size // 0) / 1073741824) as $gb
            | ($hrs * $tgt)                 as $est
            | ($gb - $est)                  as $save
            | select($save >= $minsave)
            | select(($m.ids | map(. as $i | $exclude | index($i)) | all(. == null)))
            | select(($m.ids | map(. as $i | $queue   | index($i)) | all(. == null)))
            | { epIds: $m.ids, epId: $m.ids[0], seriesId: $s.id, series: $s.title,
                episode: $m.label, res: $res, fileId: $f.id,
                quality: ($f.quality.quality.name // "?"),
                cfscore: ($f.customFormatScore // 0),
                minutes: (($minutes*10|round)/10),
                gb: (($gb*10|round)/10), est: (($est*10|round)/10),
                rate: (($gb/$hrs*10|round)/10), save: (($save*10|round)/10) }
          ]')
    echo "${FOUND:-[]}" >> "$CAND_FILE"
done <<< "$(echo "$SERIES" | jq -c '.[]')"

CANDIDATES=$(jq -c -s 'add // [] | sort_by(-.save)' "$CAND_FILE")
TOTAL=$(echo "$CANDIDATES" | jq 'length')
SAVE_ALL=$(echo "$CANDIDATES" | jq '[.[].save] | add // 0 | (.*10|round)/10')
log "Oversized episodes remaining: $TOTAL, estimated savings ~${SAVE_ALL} GB"

if [ "$TOTAL" -eq 0 ]; then
    log "Nothing to do. Library is slim. | in flight: $INFLIGHT_N | total recovered so far: $(recovered_total) GB"
    log "===== Run end ====="
    exit 0
fi

# --------------------------- Grab the batch ----------------------------------
BATCH=$(echo "$CANDIDATES" | jq -c ".[0:$BATCH_SIZE][]")
GRABBED=0
while IFS= read -r C; do
    [ -z "$C" ] && continue
    EPID=$(echo "$C"  | jq -r '.epId')
    SID=$(echo "$C"   | jq -r '.seriesId')
    SER=$(echo "$C"   | jq -r '.series')
    EPN=$(echo "$C"   | jq -r '.episode')
    GB=$(echo "$C"    | jq -r '.gb')
    EST=$(echo "$C"   | jq -r '.est')
    RATE=$(echo "$C"  | jq -r '.rate')
    QUAL=$(echo "$C"  | jq -r '.quality')
    FID=$(echo "$C"   | jq -r '.fileId')
    MINUTES=$(echo "$C" | jq -r '.minutes')
    RES=$(echo "$C"   | jq -r '.res')

    log "Candidate: $SER $EPN [$QUAL] - ${GB} GB @ ${RATE} GiB/h, target ${EST} GB"

    RELEASES=$(api_get "release?episodeId=$EPID" "$RELEASE_TIMEOUT")
    if [ -z "$RELEASES" ]; then
        log "  Release search failed or timed out - skipping, file untouched."
        ledger "SKIP_NO_RELEASE" "$EPID" "$SID" "$SER" "$EPN" "$GB" "" "release search failed or timed out"
        continue
    fi

    # We are bypassing Sonarr's decision engine with the guid push, so EVERY check
    # it would normally do has to happen right here.
    BEST=$(echo "$RELEASES" | jq -c \
        --argjson minutes "$MINUTES" --argjson curgb "$GB" --arg res "$RES" \
        --argjson tgt "$([ "$RES" = "1080p" ] && echo "$TARGET_1080" || echo "$TARGET_720")" \
        --argjson minsave "$MIN_SAVINGS_GB" \
        --argjson b1lo "$BLURAY_1080_LO" --argjson b1hi "$BLURAY_1080_HI" \
        --argjson w1lo "$WEB_1080_LO"    --argjson w1hi "$WEB_1080_HI" \
        --argjson h1lo "$HDTV_1080_LO"   --argjson h1hi "$HDTV_1080_HI" \
        --argjson b7lo "$BLURAY_720_LO"  --argjson b7hi "$BLURAY_720_HI" \
        --argjson w7lo "$WEB_720_LO"     --argjson w7hi "$WEB_720_HI" \
        --argjson h7lo "$HDTV_720_LO"    --argjson h7hi "$HDTV_720_HI" '
        ($minutes / 60) as $hrs
        | ($hrs * $tgt) as $prefgb
        # Allowed qualities and their size windows, per profile. Anything not
        # listed (remux, 2160p, SD) is never grabbed.
        | (if $res == "1080p" then
              {"Bluray-1080p": {lo:$b1lo,hi:$b1hi}, "WEBDL-1080p": {lo:$w1lo,hi:$w1hi},
               "WEBRip-1080p": {lo:$w1lo,hi:$w1hi}, "HDTV-1080p": {lo:$h1lo,hi:$h1hi},
               "Bluray-720p": {lo:$b7lo,hi:$b7hi}, "WEBDL-720p": {lo:$w7lo,hi:$w7hi},
               "WEBRip-720p": {lo:$w7lo,hi:$w7hi}}
           else
              {"Bluray-720p": {lo:$b7lo,hi:$b7hi}, "WEBDL-720p": {lo:$w7lo,hi:$w7hi},
               "WEBRip-720p": {lo:$w7lo,hi:$w7hi}, "HDTV-720p": {lo:$h7lo,hi:$h7hi}}
           end) as $allowed
        | [ .[]
            | (.quality.quality.name) as $q
            | select($allowed[$q] != null)
            # A season pack would replace one episode with a whole season.
            | select((.fullSeason // false) | not)
            | select((.title // "") | test("commentary|extras[ .-]only|sample"; "i") | not)
            | ((.languages // []) | map(.name)) as $langs
            | select(($langs | length) == 0 or ($langs | index("English")) != null)
            | (if ($langs | index("English")) != null and ($langs | length) == 1 then 0 else 1 end) as $langpen
            | ((.size // 0) / 1073741824) as $gb
            | select($gb > 0)
            | ($allowed[$q]) as $b
            | select($gb >= ($b.lo * $hrs) and $gb <= ($b.hi * $hrs))
            # THE guarantee. Sonarr will not check this for us - a grab that is
            # not actually smaller is worse than doing nothing.
            | select(($curgb - $gb) >= $minsave)
            | select((.customFormatScore // 0) >= 0)
            | { guid, indexerId, quality: $q,
                gb: (($gb*10|round)/10), score: (.customFormatScore // 0),
                langpen: $langpen,
                dist: (($gb - $prefgb) | if . < 0 then -. else . end), rtitle: .title }
          ]
        | sort_by(-.score, .langpen, .dist) | .[0] // empty')

    if [ -z "$BEST" ]; then
        log "  No release met the size/quality bar - skipping, file untouched."
        ledger "SKIP_NO_RELEASE" "$EPID" "$SID" "$SER" "$EPN" "$GB" "" "no release was both acceptable and >=${MIN_SAVINGS_GB} GB smaller"
        continue
    fi

    RGB=$(echo "$BEST"    | jq -r '.gb')
    RQ=$(echo "$BEST"     | jq -r '.quality')
    RTITLE=$(echo "$BEST" | jq -r '.rtitle')
    SAVES=$(echo "$GB $RGB" | awk '{printf "%.1f", $1-$2}')
    log "  Verified release: $RTITLE [$RQ] ${RGB} GB - saves ${SAVES} GB"

    if [ "$DRY_RUN" = true ]; then
        log "  DRY RUN - would grab this. The old file stays until the download completes."
        continue
    fi

    GRAB_BODY=$(echo "$BEST" | jq -c '{guid, indexerId}')
    if api_post "release" "$GRAB_BODY" >/dev/null; then
        ledger "GRABBED" "$EPID" "$SID" "$SER" "$EPN" "$GB" "" "oldFileId=$FID grabbing: $RTITLE (${RGB} GB, saves ${SAVES})"
        log "  Grab sent to download client. Old file stays until the bits land."
        GRABBED=$((GRABBED+1))
    else
        log "  ERROR: Sonarr refused the push (stale guid?) - file untouched."
        ledger "SKIP_NO_RELEASE" "$EPID" "$SID" "$SER" "$EPN" "$GB" "" "Sonarr refused the release push"
    fi
done <<< "$BATCH"

# ------------------------------- Summary -------------------------------------
NEEDS_HELP=$(grep -c ",ABANDONED," "$LEDGER" 2>/dev/null || true)
log "Batch complete: $GRABBED grabbed | in flight: $((INFLIGHT_N+GRABBED)) | today: $((DONE_TODAY+GRABBED))/$DAILY_CAP | total recovered so far: $(recovered_total) GB | remaining: $((TOTAL-GRABBED))"
[ "${NEEDS_HELP:-0}" -gt 0 ] && log "!! $NEEDS_HELP episode(s) ABANDONED - grep ABANDONED $LEDGER"
log "===== Run end ====="
