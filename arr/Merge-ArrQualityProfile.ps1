<#
.SYNOPSIS
    Moves movies/series off old Radarr or Sonarr quality profiles onto the ones
    you keep, and optionally deletes the emptied profiles.

.DESCRIPTION
    -ProfileMap says where everything on an old profile goes. -TitleMap overrides
    that for individual titles (and can move titles on profiles that aren't being
    retired). Uses the bulk editor endpoint, so it's one PUT per target profile.
    In Radarr, collections on a source profile are repointed by -ProfileMap too.

    BEFORE MOVING ANYTHING, READ THE BelowCutoff COLUMN.
    The app ranks a file by its quality's POSITION in the profile, so moving a
    title can turn files you're happy with into "cutoff unmet" - e.g. a DVD rip
    moved onto a 720p profile, where SD sits in the disallowed block below the
    cutoff. Those files then get replaced by RSS sync if the title is monitored,
    and by any cutoff-unmet search either way. BelowCutoff counts them; Monitored
    tells you whether RSS will act on them unattended.

    Profiles are only deleted when nothing is left on them. External apps that
    reference a profile by id (Overseerr / Jellyseerr defaults) are invisible to
    this script - repoint them first, or new requests fail.

.PARAMETER App
    Radarr or Sonarr.

.PARAMETER ProfileMap
    Old profile name -> profile to move its titles to.

.PARAMETER TitleMap
    Title -> profile. Takes precedence over -ProfileMap.

.PARAMETER RemoveEmpty
    Delete each -ProfileMap source profile once nothing is assigned to it.

.EXAMPLE
    .\Merge-ArrQualityProfile.ps1 -App Radarr -BaseUrl http://localhost:7878 `
        -ProfileMap @{ 'TRaSH 720/1080' = '1080p (720p fallback)' } -RemoveEmpty
    # Dry run - shows every move and the profiles it would delete
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Radarr', 'Sonarr')][string]$App,
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [string]$ApiKey,                 # default: <App>ApiKey from SecretManagement
    [hashtable]$ProfileMap = @{},
    [hashtable]$TitleMap = @{},
    [switch]$RemoveEmpty,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')
if (-not $ApiKey) {
    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) { throw "Pass -ApiKey, or install Microsoft.PowerShell.SecretManagement and Set-Secret -Name ${App}ApiKey." }
    $ApiKey = Get-Secret -Name "${App}ApiKey" -AsPlainText
}
$Headers = @{ 'X-Api-Key' = $ApiKey }

function Invoke-ArrApi {
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
        # Bounce through a variable so a JSON array unrolls when piped (see the
        # note in Set-RadarrQualityConfig.ps1).
        return $result
    }
    catch {
        Write-Host "API call failed: $Method $uri" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
        throw
    }
}

# Rank of every quality id within a profile, plus the cutoff's rank. Items are
# stored lowest-priority-first; qualities inside a group share the group's rank.
function Get-ProfileRanking($QualityProfile) {
    $rank = @{}; $cutoffRank = $null
    for ($i = 0; $i -lt $QualityProfile.items.Count; $i++) {
        $item = $QualityProfile.items[$i]
        if ($item.items) {
            foreach ($sub in $item.items) { $rank[[int]$sub.quality.id] = $i }
            if ([int]$item.id -eq [int]$QualityProfile.cutoff) { $cutoffRank = $i }
        }
        else {
            $rank[[int]$item.quality.id] = $i
            if ([int]$item.quality.id -eq [int]$QualityProfile.cutoff) { $cutoffRank = $i }
        }
    }
    [pscustomobject]@{ Rank = $rank; Cutoff = $cutoffRank }
}

$mode = if ($Apply) { 'APPLY' } else { 'DRY RUN (use -Apply to commit)' }
Write-Host "`n=== $App Profile Merge | Mode: $mode ===" -ForegroundColor Cyan
$status = Invoke-ArrApi -Path 'system/status'
Write-Host "Connected to $App $($status.version) at $BaseUrl" -ForegroundColor Green

$profiles = Invoke-ArrApi -Path 'qualityprofile'
# [int] on both sides: JSON numbers come back Int64, and an Int64 hashtable key
# never matches an Int32 lookup.
$byName = @{}; foreach ($p in $profiles) { $byName[$p.name] = $p }
$byId   = @{}; foreach ($p in $profiles) { $byId[[int]$p.id] = $p }

foreach ($n in @($ProfileMap.Keys) + @($ProfileMap.Values) + @($TitleMap.Values)) {
    if (-not $byName.ContainsKey($n)) {
        Write-Host "FATAL: profile '$n' not found. $App reports:" -ForegroundColor Red
        $profiles | ForEach-Object { Write-Host "    - $($_.name)" }
        throw "Unknown profile '$n'."
    }
}
foreach ($k in $ProfileMap.Keys) {
    if ($ProfileMap.Values -contains $k) { throw "'$k' is both a source and a target in -ProfileMap." }
}

$rankings = @{}
foreach ($p in $profiles) { $rankings[[int]$p.id] = Get-ProfileRanking $p }

$isRadarr = $App -eq 'Radarr'
$items = if ($isRadarr) { Invoke-ArrApi -Path 'movie' } else { Invoke-ArrApi -Path 'series' }

foreach ($t in $TitleMap.Keys) {
    if (-not ($items | Where-Object { $_.title -eq $t })) { Write-Host "  ! TitleMap: '$t' not found - ignored" -ForegroundColor Yellow }
}

# --- Work out the moves ------------------------------------------------------
$moves = New-Object System.Collections.Generic.List[object]
foreach ($it in $items) {
    $from = $byId[[int]$it.qualityProfileId].name
    $to = if ($TitleMap.ContainsKey($it.title)) { $TitleMap[$it.title] }
          elseif ($ProfileMap.ContainsKey($from)) { $ProfileMap[$from] }
          else { $null }
    if (-not $to -or $to -eq $from) { continue }

    $qualityIds = if ($isRadarr) {
        if ($it.hasFile) { @([int]$it.movieFile.quality.quality.id) } else { @() }
    } else {
        @(Invoke-ArrApi -Path "episodefile?seriesId=$($it.id)" | ForEach-Object { [int]$_.quality.quality.id })
    }
    $target = $rankings[[int]$byName[$to].id]
    $below = @($qualityIds | Where-Object { $target.Rank[$_] -lt $target.Cutoff }).Count

    $moves.Add([pscustomobject]@{
        Id          = [int]$it.id
        Title       = $it.title
        From        = $from
        To          = $to
        ToId        = [int]$byName[$to].id
        Files       = $qualityIds.Count
        BelowCutoff = $below
        Monitored   = [bool]$it.monitored
    })
}

if ($moves.Count -eq 0) { Write-Host "`nNo moves needed." -ForegroundColor Green }
else {
    Write-Host "`n--- Moves ---" -ForegroundColor Cyan
    $moves | Sort-Object To, Title | Format-Table Title, From, To, Files, BelowCutoff, Monitored -AutoSize

    $risky = @($moves | Where-Object { $_.BelowCutoff -gt 0 -and $_.Monitored })
    if ($risky.Count -gt 0) {
        Write-Host "  ! $($risky.Count) monitored title(s) would have files below cutoff - RSS will replace them unattended:" -ForegroundColor Yellow
        $risky | ForEach-Object { Write-Host "      $($_.Title): $($_.BelowCutoff) of $($_.Files) files" -ForegroundColor Yellow }
    }
}

# --- Radarr collections ------------------------------------------------------
# Every Radarr collection carries its own quality profile (used when a monitored
# collection auto-adds movies), and Radarr refuses to delete a profile any
# collection still points at - even an unmonitored one. Repoint them along with
# the movies, by -ProfileMap.
$collectionMoves = @()
if ($isRadarr) {
    $collections = Invoke-ArrApi -Path 'collection'
    foreach ($c in $collections) {
        $from = $byId[[int]$c.qualityProfileId].name
        if ($ProfileMap.ContainsKey($from)) {
            $collectionMoves += [pscustomobject]@{ Id = [int]$c.id; ToId = [int]$byName[$ProfileMap[$from]].id; Monitored = [bool]$c.monitored }
        }
    }
    if ($collectionMoves.Count -gt 0) {
        Write-Host ("`n  {0} collection(s) to repoint ({1} monitored)." -f $collectionMoves.Count,
            @($collectionMoves | Where-Object Monitored).Count) -ForegroundColor Cyan
    }
}

# --- Profiles that end up empty ----------------------------------------------
$toRemove = @()
if ($RemoveEmpty) {
    foreach ($src in $ProfileMap.Keys) {
        $srcId = [int]$byName[$src].id
        $left = @($items | Where-Object {
            [int]$_.qualityProfileId -eq $srcId -and -not ($moves | Where-Object Id -eq ([int]$_.id))
        })
        if ($left.Count -eq 0) { $toRemove += $byName[$src] }
        else { Write-Host "  ! '$src' keeps $($left.Count) title(s) - not deleting it" -ForegroundColor Yellow }
    }
    if ($toRemove.Count -gt 0) {
        Write-Host "`n--- Profiles to delete once empty ---" -ForegroundColor Cyan
        $toRemove | ForEach-Object { Write-Host "    $($_.name) (id $($_.id))" }
        Write-Host '    Repoint Overseerr/Jellyseerr defaults off these first.' -ForegroundColor DarkGray
    }
}

if (-not $Apply) {
    Write-Host "`nDRY RUN - nothing changed. Re-run with -Apply to commit." -ForegroundColor Cyan
    return
}

# --- Apply -------------------------------------------------------------------
foreach ($grp in ($moves | Group-Object ToId)) {
    $ids = @($grp.Group | ForEach-Object { $_.Id })
    $body = if ($isRadarr) { @{ movieIds = $ids; qualityProfileId = [int]$grp.Name } }
            else { @{ seriesIds = $ids; qualityProfileId = [int]$grp.Name } }
    $path = if ($isRadarr) { 'movie/editor' } else { 'series/editor' }
    $null = Invoke-ArrApi -Method 'PUT' -Path $path -Body $body
    Write-Host ("  Moved {0} title(s) to '{1}'." -f $ids.Count, $byId[[int]$grp.Name].name) -ForegroundColor Green
}

foreach ($grp in ($collectionMoves | Group-Object ToId)) {
    $ids = @($grp.Group | ForEach-Object { $_.Id })
    $null = Invoke-ArrApi -Method 'PUT' -Path 'collection' -Body @{ collectionIds = $ids; qualityProfileId = [int]$grp.Name }
    Write-Host ("  Repointed {0} collection(s) to '{1}'." -f $ids.Count, $byId[[int]$grp.Name].name) -ForegroundColor Green
}

foreach ($p in $toRemove) {
    # The app itself refuses to delete a profile still used by a title or an
    # import list, so a failure here leaves things as they were.
    try {
        $null = Invoke-ArrApi -Method 'DELETE' -Path "qualityprofile/$($p.id)"
        Write-Host "  Deleted profile '$($p.name)'." -ForegroundColor Green
    }
    catch { Write-Host "  Could not delete '$($p.name)' - see the error above." -ForegroundColor Yellow }
}

Write-Host "`nDone." -ForegroundColor Green
