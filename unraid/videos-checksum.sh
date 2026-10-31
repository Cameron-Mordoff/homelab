#!/bin/bash
# =============================================================================
# videos-checksum.sh - bit-rot check for the irreplaceable home videos
#
# XFS has no data checksums and Unraid parity can say two disks disagree but
# not which one is right. Worse, Backrest (B2) and qnap-backup.sh will happily
# copy a silently corrupted file over the good copy. This keeps a BLAKE2
# manifest of media/videos and re-reads every file monthly:
#
#   new file                     -> hashed and added
#   size or mtime changed        -> treated as a real edit: re-hashed, noted
#   unchanged but hash differs   -> BIT ROT: Unraid alert (-> Discord #critical)
#   in manifest, gone from disk  -> warning
#
# Restore a rotted file from Backrest (plan home-videos) or the QNAP copy,
# then run with --accept PATH to take the restored file's hash.
#
# The File Integrity plugin can't do this: it hashes whole disks and only
# excludes top-level shares, so it would hash all of the data share.
#
#   bash videos-checksum.sh                # verify + update manifest
#   bash videos-checksum.sh --accept PATH  # re-baseline one file
#
# Schedule from the User Scripts plugin: custom cron "0 3 20 * *"
# =============================================================================

SRC="/mnt/user/data/media/videos"
MANIFEST="/mnt/user/backups/checksums/videos.b2"   # hash<TAB>size<TAB>mtime<TAB>path
NOTIFY="/usr/local/emhttp/webGui/scripts/notify"

HC_KEY_FILE="/boot/config/plugins/user.scripts/healthchecks.key"   # project ping key
HC_SLUG="videos-checksum"

set -uo pipefail

log() { echo "[$(date '+%F %T')] $*"; }
hc()  { [[ -r "$HC_KEY_FILE" ]] || return 0
        curl -fsS -m 10 --retry 3 -o /dev/null "https://hc-ping.com/$(<"$HC_KEY_FILE")/$HC_SLUG$1" || true; }
entry() { printf '%s\t%s\t%s\t%s\n' "$(b2sum "$1" | cut -d' ' -f1)" "$(stat -c %s "$1")" "$(stat -c %Y "$1")" "$1"; }

mkdir -p "$(dirname "$MANIFEST")"; touch "$MANIFEST"

if [[ "${1:-}" == "--accept" ]]; then
    f="${2:?--accept needs a path}"; [[ -f "$f" ]] || { echo "no such file: $f"; exit 1; }
    { awk -F'\t' -v p="$f" '$4 != p' "$MANIFEST"; entry "$f"; } > "$MANIFEST.new" && mv "$MANIFEST.new" "$MANIFEST"
    log "re-baselined $f"; exit 0
fi

declare -A H=() S=() M=()
while IFS=$'\t' read -r h s m p; do H[$p]=$h; S[$p]=$s; M[$p]=$m; done < "$MANIFEST"

NEW=0; EDITED=0; OK=0; ROT=(); NEXT=$(mktemp); trap 'rm -f "$NEXT"' EXIT
log "===== Verify $SRC ($(( ${#H[@]} )) files in manifest) ====="
while IFS= read -r -d '' f; do
    e=$(entry "$f") || { log "  read FAILED: $f"; ROT+=("unreadable: $f"); continue; }
    IFS=$'\t' read -r h s m _ <<< "$e"
    if [[ -z "${H[$f]+x}" ]]; then NEW=$((NEW+1)); echo "$e" >> "$NEXT"
    elif [[ "$s" != "${S[$f]}" || "$m" != "${M[$f]}" ]]; then EDITED=$((EDITED+1)); log "  edited: $f"; echo "$e" >> "$NEXT"
    elif [[ "$h" != "${H[$f]}" ]]; then
        ROT+=("$f"); log "  HASH MISMATCH: $f"
        printf '%s\t%s\t%s\t%s\n' "${H[$f]}" "${S[$f]}" "${M[$f]}" "$f" >> "$NEXT"   # keep the good hash
    else OK=$((OK+1)); echo "$e" >> "$NEXT"; fi
    unset "H[$f]"
done < <(find "$SRC" -type f -print0)

GONE=${#H[@]}
for p in "${!H[@]}"; do log "  missing: $p"; done
mv "$NEXT" "$MANIFEST"; trap - EXIT
log "ok $OK, new $NEW, edited $EDITED, missing $GONE, mismatched ${#ROT[@]}"

if (( ${#ROT[@]} )); then
    "$NOTIFY" -e "videos-checksum" -i alert -s "Home videos: ${#ROT[@]} file(s) failed checksum" \
        -d "Possible bit rot - restore from Backrest/QNAP: $(printf '%s; ' "${ROT[@]}")"
    hc /fail; exit 1
fi
if (( GONE )); then
    "$NOTIFY" -e "videos-checksum" -i warning -s "Home videos: $GONE file(s) missing" -d "See the User Scripts log"
fi
hc ""
