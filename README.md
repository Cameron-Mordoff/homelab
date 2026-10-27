# homelab

Scripts for shrinking a Plex library — Radarr and Sonarr on unRAID — **without giving up
quality you'd actually notice.**

The premise: most of the waste in a media library isn't spread evenly. It's concentrated
in a handful of remuxes and bloated encodes. Find those, replace them at a sane bitrate,
and leave everything else alone.

Real numbers from the library these were built against:

| | Before | Reclaimable | Where |
|---|---|---|---|
| Movies | — | **375 GB** (done) | oversized 1080p Blu-ray rips |
| TV | 5.1 TB | **~620 GB** | **174 files** — mostly remux documentaries |

That TV number is the whole point: 620 GB sitting in 174 of 5,422 files. Three percent of
the files, twelve percent of the library.

---

## Safety model

These scripts delete things. The design assumes they will fail, and every one of them
was rewritten after a failure that cost real files.

- **Nothing is deleted until the replacement is on disk.** Both workers grab first and
  delete only once the download has *finished* — and `sonarr-reclaim.sh` only deletes at
  all if the import turns out to be blocked. An earlier delete-first version lost 5 movies
  in a single batch when the NZBs never completed. Under this design that same failure is a
  no-op: the download never lands, so the delete never happens.
- **The scripts push a specific release by `guid`, not a blind search.** `POST /release`
  bypasses the app's decision engine entirely — which is the *only* way to replace an
  oversized file of an *allowed* quality (a 36 GB `Bluray-1080p` doc episode sits above the
  profile cutoff, so a normal search finds releases and then rejects every one of them with
  `DiskCutoffMet`). The flip side: the script is then solely responsible for vetting the
  release, so it checks quality, size window, season-pack, language, and that the thing is
  genuinely smaller — before it pushes.
- **Dry run by default.** Every script previews. Dry runs never write to the ledger, so a
  preview can't silently change what a later run does.
- **Savings are a floor, not a hope.** A file is only touched when even the *worst* release
  the quality profile permits is still smaller than what's on disk. Shrink-only by
  construction — which is why SD/DVD files are never "upgraded" into something bigger.
- **Append-only CSV ledger.** Every action recorded, with actual GB recovered. Stateless
  otherwise: kill it mid-run, it picks up from live API state.
- **Guards:** night window, parity-check detection, batch size, daily cap, queue depth,
  and cooldowns so an ungrabbable file can't hog the queue forever.

---

## The counterintuitive part: cutoff belongs at the *bottom*

Both Radarr and Sonarr rank a file by its **position** in the quality profile's item list
and **ignore the allowed/disallowed flag entirely** (`QualityProfile.GetIndex` never reads
`Allowed`). "Cutoff unmet" means *"positioned below the cutoff"* — nothing more.

So if you set the cutoff to your highest quality (the intuitive choice), every WEB-DL file
you own sits below it, and the app will chase Blu-ray upgrades across your whole library —
**growing** it. The config scripts put the cutoff low, so only the genuinely unwanted
qualities (remux, 2160p, SD) sit beneath it.

Same trap in the custom-format cutoff: `cutoffFormatScore` is compared as
`currentScore < cutoff`. Your existing files score 0, so *any* positive value makes every
file permanently cutoff-unmet. It must be `0`.

---

## Layout

```
radarr/
  Get-RadarrSizeReport.ps1     read-only: what's oversized and by how much
  Set-RadarrQualityConfig.ps1  size caps + the "1080p (720p fallback)" profile
sonarr/
  Get-SonarrSizeReport.ps1     read-only: per-series/season/file, with a 720p recommendation
  Set-SonarrQualityConfig.ps1  size caps + "1080p TV" / "720p TV" profiles (remux blocked)
  Set-SonarrSeriesProfile.ps1  bulk-assign series to profiles from the report CSV
unraid/
  radarr-regrab.sh             grab-first / delete-last worker (hourly cron)
  sonarr-reclaim.sh            paced search-and-push worker (hourly cron)
  qnap-backup.sh               exact-mirror backup of media + appdata archives to a QNAP over SSH
  collect-inventory.sh         read-only, redacted snapshot of the server's config for review
```

### Backups

Appdata is archived weekly by the Appdata Backup plugin to an array-only `backups` share
(flash drive included, metrics databases skipped). `qnap-backup.sh` then mirrors those
archives - plus the media shares - to a QNAP over SSH. Host and user come from
`/boot/config/plugins/user.scripts/qnap-backup.conf` so nothing site-specific lives here:

```bash
QNAP_HOST="192.0.2.15"
QNAP_USER="backupuser"
```

### TV is not movies

For movies, size tracks runtime. For TV, the lever is **episode-hours** — episode count ×
runtime — which is why `Get-SonarrSizeReport.ps1` ranks by *savings from the recommended
action* rather than raw size. Downgrading The Office (201 × 22min) to 720p reclaims a lot;
downgrading Band of Brothers (10 × 60min) reclaims little and costs you the one show you
wanted in HD. A naive "biggest first" report tells you to gut exactly the wrong things.

---

## Usage

Everything is dry-run by default. Read the output before committing.

The PowerShell scripts take `-ApiKey`, or fall back to a `RadarrApiKey` / `SonarrApiKey`
secret from [SecretManagement](https://learn.microsoft.com/powershell/utility-modules/secretmanagement/overview)
so the key never lands in shell history:

```powershell
Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope CurrentUser
Register-SecretVault -Name Homelab -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
Set-Secret -Name SonarrApiKey   # prompts
```

```powershell
# 1. See what you're dealing with (read-only)
.\sonarr\Get-SonarrSizeReport.ps1 -BaseUrl http://localhost:8989 -Detailed

# 2. Cap sizes, create profiles (dry run, then -Apply)
.\sonarr\Set-SonarrQualityConfig.ps1 -BaseUrl http://localhost:8989
.\sonarr\Set-SonarrQualityConfig.ps1 -BaseUrl http://localhost:8989 -Apply

# 3. Assign series. The report CSV is the control surface — edit TargetRes to override.
.\sonarr\Set-SonarrSeriesProfile.ps1 -BaseUrl http://localhost:8989 -ExcludeProfile Kids -Apply
```

Then on unRAID (User Scripts plugin, hourly):

```bash
cp unraid/sonarr-reclaim.sh /boot/config/plugins/user.scripts/scripts/...
echo 'YOUR_API_KEY' > /boot/config/plugins/user.scripts/sonarr-reclaim.key
chmod 600 /boot/config/plugins/user.scripts/sonarr-reclaim.key
# leave DRY_RUN=true, run once, read the candidate list — that list is the plan
```

Requires `jq` and `curl` on the unRAID host. The scripts read their API key from a file;
never put it in the script.

### Gotchas worth knowing

- **You do NOT need to monitor anything.** This is the opposite of the obvious guess, and
  it matters: most people unmonitor a movie once they have the file, precisely to stop the
  app re-grabbing it. Verified against Radarr 6.3 / Sonarr 4.0 source — `monitored` gates
  exactly **one** thing, unattended **RSS sync**. It does not gate interactive search
  (`MonitoredMovieSpecification` literally logs *"Skipping monitored check during search"*),
  it does not gate `POST /release` (which bypasses the decision engine entirely), and there
  is no monitored check anywhere in the import pipeline. These scripts deliberately ignore
  it. Bulk-monitoring to "make them work" would switch on unattended grabbing across your
  whole library — the exact thing unmonitoring was protecting you from.
- **Import rejects a quality *downgrade*, and never looks at size.** Replacing a 24 GB
  Bluray-1080p with a 10 GB Bluray-1080p is a *same-quality* import and lands fine. But
  Bluray-1080p → WEBDL-1080p is a downgrade and gets rejected — the download just strands
  in the client as `importBlocked`. Both workers handle this by deleting the old file *at
  that point* (the new bits are already on disk, so it's safe) and re-triggering the import.
- **Qualify candidates against the TARGET rate, not the MAX.** Qualifying against the
  profile's ceiling means a file already under the ceiling can never be a candidate, however
  far above target it is — It's Always Sunny at 2.45 GiB/h against a 2.5 max is unreachable,
  even though it's 63% over the 1.5 target. Because these scripts pick the exact release,
  the savings guarantee comes from checking the *chosen release's real size*, not from a
  worst-case estimate against the ceiling.
- **Size caps are global in Sonarr**, not per-profile. That's the only place a ceiling can
  be enforced, and it affects every series including ones on other profiles.
- **`MAX_*` in the shell scripts must match the quality definitions in the PS1s.** The
  savings guarantee is void otherwise.

---

## License

MIT — see [LICENSE](LICENSE).
