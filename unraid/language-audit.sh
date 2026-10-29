#!/bin/bash
# =============================================================================
# language-audit.sh - weekly list of files nobody can listen to
#
# The Tdarr plugin (tdarr/Tdarr_Plugin_hl01_...) keeps English + the original
# language and drops the rest, but it can't add a track that isn't there. A
# file whose ONLY audio is some third language (a German dub of a Danish film,
# an Italian-only release) passes every other check. This finds those, so they
# can be re-grabbed.
#
# A file is flagged when none of its audio tracks is English, the title's
# original language (from Radarr/Sonarr) or untagged ("und" - the plugin tags
# a lone untagged track as the original language, so it counts as fine).
#
# Reads only: track languages come from Tdarr's ffprobe data in its database,
# so no media file is opened and no drive spins up. Files Tdarr hasn't scanned
# yet are picked up the week after it does.
#
# Posted as one Discord embed; titles flagged for the first time are marked 🆕.
# Flagged paths are kept in STATE_FILE on flash (one write a week).
#
# Schedule from the User Scripts plugin, after the weekly summary: 20 9 * * 1
# Webhook URL goes in CONF_FILE (never in this repo):
#   DISCORD_AUDIT_WEBHOOK="https://discord.com/api/webhooks/..."
#
#   bash language-audit.sh --print    # print the payload, post nothing, save nothing
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
CONF_FILE="/boot/config/plugins/user.scripts/language-audit.conf"
STATE_FILE="/boot/config/plugins/user.scripts/language-audit/last.json"
RADARR_URL="http://localhost:7878"; RADARR_CONFIG="/mnt/user/appdata/radarr/config.xml"
SONARR_URL="http://localhost:8989"; SONARR_CONFIG="/mnt/user/appdata/sonarr/config.xml"
TDARR_DB="/mnt/user/appdata/tdarr/server/Tdarr/DB2/SQL/database.db"

# Same table as the Tdarr plugin: Radarr/Sonarr language name -> codes a muxer
# may have written. Keep the two in sync.
LANG_CODES='{
  "English": ["eng","en"], "French": ["fre","fra","fr"], "German": ["ger","deu","de"],
  "Italian": ["ita","it"], "Spanish": ["spa","es"], "Spanish (Latino)": ["spa","es"],
  "Portuguese": ["por","pt"], "Portuguese (Brazil)": ["por","pt"], "Japanese": ["jpn","ja"],
  "Korean": ["kor","ko"], "Chinese": ["chi","zho","zh","cmn","yue"], "Cantonese": ["chi","zho","zh","yue"],
  "Mandarin": ["chi","zho","zh","cmn"], "Swedish": ["swe","sv"], "Norwegian": ["nor","nob","nno","no","nb","nn"],
  "Danish": ["dan","da"], "Finnish": ["fin","fi"], "Icelandic": ["ice","isl","is"], "Dutch": ["dut","nld","nl"],
  "Flemish": ["dut","nld","nl"], "Russian": ["rus","ru"], "Ukrainian": ["ukr","uk"], "Polish": ["pol","pl"],
  "Czech": ["cze","ces","cs"], "Hungarian": ["hun","hu"], "Greek": ["gre","ell","el"], "Turkish": ["tur","tr"],
  "Arabic": ["ara","ar"], "Hebrew": ["heb","he"], "Persian": ["per","fas","fa"], "Hindi": ["hin","hi"],
  "Tamil": ["tam","ta"], "Telugu": ["tel","te"], "Thai": ["tha","th"], "Vietnamese": ["vie","vi"],
  "Indonesian": ["ind","id"], "Romanian": ["rum","ron","ro"]
}'
UNDEFINED='["und","","mul","zxx"]'
# -----------------------------------------------------------------------------

[ -f "$CONF_FILE" ] && . "$CONF_FILE"
PRINT_ONLY=false; [ "$1" = "--print" ] && PRINT_ONLY=true
$PRINT_ONLY || [ -n "$DISCORD_AUDIT_WEBHOOK" ] || { echo "DISCORD_AUDIT_WEBHOOK not set in $CONF_FILE"; exit 1; }

key() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$1" 2>/dev/null; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# Title folder -> {title, orig, kind}. Library files sit at
# /data/media/<lib>/shd/<Title>/..., so the first five path parts are the key.
curl -sf -m 120 -H "X-Api-Key: $(key "$RADARR_CONFIG")" "$RADARR_URL/api/v3/movie" \
    | jq '[.[] | {(.path): {title: "\(.title) (\(.year))", orig: .originalLanguage.name, kind: "movie"}}] | add // {}' > "$WORK/movies.json" \
    || { echo "Radarr API call failed"; exit 1; }
curl -sf -m 120 -H "X-Api-Key: $(key "$SONARR_CONFIG")" "$SONARR_URL/api/v3/series" \
    | jq '[.[] | {(.path): {title: .title, orig: .originalLanguage.name, kind: "show"}}] | add // {}' > "$WORK/shows.json" \
    || { echo "Sonarr API call failed"; exit 1; }

# One line per file: path <TAB> comma-separated audio languages ("NONE" = no audio)
sqlite3 -separator $'\t' "file:$TDARR_DB?mode=ro" "
    select id, coalesce((select group_concat(coalesce(lower(json_extract(s.value, '\$.tags.language')), ''), ',')
                         from json_each(json_extract(json_data, '\$.ffProbeData.streams')) s
                         where json_extract(s.value, '\$.codec_type') = 'audio'), 'NONE')
    from filejsondb" > "$WORK/audio.tsv" || { echo "reading the Tdarr database failed"; exit 1; }

# Flagged titles: [{title, kind, orig, langs, files, paths}]
jq -Rn --slurpfile m "$WORK/movies.json" --slurpfile s "$WORK/shows.json" \
       --argjson L "$LANG_CODES" --argjson U "$UNDEFINED" '
    ($m[0] + $s[0]) as $arr |
    [ inputs | split("\t")   # "" | split(",") is [] in jq - a lone untagged track must stay [""]
      | {path: .[0], a: (if .[1] == "NONE" then [] elif .[1] == "" then [""] else .[1] | split(",") end)}
      | . + {t: $arr[.path | split("/")[0:6] | join("/")]} | select(.t != null)
      | ($L.English + $U + ($L[.t.orig] // [])) as $ok
      | select(.a | any(. as $x | $ok | index($x)) | not) ]
    | group_by(.t.title)
    | map({title: .[0].t.title, kind: .[0].t.kind, orig: (.[0].t.orig // "unknown"),
           langs: ([.[].a[]] | unique | map(if . == "" then "und" else . end)),
           files: length, paths: [.[].path]})
    | sort_by(.kind, .title)' < "$WORK/audio.tsv" > "$WORK/flagged.json"

prev=$(jq -c '.paths // []' "$STATE_FILE" 2>/dev/null || echo '[]')
COUNT=$(jq 'length' "$WORK/flagged.json")
SCANNED=$(wc -l < "$WORK/audio.tsv")

# "🆕 Land of Mine (2015) - ger (original: Danish)"; shows add the episode count.
LIST=$(jq -r --argjson prev "$prev" '
    .[] | (if (.paths - $prev | length) > 0 then "🆕 " else "" end)
          + "**\(.title)**" + (if .kind == "show" then " · \(.files) ep" else "" end)
          + " - " + (if .langs == [] then "no audio" else (.langs | join(", ")) end)
          + " (original: \(.orig))"' "$WORK/flagged.json")
# Embed descriptions stop at 4096 characters.
if [ ${#LIST} -gt 3800 ]; then
    LIST="$(printf '%s' "$LIST" | head -c 3700 | sed '$d')"$'\n'"…and more - run with --print for the full list"
fi
[ "$COUNT" -eq 0 ] && LIST="Every file has English, original-language or untagged audio. ✅"

payload=$(jq -n --arg d "$LIST" --argjson n "$COUNT" --arg scanned "$SCANNED" --arg host "$(hostname)" --arg ts "$(date -u +%FT%TZ)" \
    '{username: "Language audit", embeds: [{
        title: ("🗣️ Audio language audit · " + (if $n == 1 then "1 title" else "\($n) titles" end) + " to re-grab"),
        description: $d, color: (if $n == 0 then 3066993 else 15105570 end), timestamp: $ts,
        footer: {text: "\($host) · \($scanned) files checked · only audio is not English/original"}}]}')

if $PRINT_ONLY; then echo "$payload" | jq .; exit 0; fi

code=$(echo "$payload" | curl -s -m 20 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d @- "$DISCORD_AUDIT_WEBHOOK")
[[ "$code" == 2* ]] || { echo "posting audit failed (HTTP $code)"; exit 1; }
mkdir -p "$(dirname "$STATE_FILE")"
jq '{paths: [.[].paths[]], at: now | floor}' "$WORK/flagged.json" > "$STATE_FILE"
echo "language audit posted ($COUNT flagged)"
