#!/bin/bash
# =============================================================================
# health-report.sh - weekly server health summary, sent as one Unraid
# notification (and so to whatever agents are enabled: Pushover, Discord, ...)
#
# WHAT IT CHECKS
# --------------
#   - array started; every assigned disk present, DISK_OK, no read/write errors
#   - SMART per disk, against LAST WEEK'S values: reallocated / pending /
#     uncorrectable sectors, CRC errors, NVMe wear, spare and media errors
#   - temperatures, array / cache / docker.img space
#   - last parity check: age, errors, whether it finished
#   - newest Appdata Backup archive: age, flash backup included
#   - last qnap-backup.sh run: age, status
#   - newest Backrest (restic) snapshot per plan: age in hours
#   - autostart containers that aren't running, unhealthy containers
#
# WHY DELTAS, NOT THRESHOLDS
# --------------------------
# Unraid already alerts on a SMART attribute the first time it goes non-zero.
# What it doesn't tell you is that a disk which has had 8 reallocated sectors
# for two years now has 40. On second-hand disks the trend is the signal, so
# each counter is compared with the previous run (state file on flash, keyed
# by serial number so a renamed sdX doesn't reset the history).
#
# A report is sent EVERY run, even when everything is fine. The weekly "OK" is
# the heartbeat: if it stops arriving, notifications or the script are broken.
#
# Read-only: changes nothing on the server. The one side effect is spinning up
# sleeping disks to read SMART (SMART_WAKE=false to skip those instead).
#
#   bash health-report.sh            # check, notify, save SMART baseline
#   bash health-report.sh --print    # print the report only: no notify, no state write
#
# Schedule weekly via the User Scripts plugin, after the Monday appdata backup:
#   0 9 * * 1
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
# Flash, not appdata: the report must still work when the array won't start.
DATA_DIR="/boot/config/plugins/user.scripts/health-report"
CONF_FILE="/boot/config/plugins/user.scripts/health-report.conf"   # optional overrides

TEMP_HDD_MAX=50              # C
TEMP_NVME_MAX=70             # C
NVME_WEAR_WARN=80            # % "percentage used"
ARRAY_WARN_PCT=85; ARRAY_ALERT_PCT=95
CACHE_WARN_PCT=80; CACHE_ALERT_PCT=90
DOCKER_WARN_PCT=80; DOCKER_ALERT_PCT=90
DISK_FULL_PCT=98             # a single array disk this full is worth knowing

PARITY_MAX_AGE_DAYS=100      # checks run quarterly
APPDATA_BACKUP_DIR="/mnt/user/backups/appdata"
APPDATA_MAX_AGE_DAYS=8       # backups run weekly
QNAP_LOG="/mnt/user/appdata/qnap-backup/run.log"
QNAP_MAX_AGE_DAYS=8          # 0 = don't check (e.g. not scheduled yet)

BACKREST_CONTAINER="backrest"   # "" = don't check
BACKREST_CONFIG="/mnt/user/appdata/backrest/config/config.json"
# Hours, not days: sized so this Monday 09:00 report catches a run that failed
# THIS morning. The Monday 04:00/05:00 plans are ~4h old when fine and ~173h
# after one failure; the daily 03:00 plan ~6h vs ~30h.
BACKREST_MAX_AGE_HOURS=170                 # plans not listed below
BACKREST_PLAN_MAX_AGE="vaultwarden=26"     # plan=hours, space-separated

SMART_WAKE=true
NOTIFY="/usr/local/emhttp/webGui/scripts/notify"
# -----------------------------------------------------------------------------

[ -f "$CONF_FILE" ] && . "$CONF_FILE"

PRINT_ONLY=false
[ "$1" = "--print" ] && PRINT_ONLY=true

STATE_FILE="$DATA_DIR/smart.state"
NEW_STATE=$(mktemp)
trap 'rm -f "$NEW_STATE"' EXIT
mkdir -p "$DATA_DIR"
touch "$STATE_FILE"

ALERTS=(); WARNS=(); REPORT=""
alert() { ALERTS+=("$*"); }
warn()  { WARNS+=("$*"); }
line()  { REPORT+="$*"$'\n'; }

NOW_EPOCH=$(date +%s)
days_since() { echo $(( (NOW_EPOCH - $1) / 86400 )); }
pct() { [ "${1:-0}" -gt 0 ] && echo $(( ($1 - $2) * 100 / $1 )) || echo 0; }   # size free -> % used

# Previous value of a counter, empty if never seen.
prev() { awk -v k="$1 $2" '$1" "$2==k {v=$3} END {print v}' "$STATE_FILE"; }
save() { echo "$1 $2 $3" >> "$NEW_STATE"; }

# Compare a counter with last run. $4 = alert|warn on increase.
delta() {   # serial attr value severity label
    local p; p=$(prev "$1" "$2")
    save "$1" "$2" "$3"
    if [ -z "$p" ]; then
        [ "$3" -gt 0 ] && warn "$5 is $3 (first reading - baseline)"
    elif [ "$3" -gt "$p" ]; then
        "$4" "$5 rose $p -> $3"
    fi
}

line "$(hostname) - Unraid $(sed -n 's/^version="\(.*\)"/\1/p' /etc/unraid-version) - up $(uptime -p | sed 's/^up //')"
line ""

# ----------------------------- Array & disks ---------------------------------
MDSTATE=$(mdcmd status 2>/dev/null | sed -n 's/^mdState=//p')
[ "$MDSTATE" = "STARTED" ] || alert "Array is not started (mdState=${MDSTATE:-unknown})"

MDRESYNC=$(mdcmd status 2>/dev/null | sed -n 's/^mdResync=//p')

# One line per disks.ini section: name|device|type|status|numErrors|temp|fsSize|fsFree|idSb
DISKS=$(awk -F= '
    function out() { if (name != "") print name"|"dev"|"type"|"st"|"err"|"tmp"|"size"|"free"|"idsb; name=dev=type=st=err=tmp=size=free=idsb="" }
    /^\[/ { out(); next }
    { v = substr($0, index($0, "=") + 1); gsub(/"/, "", v) }
    $1=="name"{name=v} $1=="device"{dev=v} $1=="type"{type=v} $1=="status"{st=v}
    $1=="numErrors"{err=v} $1=="temp"{tmp=v} $1=="fsSize"{size=v} $1=="fsFree"{free=v} $1=="idSb"{idsb=v}
    END { out() }' /var/local/emhttp/disks.ini)

line "== Disks"
ARR_SIZE=0; ARR_FREE=0
while IFS='|' read -r name dev type st err tmp size free idsb; do
    [ "$type" = "Flash" ] && continue
    if [ -z "$dev" ]; then
        # Unassigned slots have no device AND no superblock id. A slot that
        # has an id but no device is a disk the array expects and can't find.
        [ -n "$idsb" ] && alert "$name ($idsb) is MISSING ($st)"
        continue
    fi
    [ "$st" = "DISK_OK" ] || alert "$name: status $st"
    [ "${err:-0}" -gt 0 ] && alert "$name: $err read/write errors since array start"

    if [ "$type" = "Data" ]; then
        ARR_SIZE=$((ARR_SIZE + ${size:-0})); ARR_FREE=$((ARR_FREE + ${free:-0}))
        used=$(pct "${size:-0}" "${free:-0}")
        [ "$used" -ge "$DISK_FULL_PCT" ] && warn "$name is ${used}% full"
    fi

    smart_opts=(-j -i -H -A)   # -i: serial_number is only in the info section
    $SMART_WAKE || smart_opts+=(-n standby)
    J=$(smartctl "${smart_opts[@]}" "/dev/$dev" 2>/dev/null)
    if [ -z "$J" ] || [ "$(echo "$J" | jq -r '.smartctl.exit_status // 255')" = "2" ]; then
        line "  $name ($dev): in standby - SMART skipped"
        continue
    fi
    serial=$(echo "$J" | jq -r '.serial_number // empty')
    serial=${serial:-$dev}
    [ "$(echo "$J" | jq -r '.smart_status.passed')" = "false" ] && alert "$name ($dev): SMART overall health FAILED"
    t=$(echo "$J" | jq -r '.temperature.current // empty')
    hours=$(echo "$J" | jq -r '.power_on_time.hours // empty')

    if echo "$J" | jq -e '.nvme_smart_health_information_log' >/dev/null; then
        N=$(echo "$J" | jq -c '.nvme_smart_health_information_log')
        crit=$(echo "$N" | jq -r '.critical_warning'); wear=$(echo "$N" | jq -r '.percentage_used')
        spare=$(echo "$N" | jq -r '.available_spare'); spare_min=$(echo "$N" | jq -r '.available_spare_threshold')
        media=$(echo "$N" | jq -r '.media_errors')
        [ "$crit" != "0" ] && alert "$name ($dev): NVMe critical warning flag $crit"
        [ "$spare" -le "$spare_min" ] && alert "$name ($dev): NVMe spare ${spare}% at/below threshold ${spare_min}%"
        [ "$wear" -ge "$NVME_WEAR_WARN" ] && warn "$name ($dev): NVMe ${wear}% worn"
        [ -n "$t" ] && [ "$t" -gt "$TEMP_NVME_MAX" ] && warn "$name ($dev): ${t}C"
        delta "$serial" media_errors "$media" alert "$name ($dev) NVMe media errors"
        p=$(prev "$serial" wear); save "$serial" wear "$wear"
        line "  $name ($dev) ${t}C ${hours}h  wear ${wear}%${p:+ (was ${p}%)} spare ${spare}% media_errors ${media}"
    else
        attr() { echo "$J" | jq -r --argjson id "$1" '[.ata_smart_attributes.table[]? | select(.id==$id) | .raw.value][0] // 0'; }
        realloc=$(attr 5); reported=$(attr 187); pending=$(attr 197); uncorr=$(attr 198); crc=$(attr 199)
        [ -n "$t" ] && [ "$t" -gt "$TEMP_HDD_MAX" ] && warn "$name ($dev): ${t}C"
        delta "$serial" realloc  "$realloc"  alert "$name ($dev) reallocated sectors"
        delta "$serial" reported "$reported" alert "$name ($dev) reported uncorrectable"
        delta "$serial" pending  "$pending"  alert "$name ($dev) pending sectors"
        delta "$serial" uncorr   "$uncorr"   alert "$name ($dev) offline uncorrectable"
        delta "$serial" crc      "$crc"      warn  "$name ($dev) CRC errors (cable/backplane, not the disk)"
        line "  $name ($dev) ${t}C ${hours}h  realloc $realloc pending $pending uncorr $uncorr crc $crc"
    fi
done <<< "$DISKS"

# ----------------------------- Space -----------------------------------------
line ""
line "== Space"
used=$(pct "$ARR_SIZE" "$ARR_FREE")
line "  array  ${used}% used, $((ARR_FREE / 1024 / 1024 / 1024)) TiB free"
if   [ "$used" -ge "$ARRAY_ALERT_PCT" ]; then alert "Array ${used}% full"
elif [ "$used" -ge "$ARRAY_WARN_PCT" ];  then warn  "Array ${used}% full"; fi

while IFS='|' read -r name dev type st err tmp size free idsb; do
    [ "$type" = "Cache" ] && [ -n "$dev" ] || continue
    used=$(pct "${size:-0}" "${free:-0}")
    line "  $name  ${used}% used"
    if   [ "$used" -ge "$CACHE_ALERT_PCT" ]; then alert "$name ${used}% full"
    elif [ "$used" -ge "$CACHE_WARN_PCT" ];  then warn  "$name ${used}% full"; fi
done <<< "$DISKS"

if used=$(df -P /var/lib/docker 2>/dev/null | awk 'NR==2 {sub("%","",$5); print $5}') && [ -n "$used" ]; then
    line "  docker.img  ${used}% used"
    if   [ "$used" -ge "$DOCKER_ALERT_PCT" ]; then alert "docker.img ${used}% full"
    elif [ "$used" -ge "$DOCKER_WARN_PCT" ];  then warn  "docker.img ${used}% full"; fi
fi

# ----------------------------- Parity ----------------------------------------
line ""
line "== Parity"
if [ "${MDRESYNC:-0}" -gt 0 ]; then
    line "  check in progress"
elif LAST=$(tail -1 /boot/config/parity-checks.log 2>/dev/null) && [ -n "$LAST" ]; then
    # date|duration s|speed B/s|exit status|errors|action|size
    IFS='|' read -r pdate pdur _ pstatus perrs _ _ <<< "$LAST"
    # "2026 Aug 11 20:48:57" -> GNU date wants the year after the day
    pepoch=$(date -d "$(echo "$pdate" | awk '{print $2" "$3" "$1" "$4}')" +%s 2>/dev/null || echo 0)
    age=$(days_since "$pepoch")
    line "  last check $(date -d "@$pepoch" +%F) (${age}d ago), $((pdur / 3600))h, exit $pstatus, $perrs errors"
    [ "$perrs" -gt 0 ] && alert "Last parity check found $perrs errors"
    [ "$pstatus" != "0" ] && warn "Last parity check did not finish (exit $pstatus)"
    [ "$age" -gt "$PARITY_MAX_AGE_DAYS" ] && warn "No parity check for ${age} days"
else
    warn "No parity check history"
fi

# ----------------------------- Backups ---------------------------------------
line ""
line "== Backups"
NEWEST=$(ls -1dt "$APPDATA_BACKUP_DIR"/ab_* 2>/dev/null | head -1)
if [ -z "$NEWEST" ]; then
    alert "No Appdata Backup archives in $APPDATA_BACKUP_DIR"
else
    age=$(days_since "$(stat -c %Y "$NEWEST")")
    count=$(ls -1 "$NEWEST"/*.tar* 2>/dev/null | wc -l)
    line "  appdata  $(basename "$NEWEST") (${age}d ago), $count container archives"
    [ "$age" -gt "$APPDATA_MAX_AGE_DAYS" ] && warn "Newest appdata backup is ${age} days old"
    ls "$NEWEST"/*flash-backup*.zip >/dev/null 2>&1 || warn "Newest appdata backup has no flash backup"
    grep -q 'DONE!' "$NEWEST/backup.log" 2>/dev/null || warn "Newest appdata backup log doesn't show it finished"
fi

if [ "$QNAP_MAX_AGE_DAYS" -gt 0 ]; then
    END=$(grep 'Run end (status=' "$QNAP_LOG" 2>/dev/null | tail -1)
    if [ -z "$END" ]; then
        warn "qnap-backup has never completed a run"
    else
        qdate=$(echo "$END" | sed -n 's/^\[\([^]]*\)\].*/\1/p')
        qstatus=$(echo "$END" | sed -n 's/.*status=\([A-Z]*\).*/\1/p')
        age=$(days_since "$(date -d "$qdate" +%s)")
        line "  qnap     last run $qdate (${age}d ago), $qstatus"
        [ "$qstatus" = "OK" ] || warn "Last qnap-backup run finished with $qstatus - see $QNAP_LOG"
        [ "$age" -gt "$QNAP_MAX_AGE_DAYS" ] && warn "Last qnap-backup run was ${age} days ago"
    fi
fi

# Asks restic, not Backrest's UI state: a plan whose runs "succeed" but never
# land a snapshot in the repo still shows up here. Repo URI, password and env
# come from Backrest's config and reach restic as environment variables passed
# by NAME (docker exec -e VAR), so no secret appears in the process list.
if [ -n "$BACKREST_CONTAINER" ]; then
    if [ ! -r "$BACKREST_CONFIG" ]; then
        alert "Backrest config not found at $BACKREST_CONFIG"
    elif ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$BACKREST_CONTAINER"; then
        alert "Backrest container '$BACKREST_CONTAINER' is not running - no off-site backups"
    else
        while IFS= read -r repo; do
            rid=$(jq -r '.id' <<< "$repo")
            SNAPS=$(
                export RESTIC_REPOSITORY RESTIC_PASSWORD
                RESTIC_REPOSITORY=$(jq -r '.uri' <<< "$repo")
                RESTIC_PASSWORD=$(jq -r '.password' <<< "$repo")
                pass=(-e RESTIC_REPOSITORY -e RESTIC_PASSWORD)
                while IFS= read -r kv; do
                    [ -n "$kv" ] || continue
                    export "${kv?}"; pass+=(-e "${kv%%=*}")
                done < <(jq -r '.env[]?' <<< "$repo")
                timeout 180 docker exec "${pass[@]}" "$BACKREST_CONTAINER" \
                    restic snapshots --json --no-lock 2>/dev/null
            )
            if ! echo "$SNAPS" | jq -e 'type == "array"' >/dev/null 2>&1; then
                alert "Backrest repo '$rid': could not list snapshots (repo unreachable or password wrong)"
                continue
            fi
            # Newest snapshot time per plan tag: "plan time"
            LATEST=$(echo "$SNAPS" | jq -r '
                map(. as $s | ($s.tags // [])[] | select(startswith("plan:")) | {p: .[5:], t: $s.time})
                | group_by(.p)[] | max_by(.t) | "\(.p) \(.t)"')
            for plan in $(jq -r --arg r "$rid" '.plans[]? | select(.repo == $r) | .id' "$BACKREST_CONFIG"); do
                max=$(echo "$BACKREST_PLAN_MAX_AGE" | tr ' ' '\n' | sed -n "s/^$plan=//p")
                max=${max:-$BACKREST_MAX_AGE_HOURS}
                t=$(echo "$LATEST" | awk -v p="$plan" '$1 == p {print $2}')
                if [ -z "$t" ]; then
                    warn "Backrest plan '$plan' has no snapshots in repo '$rid'"
                    continue
                fi
                hrs=$(( (NOW_EPOCH - $(date -d "$t" +%s)) / 3600 ))
                line "  backrest $plan: newest snapshot ${hrs}h ago ($(date -d "$t" '+%F %H:%M'))"
                [ "$hrs" -gt "$max" ] && warn "Backrest plan '$plan': newest snapshot is ${hrs}h old (limit ${max}h)"
            done
        done < <(jq -c '.repos[]?' "$BACKREST_CONFIG")
    fi
fi

# ----------------------------- Containers ------------------------------------
line ""
line "== Containers"
RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null)
EXISTING=$(docker ps -a --format '{{.Names}}' 2>/dev/null)
line "  $(echo "$RUNNING" | grep -c .) running"
# Unraid leaves removed containers in the autostart list, so only containers
# that still exist count.
while read -r c _; do
    [ -n "$c" ] || continue
    echo "$EXISTING" | grep -qx "$c" || continue
    echo "$RUNNING" | grep -qx "$c" || warn "Autostart container '$c' is not running"
done < /var/lib/docker/unraid-autostart
for c in $(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null); do
    warn "Container '$c' is unhealthy"
done

# ----------------------------- Send ------------------------------------------
if [ ${#ALERTS[@]} -gt 0 ]; then
    LEVEL=alert;   SUBJECT="Health: ${#ALERTS[@]} alert(s), ${#WARNS[@]} warning(s)"
elif [ ${#WARNS[@]} -gt 0 ]; then
    LEVEL=warning; SUBJECT="Health: ${#WARNS[@]} warning(s)"
else
    LEVEL=normal;  SUBJECT="Health: OK"
fi

ISSUES=""
for a in "${ALERTS[@]}"; do ISSUES+="ALERT: $a"$'\n'; done
for w in "${WARNS[@]}";  do ISSUES+="WARN: $w"$'\n'; done
FULL="$SUBJECT"$'\n'"${ISSUES:+$ISSUES}"$'\n'"$REPORT"

if $PRINT_ONLY; then
    echo "$FULL"
    exit 0
fi

echo "$FULL" > "$DATA_DIR/last-report.txt"
mv "$NEW_STATE" "$STATE_FILE"

# Pushover shows only subject + description, so the description carries the
# issues; the full report goes in the message. notify splits the message on a
# LITERAL backslash-n, not a newline.
DESC=$(printf '%s' "${ISSUES:-All checks passed.}" | paste -sd ';' | sed 's/;/; /g' | cut -c1-900)
MSG=$(printf '%s' "$FULL" | awk '{printf "%s\\n", $0}')
"$NOTIFY" -e "Health report" -s "$SUBJECT" -d "$DESC" -m "$MSG" -i "$LEVEL"
echo "$FULL"
