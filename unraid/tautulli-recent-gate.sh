#!/bin/bash
# =============================================================================
# tautulli-recent-gate.sh - keep old items out of the "New on Plex" feed
#
# Plex sometimes creates a fresh metadata item for a movie it already had
# (e.g. Tdarr edits a file whose name says {edition-X} but the Plex item has
# no edition - Plex splits it off as a new edition). Tautulli sees that as
# "recently added" and posts it, although Plex kept the original added date.
#
# Tautulli conditions can't do date maths: {added_date} is only a string
# (MM-DD-YYYY, UTC, from Tautulli's date_format). So this script keeps an
# "Added Date is <today> or <yesterday>" condition on the notifier and rolls
# the dates forward. Anything Plex says was added before yesterday is
# dropped. Other conditions on the notifier are left alone.
#
# Writes straight to tautulli.db (Tautulli reads notifier config from the DB
# on every notification; the API's set_notifier_config needs the whole
# notifier config re-sent and silently mangles repeated params).
#
# FAILURE MODE: if this stops running, new items stop posting about two days
# later - hence the healthchecks.io ping.
#
# Schedule from the User Scripts plugin: hourly ("5 * * * *"). Idempotent;
# only touches the DB when the dates change.
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
TAUTULLI_DB="/mnt/user/appdata/tautulli/tautulli.db"
NOTIFIER_IDS="39"           # space-separated; 39 = #new-on-plex webhook
DATE_FMT="+%m-%d-%Y"        # must match Tautulli's date_format (MM-DD-YYYY)
DRY_RUN=false

HC_KEY_FILE="/boot/config/plugins/user.scripts/healthchecks.key"   # project ping key
HC_SLUG="tautulli-recent-gate"
# -----------------------------------------------------------------------------

set -uo pipefail

log() { echo "[$(date '+%F %T')] $*"; }
hc()  { [[ -r "$HC_KEY_FILE" ]] || return 0
        curl -fsS -m 10 --retry 3 -o /dev/null "https://hc-ping.com/$(<"$HC_KEY_FILE")/$HC_SLUG$1" || true; }
die() { log "FATAL: $*"; hc /fail; exit 1; }

command -v jq >/dev/null || die "jq not found"
command -v sqlite3 >/dev/null || die "sqlite3 not found"
[[ -w "$TAUTULLI_DB" ]] || die "can't write $TAUTULLI_DB"

# Tautulli formats added_at in UTC
TODAY=$(date -u "$DATE_FMT"); YESTERDAY=$(date -u -d yesterday "$DATE_FMT")

for id in $NOTIFIER_IDS; do
    CUR=$(sqlite3 -cmd ".timeout 10000" "$TAUTULLI_DB" \
            "select coalesce(custom_conditions,'[]') from notifiers where id=$id;") \
        || die "notifier $id: DB read failed"
    [[ -n "$CUR" ]] || die "notifier $id not found"

    NEW=$(jq -c --arg t "$TODAY" --arg y "$YESTERDAY" \
            'map(select(.parameter != "added_date"))
             + [{parameter: "added_date", operator: "is", value: [$t, $y], type: "str"}]' <<<"$CUR") \
        || die "notifier $id: can't parse custom_conditions: $CUR"

    if [[ "$(jq -cS . <<<"$CUR")" == "$(jq -cS . <<<"$NEW")" ]]; then
        log "notifier $id: up to date ($TODAY, $YESTERDAY)"; continue
    fi
    if [[ "$DRY_RUN" == true ]]; then log "notifier $id: WOULD set $NEW"; continue; fi

    sqlite3 -cmd ".timeout 10000" "$TAUTULLI_DB" \
        "update notifiers set custom_conditions='${NEW//\'/\'\'}' where id=$id;" \
        || die "notifier $id: DB write failed"
    log "notifier $id: set $NEW"
done

hc ""
