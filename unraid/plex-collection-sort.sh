#!/bin/bash
# =============================================================================
# plex-collection-sort.sh - keep movie series in order in the Plex library
#
# Plex sorts the library by each movie's sort title, so a series lands in
# alphabetical order of its subtitles (Harry Potter: Chamber, Deathly, Goblet,
# Half-Blood ...). This sets the sort title of every movie in a TMDB collection
# (as Radarr reports it) to "<series> NN", numbered by theatrical release:
#   Harry Potter and the Philosopher's Stone -> "Harry Potter 01"
# The displayed title is untouched. The field is locked, the same lock Plex sets
# when you edit it by hand, so metadata refreshes don't undo it.
#
# Series name = collection name minus " Collection", a trailing "(...)", "..."
# and a leading The/A/An. Two collections that clean to the same name get the
# first film's year added ("Spider-Man 2002 01" / "Spider-Man 2017 01").
# Only collections with 2+ downloaded movies are touched; movies already set to
# the right value are skipped, so reruns only change what's new.
#
# Every sort title it changes is appended to SNAPSHOT first (rating key, old
# value) so a run can be reverted. Old value empty = Plex's default (the title).
#
#   bash plex-collection-sort.sh --print    # list the changes, touch nothing
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
RADARR_URL="http://localhost:7878"; RADARR_CONFIG="/mnt/user/appdata/radarr/config.xml"
PLEX_URL="http://localhost:32400"; MOVIE_SECTION=4
PLEX_PREFS="/mnt/user/appdata/binhex-plex/Plex Media Server/Preferences.xml"
SNAPSHOT="/mnt/user/backups/plex-collection-sort/snapshot.tsv"

# Collection -> series name, where the cleaned collection name reads badly.
declare -A RENAME=(
    ["28 Days/Weeks/Years Later Collection"]="28 Days Later"
    ["Jump Street Collection"]="21 Jump Street"
    ["Star Trek: Alternate Reality Collection"]="Star Trek"
)
# Related films, not a numbered series - grouping them would just move them.
SKIP=("Clint Eastwood's Iwo Jima Collection" "Dreamworks' Pentateuch" "Hercule Poirot (Kenneth Branagh) Collection")
# -----------------------------------------------------------------------------

PRINT_ONLY=false; [ "$1" = "--print" ] && PRINT_ONLY=true
key() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$1" 2>/dev/null; }
[ -r "$PLEX_PREFS" ] || PLEX_PREFS=$(find /mnt/user/appdata/binhex-plex -maxdepth 4 -name Preferences.xml | head -1)
PT=$(grep -oP 'PlexOnlineToken="\K[^"]+' "$PLEX_PREFS")
[ -n "$PT" ] || { echo "no Plex token in $PLEX_PREFS"; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

curl -sf -m 120 -H "X-Api-Key: $(key "$RADARR_CONFIG")" "$RADARR_URL/api/v3/movie" > "$WORK/radarr.json" \
    || { echo "Radarr API call failed"; exit 1; }
# Plex: tmdb id -> rating key and current sort title
curl -sf -m 120 -H 'Accept: application/json' "$PLEX_URL/library/sections/$MOVIE_SECTION/all?type=1&includeGuids=1&X-Plex-Token=$PT" \
    | jq '[.MediaContainer.Metadata[] | (.Guid // [] | map(.id | select(startswith("tmdb://")) | ltrimstr("tmdb://")) | .[0]) as $t
           | select($t) | {($t): {rk: .ratingKey, sort: (.titleSort // "")}}] | add // {}' > "$WORK/plex.json" \
    || { echo "Plex API call failed"; exit 1; }

renames=$(for k in "${!RENAME[@]}"; do jq -n --arg k "$k" --arg v "${RENAME[$k]}" '{($k): $v}'; done | jq -s 'add // {}')
skips=$(printf '%s\n' "${SKIP[@]}" | jq -R . | jq -s .)

# One line per wanted change: ratingKey, new sort title, old, title - separated by
# \x1f, not tab: read treats tab as whitespace and collapses an empty old value.
jq -r --slurpfile p "$WORK/plex.json" --argjson rn "$renames" --argjson skip "$skips" '
    def clean: sub(" Collection$"; "") | sub(" \\([^)]*\\)$"; "") | sub("\\.\\.\\.$"; "") | sub("^(The|A|An) "; "");
    [ .[] | select(.hasFile and .collection.title != null and (.collection.title as $c | $skip | index($c) | not))
      | {c: .collection.title, tmdb: (.tmdbId | tostring), t: .title, y: .year,
         d: (.inCinemas // .physicalRelease // .digitalRelease // "\(.year)-12-31")} ]
    | group_by(.c) | map(select(length >= 2) | sort_by(.d, .t))
    | map({films: ., name: ($rn[.[0].c] // (.[0].c | clean)), year: .[0].y})
    | group_by(.name) | map(if length > 1 then map(.name += " \(.year)") else . end) | add // []
    | .[] | .name as $n | .films | to_entries[]
    | $p[0][.value.tmdb] as $px | select($px)
    | "\($n) \(.key + 1 | if . < 10 then "0\(.)" else tostring end)" as $new
    | select($px.sort != $new)   # /all never reports locks, so compare the value only
    | [$px.rk, $new, $px.sort, "\(.value.t) (\(.value.y))"] | join("\u001f")
' "$WORK/radarr.json" > "$WORK/changes.txt"

N=$(wc -l < "$WORK/changes.txt")
if $PRINT_ONLY; then
    awk -F'\x1f' '{printf "%-34s <- %s   (was: %s)\n", $2, $4, ($3 == "" ? "-" : $3)}' "$WORK/changes.txt"
    echo "$N change(s)"; exit 0
fi
[ "$N" -eq 0 ] && { echo "nothing to change"; exit 0; }

mkdir -p "$(dirname "$SNAPSHOT")"
[ -s "$SNAPSHOT" ] || printf 'when\tratingKey\told_titleSort\ttitle\n' > "$SNAPSHOT"
FAILED=0
while IFS=$'\x1f' read -r rk new old title; do
    printf '%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$rk" "$old" "$title" >> "$SNAPSHOT"
    code=$(curl -s -m 30 -o /dev/null -w '%{http_code}' -X PUT -G "$PLEX_URL/library/sections/$MOVIE_SECTION/all" \
           --data-urlencode "type=1" --data-urlencode "id=$rk" --data-urlencode "titleSort.value=$new" \
           --data-urlencode "titleSort.locked=1" --data-urlencode "X-Plex-Token=$PT")
    [[ "$code" == 2* ]] || { echo "FAILED ($code): $title -> $new"; FAILED=1; }
done < "$WORK/changes.txt"
echo "$N sort title(s) set$([ $FAILED -eq 1 ] && echo ", some FAILED")"
exit $FAILED
