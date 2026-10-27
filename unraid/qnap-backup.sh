#!/bin/bash
# =============================================================================
# qnap-backup.sh - exact mirror of media + appdata from unRAID to a QNAP NAS
#
# PUSH OVER SSH, rsync --delete, ONE JOB PER SHARE
# ------------------------------------------------
# Each job is an exact mirror: anything removed from unRAID is removed from the
# QNAP on the next run. That includes files the reclaim workers replace, which
# is what keeps the backup the same size as the library instead of growing by
# every superseded remux.
#
# THE FAILURE THIS IS DESIGNED AROUND
# -----------------------------------
# An exact mirror of an EMPTY source is an empty backup. Array stopped, share
# renamed, a typo in a path - rsync --delete will faithfully wipe the QNAP copy.
# So before any job runs with --delete:
#   - the source must exist and contain files
#   - the source must hold at least MIN_SOURCE_RATIO of the files the
#     destination already has (a share that "shrank" by 90% is a mount problem,
#     not a cleanup)
#   - rsync is capped at MAX_DELETE deletions per job (--max-delete); past that
#     it stops deleting and the run is flagged
# Deletes are applied AFTER transfers (--delete-delay), so a run that dies
# partway leaves extra files on the QNAP, never missing ones.
#
# APPDATA
# -------
# The normal route is the "appdatabackups" job: it mirrors the archives the
# Appdata Backup plugin already made, so nothing live is copied.
# A job named exactly "appdata" copies /mnt/user/appdata directly instead.
# Copying live SQLite databases (Plex, Radarr, Sonarr) gives you a backup that
# may not open, so containers in STOP_CONTAINERS are stopped for that job
# only and restarted afterwards - including on Ctrl-C or error (trap).
#
# Run by hand from the User Scripts plugin ("Run in background") or SSH. A
# full first sync of several TB takes many hours; it is safe to kill and rerun,
# rsync resumes from what is already on the QNAP.
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
QNAP_HOST="qnap.lan"                         # hostname or IP - set in CONF_FILE
QNAP_USER="backup"                           # see PRESERVE_OWNER below - set in CONF_FILE
QNAP_PORT=22
QNAP_RSYNC="/usr/bin/rsync"                  # QTS non-login PATH can miss it

# /root on unRAID is RAM - a key there is gone after reboot. Keep it on flash.
SSH_KEY="/boot/config/ssh/qnap_backup"
SSH_KNOWN_HOSTS="/boot/config/ssh/qnap_known_hosts"

# "name|source/|qnap-dest". Trailing slash on the source = mirror its CONTENTS.
# QTS shares live under /share/<ShareName>. Each dest's parent must exist.
JOBS=(
    # Archives written by the Appdata Backup plugin (weekly). Already consistent
    # snapshots, so no containers are stopped for this job.
    "appdatabackups|/mnt/user/backups/appdata/|/share/AppDataBackup/appdata"
    "movies|/mnt/user/data/media/movies/|/share/ServerBackup/movies"
    # "tv|/mnt/user/data/media/tv/|/share/ServerBackup/tv"     # off until INCLUDE_tv is filled in
)

# Optional per-job allow-list: INCLUDE_<jobname>. Paths are relative to the
# job's source; folder names must match exactly (ls the share to copy them).
# Empty = back up the whole source. To skip a job entirely, comment out its
# JOBS line instead. A listed path that doesn't exist fails the run - a typo
# must never silently mean "not backed up".
INCLUDE_movies=()
INCLUDE_tv=(
    # "shd/Band of Brothers"
    # "shd/The Pacific"
)

# With an allow-list, what happens to unlisted folders ALREADY on the QNAP?
# false = left alone (never updated, never deleted). true = deleted, so the
# QNAP holds exactly the list. Still subject to MAX_DELETE.
PRUNE_UNLISTED=false

# QTS drops its own folders into shares (File Station / Multimedia Console
# thumbnails, recycle bin, snapshot view). They don't exist on unRAID, so an
# exact mirror would delete them every run. Protect them from --delete.
QNAP_PROTECT=(".@__thumb/" "@Recycle/" "@Recently-Snapshot/")

# Stopped for the appdata job only. Must match `docker ps` names exactly.
STOP_CONTAINERS=(binhex-plex radarr sonarr)

# Regenerable bulk under appdata - not worth the file count.
APPDATA_EXCLUDES=(
    "*/Plex Media Server/Cache/"
    "*/Plex Media Server/Codecs/"
    "*/Plex Media Server/Crash Reports/"
    "*/Plex Media Server/Logs/"
    "*/transcode/"
)

# true needs a QNAP account that can chown (admin). With a normal user, set
# false - otherwise every file errors and rsync exits 23.
PRESERVE_OWNER=false

MIN_SOURCE_RATIO="0.90" # source must hold >= 90% of dest's file count
# Per-job override: MIN_RATIO_<jobname>. The plugin prunes a whole weekly run
# at once (~20% of its files), which would trip the 90% guard every week.
MIN_RATIO_appdatabackups="0.50"
MAX_DELETE=1000         # per job; a reclaim batch replaces tens, not thousands

DRY_RUN=true            # true = rsync -n, nothing copied or deleted. FLIP WHEN READY.

DATA_DIR="/mnt/user/appdata/qnap-backup"

# Site-specific values (QNAP_HOST, QNAP_USER, ...) live on the flash drive, not
# in the repo. Anything set there overrides the defaults above.
CONF_FILE="/boot/config/plugins/user.scripts/qnap-backup.conf"
[ -r "$CONF_FILE" ] && . "$CONF_FILE"
# -----------------------------------------------------------------------------

RUNLOG="$DATA_DIR/run.log"
NOW() { date '+%Y-%m-%d %H:%M:%S'; }
mkdir -p "$DATA_DIR"
log() { echo "[$(NOW)] $*" | tee -a "$RUNLOG"; }

# aes128-gcm is the cheapest cipher for the QNAP's CPU to decrypt; on a LAN the
# box usually bottlenecks on SSH crypto long before the disks.
SSH_CMD="ssh -p $QNAP_PORT -i $SSH_KEY -o UserKnownHostsFile=$SSH_KNOWN_HOSTS -o BatchMode=yes -o ConnectTimeout=15 -c aes128-gcm@openssh.com"
qnap() { $SSH_CMD "$QNAP_USER@$QNAP_HOST" "$@"; }

log "===== Run start (DRY_RUN=$DRY_RUN) ====="

# ------------------------- GUARD 1: single instance -------------------------
exec 9>"$DATA_DIR/lock"
flock -n 9 || { log "Another run is in progress - exiting."; exit 0; }

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

# ------------------------- GUARD 3: QNAP reachable --------------------------
[ -r "$SSH_KEY" ] || { log "FATAL: no SSH key at $SSH_KEY"; exit 1; }
if ! qnap "test -x '$QNAP_RSYNC'"; then
    log "FATAL: cannot reach $QNAP_USER@$QNAP_HOST, or $QNAP_RSYNC missing there."
    exit 1
fi
log "Connected to $QNAP_HOST"

# ------------------------- container handling -------------------------------
STOPPED=()
restart_containers() {
    for c in "${STOPPED[@]}"; do
        log "Starting container $c"
        docker start "$c" >/dev/null || log "WARN: failed to start $c - START IT MANUALLY"
    done
    STOPPED=()
}
trap restart_containers EXIT
trap 'log "Interrupted"; restart_containers; exit 130' INT TERM

stop_containers() {
    for c in "${STOP_CONTAINERS[@]}"; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ]; then
            log "Stopping container $c"
            docker stop -t 60 "$c" >/dev/null && STOPPED+=("$c")
        else
            log "Container $c not running or not found - skipping"
        fi
    done
}

# ------------------------- jobs ---------------------------------------------
# QTS ships rsync 3.0.7 as the server side. Nothing newer than 3.0 may go in
# here - e.g. --info= (3.1+) is forwarded to the server and kills the session
# with "unknown option" / exit 12.
RSYNC_OPTS=(-rltD --partial --delete-delay --max-delete="$MAX_DELETE"
            --itemize-changes --stats --rsync-path="$QNAP_RSYNC" -e "$SSH_CMD")
if [ "$PRESERVE_OWNER" = true ]; then
    RSYNC_OPTS+=(-pog --numeric-ids)
else
    RSYNC_OPTS+=(--no-perms --no-owner --no-group)
fi
for p in "${QNAP_PROTECT[@]}"; do RSYNC_OPTS+=(--filter="protect $p"); done
[ "$DRY_RUN" = true ] && RSYNC_OPTS+=(-n)

FAILED=0
for job in "${JOBS[@]}"; do
    IFS='|' read -r NAME SRC DEST <<< "$job"
    OUT="$DATA_DIR/$NAME.last.log"
    log "--- $NAME: $SRC -> $QNAP_HOST:$DEST"

    # The empty-source guard. Never skip this for an exact mirror.
    if [ ! -d "$SRC" ]; then
        log "SKIP $NAME: source $SRC does not exist"; FAILED=1; continue
    fi

    # Allow-list -> rsync filters. Each listed folder needs its parent dirs
    # included too, or rsync never descends far enough to see it. Guard counts
    # cover only the listed folders, on both sides.
    eval "LIST=(\"\${INCLUDE_$NAME[@]}\")"
    FILTERS=(); SRC_PATHS=("$SRC"); DEST_PATHS=("$DEST")
    if [ ${#LIST[@]} -gt 0 ]; then
        SRC_PATHS=(); DEST_PATHS=(); unset SEEN; declare -A SEEN=()
        for p in "${LIST[@]}"; do
            p="${p#/}"; p="${p%/}"
            if [ ! -d "$SRC/$p" ]; then
                log "WARN $NAME: '$p' not found under $SRC - typo? Not backed up."; FAILED=1; continue
            fi
            SRC_PATHS+=("$SRC/$p"); DEST_PATHS+=("$DEST/$p")
            parent=""; IFS='/' read -ra parts <<< "$p"
            for part in "${parts[@]:0:${#parts[@]}-1}"; do
                parent+="/$part"
                [ -n "${SEEN[$parent]}" ] || { FILTERS+=(--include="$parent/"); SEEN[$parent]=1; }
            done
            # *** makes this a wildcard pattern, so [ ] * ? in a name must be escaped
            FILTERS+=(--include="/$(printf '%s' "$p" | sed 's/[][*?\\]/\\&/g')/***")
        done
        [ ${#SRC_PATHS[@]} -eq 0 ] && { log "SKIP $NAME: none of INCLUDE_$NAME exist"; continue; }
        FILTERS+=(--exclude="*")
        [ "$PRUNE_UNLISTED" = true ] && FILTERS+=(--delete-excluded)
        log "$NAME: allow-list of ${#SRC_PATHS[@]} folder(s), PRUNE_UNLISTED=$PRUNE_UNLISTED"
    fi

    SRC_COUNT=$(find "${SRC_PATHS[@]}" -type f 2>/dev/null | wc -l)
    if [ "$SRC_COUNT" -eq 0 ]; then
        log "SKIP $NAME: source $SRC is empty - array down or wrong path?"; FAILED=1; continue
    fi
    # mkdir without -p: a missing share means a wrong path, not a folder to invent
    qnap "test -d '$DEST' || mkdir '$DEST'" || { log "SKIP $NAME: cannot create $DEST (does $(dirname "$DEST") exist?)"; FAILED=1; continue; }
    DEST_COUNT=$(qnap "find $(printf '%q ' "${DEST_PATHS[@]}") -type f -not -path '*/.@__thumb/*' 2>/dev/null | wc -l")
    eval "RATIO=\${MIN_RATIO_$NAME:-$MIN_SOURCE_RATIO}"
    if [ "${DEST_COUNT:-0}" -gt 0 ] && \
       awk -v s="$SRC_COUNT" -v d="$DEST_COUNT" -v r="$RATIO" 'BEGIN {exit !(s < d*r)}'; then
        log "SKIP $NAME: source has $SRC_COUNT files, backup has $DEST_COUNT (< $RATIO). Refusing to mirror."
        FAILED=1; continue
    fi
    log "$NAME: $SRC_COUNT files on unRAID, $DEST_COUNT on QNAP"

    EXCLUDES=()
    if [ "$NAME" = appdata ]; then
        for e in "${APPDATA_EXCLUDES[@]}"; do EXCLUDES+=(--exclude="$e"); done
        EXCLUDES+=(--exclude="qnap-backup/")    # our own log is being written
        [ "$DRY_RUN" = false ] && stop_containers
    fi

    rsync "${RSYNC_OPTS[@]}" "${EXCLUDES[@]}" "${FILTERS[@]}" "$SRC" "$QNAP_USER@$QNAP_HOST:$DEST/" > "$OUT" 2>&1
    RC=$?
    [ "$NAME" = appdata ] && restart_containers

    case $RC in 0|23|24|25) ;; *)
        log "$NAME: rsync exit $RC - see $OUT:"
        tail -5 "$OUT" | sed 's/^/    /' | tee -a "$RUNLOG"
        FAILED=1; continue ;;
    esac

    COPIES=$(grep -c '^<f' "$OUT")
    DELETES=$(grep -c '^\*deleting' "$OUT")
    SIZE=$(grep -oP 'Total transferred file size: \K[0-9,]+' "$OUT" | tr -d ,)
    log "$NAME: $COPIES files to copy ($(awk -v b="${SIZE:-0}" 'BEGIN {printf "%.1f", b/1024^3}') GiB), $DELETES to delete"
    if [ "$DRY_RUN" = true ] && [ "$DELETES" -gt 0 ]; then
        log "$NAME: first deletions (full list in $OUT):"
        grep '^\*deleting' "$OUT" | head -10 | sed 's/^/    /' | tee -a "$RUNLOG"
    fi

    case $RC in
        0)  log "$NAME: OK" ;;
        24) log "$NAME: OK (some files vanished during transfer - normal for a live share)" ;;
        23) log "$NAME: PARTIAL - some files failed (permissions?). grep 'rsync:' $OUT"; FAILED=1 ;;
        25) log "$NAME: HIT MAX_DELETE ($MAX_DELETE) - deletions stopped. Review $OUT, raise the cap if intended."; FAILED=1 ;;
    esac
done

log "===== Run end (status=$([ $FAILED -eq 0 ] && echo OK || echo ERRORS)) ====="
exit $FAILED
