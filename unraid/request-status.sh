#!/bin/bash
# =============================================================================
# request-status.sh - DM each requester a live status card for their request
#
# For every Seerr request that's still being processed, the "Andromeda Requests"
# bot (Doplarr's bot) DMs the requester ONE message and keeps editing it:
#
#   VisionQuest (2026) - Season 1        ▰▰▰▱▱▱▱▱▱▱ 3/8 on Plex
#   ✅ On Plex      E01-E03
#   ⬇️ Downloading  E04 82% · E05 40%    done in 12 minutes
#   📅 Not out yet  next E07 Nov 4
#
# Edits don't notify, so the requester gets exactly two pings: the first card,
# and a short "it's ready" message when everything that has aired is on Plex
# (again for each later episode of an airing show). If someone has DMs from
# server members turned off, the card goes to FALLBACK_CHANNEL_ID with a mention.
#
# Data: Seerr (who asked for what + their Discord ID, set under the user's
# Settings > Notifications > Discord) and the Sonarr/Radarr queues, which already
# carry SABnzbd/Deluge progress - so no download-client credentials needed here.
#
# A download in a problem state (failed, import blocked, client warning) or an
# aired episode with no release after STALL_HOURS is posted once to
# WARN_CHANNEL_ID, so it can be fixed before the requester has to ask.
#
# Schedule from the User Scripts plugin: */10 * * * *
# Secrets go in CONF_FILE (never in this repo):
#   DISCORD_BOT_TOKEN="..."            # same token as the Doplarr container
#   WARN_CHANNEL_ID="..."              # #warnings
#   FALLBACK_CHANNEL_ID="..."          # #requests
#   SEERR_PUBLIC_URL="https://..."     # optional: card title links there + "browse more" line
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
CONF_FILE="/boot/config/plugins/user.scripts/request-status.conf"
STATE_DIR="/mnt/user/appdata/request-status"   # one JSON per tracked request (rewritten often - not flash)

SEERR_URL="http://localhost:5055"
SEERR_SETTINGS="/mnt/user/appdata/seerr/settings.json"
RADARR_URL="http://localhost:7878"
SONARR_URL="http://localhost:8989"
RADARR_CONFIG="/mnt/user/appdata/radarr/config.xml"
SONARR_CONFIG="/mnt/user/appdata/sonarr/config.xml"

SKIP_USERS="1"              # Seerr user ids that never get DMs (1 = admin)
STALL_HOURS=24              # aired + requested this long with no release -> warn
DRY_RUN=false               # true = print the cards, send nothing, save nothing

DISCORD_API="https://discord.com/api/v10"
UA="User-Agent: DiscordBot (https://github.com/Cameron-Mordoff/homelab, 1.0)"   # Discord 403s without it
HC_KEY_FILE="/boot/config/plugins/user.scripts/healthchecks.key"   # project ping key
HC_SLUG="request-status"
# -----------------------------------------------------------------------------

set -uo pipefail

log() { echo "[$(date '+%F %T')] $*"; }
hc()  { [[ -r "$HC_KEY_FILE" ]] || return 0
        curl -fsS -m 10 --retry 3 -o /dev/null "https://hc-ping.com/$(<"$HC_KEY_FILE")/$HC_SLUG$1" || true; }
die() { log "FATAL: $*"; hc /fail; exit 1; }
key() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$1" 2>/dev/null; }

seerr() { curl -sf -m 30 -H "X-Api-Key: $SEERR_KEY" "$SEERR_URL/api/v1/$1"; }
arr()   { curl -sf -m 60 -H "X-Api-Key: $2" "$1/api/v3/$3"; }

# discord METHOD PATH [JSON] -> prints the HTTP code, body in $WORK/resp.
# Retries once on a rate limit.
discord() {
    local code try
    for try in 1 2; do
        code=$(curl -s -m 20 -o "$WORK/resp" -w '%{http_code}' -X "$1" -H "$UA" \
                    -H "Authorization: Bot $DISCORD_BOT_TOKEN" -H 'Content-Type: application/json' \
                    ${3:+-d "$3"} "$DISCORD_API$2")
        [[ "$code" == 429 ]] || break
        sleep "$(jq -r '.retry_after // 2 | ceil' "$WORK/resp" 2>/dev/null || echo 2)"
    done
    echo "$code"
}

# say CHANNEL JSON -> new message id (empty on failure)
say() { [[ "$(discord POST "/channels/$1/messages" "$2")" == 200 ]] && jq -r '.id' "$WORK/resp"; }

[[ -f "$CONF_FILE" ]] && . "$CONF_FILE"
[[ -n "${DISCORD_BOT_TOKEN:-}" ]] || die "DISCORD_BOT_TOKEN not set in $CONF_FILE"
command -v jq >/dev/null || die "jq not found"
SEERR_KEY=$(jq -r '.main.apiKey' "$SEERR_SETTINGS" 2>/dev/null)
SKEY=$(key "$SONARR_CONFIG"); RKEY=$(key "$RADARR_CONFIG")
[[ -n "$SEERR_KEY" && -n "$SKEY" && -n "$RKEY" ]] || die "missing Seerr/Sonarr/Radarr API key"

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/.lock"; flock -n 9 || { log "previous run still going"; exit 0; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
NOW=$(date +%s)

# ---------------------------------------------------------------------------
# Turns {items, ...} into the card + flags. Each item is one episode (or the
# movie): {s, e, cat, pct, eta, air, note}, cat = ready | downloading |
# importing | problem | searching | upcoming.
# ---------------------------------------------------------------------------
RENDER='
def pad: tostring | if length < 2 then "0" + . else . end;
def lbl: if .s == null then "" elif $multi then "S\(.s|pad)E\(.e|pad)" else "E\(.e|pad)" end;
def ranges: reduce .[] as $i ([];
        if length > 0 and .[-1].b.s == $i.s and .[-1].b.e + 1 == $i.e then .[-1].b = $i else . + [{a: $i, b: $i}] end)
    | map(if .a == .b then (.a|lbl) else "\(.a|lbl)–\(.b|lbl)" end)
    | if length > 12 then .[:12] + ["…"] else . end | join(", ");
def ts($t; $f): "<t:\($t):\($f)>";          # Discord renders it in the viewer timezone
def cat($c): [.[] | select(.cat == $c)];

(.items | sort_by(.s, .e)) as $it
| ($it | cat("ready")) as $ready | ($it | cat("downloading")) as $dl | ($it | cat("importing")) as $imp
| ($it | cat("problem")) as $prob | ($it | cat("searching")) as $srch | ($it | cat("upcoming")) as $up
| [$srch[] | select(($now - ([$m.created, (.air // 0)] | max)) > $stall * 3600)] as $stalled
| ($dl + $imp + $prob + $srch | length == 0) and ($ready | length > 0) as $done
| ($dl | map(.eta // empty) | max) as $eta
| ($up | map(.air // empty) | min) as $next
| ($m.type == "movie") as $movie
| ($m.title + (if $m.year then " (\($m.year))" else "" end)
   + (if $movie then "" elif $multi then " — Seasons \($m.seasons | map(tostring) | join(", "))"
      else " — Season \($m.seasons[0])" end)) as $title
| {
    done: $done,
    ready: [$ready[] | lbl],
    warn: ([ (if ($prob | length) > 0 then "problem with " + ($prob | map((lbl | if . == "" then "the download" else . end)
                + (if .note then " (\(.note))" else "" end)) | join(", ")) else empty end),
            (if ($stalled | length) > 0 then "no release found for " + (if $movie then "the movie" else ($stalled | ranges) end)
                + " after \($stall)h" else empty end) ] | join("; ")),
    title: $title,
    embed: ({
      title: $title,
      color: (if $done then 3066993 elif ($prob + $stalled | length) > 0 then 15105570 else 3447003 end),
      footer: {text: (if $done then "All done — enjoy!" else "Updates every 10 min · request #\($m.rid)" end)}
    }
    + (if $m.url then {url: $m.url} else {} end)
    + (if $m.poster then {thumbnail: {url: $m.poster}} else {} end)
    + if $movie then {
        description: (
          if ($ready | length) > 0 then "✅ **On Plex** — ready to watch."
          elif ($imp | length) > 0 then "⏳ **Finishing up** — downloaded, being added to Plex now."
          elif ($dl | length) > 0 then "⬇️ **Downloading** — \($dl[0].pct // 0)%" + (if $eta then " · done \(ts($eta; "R"))" else "" end)
          elif ($prob | length) > 0 then "⚠️ **Hit a snag** — the download had a problem. Cam has been told and it will be retried."
          elif ($up | length) > 0 then "📅 **Not out yet** — " + (if $next then "expected \(ts($next; "D")); " else "" end)
                                       + "it will download as soon as it is released."
          else "🔎 **Searching** — no release found yet, still looking."
               + (if ($stalled | length) > 0 then " Cam has been told." else "" end) end)
      } else {
        description: (($it | length) as $n | ($ready | length) as $r | ($n | if . > 0 then ($r * 10 / .) | floor else 0 end) as $f
          | ([range($f)] | map("🟩") | join("")) + ([range(10 - $f)] | map("⬜") | join("")) + "  **\($r)/\($n)** on Plex"),
        fields: [
          (if ($ready | length) > 0 then {name: "✅ On Plex (\($ready | length))", value: ($ready | ranges)} else empty end),
          (if ($dl | length) > 0 then {name: "⬇️ Downloading (\($dl | length))",
              value: (($dl | .[:10] | map("\(lbl) \(.pct // 0)%") | join(" · "))
                      + (if ($dl | length) > 10 then " · +\(($dl | length) - 10) more" else "" end)
                      + (if $eta then "\nAll done \(ts($eta; "R"))" else "" end))} else empty end),
          (if ($imp | length) > 0 then {name: "⏳ Finishing up (\($imp | length))",
              value: (($imp | ranges) + "\nDownloaded — being added to Plex now.")} else empty end),
          (if ($prob | length) > 0 then {name: "⚠️ Hit a snag (\($prob | length))",
              value: (($prob | ranges) + "\nThe download had a problem. Cam has been told and it will be retried.")} else empty end),
          (if ($srch | length) > 0 then {name: "🔎 Searching (\($srch | length))",
              value: (($srch | ranges) + "\nNo release found yet — still looking."
                      + (if ($stalled | length) > 0 then " Cam has been told." else "" end))} else empty end),
          (if ($up | length) > 0 then {name: "📅 Not out yet (\($up | length))",
              value: ("Next: " + ($up | min_by(.air // 1e12) | lbl) + (if $next then " \(ts($next; "D"))" else "" end)
                      + (if ($up | length) > 1 then " · \(($up | length) - 1) more after" else "" end)
                      + "\nEach one downloads as soon as it airs.")} else empty end)
        ]
      } end)
  }'

# Sonarr/Radarr queue record -> category
CLASSIFY='def classify: if (.trackedDownloadStatus // "ok") != "ok"
                           or ((.trackedDownloadState // "") | IN("failed", "failedPending", "importBlocked")) then "problem"
                        elif (.trackedDownloadState // "") | IN("importPending", "importing", "imported") then "importing"
                        else "downloading" end;
          def epoch: if . then sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 else null end;
          def pct: if (.size // 0) > 0 then (100 - .sizeleft * 100 / .size) | floor else 0 end;
          def note: ([.statusMessages[]?.messages[]?] + [.errorMessage // empty] | first) // null;'

# ------------------------------- Requests -----------------------------------
PROC=$(seerr "request?filter=processing&take=100&sort=added") || die "Seerr unreachable"
TRACKED=$(cd "$STATE_DIR" && ls -- *.json 2>/dev/null | sed 's/\.json$//')
RIDS=$( { jq -r '.results[].id' <<<"$PROC"; echo "$TRACKED"; } | grep . | sort -nu)

declare -A DID_CACHE
discord_id() {
    [[ -n "${DID_CACHE[$1]+x}" ]] || DID_CACHE[$1]=$(seerr "user/$1" | jq -r '.settings.discordIds[0] // .settings.discordId // empty')
    echo "${DID_CACHE[$1]}"
}

SENT=0; FAILED=0
for rid in $RIDS; do
    SF="$STATE_DIR/$rid.json"
    st=$(cat "$SF" 2>/dev/null || echo '{}')
    if ! r=$(jq -ce --argjson id "$rid" '.results[] | select(.id == $id)' <<<"$PROC"); then
        # Tracked but no longer processing: available now, or declined/deleted.
        r=$(seerr "request/$rid") || { log "#$rid: gone from Seerr - forgetting it"; rm -f "$SF"; continue; }
        [[ "$(jq -r '.media.status' <<<"$r")" == 5 ]] || { log "#$rid: no longer processing - forgetting it"; rm -f "$SF"; continue; }
    fi
    IFS=$'\t' read -r uid type ext tmdb created < <(jq -r '[.requestedBy.id, .type, (.media.externalServiceId // ""),
        .media.tmdbId, (.createdAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)] | @tsv' <<<"$r")
    [[ " $SKIP_USERS " == *" $uid "* ]] && continue
    did=$(discord_id "$uid")
    [[ -n "$did" ]] || { log "#$rid: Seerr user $uid has no Discord ID - skipping"; continue; }
    [[ -n "$ext" ]] || { log "#$rid: not in Sonarr/Radarr yet"; continue; }

    # Title + poster, looked up once per request
    if [[ -z "$(jq -r '.title // empty' <<<"$st")" ]]; then
        info=$(seerr "$type/$tmdb") || { log "#$rid: Seerr $type/$tmdb lookup failed"; FAILED=1; continue; }
        st=$(jq -c --argjson i "$info" '. + {title: ($i.title // $i.name), year: (($i.releaseDate // $i.firstAirDate // "")[:4]),
                 poster: (if $i.posterPath then "https://image.tmdb.org/t/p/w300\($i.posterPath)" else null end)}' <<<"$st")
    fi

    if [[ "$type" == tv ]]; then
        seasons=$(jq -c '[.seasons[].seasonNumber] | sort' <<<"$r")
        eps=$(arr "$SONARR_URL" "$SKEY" "episode?seriesId=$ext") && q=$(arr "$SONARR_URL" "$SKEY" "queue/details?seriesId=$ext") \
            || { log "#$rid: Sonarr lookup failed"; FAILED=1; continue; }
        items=$(jq -c --argjson q "$q" --argjson seasons "$seasons" --argjson now "$NOW" "$CLASSIFY"'
            ($q | map({key: (.episodeId | tostring), value: .}) | from_entries) as $qm
            | [.[] | select(.seasonNumber as $s | $seasons | index($s)) | $qm[.id | tostring] as $qi | (.airDateUtc | epoch) as $air
               | {s: .seasonNumber, e: .episodeNumber, air: $air,
                  cat: (if .hasFile then "ready" elif $qi then ($qi | classify)
                        elif $air == null or $air > $now then "upcoming" else "searching" end),
                  pct: ($qi | if . then pct else null end), eta: ($qi.estimatedCompletionTime // null | epoch),
                  note: ($qi | if . then note else null end)}]' <<<"$eps")
    else
        seasons='[]'
        mv=$(arr "$RADARR_URL" "$RKEY" "movie/$ext") && q=$(arr "$RADARR_URL" "$RKEY" "queue/details?movieId=$ext") \
            || { log "#$rid: Radarr lookup failed"; FAILED=1; continue; }
        items=$(jq -c --argjson q "$q" "$CLASSIFY"'
            ((.digitalRelease // .physicalRelease // .inCinemas // null) | epoch) as $air
            | [{s: null, e: null, air: $air,
                cat: (if .hasFile then "ready" elif ($q | length) > 0 then ($q[0] | classify)
                      elif .isAvailable | not then "upcoming" else "searching" end),
                pct: ($q[0] | if . then pct else null end), eta: ($q[0].estimatedCompletionTime // null | epoch),
                note: ($q[0] | if . then note else null end)}]' <<<"$mv")
    fi

    url=""; [[ -n "${SEERR_PUBLIC_URL:-}" ]] && url="${SEERR_PUBLIC_URL%/}/$type/$tmdb"
    meta=$(jq -c --arg rid "$rid" --arg type "$type" --argjson seasons "$seasons" --argjson created "$created" --arg url "$url" \
        '{rid: $rid, type: $type, seasons: $seasons, created: $created, url: (if $url == "" then null else $url end),
          title: .title, year: (if .year == "" then null else .year end), poster: .poster}' <<<"$st")
    out=$(jq -c -n --argjson items "$items" --argjson m "$meta" --argjson now "$NOW" --argjson stall "$STALL_HOURS" \
        --argjson multi "$(jq 'length > 1' <<<"$seasons")" \
        '{items: $items} | '"$RENDER") || { log "#$rid: render failed"; FAILED=1; continue; }
    title=$(jq -r '.title' <<<"$out")
    hash=$(jq -cS '.embed' <<<"$out" | md5sum | cut -c1-32)

    if [[ "$DRY_RUN" == true ]]; then
        log "#$rid $title -> Discord $did"; jq '.embed' <<<"$out"; continue
    fi

    # ---- the card: post once, then edit in place (re-post if it was deleted)
    # timestamp = when the status last changed (added after hashing, so it doesn't force an edit every run)
    msg=$(jq -c --argjson e "$(jq -c --arg ts "$(date -u +%FT%TZ)" '.embed + {timestamp: $ts}' <<<"$out")" --arg home "${SEERR_PUBLIC_URL:-}" --arg rc "${FALLBACK_CHANNEL_ID:-}" -n \
        '{content: ("Here’s the status of your request — this message keeps itself up to date."
                    + (if $home != "" then "\nWant something else? Use `/request` in "
                         + (if $rc != "" then "<#\($rc)>" else "#requests" end)
                         + " or browse <\($home)> (sign in with Plex)." else "" end)),
          embeds: [$e]}')
    ch=$(jq -r '.channel // empty' <<<"$st"); mid=$(jq -r '.message // empty' <<<"$st")
    if [[ -n "$mid" && "$hash" != "$(jq -r '.hash // empty' <<<"$st")" ]]; then
        code=$(discord PATCH "/channels/$ch/messages/$mid" "$msg")
        [[ "$code" == 404 ]] && mid=""
        [[ "$code" == 200 || "$code" == 404 ]] || { log "#$rid: editing card failed ($code)"; FAILED=1; }
    fi
    if [[ -z "$mid" ]]; then
        ch=""
        [[ "$(discord POST /users/@me/channels "$(jq -nc --arg u "$did" '{recipient_id: $u}')")" == 200 ]] \
            && ch=$(jq -r '.id' "$WORK/resp") && mid=$(say "$ch" "$msg")
        if [[ -z "$mid" && -n "${FALLBACK_CHANNEL_ID:-}" ]]; then      # DMs closed (50007) -> public channel
            log "#$rid: DM to $did failed - using fallback channel"
            ch=$FALLBACK_CHANNEL_ID
            mid=$(say "$ch" "$(jq -c --arg u "$did" '.content = "<@\($u)> " + .content | .allowed_mentions = {users: [$u]}' <<<"$msg")")
        fi
        [[ -n "$mid" ]] || { log "#$rid: could not post card ($(head -c 200 "$WORK/resp"))"; FAILED=1; continue; }
        log "#$rid: card posted for $title"; SENT=$((SENT + 1))
    fi
    st=$(jq -c --arg ch "$ch" --arg mid "$mid" --arg h "$hash" '. + {channel: $ch, message: $mid, hash: $h}' <<<"$st")

    # ---- the ping: a NEW message (edits don't notify) when everything aired is on Plex
    if [[ "$(jq -r '.done' <<<"$out")" == true ]]; then
        new=$(jq -c --argjson st "$st" '.ready - ($st.pinged // [])' <<<"$out")
        if [[ "$new" != "[]" ]]; then
            text=$(jq -r --argjson new "$new" --arg t "$title" \
                'if (.ready | length) == ($new | length) or $new == [""] then "✅ **\($t)** is ready on Plex — enjoy!"
                 else "✅ **\($t)**: \($new | join(", ")) " + (if ($new | length) == 1 then "is" else "are" end) + " now on Plex." end' <<<"$out")
            pmsg=$(jq -nc --arg c "$text" '{content: $c}')
            [[ "$ch" == "${FALLBACK_CHANNEL_ID:-}" ]] && pmsg=$(jq -c --arg u "$did" '.content = "<@\($u)> " + .content | .allowed_mentions = {users: [$u]}' <<<"$pmsg")
            if [[ -n "$(say "$ch" "$pmsg")" ]]; then
                st=$(jq -c --argjson r "$(jq -c '.ready' <<<"$out")" '.pinged = $r' <<<"$st"); log "#$rid: ready ping sent"
            else
                log "#$rid: ready ping failed"; FAILED=1
            fi
        fi
    fi

    # ---- tell the admin once per distinct problem
    warn=$(jq -r '.warn' <<<"$out")
    if [[ -n "$warn" && "$warn" != "$(jq -r '.warned // empty' <<<"$st")" && -n "${WARN_CHANNEL_ID:-}" ]]; then
        who=$(jq -r '.requestedBy.displayName' <<<"$r")
        say "$WARN_CHANNEL_ID" "$(jq -nc --arg c "⚠️ Request #$rid **$title** ($who): $warn" '{content: $c}')" >/dev/null \
            && log "#$rid: warned - $warn"
    fi
    st=$(jq -c --arg w "$warn" '.warned = $w' <<<"$st")

    echo "$st" > "$SF.tmp" && mv "$SF.tmp" "$SF"
    # Finished and Seerr agrees - stop tracking
    if [[ "$(jq -r '.done' <<<"$out")" == true && "$(jq -r '.media.status' <<<"$r")" == 5 ]]; then
        rm -f "$SF"; log "#$rid: complete"
    fi
done

log "done ($SENT new cards)"
[[ "$FAILED" == 0 ]] && hc "" || hc /fail
