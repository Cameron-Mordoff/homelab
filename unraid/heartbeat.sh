#!/bin/bash
# =============================================================================
# heartbeat.sh - "I'm alive" ping to healthchecks.io every few minutes
#
# Nothing on the server can report the server being down. This is the other
# way round: healthchecks.io expects a ping every 5 minutes and alerts (Discord,
# email) when they stop - power loss, a hang, the network or WAN going down.
#
# Schedule from the User Scripts plugin: */5 * * * *
# The project ping key lives on the flash drive, never in this repo.
# =============================================================================

HC_KEY_FILE="/boot/config/plugins/user.scripts/healthchecks.key"
HC_SLUG="andromeda-heartbeat"

[ -r "$HC_KEY_FILE" ] || { echo "no ping key at $HC_KEY_FILE"; exit 1; }
curl -fsS -m 10 --retry 3 -o /dev/null "https://hc-ping.com/$(cat "$HC_KEY_FILE")/$HC_SLUG"
