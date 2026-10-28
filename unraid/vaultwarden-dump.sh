#!/bin/bash
# =============================================================================
# vaultwarden-dump.sh - consistent nightly copy of Vaultwarden for off-site backup
#
# WHY NOT BACK UP APPDATA DIRECTLY
# --------------------------------
# Vaultwarden keeps its vault in SQLite with a write-ahead log. Copying
# db.sqlite3 while the container runs can catch the db and -wal files at
# different moments, giving a backup that may not open. sqlite3 ".backup" takes
# a consistent snapshot through SQLite itself, with no need to stop the container.
#
# Each run writes one dated folder to DEST_DIR:
#   db.sqlite3     - consistent snapshot, checked with PRAGMA integrity_check
#   attachments/   - file attachments (not in the db)
#   sends/         - Send files, if any
#   rsa_key*.pem   - signing keys; without them every client must log in again
# Folders older than KEEP_DAYS are removed. Backrest picks DEST_DIR up and
# keeps its own longer history off-site.
#
# Schedule from the User Scripts plugin, before the Backrest job (e.g. 02:30).
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
SRC_DIR="/mnt/user/appdata/vaultwarden"
DEST_DIR="/mnt/user/backups/vaultwarden"
KEEP_DAYS=14
DRY_RUN=false                                # true = show what would happen
# -----------------------------------------------------------------------------

set -uo pipefail

log()  { echo "[$(date '+%F %T')] $*"; }
fail() { log "ERROR: $*"; /usr/local/emhttp/webGui/scripts/notify -i alert \
           -s "Vaultwarden dump failed" -d "$*" >/dev/null 2>&1; exit 1; }

[[ -f "$SRC_DIR/db.sqlite3" ]] || fail "no database at $SRC_DIR/db.sqlite3"
command -v sqlite3 >/dev/null  || fail "sqlite3 not found"

out="$DEST_DIR/$(date +%F)"
if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would snapshot $SRC_DIR/db.sqlite3 -> $out/db.sqlite3"
    log "DRY RUN: would copy attachments/ sends/ rsa_key*.pem"
    find "$DEST_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" \
        -printf "DRY RUN: would remove %p\n" 2>/dev/null
    exit 0
fi

mkdir -p "$out" || fail "cannot create $out"

# Snapshot to a temp name first so a half-written file is never mistaken for a good one.
sqlite3 "$SRC_DIR/db.sqlite3" ".backup '$out/db.sqlite3.tmp'" || fail "sqlite3 .backup failed"
check=$(sqlite3 "$out/db.sqlite3.tmp" "PRAGMA integrity_check;")
[[ "$check" == "ok" ]] || fail "integrity_check on snapshot returned: $check"
mv "$out/db.sqlite3.tmp" "$out/db.sqlite3"

for item in attachments sends; do
    [[ -d "$SRC_DIR/$item" ]] && rsync -a --delete "$SRC_DIR/$item/" "$out/$item/"
done
cp -p "$SRC_DIR"/rsa_key*.pem "$out/" 2>/dev/null

log "snapshot: $out ($(du -sh "$out" | cut -f1))"

# Prune only dated folders, never anything else that ends up in DEST_DIR.
find "$DEST_DIR" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
    -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}' -mtime +"$KEEP_DAYS" \
    -print -exec rm -rf {} + | sed 's/^/removed: /'
