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

- **Nothing is deleted until the replacement is on disk.** `radarr-regrab.sh` grabs first
  and deletes only once the download has *finished*. An earlier delete-first version lost
  5 movies in a single batch when the NZBs never completed. `sonarr-reclaim.sh` never
  deletes at all — it triggers a search and lets Sonarr swap the file on import.
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
  sonarr-reclaim.sh            paced EpisodeSearch worker, never deletes (hourly cron)
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

```powershell
# 1. See what you're dealing with (read-only)
.\sonarr\Get-SonarrSizeReport.ps1 -BaseUrl http://localhost:8989 -ApiKey <key> -Detailed

# 2. Cap sizes, create profiles (dry run, then -Apply)
.\sonarr\Set-SonarrQualityConfig.ps1 -BaseUrl http://localhost:8989 -ApiKey <key>
.\sonarr\Set-SonarrQualityConfig.ps1 -BaseUrl http://localhost:8989 -ApiKey <key> -Apply

# 3. Assign series. The report CSV is the control surface — edit TargetRes to override.
.\sonarr\Set-SonarrSeriesProfile.ps1 -BaseUrl http://localhost:8989 -ApiKey <key> `
    -ExcludeProfile Kids -Apply
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

- **Unmonitored series can never be reclaimed.** Sonarr refuses to search them. The reclaim
  script lists them rather than silently skipping.
- **Size caps are global in Sonarr**, not per-profile. That's the only place a ceiling can
  be enforced, and it affects every series including ones on other profiles.
- **`MAX_*` in the shell scripts must match the quality definitions in the PS1s.** The
  savings guarantee is void otherwise.

---

## License

MIT — see [LICENSE](LICENSE).
