#!/bin/bash
# =============================================================================
# discord-status.sh - one live "server status" message in a Discord channel
#
# Edits the SAME message every run (Discord webhooks can edit their own
# messages), so the channel always shows one up-to-date status card instead of
# a growing log: overall 🟢/🟡/🔴, server, storage, containers, backups, Plex
# and internet. If the message is deleted, the next run posts a new one.
#
# Cheap by design, because it runs every 5 minutes:
#   - never wakes sleeping disks (storage comes from Unraid's disks.ini)
#   - writes to flash only when it has to post a new message (message id)
#   - asks the off-site repo for snapshot ages at most every BACKUP_EVERY_MIN
#
# Schedule from the User Scripts plugin: */5 * * * *
# Webhook URL goes in CONF_FILE (never in this repo):
#   DISCORD_STATUS_WEBHOOK="https://discord.com/api/webhooks/..."
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
CONF_FILE="/boot/config/plugins/user.scripts/discord-status.conf"
STATE_DIR="/boot/config/plugins/user.scripts/discord-status"   # message id
CACHE_DIR="/tmp/discord-status"                                 # RAM, per boot

HOST_IP="192.168.1.10"
TAUTULLI_URL="http://$HOST_IP:8181"
TAUTULLI_CONFIG="/mnt/cache/appdata/tautulli/config.ini"
INFLUX_URL="http://$HOST_IP:8086"; INFLUX_DB="unifi"
BACKREST_CONTAINER="backrest"
BACKREST_CONFIG="/mnt/user/appdata/backrest/config/config.json"
BACKUP_EVERY_MIN=30
BACKUP_MAX_AGE_HOURS=170                    # matches health-report.sh
BACKUP_PLAN_MAX_AGE="vaultwarden=26"

CACHE_WARN_PCT=80;  CACHE_ALERT_PCT=90
ARRAY_WARN_PCT=85;  ARRAY_ALERT_PCT=95
CPU_WARN_C=75
LATENCY_WARN_MS=50
# -----------------------------------------------------------------------------

[ -f "$CONF_FILE" ] && . "$CONF_FILE"
[ -n "$DISCORD_STATUS_WEBHOOK" ] || { echo "DISCORD_STATUS_WEBHOOK not set in $CONF_FILE"; exit 1; }
mkdir -p "$STATE_DIR" "$CACHE_DIR"

LEVEL=0                                       # 0 ok, 1 warning, 2 problem
ISSUES=()
flag() { [ "$1" -gt "$LEVEL" ] && LEVEL=$1; ISSUES+=("$2"); }
NOW=$(date +%s)

# ----------------------------- Server ----------------------------------------
read -r load1 _ < /proc/loadavg
cores=$(nproc)
mem_total=$(awk '/^MemTotal/ {print $2}' /proc/meminfo); mem_avail=$(awk '/^MemAvailable/ {print $2}' /proc/meminfo)
mem_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
cpu_c=""
for d in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$d/name" 2>/dev/null)" = coretemp ] && cpu_c=$(( $(cat "$d/temp1_input") / 1000 )) && break
done
[ -n "$cpu_c" ] && [ "$cpu_c" -ge "$CPU_WARN_C" ] && flag 1 "CPU ${cpu_c}°C"
up=$(uptime -p | sed 's/^up //; s/ days\?/d/; s/ hours\?/h/; s/ minutes\?/m/; s/,//g')
SERVER="Up $up · load $load1/$cores · RAM ${mem_pct}%${cpu_c:+ · CPU ${cpu_c}°C}"

# ----------------------------- Storage ---------------------------------------
mdstate=$(mdcmd status 2>/dev/null | sed -n 's/^mdState=//p')
[ "$mdstate" = STARTED ] || flag 2 "Array not started"
read -r arr_size arr_free < <(awk -F= '
    /^\[/ {if (t=="Data") {s+=sz; f+=fr}; t=sz=fr=""} { v=substr($0,index($0,"=")+1); gsub(/"/,"",v) }
    $1=="type"{t=v} $1=="fsSize"{sz=v} $1=="fsFree"{fr=v}
    END {if (t=="Data") {s+=sz; f+=fr}; print s+0, f+0}' /var/local/emhttp/disks.ini)
arr_pct=$(( arr_size > 0 ? (arr_size - arr_free) * 100 / arr_size : 0 ))
cache_pct=$(df --output=pcent /mnt/cache 2>/dev/null | tail -1 | tr -dc '0-9')
if   [ "${cache_pct:-0}" -ge "$CACHE_ALERT_PCT" ]; then flag 2 "Cache ${cache_pct}% full"
elif [ "${cache_pct:-0}" -ge "$CACHE_WARN_PCT" ];  then flag 1 "Cache ${cache_pct}% full"; fi
if   [ "$arr_pct" -ge "$ARRAY_ALERT_PCT" ]; then flag 2 "Array ${arr_pct}% full"
elif [ "$arr_pct" -ge "$ARRAY_WARN_PCT" ];  then flag 1 "Array ${arr_pct}% full"; fi
disk_err=$(awk -F= '$1=="numErrors" {gsub(/"/,"",$2); s+=$2} END {print s+0}' /var/local/emhttp/disks.ini)
[ "$disk_err" -gt 0 ] && flag 2 "$disk_err disk read/write errors"
parity=""
if last=$(tail -1 /boot/config/parity-checks.log 2>/dev/null) && [ -n "$last" ]; then
    pdate=$(echo "$last" | cut -d'|' -f1 | awk '{print $2" "$3" "$1" "$4}')
    parity=" · parity $(( (NOW - $(date -d "$pdate" +%s 2>/dev/null || echo "$NOW")) / 86400 ))d ago"
fi
STORAGE="Array ${arr_pct}% ($((arr_free / 1024 / 1024 / 1024)) TiB free) · cache ${cache_pct}%${parity}"
[ "$disk_err" -gt 0 ] && STORAGE+=" · **$disk_err disk errors**"

# ----------------------------- Containers ------------------------------------
running=$(docker ps --format '{{.Names}}' 2>/dev/null)
existing=$(docker ps -a --format '{{.Names}}' 2>/dev/null)
down=()
while read -r c _; do
    [ -n "$c" ] && echo "$existing" | grep -qx "$c" && ! echo "$running" | grep -qx "$c" && down+=("$c")
done < /var/lib/docker/unraid-autostart
unhealthy=$(docker ps --filter health=unhealthy --format '{{.Names}}' | paste -sd, -)
CONTAINERS="$(echo "$running" | grep -c .) running"
[ ${#down[@]} -gt 0 ] && { CONTAINERS+=" · **down: $(IFS=,; echo "${down[*]}")**"; flag 2 "Down: $(IFS=,; echo "${down[*]}")"; }
[ -n "$unhealthy" ] && { CONTAINERS+=" · unhealthy: $unhealthy"; flag 1 "Unhealthy: $unhealthy"; }

# ----------------------------- Backups (cached) ------------------------------
BCACHE="$CACHE_DIR/backups.txt"
if [ ! -s "$BCACHE" ] || [ $(( NOW - $(stat -c %Y "$BCACHE") )) -ge $(( BACKUP_EVERY_MIN * 60 )) ]; then
    repo=$(jq -c '.repos[0]' "$BACKREST_CONFIG" 2>/dev/null)
    snaps=$(
        export RESTIC_REPOSITORY RESTIC_PASSWORD
        RESTIC_REPOSITORY=$(jq -r '.uri' <<< "$repo"); RESTIC_PASSWORD=$(jq -r '.password' <<< "$repo")
        pass=(-e RESTIC_REPOSITORY -e RESTIC_PASSWORD)
        while IFS= read -r kv; do [ -n "$kv" ] && export "${kv?}" && pass+=(-e "${kv%%=*}"); done < <(jq -r '.env[]?' <<< "$repo")
        timeout 120 docker exec "${pass[@]}" "$BACKREST_CONTAINER" restic snapshots --json --no-lock 2>/dev/null)
    if echo "$snaps" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "$snaps" | jq -r 'map(. as $s | ($s.tags // [])[] | select(startswith("plan:")) | {p: .[5:], t: $s.time})
                              | group_by(.p)[] | max_by(.t) | "\(.p) \(.t)"' > "$BCACHE.new" && mv "$BCACHE.new" "$BCACHE"
    else
        echo "ERROR repo-unreachable" > "$BCACHE"
    fi
fi
BACKUPS=""
while read -r plan t; do
    [ -n "$plan" ] || continue
    if [ "$plan" = ERROR ]; then BACKUPS="**off-site repo unreachable**"; flag 2 "Backup repo unreachable"; break; fi
    hrs=$(( (NOW - $(date -d "$t" +%s)) / 3600 ))
    max=$(echo "$BACKUP_PLAN_MAX_AGE" | tr ' ' '\n' | sed -n "s/^$plan=//p"); max=${max:-$BACKUP_MAX_AGE_HOURS}
    age=$([ "$hrs" -ge 48 ] && echo "$((hrs / 24))d" || echo "${hrs}h")
    if [ "$hrs" -gt "$max" ]; then BACKUPS+="**$plan $age** · "; flag 2 "Backup $plan is $age old"; else BACKUPS+="$plan $age · "; fi
done < "$BCACHE"
BACKUPS=${BACKUPS% · }

# ----------------------------- Plex ------------------------------------------
tk=$(grep -m1 '^api_key' "$TAUTULLI_CONFIG" 2>/dev/null | sed 's/.*= *//')
act=$(curl -s -m 10 "$TAUTULLI_URL/api/v2?apikey=$tk&cmd=get_activity" | jq -c '.response.data // empty' 2>/dev/null)
if [ -n "$act" ]; then
    PLEX=$(echo "$act" | jq -r '"\(.stream_count) streaming" + (if (.stream_count_transcode|tonumber) > 0 then " · \(.stream_count_transcode) transcoding" else "" end) + (if (.wan_bandwidth|tonumber) > 0 then " · \((.wan_bandwidth|tonumber)/1000|floor) Mbps remote" else "" end)')
else
    PLEX="**Tautulli not responding**"; flag 1 "Tautulli not responding"
fi

# ----------------------------- Internet --------------------------------------
wan=$(curl -s -m 10 "$INFLUX_URL/query" --data-urlencode "db=$INFLUX_DB" \
      --data-urlencode "q=SELECT mean(\"latency_average\"), mean(\"availability\") FROM \"usg_wan_monitors\" WHERE \"type\" = 'icmp' AND time > now() - 10m" \
      | jq -r '.results[0].series[0].values[0] | "\(.[1] // "") \(.[2] // "")"' 2>/dev/null)
read -r lat avail <<< "$wan"
if [ -n "$lat" ]; then
    lat=$(printf '%.0f' "$lat"); avail=$(printf '%.0f' "$avail")
    INTERNET="${lat} ms · ${avail}% available"
    [ "$lat" -gt "$LATENCY_WARN_MS" ] && flag 1 "Internet latency ${lat} ms"
    [ "$avail" -lt 98 ] && flag 1 "Internet ${avail}% available"
else
    INTERNET="no data"; flag 1 "No internet monitor data"
fi

# ----------------------------- Post / edit -----------------------------------
case $LEVEL in
    0) head="🟢 All systems normal"; color=3066993 ;;
    1) head="🟡 Needs a look";        color=15105570 ;;
    *) head="🔴 Problem";             color=15158332 ;;
esac
desc=""
for i in "${ISSUES[@]}"; do desc+="• $i"$'\n'; done

payload=$(jq -n --arg t "$head" --arg d "$desc" --argjson c "$color" --arg ts "$(date -u +%FT%TZ)" --arg host "$(hostname)" \
    --arg s "$SERVER" --arg st "$STORAGE" --arg co "$CONTAINERS" --arg b "${BACKUPS:-no snapshots yet}" --arg p "$PLEX" --arg i "$INTERNET" \
    '{username: "Status", embeds: [{title: $t, description: $d, color: $c, timestamp: $ts,
       footer: {text: ($host + " · refreshes every 5 min")},
       fields: [ {name: "🖥️ Server", value: $s}, {name: "💾 Storage", value: $st}, {name: "📦 Containers", value: $co},
                 {name: "☁️ Off-site backups", value: $b}, {name: "🎬 Plex", value: $p, inline: true},
                 {name: "🌐 Internet", value: $i, inline: true} ]}]}')

MSG_FILE="$STATE_DIR/message_id"
mid=$(cat "$MSG_FILE" 2>/dev/null)
code=000
if [ -n "$mid" ]; then
    code=$(echo "$payload" | jq 'del(.username)' | curl -s -m 20 -o /dev/null -w '%{http_code}' -X PATCH \
           -H 'Content-Type: application/json' -d @- "$DISCORD_STATUS_WEBHOOK/messages/$mid")
fi
if [ "$code" != 200 ]; then                     # first run, or the message was deleted
    mid=$(echo "$payload" | curl -s -m 20 -H 'Content-Type: application/json' -d @- "$DISCORD_STATUS_WEBHOOK?wait=true" | jq -r '.id // empty')
    [ -n "$mid" ] && echo "$mid" > "$MSG_FILE" || { echo "posting status failed"; exit 1; }
fi
echo "$head (${#ISSUES[@]} issues)"
