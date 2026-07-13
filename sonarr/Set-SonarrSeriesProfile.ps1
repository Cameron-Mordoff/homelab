<#
.SYNOPSIS
    Bulk-assigns Sonarr series to the 1080p / 720p quality profiles, driven by
    the TargetRes column of Get-SonarrSizeReport.ps1's CSV.

.DESCRIPTION
    Reads SonarrSeriesReport.csv and moves each series onto the profile implied
    by its TargetRes column. The CSV is the control surface on purpose: review
    it, hand-edit TargetRes for any show you disagree with, then run this.

    Uses PUT /api/v3/series/editor, so the whole library is at most two API
    calls rather than one PUT per show.

    WHAT THIS DOES AND DOES NOT DO
    ------------------------------
    Sonarr ranks an episode file's quality by its POSITION in the profile's
    items list. It ignores the allowed/disallowed flag entirely when ranking
    (QualityProfile.GetIndex never looks at Allowed). Set-SonarrQualityConfig.ps1
    writes the disallowed qualities BELOW the allowed ones, so:

      - a Bluray-1080p Remux file on the 1080p profile now ranks BELOW
        Bluray-1080p  -> the episode becomes "cutoff unmet"
      - a Bluray-1080p file on the 720p profile ranks BELOW Bluray-720p
        -> also "cutoff unmet"

    That is what lets Sonarr replace those files with smaller ones - and the
    import genuinely replaces the file, it is not just a queued grab.

    BUT: Sonarr has NO scheduled cutoff-unmet search. Assigning a profile
    reclaims nothing on its own; a search has to be triggered. What DOES happen
    automatically is RSS sync - any affected episode whose replacement shows up
    in an indexer feed gets grabbed with no user action. For a mostly-ended
    library that is a trickle, but be aware it is not zero.

.PARAMETER TargetRes
    Only reassign shows heading to this resolution ('1080p', '720p', or 'both').
    Use it to roll out in stages instead of moving 105 shows at once.

.PARAMETER ExcludeProfile
    Never touch series currently on these profiles (e.g. Kids, an anime profile).

.PARAMETER SkipTag
    Never touch series carrying this Sonarr tag.

.EXAMPLE
    .\Set-SonarrSeriesProfile.ps1 -BaseUrl http://localhost:8989 -ApiKey xxxx
    # Dry run - shows every move it would make

.EXAMPLE
    .\Set-SonarrSeriesProfile.ps1 -BaseUrl http://localhost:8989 -ApiKey xxxx `
        -TargetRes 1080p -ExcludeProfile Kids -Apply
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [string]$ReportCsv = '.\SonarrSeriesReport.csv',

    [string]$Profile1080Name = '1080p TV (720p fallback)',
    [string]$Profile720Name  = '720p TV',

    [ValidateSet('1080p', '720p', 'both')]
    [string]$TargetRes = 'both',

    # Only act on shows whose Suggest column matches (e.g. 'ok'). Use with
    # -Revert to undo a subset of a previous assignment.
    [string]$OnlySuggest,

    # Undo: put each series back on the profile recorded in the CSV's Profile
    # column. That column is a snapshot of what the show was on when the report
    # ran, so the CSV doubles as an undo log - keep a copy before re-running the
    # report, which overwrites it with the CURRENT (post-move) profiles.
    [switch]$Revert,

    [string[]]$ExcludeProfile = @(),
    [string]$SkipTag = 'profile-lock',

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')
$Headers = @{ 'X-Api-Key' = $ApiKey }

function Invoke-SonarrApi {
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory = $true)][string]$Path,
        $Body = $null
    )
    $uri = "$BaseUrl/api/v3/$Path"
    try {
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 20
            $result = Invoke-RestMethod -Uri $uri -Method $Method -Headers $Headers `
                -Body $json -ContentType 'application/json'
        }
        else {
            $result = Invoke-RestMethod -Uri $uri -Method $Method -Headers $Headers
        }
        # Invoke-RestMethod returns a JSON array as ONE non-enumerated object;
        # bouncing it through a variable makes PowerShell unroll it so callers
        # can pipe it to Where-Object without the filter silently matching all.
        return $result
    }
    catch {
        Write-Host "API call failed: $Method $uri" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
        throw
    }
}

$mode = if ($Apply) { 'APPLY' } else { 'DRY RUN (use -Apply to commit)' }
$verb = if ($Revert) { 'Profile REVERT' } else { 'Series Profile Assignment' }
Write-Host "`n=== Sonarr $verb | Mode: $mode ===" -ForegroundColor Cyan

$status = Invoke-SonarrApi -Path 'system/status'
Write-Host "Connected to Sonarr $($status.version) at $BaseUrl" -ForegroundColor Green

if (-not (Test-Path $ReportCsv)) {
    throw "Report not found: $ReportCsv. Run Get-SonarrSizeReport.ps1 first."
}
$report = @(Import-Csv $ReportCsv)
if (-not ($report[0].PSObject.Properties.Name -contains 'TargetRes')) {
    throw "$ReportCsv has no TargetRes column - it was written by an older version of Get-SonarrSizeReport.ps1. Re-run the report."
}
if ($Revert -and -not ($report[0].PSObject.Properties.Name -contains 'Profile')) {
    throw "$ReportCsv has no Profile column, so there is nothing to revert to."
}
Write-Host "Loaded $($report.Count) shows from $ReportCsv"

# --- Resolve profiles and tags -----------------------------------------------
$profiles = Invoke-SonarrApi -Path 'qualityprofile'
# Cast the ids to [int] on BOTH sides of these maps. JSON numbers deserialize as
# Int64, and a hashtable keyed by Int64 does not match an Int32 lookup - the
# boxed values are not equal. That silently returns $null, which made
# -ExcludeProfile compare against nothing and move a protected series.
$byName   = @{}; foreach ($p in $profiles) { $byName[$p.name] = [int]$p.id }
$byId     = @{}; foreach ($p in $profiles) { $byId[[int]$p.id] = $p.name }

foreach ($n in @($Profile1080Name, $Profile720Name)) {
    if (-not $byName.ContainsKey($n)) {
        Write-Host "FATAL: profile '$n' not found. Sonarr reports:" -ForegroundColor Red
        $profiles | ForEach-Object { Write-Host "    - $($_.name)" }
        throw "Run Set-SonarrQualityConfig.ps1 -Apply first."
    }
}
$id1080 = $byName[$Profile1080Name]
$id720  = $byName[$Profile720Name]

$skipTagId = (Invoke-SonarrApi -Path 'tag' | Where-Object { $_.label -eq $SkipTag } | Select-Object -First 1).id

$series = Invoke-SonarrApi -Path 'series'
$seriesById = @{}; foreach ($s in $series) { $seriesById[[int]$s.id] = $s }

# --- Work out the moves ------------------------------------------------------
$moves   = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[object]

foreach ($row in $report) {
    $sid = [int]$row.SeriesId
    $s   = $seriesById[$sid]
    if (-not $s) {
        $skipped.Add([pscustomobject]@{ Title = $row.Title; Reason = 'not in Sonarr any more' })
        continue
    }

    if ($TargetRes -ne 'both' -and $row.TargetRes -ne $TargetRes) { continue }
    if ($OnlySuggest -and $row.Suggest -ne $OnlySuggest) { continue }

    if ($Revert) {
        if (-not $row.Profile -or -not $byName.ContainsKey($row.Profile)) {
            $skipped.Add([pscustomobject]@{ Title = $row.Title; Reason = "original profile '$($row.Profile)' no longer exists" })
            continue
        }
        $want = $byName[$row.Profile]
    }
    else {
        $want = if ($row.TargetRes -eq '720p') { $id720 } else { $id1080 }
    }
    $wantName = $byId[$want]

    $currentName = $byId[[int]$s.qualityProfileId]
    if (-not $currentName) { $currentName = "unknown (id $($s.qualityProfileId))" }
    if ($ExcludeProfile -contains $currentName) {
        $skipped.Add([pscustomobject]@{ Title = $s.title; Reason = "on excluded profile '$currentName'" })
        continue
    }
    if ($skipTagId -and ($s.tags -contains $skipTagId)) {
        $skipped.Add([pscustomobject]@{ Title = $s.title; Reason = "tagged '$SkipTag'" })
        continue
    }
    if ([int]$s.qualityProfileId -eq $want) { continue }   # already correct

    $moves.Add([pscustomobject]@{
        SeriesId = $sid
        Title    = $s.title
        Files    = [int]$row.EpisodeFiles
        SizeGB   = [double]$row.SizeGB
        From     = $currentName
        To       = $wantName
        ToId     = $want
        Suggest  = $row.Suggest
    })
}

if ($skipped.Count -gt 0) {
    Write-Host "`n--- Skipped ($($skipped.Count)) ---" -ForegroundColor DarkGray
    $skipped | Group-Object Reason | ForEach-Object { Write-Host ("    {0,-40} {1}" -f $_.Name, $_.Count) -ForegroundColor DarkGray }
}

if ($moves.Count -eq 0) {
    Write-Host "`nNothing to do - every show is already on the right profile." -ForegroundColor Green
    return
}

Write-Host "`n--- Moves by profile ---" -ForegroundColor Cyan
$moves | Group-Object To | ForEach-Object {
    $g = $_.Group
    Write-Host ("  -> {0,-26} {1,3} shows  {2,5} files  {3,7} GB" -f $_.Name, $_.Count,
        (($g | Measure-Object Files -Sum).Sum),
        [math]::Round((($g | Measure-Object SizeGB -Sum).Sum), 0)) -ForegroundColor Green
}
Write-Host "`n--- From which profile ---" -ForegroundColor Cyan
$moves | Group-Object From | Sort-Object Count -Descending | ForEach-Object {
    Write-Host ("  {0,-26} {1,3} shows" -f $_.Name, $_.Count)
}

Write-Host "`n--- The 720p downgrades (these lose resolution - check them) ---" -ForegroundColor Yellow
$dg = @($moves | Where-Object { $_.ToId -eq $id720 } | Sort-Object SizeGB -Descending)
if ($dg.Count -gt 0) { $dg | Format-Table Title, Files, SizeGB, From, Suggest -AutoSize }
else { Write-Host '    (none)' -ForegroundColor DarkGray }

# --- Apply -------------------------------------------------------------------
if (-not $Apply) {
    Write-Host "`nDRY RUN - nothing changed. Re-run with -Apply to commit." -ForegroundColor Cyan
    Write-Host 'Tip: edit the TargetRes column in the CSV to override any of the above.' -ForegroundColor DarkGray
    return
}

foreach ($grp in ($moves | Group-Object ToId)) {
    $ids = @($grp.Group | ForEach-Object { $_.SeriesId })
    $body = @{ seriesIds = $ids; qualityProfileId = [int]$grp.Name }
    $null = Invoke-SonarrApi -Method 'PUT' -Path 'series/editor' -Body $body
    Write-Host ("  Moved {0} series to '{1}'." -f $ids.Count, $byId[[int]$grp.Name]) -ForegroundColor Green
}

Write-Host "`nDone. $($moves.Count) series reassigned." -ForegroundColor Green
Write-Host @"

WHAT HAPPENS NOW
  Nothing reclaims space yet. Sonarr has no scheduled cutoff-unmet search, so
  it will not go looking for smaller releases for your back catalogue.

  It WILL, however, grab a replacement for any affected episode that turns up
  in an indexer RSS feed - unattended. Mostly relevant for still-airing shows.

  To actually reclaim the space, trigger a cutoff-unmet search in controlled
  batches (Wanted > Cutoff Unmet in the UI, or the reclaim script).
"@ -ForegroundColor Yellow
