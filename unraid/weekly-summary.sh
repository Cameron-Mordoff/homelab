#!/bin/bash
# =============================================================================
# weekly-summary.sh - "the week on the server" card for a Discord channel
#
# Companion to health-report.sh: that one says whether anything is wrong, this
# one says what the server was used for. Posted as a single Discord embed:
#   - Plex: plays and hours watched, top movies / shows / people
#   - what was added (movies, episodes) and what was requested
#   - storage used and the change since last week
#   - off-site backups: snapshot count and repo size, change since last week
#
# Last week's numbers are kept in STATE_FILE on flash (one write a week).
#
# Schedule from the User Scripts plugin, after the health report: 10 9 * * 1
# Webhook URL goes in CONF_FILE (never in this repo):
#   DISCORD_WEEKLY_WEBHOOK="https://discord.com/api/webhooks/..."
#
#   bash weekly-summary.sh --print    # print the payload, post nothing, save nothing
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
CONF_FILE="/boot/config/plugins/user.scripts/weekly-summary.conf"
STATE_FILE="/boot/config/plugins/user.scripts/weekly-summary/last.json"
HOST_IP="192.168.1.10"
TAUTULLI_URL="http://$HOST_IP:8181"
TAUTULLI_CONFIG="/mnt/cache/appdata/tautulli/config.ini"
PLEX_URL="http://$HOST_IP:32400"                 # local requests need no token
MOVIE_SECTION=4; TV_SECTION=5
OVERSEERR_URL="http://$HOST_IP:5055"
OVERSEERR_SETTINGS="/mnt/user/appdata/binhex-overseerr/overseerr/settings.json"
BACKREST_CONTAINER="backrest"
BACKREST_CONFIG="/mnt/user/appdata/backrest/config/config.json"
DAYS=7
# -----------------------------------------------------------------------------

[ -f "$CONF_FILE" ] && . "$CONF_FILE"
PRINT_ONLY=false; [ "$1" = "--print" ] && PRINT_ONLY=true
$PRINT_ONLY || [ -n "$DISCORD_WEEKLY_WEBHOOK" ] || { echo "DISCORD_WEEKLY_WEBHOOK not set in $CONF_FILE"; exit 1; }

NOW=$(date +%s); SINCE=$(( NOW - DAYS * 86400 ))
gib() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'; }
tib() { awk -v b="$1" 'BEGIN { printf "%.2f", b / 1099511627776 }'; }
delta() {   # now prev unit-fn -> " (+1.2 GiB)" / ""
    [ -n "$2" ] || return
    local d=$(( $1 - $2 )) sign=+; [ $d -lt 0 ] && { sign=-; d=$(( -d )); }
    echo " (${sign}$($3 $d) $([ "$3" = tib ] && echo TiB || echo GiB))"
}
prev=$(cat "$STATE_FILE" 2>/dev/null || echo '{}')

# ----------------------------- Plex (Tautulli) -------------------------------
tk=$(grep -m1 '^api_key' "$TAUTULLI_CONFIG" 2>/dev/null | sed 's/.*= *//')
T="$TAUTULLI_URL/api/v2?apikey=$tk"
hist=$(curl -s -m 60 "$T&cmd=get_history&after=$(date -d "@$SINCE" +%F)&length=10000")
PLAYS=$(echo "$hist" | jq -r '.response.data | "\(.recordsFiltered) plays · \(((([.data[].play_duration // 0] | add) // 0) / 3600 | floor)) h watched"')
stats=$(curl -s -m 60 "$T&cmd=get_home_stats&time_range=$DAYS&stats_type=duration&stats_count=5")
top() {     # stat_id label-field
    echo "$stats" | jq -r --arg id "$1" --arg f "$2" '
        [.response.data[] | select(.stat_id == $id) | .rows[] | "\(.[$f]) · \((.total_duration / 3600 * 10 | floor) / 10)h"]
        | if length == 0 then "-" else to_entries | map("\(.key + 1). \(.value)") | join("\n") end'
}
TOP_MOVIES=$(top top_movies title); TOP_TV=$(top top_tv title); TOP_USERS=$(top top_users friendly_name)

# ----------------------------- Added / requested -----------------------------
added() {   # section type
    curl -s -m 60 -H 'Accept: application/json' \
        "$PLEX_URL/library/sections/$1/all?type=$2&addedAt%3E%3E=$SINCE&X-Plex-Container-Start=0&X-Plex-Container-Size=0" \
        | jq -r '.MediaContainer.totalSize // .MediaContainer.size // 0'
}
plural() { [ "$1" = 1 ] && echo "1 $2" || echo "$1 ${2}s"; }
ADDED="$(plural "$(added "$MOVIE_SECTION" 1)" movie) · $(plural "$(added "$TV_SECTION" 4)" episode)"
ok=$(jq -r '.main.apiKey' "$OVERSEERR_SETTINGS" 2>/dev/null)
REQUESTS=$(curl -s -m 30 -H "X-Api-Key: $ok" "$OVERSEERR_URL/api/v1/request?take=100&skip=0&filter=all&sort=added" \
    | jq -r --arg d "$(date -u -d "@$SINCE" +%FT%TZ)" \
        '[.results[] | select(.createdAt > $d)] | "\(length) requested · \([.[] | select(.media.status == 5)] | length) now available"')

# ----------------------------- Storage ---------------------------------------
read -r arr_size arr_free < <(awk -F= '
    /^\[/ {if (t=="Data") {s+=sz; f+=fr}; t=sz=fr=""} { v=substr($0,index($0,"=")+1); gsub(/"/,"",v) }
    $1=="type"{t=v} $1=="fsSize"{sz=v} $1=="fsFree"{fr=v}
    END {if (t=="Data") {s+=sz; f+=fr}; print s+0, f+0}' /var/local/emhttp/disks.ini)
arr_used=$(( (arr_size - arr_free) * 1024 ))                    # disks.ini is in KiB
cache_used=$(( $(df -B1 --output=used /mnt/cache | tail -1) ))
STORAGE="Array $(tib $arr_used) of $(tib $(( arr_size * 1024 ))) TiB used$(delta $arr_used "$(echo "$prev" | jq -r '.arr_used // empty')" tib)"
STORAGE+=$'\n'"Cache $(gib $cache_used) GiB used$(delta $cache_used "$(echo "$prev" | jq -r '.cache_used // empty')" gib)"

# ----------------------------- Backups ---------------------------------------
repo=$(jq -c '.repos[0]' "$BACKREST_CONFIG" 2>/dev/null)
restic_run() {
    (   export RESTIC_REPOSITORY RESTIC_PASSWORD
        RESTIC_REPOSITORY=$(jq -r '.uri' <<< "$repo"); RESTIC_PASSWORD=$(jq -r '.password' <<< "$repo")
        pass=(-e RESTIC_REPOSITORY -e RESTIC_PASSWORD)
        while IFS= read -r kv; do [ -n "$kv" ] && export "${kv?}" && pass+=(-e "${kv%%=*}"); done < <(jq -r '.env[]?' <<< "$repo")
        timeout 300 docker exec "${pass[@]}" "$BACKREST_CONTAINER" restic "$@" --json --no-lock 2>/dev/null )
}
snaps=$(restic_run snapshots | jq 'length' 2>/dev/null)
repo_size=$(restic_run stats --mode raw-data | jq -r '.total_size // empty' 2>/dev/null)
if [ -n "$snaps" ] && [ -n "$repo_size" ]; then
    BACKUPS="$snaps snapshots · $(gib "$repo_size") GiB in B2$(delta "$repo_size" "$(echo "$prev" | jq -r '.repo_size // empty')" gib)"
else
    BACKUPS="**could not read the off-site repo**"; repo_size=""
fi

# ----------------------------- Post ------------------------------------------
range="$(date -d "@$SINCE" '+%b %-d') – $(date '+%b %-d')"
payload=$(jq -n --arg r "$range" --arg host "$(hostname)" --arg ts "$(date -u +%FT%TZ)" \
    --arg plays "$PLAYS" --arg tm "$TOP_MOVIES" --arg tt "$TOP_TV" --arg tu "$TOP_USERS" \
    --arg added "$ADDED" --arg req "$REQUESTS" --arg st "$STORAGE" --arg b "$BACKUPS" \
    '{username: "Weekly summary", embeds: [{title: ("📅 The week on Plex · " + $r), color: 15048717, timestamp: $ts,
       description: ("**" + $plays + "**"), footer: {text: $host},
       fields: [ {name: "🎬 Top movies", value: $tm, inline: true}, {name: "📺 Top shows", value: $tt, inline: true},
                 {name: "👥 Most watching", value: $tu, inline: true},
                 {name: "➕ Added", value: $added, inline: true}, {name: "🙋 Requests", value: $req, inline: true},
                 {name: "💾 Storage", value: $st}, {name: "☁️ Off-site backups", value: $b} ]}]}')

if $PRINT_ONLY; then echo "$payload" | jq .; exit 0; fi

code=$(echo "$payload" | curl -s -m 20 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d @- "$DISCORD_WEEKLY_WEBHOOK")
[[ "$code" == 2* ]] || { echo "posting summary failed (HTTP $code)"; exit 1; }
mkdir -p "$(dirname "$STATE_FILE")"
jq -n --argjson a "$arr_used" --argjson c "$cache_used" --arg r "$repo_size" --argjson t "$NOW" \
    '{arr_used: $a, cache_used: $c, repo_size: ($r | tonumber? // null), at: $t}' > "$STATE_FILE"
echo "weekly summary posted"
