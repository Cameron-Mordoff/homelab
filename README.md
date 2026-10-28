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

```text
radarr/    PowerShell: size reports and quality-profile config for Radarr
sonarr/    PowerShell: size reports, quality profiles and bulk series assignment for Sonarr
arr/       PowerShell: tools that work on either app (profile consolidation)
unraid/    Bash: scripts that run on the server via the User Scripts plugin
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
