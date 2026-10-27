<#
.SYNOPSIS
    Configures Radarr quality definitions (file size limits) and creates a
    "1080p (720p fallback)" quality profile with TRaSH custom format scores.

.DESCRIPTION
    Two things happen (both support dry-run):

    1. Quality Definitions (Settings > Quality)
       Sets Min / Preferred / Max size-per-hour limits for the 720p/1080p
       qualities so a ~2h movie lands at ~10-15 GB for 1080p Bluray and
       ~5 GB for 720p.

    2. Quality Profile (Settings > Profiles)
       Creates "1080p (720p fallback)":
         - Enabled (ascending priority):
             WEB 720p (group) -> Bluray-720p -> HDTV-1080p ->
             WEB 1080p (group) -> Bluray-1080p
         - Upgrade Until: Bluray-1080p
         - Custom format scores: LQ / BR-DISK / 3D = -10000,
           HD Bluray Tier 01 = +100, Tier 02 = +50, Repack/Proper bumps
         - Min format score 0, Upgrade-until format score 100

    NOTE: Bluray is preferred over WEB at the same resolution. To flip that,
    swap the order in $ProfileQualityOrder below.

.PARAMETER BaseUrl
    Radarr base URL, e.g. http://192.168.1.50:7878 (no trailing slash needed).

.PARAMETER ApiKey
    Radarr API key (Settings > General > Security). Defaults to the RadarrApiKey
    secret from Microsoft.PowerShell.SecretManagement.

.PARAMETER Apply
    Actually write changes. Without this switch the script is a DRY RUN and
    only prints what it would do.

.PARAMETER UpdateExistingProfile
    If a profile with the same name already exists, update it in place
    instead of aborting.

.EXAMPLE
    .\Set-RadarrQualityConfig.ps1 -BaseUrl http://localhost:7878 -ApiKey xxxx
    # Dry run - review the output

.EXAMPLE
    .\Set-RadarrQualityConfig.ps1 -BaseUrl http://localhost:7878 -ApiKey xxxx -Apply
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [string]$ApiKey,
    [switch]$Apply,
    [switch]$UpdateExistingProfile
)

# =============================================================================
# CONFIG - edit these to taste
# =============================================================================

$ProfileName = '1080p (720p fallback)'

# Size targets in GiB per HOUR (what the Radarr UI sliders display).
# Radarr scales by actual runtime, so a 2h movie = 2x these numbers.
#   Bluray-1080p: pref 6.5 GiB/h -> ~13 GB preferred / 16 GB cap on a 2h film
#   720p:         pref 2.5 GiB/h -> ~5 GB on a 2h film
#
# KEEP IN SYNC with unraid/radarr-regrab.sh (TARGET_GIBH, BLURAY_LO/HI, WEB_LO/HI).
# The regrab script only accepts releases inside these windows, so widening one
# here without widening the other just means it finds nothing to grab.
$QualityDefinitionTargets = @(
    @{ Quality = 'Bluray-1080p'; MinGiBh = 3.0; PrefGiBh = 6.5; MaxGiBh = 8.0 }
    @{ Quality = 'WEBDL-1080p' ; MinGiBh = 2.0; PrefGiBh = 4.0; MaxGiBh = 6.0 }
    @{ Quality = 'WEBRip-1080p'; MinGiBh = 2.0; PrefGiBh = 4.0; MaxGiBh = 6.0 }
    @{ Quality = 'HDTV-1080p'  ; MinGiBh = 2.0; PrefGiBh = 3.5; MaxGiBh = 5.0 }
    @{ Quality = 'Bluray-720p' ; MinGiBh = 1.0; PrefGiBh = 2.5; MaxGiBh = 3.5 }
    @{ Quality = 'WEBDL-720p'  ; MinGiBh = 1.0; PrefGiBh = 2.5; MaxGiBh = 3.5 }
    @{ Quality = 'WEBRip-720p' ; MinGiBh = 1.0; PrefGiBh = 2.5; MaxGiBh = 3.5 }
)

# Enabled qualities, ASCENDING priority (last = best / top of the UI list).
# Entries with Group = list of quality names become a grouped tier.
$ProfileQualityOrder = @(
    @{ GroupName = 'WEB 720p' ; GroupId = 1001; Group = @('WEBRip-720p', 'WEBDL-720p') }
    @{ Quality = 'Bluray-720p' }
    @{ Quality = 'HDTV-1080p' }
    @{ GroupName = 'WEB 1080p'; GroupId = 1002; Group = @('WEBRip-1080p', 'WEBDL-1080p') }
    @{ Quality = 'Bluray-1080p' }   # <- top priority AND the upgrade cutoff
)
# UPGRADE CUTOFF. Not the highest quality - read on, this is counterintuitive.
#
# Radarr ranks a file purely by its POSITION in the items array and ignores the
# allowed flag entirely (QualityProfile.GetIndex never reads Allowed). "Cutoff
# unmet" therefore means "positioned below the cutoff", and Radarr will chase an
# upgrade for anything below it, unattended, on every RSS sync.
#
# Set this to Bluray-1080p (the intuitive choice, and what this script used to
# do) and every WEBDL-1080p file you own sits below the cutoff -> Radarr grabs
# Bluray-1080p replacements at up to 8 GiB/h against their current ~4 -> the
# library grows and quietly undoes the slimming.
#
# 'WEB 1080p' is the sweet spot for movies:
#   below it  -> Remux / BR-DISK / 2160p / SD, plus 720p and HDTV-1080p.
#                Those DO get upgraded, which is the point of a "720p fallback"
#                profile: a 720p file should become 1080p.
#   at/above  -> WEBDL-1080p, WEBRip-1080p, Bluray-1080p. Left alone. No churn.
$CutoffQualityName = 'WEB 1080p'   # the grouped tier, by name

# Custom format scores (matched by CF name; anything not listed scores 0).
$CustomFormatScores = @{
    'LQ'                = -10000
    'BR-DISK'           = -10000
    '3D'                = -10000
    'HD Bluray Tier 01' = 100
    'HD Bluray Tier 02' = 50
    'Repack/Proper'     = 5
    'Repack2'           = 6
    'Repack3'           = 7
}

$MinFormatScore = 0        # releases scoring below this are rejected outright

# MUST be 0. Radarr's CutoffNotMet is an OR: quality-cutoff-unmet OR
# custom-format-cutoff-unmet, where the CF test is `currentScore < CutoffFormatScore`.
# Your existing files score 0, so any positive value makes 0 < N true for EVERY
# movie in the library - permanently CF-cutoff-unmet - and Radarr keeps grabbing
# same-quality releases with a higher CF score, forever, on RSS sync. Each one is
# a full re-download and re-import, and it can land anywhere up to the size cap.
#
# Worse, that churn is INVISIBLE: Wanted > Cutoff Unmet is computed from quality
# only, so CF-driven re-grabs never show up in it.
#
# Setting this to 100 (as this script originally did) re-opens exactly the churn
# the cutoff above is there to prevent.
$CutoffFormatScore = 0

# =============================================================================
# Helpers
# =============================================================================

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')
if (-not $ApiKey) {
    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) { throw 'Pass -ApiKey, or install Microsoft.PowerShell.SecretManagement and Set-Secret -Name RadarrApiKey.' }
    $ApiKey = Get-Secret -Name RadarrApiKey -AsPlainText
}
$Headers = @{ 'X-Api-Key' = $ApiKey }

function Invoke-RadarrApi {
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
        # Invoke-RestMethod hands a JSON array back as ONE non-enumerated object.
        # Returning that directly means `Invoke-RadarrApi ... | Where-Object {...}`
        # sees a single item - the whole array - and `$_.name -eq 'x'` on an array
        # is truthy, so the filter matches EVERYTHING and $existing becomes every
        # profile. Bouncing it through a variable makes PowerShell unroll it.
        return $result
    }
    catch {
        Write-Host "API call failed: $Method $uri" -ForegroundColor Red
        if ($_.ErrorDetails.Message) {
            Write-Host $_.ErrorDetails.Message -ForegroundColor Red
        }
        throw
    }
}

# Radarr stores definition sizes as MB/minute; the UI displays GiB/hour.
function ConvertTo-MBPerMin([double]$GiBPerHour) {
    [math]::Round($GiBPerHour * 1024 / 60, 1)
}
function ConvertTo-GiBPerHour($MBPerMin) {
    if ($null -eq $MBPerMin) { return 'Unlimited' }
    '{0:N1}' -f ($MBPerMin * 60 / 1024)
}

$mode = if ($Apply) { 'APPLY' } else { 'DRY RUN (use -Apply to commit)' }
Write-Host "`n=== Radarr Quality Config | Mode: $mode ===" -ForegroundColor Cyan

# Sanity check connectivity + version
$status = Invoke-RadarrApi -Path 'system/status'
Write-Host "Connected to Radarr $($status.version) at $BaseUrl`n" -ForegroundColor Green

# =============================================================================
# Part 1: Quality Definitions
# =============================================================================

Write-Host '--- Quality Definitions ---' -ForegroundColor Cyan
$definitions = Invoke-RadarrApi -Path 'qualitydefinition'
$defChanges = @()

foreach ($target in $QualityDefinitionTargets) {
    $def = $definitions | Where-Object { $_.quality.name -eq $target.Quality }
    if (-not $def) {
        Write-Host "  ! Quality '$($target.Quality)' not found - skipping" -ForegroundColor Yellow
        continue
    }

    # Radarr requires min <= preferred <= max; a typo here otherwise fails with
    # an opaque 400 halfway through the loop, leaving definitions half-applied.
    if ($target.MinGiBh -gt $target.PrefGiBh -or $target.PrefGiBh -gt $target.MaxGiBh) {
        throw ("Bad size target for '{0}': min {1} / pref {2} / max {3} must be ascending." -f `
            $target.Quality, $target.MinGiBh, $target.PrefGiBh, $target.MaxGiBh)
    }

    $newMin  = ConvertTo-MBPerMin $target.MinGiBh
    $newPref = ConvertTo-MBPerMin $target.PrefGiBh
    $newMax  = ConvertTo-MBPerMin $target.MaxGiBh

    $line = '  {0,-14} {1,9} -> {2,-9} | {3,9} -> {4,-9} | {5,9} -> {6,-9}' -f `
        $target.Quality,
        (ConvertTo-GiBPerHour $def.minSize),       "$($target.MinGiBh) GiB/h",
        (ConvertTo-GiBPerHour $def.preferredSize), "$($target.PrefGiBh) GiB/h",
        (ConvertTo-GiBPerHour $def.maxSize),       "$($target.MaxGiBh) GiB/h"
    Write-Host $line

    # Radarr omits "Unlimited" size fields from its JSON entirely, so the
    # property may not exist on the object. Add-Member -Force creates or
    # overwrites it either way.
    $def | Add-Member -NotePropertyName minSize       -NotePropertyValue $newMin  -Force
    $def | Add-Member -NotePropertyName preferredSize -NotePropertyValue $newPref -Force
    $def | Add-Member -NotePropertyName maxSize       -NotePropertyValue $newMax  -Force
    $defChanges += $def
}
Write-Host '  (columns: min | preferred | max, current -> new)' -ForegroundColor DarkGray

if ($Apply -and $defChanges.Count -gt 0) {
    foreach ($def in $defChanges) {
        $null = Invoke-RadarrApi -Method 'PUT' -Path "qualitydefinition/$($def.id)" -Body $def
    }
    Write-Host "  Updated $($defChanges.Count) quality definitions." -ForegroundColor Green
}

# =============================================================================
# Part 2: Quality Profile
# =============================================================================

Write-Host "`n--- Quality Profile: $ProfileName ---" -ForegroundColor Cyan

# Schema gives us a template containing every quality + every custom format
$schema = Invoke-RadarrApi -Path 'qualityprofile/schema'

# Flatten schema items to individual quality entries (ungroup any defaults)
$allQualityItems = @()
foreach ($item in $schema.items) {
    if ($item.PSObject.Properties.Name -contains 'items' -and $item.items) {
        foreach ($sub in $item.items) { $allQualityItems += $sub }
    }
    else { $allQualityItems += $item }
}

function Get-QualityItem([string]$Name) {
    $found = $allQualityItems | Where-Object { $_.quality.name -eq $Name }
    if (-not $found) { throw "Quality '$Name' not found in Radarr schema." }
    return $found
}

$wantedNames = @()
foreach ($entry in $ProfileQualityOrder) {
    if ($entry.ContainsKey('Group')) { $wantedNames += $entry.Group }
    else { $wantedNames += $entry.Quality }
}

# Build items array: unwanted qualities first (allowed=false, schema order),
# then our enabled qualities/groups in ascending priority. Radarr's API stores
# items lowest-priority-first; the UI displays the list top = best.
$newItems = @()
foreach ($item in $allQualityItems) {
    if ($wantedNames -notcontains $item.quality.name) {
        $item.allowed = $false
        $newItems += $item
    }
}

$disallowedCount = $newItems.Count   # everything appended so far is allowed=false

$cutoffId = $null
foreach ($entry in $ProfileQualityOrder) {
    if ($entry.ContainsKey('Group')) {
        $groupItems = @()
        foreach ($qName in $entry.Group) {
            $qi = Get-QualityItem $qName
            $qi.allowed = $true
            $groupItems += $qi
        }
        $newItems += [pscustomobject]@{
            id      = $entry.GroupId
            name    = $entry.GroupName
            allowed = $true
            items   = $groupItems
        }
        if ($entry.GroupName -eq $CutoffQualityName) { $cutoffId = $entry.GroupId }
    }
    else {
        $qi = Get-QualityItem $entry.Quality
        $qi.allowed = $true
        $newItems += $qi
        if ($entry.Quality -eq $CutoffQualityName) { $cutoffId = $qi.quality.id }
    }
}
if ($null -eq $cutoffId) { throw "Cutoff quality '$CutoffQualityName' is not in the enabled list." }

# "Below the cutoff == disallowed + the tiers we deliberately want upgraded" only
# holds because the allowed items are contiguous at the top of the array. Radarr's
# Items.Take(cutoffIndex) is purely positional and never reads Allowed, so a
# violation here silently marks acceptable files as upgradeable and Radarr starts
# re-downloading them. Assert it rather than trust it.
for ($i = 0; $i -lt $newItems.Count; $i++) {
    $shouldBeAllowed = $i -ge $disallowedCount
    if ([bool]$newItems[$i].allowed -ne $shouldBeAllowed) {
        throw "Item ordering invariant violated at index $i - allowed items must be contiguous at the top."
    }
}
# The API only accepts a TOP-LEVEL id as the cutoff: a group by its group id, or
# a plain quality by its quality id. A quality nested INSIDE a group (e.g.
# WEBDL-1080p within 'WEB 1080p') is refused - QualityCutoffValidator never
# descends into groups - and the PUT 400s with "Cutoff must be an allowed quality
# or group".
$cutoffItem = $newItems | Where-Object {
    ($null -eq $_.quality -and $_.id -eq $cutoffId) -or ($_.quality.id -eq $cutoffId)
}
if (-not $cutoffItem -or -not $cutoffItem.allowed) {
    throw "Cutoff '$CutoffQualityName' (id $cutoffId) is not a top-level allowed item - Radarr will reject this profile."
}

# Custom format scores - warn about any configured name that doesn't exist
$existingCfNames = @($schema.formatItems | ForEach-Object { $_.name })
foreach ($cfName in $CustomFormatScores.Keys) {
    if ($existingCfNames -notcontains $cfName) {
        Write-Host "  ! Custom format '$cfName' not found in Radarr - score skipped" -ForegroundColor Yellow
    }
}
foreach ($fi in $schema.formatItems) {
    $fi.score = if ($CustomFormatScores.ContainsKey($fi.name)) { $CustomFormatScores[$fi.name] } else { 0 }
}

# Assemble the profile from the schema template (preserves any newer fields).
# Named $profileBody, not $profile - $PROFILE is a PowerShell automatic variable.
$profileBody = $schema
$profileBody.name              = $ProfileName
$profileBody.upgradeAllowed    = $true
$profileBody.cutoff            = $cutoffId
$profileBody.items             = $newItems
$profileBody.minFormatScore    = $MinFormatScore
$profileBody.cutoffFormatScore = $CutoffFormatScore

# Print summary
Write-Host '  Enabled qualities (top = most preferred):'
$display = @($ProfileQualityOrder)
[array]::Reverse($display)
foreach ($entry in $display) {
    $label  = if ($entry.ContainsKey('Group')) { "$($entry.GroupName)  [$($entry.Group -join ', ')]" } else { $entry.Quality }
    $isCut  = if ($entry.ContainsKey('Group')) { $entry.GroupName -eq $CutoffQualityName } else { $entry.Quality -eq $CutoffQualityName }
    $marker = if ($isCut) { '  <- CUTOFF (at or above this = left alone)' } else { '' }
    Write-Host ("    {0}{1}" -f $label, $marker) -ForegroundColor $(if ($isCut) { 'Yellow' } else { 'White' })
}
Write-Host '    Below the cutoff -> upgraded: 720p, HDTV-1080p, Remux, BR-DISK, 2160p, SD' -ForegroundColor DarkGray
Write-Host '  Custom format scores (non-zero):'
foreach ($kv in ($CustomFormatScores.GetEnumerator() | Sort-Object -Property Value -Descending)) {
    if ($existingCfNames -contains $kv.Key) {
        Write-Host ("    {0,-20} {1,7}" -f $kv.Key, $kv.Value)
    }
}
Write-Host "  Min format score: $MinFormatScore | Upgrade until score: $CutoffFormatScore"

# Create or update
$existing = Invoke-RadarrApi -Path 'qualityprofile' |
    Where-Object { $_.name -eq $ProfileName }

if ($Apply) {
    if ($existing) {
        if (-not $UpdateExistingProfile) {
            Write-Host "`n  Profile '$ProfileName' already exists. Re-run with -UpdateExistingProfile to overwrite." -ForegroundColor Yellow
        }
        else {
            $profileBody | Add-Member -NotePropertyName id -NotePropertyValue $existing.id -Force
            $null = Invoke-RadarrApi -Method 'PUT' -Path "qualityprofile/$($existing.id)" -Body $profileBody
            Write-Host "`n  Updated existing profile '$ProfileName' (id $($existing.id))." -ForegroundColor Green
        }
    }
    else {
        $created = Invoke-RadarrApi -Method 'POST' -Path 'qualityprofile' -Body $profileBody
        Write-Host "`n  Created profile '$ProfileName' (id $($created.id))." -ForegroundColor Green
    }
}
elseif ($existing) {
    Write-Host "`n  NOTE: profile '$ProfileName' already exists (id $($existing.id))." -ForegroundColor Yellow
    Write-Host '  On -Apply, add -UpdateExistingProfile to overwrite it.' -ForegroundColor Yellow
}

Write-Host "`nDone. $(if (-not $Apply) { 'No changes were made (dry run).' })" -ForegroundColor Cyan
