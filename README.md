# homelab

Scripts and notes for an Unraid home server: media library management for
Plex/Radarr/Sonarr, backups to a QNAP, and server housekeeping.

Everything here is written to be run against a live server, so the defaults are cautious:
scripts preview before they change anything, and nothing site-specific or secret lives in
the repo.

## What's here

| Area | What it does | Details |
|---|---|---|
| **Library slimming** | Finds oversized remuxes and bloated encodes in Radarr/Sonarr and replaces them at a sane bitrate, grab-first / delete-last | [docs/library-slimming.md](docs/library-slimming.md) |
| **Backups** | Weekly appdata + flash archives on the array, mirrored with media to a QNAP over SSH | [Backups](#backups) |
| **Health report** | Weekly notification: SMART changes since last week, space, parity, backup freshness, containers | [Health report](#health-report) |
| **Server inventory** | Read-only, redacted snapshot of the Unraid config (shares, network, Docker, plugins) for reviews | [Server inventory](#server-inventory) |
| **Notifications** | One private Discord server, channels split by severity; dead-man checks for the server itself | [Notifications](#notifications) |
| **Books** | Calibre-Web-Automated library plus a Discord bot: family requests a book, admin approves, it lands on the Kindle | [Books](#books) |
| **Tdarr** | Lossless cleanup: foreign audio/subtitle tracks, cover art and attachments; overnight health checks | [Tdarr](#tdarr) |

```text
radarr/    PowerShell: size reports and quality-profile config for Radarr
sonarr/    PowerShell: size reports, quality profiles and bulk series assignment for Sonarr
arr/       PowerShell: tools that work on either app (profile consolidation)
unraid/    Bash: scripts that run on the server via the User Scripts plugin
tdarr/     Node: Tdarr plugin and a read-only preview of what it would change
book-requests/  Python: Discord bot for ebook requests and Send to Kindle
docs/      Longer write-ups
```

## Conventions

- **Dry run by default.** Every script that changes something previews first; look for
  `DRY_RUN=true` in the shell scripts and `-Apply` on the PowerShell ones.
- **Shell scripts run on Unraid** via the User Scripts plugin. They need `jq` and `curl`,
  and use LF line endings (enforced by `.gitattributes`).
- **PowerShell scripts run from a workstation** against the apps' APIs (PowerShell 7).

## Secrets

Nothing secret or site-specific is committed:

| What | Where it lives |
|---|---|
| API keys for workstation scripts | A [SecretManagement](https://learn.microsoft.com/powershell/utility-modules/secretmanagement/overview) vault — scripts fall back to it when `-ApiKey` is omitted |
| API keys for server scripts | `/boot/config/plugins/user.scripts/*.key` on the flash drive (`chmod 600`) |
| Hosts, usernames | `*.conf` next to the keys on the flash drive |
| Reports, ledgers, inventory output | Local only — `.gitignore` covers `*.csv`, `*.log`, `inventory-*.txt` |

```powershell
Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope CurrentUser
Register-SecretVault -Name Homelab -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
Set-Secret -Name RadarrApiKey   # prompts; same for SonarrApiKey
```

## Backups

1. **Appdata Backup plugin** (weekly) archives each container's appdata, plus the flash
   drive, to an array-only `backups` share. Containers are stopped one at a time while their
   folder is archived. Metrics databases and regenerable caches (posters, Plex metadata) are
   skipped.
2. **`unraid/qnap-backup.sh`** mirrors those archives and the media shares to a QNAP over
   SSH with `rsync --delete`. Because an exact mirror of an empty source is an empty backup,
   it refuses to run if a source is missing or has shrunk past a per-job threshold, and caps
   deletions per run.
3. **Backrest** (restic) sends the irreplaceable subset off-site to Backblaze B2: home videos,
   the appdata archives and Vaultwarden. Archives are written uncompressed so restic can
   deduplicate them week to week; restic compresses them itself.
   **`unraid/vaultwarden-dump.sh`** (daily) takes a consistent `sqlite3 .backup` snapshot of
   Vaultwarden for it to pick up, since copying a live WAL-mode database may not restore.

Host and user come from `/boot/config/plugins/user.scripts/qnap-backup.conf`:

```bash
QNAP_HOST="192.0.2.15"
QNAP_USER="backupuser"
```

## Health report

`unraid/health-report.sh` runs weekly (Monday 09:00, after the appdata backup) and sends one
Unraid notification, so it reaches whatever agents are enabled (Pushover, Discord, ...). It
is read-only.

It compares each disk's SMART counters (reallocated, pending, uncorrectable, CRC; NVMe wear
and media errors) with **last week's values**, because on second-hand disks the trend
matters more than whether a counter is non-zero. It also checks space, the last parity
check, the newest appdata archive, the last `qnap-backup.sh` run, the newest Backrest
snapshot per plan (read from the restic repo itself, in hours, so a run that failed that
morning is caught), and autostart containers that aren't running. A report is sent even when everything is fine — if the weekly "OK"
stops arriving, something is broken.

```bash
bash health-report.sh --print     # preview: no notification, no state saved
```

Optionally, `DISCORD_REPORT_WEBHOOK` in the conf file posts the full report to a Discord
channel every run, so routine weeks can stay out of the alerts channel.

**`unraid/discord-status.sh`** keeps one live status card in a Discord channel, edited every
5 minutes: overall state, server, storage, containers, off-site backup ages, Plex and internet.
It never wakes sleeping disks and checks the backup repo at most every 30 minutes.

Nothing on the server can report the server being down, so the scheduled jobs also ping
[healthchecks.io](https://healthchecks.io), which alerts when a ping is late:
**`unraid/heartbeat.sh`** every 5 minutes, plus the health report, `vaultwarden-dump.sh`
and each Backrest plan when they complete. The project ping key lives on the flash drive
(`healthchecks.key`); without it the scripts skip the ping.

Baselines live on the flash drive (`health-report/smart.state`), so the report still works
when the array won't start. Thresholds can be overridden in
`/boot/config/plugins/user.scripts/health-report.conf`.

## Notifications

Everything reports to one private Discord server through per-channel webhooks. Channels are
split by **what you should do about it**, so only one of them needs to reach a phone:

| Channel | Gets | Phone |
|---|---|---|
| `#critical` | Server down (healthchecks.io), disk/array/cache alerts (Unraid), backup errors (Backrest), core services down (Uptime Kuma), AP or switch offline (Grafana), Plex down | push |
| `#warnings` | Internet latency or loss (Grafana), secondary services down, Radarr/Sonarr health, Plex remote access, new streaming device | - |
| `#status` | One live status card, edited every 5 minutes (`discord-status.sh`) | - |
| `#weekly` | Full health report, plus `weekly-summary.sh`: plays, top titles, additions, storage and backup trends | - |
| `#updates` | Container image updates (Diun), Plex updates | - |
| `#new-on-plex`, `#now-playing`, `#downloads` | Tautulli and Radarr/Sonarr activity | - |
| `#changelog` | Pushes to this repo | - |
| `#requests` | Seerr request events; `/request` via the bot | - |
| `#books` | New books in the Calibre library (`book-requests` bot) | - |

**`unraid/request-status.sh`** (every 10 minutes) DMs each requester one live status card for
their Seerr request, edited in place: episodes on Plex, download progress and ETA from the
Sonarr/Radarr queues, and what hasn't aired yet. A new message pings them when everything aired
is on Plex. Failed downloads, or episodes with no release 24 hours after airing, go to `#warnings`.

Webhook URLs live in each app's own config or in `*.conf` files on the flash drive, never here.
Uptime Kuma checks services every minute without the Docker socket; Diun has it read-only.

## Books

[Calibre-Web-Automated](https://github.com/crocodilestick/Calibre-Web-Automated) holds the ebook
library. Anything dropped into its ingest folder (an SMB path on the `data` share) is imported,
converted to EPUB and removed from the folder within seconds. The library lives in `appdata`, not
on the array: `appdata` is cache-only, so the mover never touches Calibre's `metadata.db`, and the
weekly appdata archive backs it up.

**`book-requests/`** is a small Discord bot (discord.py, built locally on the server) that turns
that into a request queue for a shared Kindle:

| Who | Sees | |
|---|---|---|
| Family | `/book title:<search>` | Open Library autocomplete; a DM card tracks the request, and a final DM says it's on the Kindle |
| Admin | Approve / Decline cards in DMs; `/books list \| send \| kindle \| link` | `/books` is hidden from non-administrators and checked again in the bot |

The bot polls the library's `metadata.db` (read-only). Each new book is announced in `#books`. When
it fuzzy-matches an open request (title without subtitle or series, author surname), the bot marks the
request fulfilled and emails the EPUB to the Kindle's Send-to-Kindle address over SMTP. Amazon no longer
takes MOBI or AZW3 by email, so it sends EPUB or PDF. Failed sends, files that sit in ingest for 30 minutes,
and requests approved a week ago with nothing arrived all go to `#warnings`. Each poll pings
healthchecks.io.

Config is environment variables only (token, channel and role IDs, SMTP app password, Kindle address);
see the top of `bot.py`. On the server they live in an env file next to the bot's state (chmod 600).

## Missing-release safety net

Radarr and Sonarr only grab new releases from RSS and never re-search a monitored item on
their own, so a release that slips between polls can stay missing until someone clicks
Search. **`unraid/arr-missing-search.sh`** (every 4 hours) does that click for recent items
only: Sonarr episodes that aired in the last 14 days (and at least 4 hours ago, so RSS gets
the first go), and Radarr movies released in the last 60 days. Anything already downloading
is skipped, and each run is capped. API keys are read from each app's `config.xml`. It pings
healthchecks.io like the other scheduled jobs.

## Trending titles

**`unraid/hype-gate.sh`** (daily) adds new movies and shows people are talking about,
without filling the server with whatever happens to be popular. Two MDBList dynamic lists
(popular, recent, rating-filtered) nominate titles, but MDBList filters on cached ratings
that lag behind, so a film that opened at 7.4 and settled at 6.2 is still on its list. The
script re-checks every nominee against IMDb's daily ratings dataset (rating and vote count),
Rotten Tomatoes when present, original language and genre, and adds only what passes.
Movies come from a Radarr import list with auto-add off; shows come from the MDBList JSON.
Added titles are tagged `hype`; shows get their first season only.

## Tdarr

Tdarr never re-encodes anything here. Its Movies and TV libraries run one classic plugin,
**`tdarr/Tdarr_Plugin_hl01_Keep_English_And_Original.js`**, which keeps English, the
title's original language (from Radarr for movies, Sonarr for episodes) and untagged
audio, drops other audio and subtitle tracks, removes embedded cover art and attachments
(fonts stay while an ASS/SSA subtitle needs them), and tags a lone untagged audio track
with the original language. MKVs that only need a tag or attachments removed are edited in
place with `mkvpropedit`; anything else is remuxed with `-c copy`.

Temporary problems (file still hardlinked to a seeding torrent, Radarr/Sonarr unreachable)
make the plugin throw, so the file lands in Tdarr's error table instead of being marked
done. **`unraid/tdarr-requeue-errors.sh`** (weekly) puts those back in the queue.
Thorough health checks (every frame decoded) run overnight only, and failures post to
Discord. `tdarr/preview-language-cleanup.js` shows what the plugin would change across the
whole library without changing anything.

## Server inventory

`unraid/collect-inventory.sh` dumps system, storage, share, network, Docker, remote-access
and plugin configuration as plain text. It changes nothing. Container environment variables
are printed as names only (except `PUID`/`PGID`/`UMASK`/`TZ`), and WireGuard keys and
password-like values are masked.

```bash
bash collect-inventory.sh > /boot/inventory-$(date +%F).txt
```

The output still contains LAN addresses, MACs and hostnames — review it before sharing,
and don't commit it.

## License

MIT — see [LICENSE](LICENSE).
