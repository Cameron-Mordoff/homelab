<#
.SYNOPSIS
    Configures Sonarr quality definitions (global size caps) and creates the
    "1080p TV (720p fallback)" and "720p TV" quality profiles.

.DESCRIPTION
    Two things happen (both support dry-run):

    1. Quality Definitions (Settings > Quality)
       Sets Min / Preferred / Max size-per-hour for the 720p/1080p qualities.

       THIS IS THE PART THAT STOPS THE BLEEDING. In Sonarr, size limits are
       GLOBAL - they live on the quality definition, not the profile. An
       uncapped Bluray-1080p is how a 6-episode documentary ends up at 12 GiB/h
       and 147 GB even while sitting on a "1080p HD" profile. Capping the
       definitions is what prevents the bloat from coming straight back after
       you re-grab.

    2. Quality Profiles (Settings > Profiles)
         - "1080p TV (720p fallback)" - the default for most shows
         - "720p TV"                  - for long-running, low-payoff shows
                                        (reality TV, long sitcoms)

       Bluray-1080p Remux is deliberately NOT allowed in either profile. Remux
       is untouched Blu-ray video; there is no quality argument for it on a TV
       library and it is where the bulk of the waste came from.

    NOTE: quality definitions are global and affect EVERY series, including any
    on other profiles (Any / Kids / TRaSH). That is intentional here - it is the
    only place Sonarr lets you enforce a size ceiling.

.PARAMETER Apply
    Actually write changes. Without this switch the script is a DRY RUN.

.PARAMETER UpdateExistingProfile
    If a profile with the same name exists, update it in place instead of skipping.

.PARAMETER SkipDefinitions
    Only touch the profiles, leave the global size caps alone.

.EXAMPLE
    .\Set-SonarrQualityConfig.ps1 -BaseUrl http://192.168.1.50:8989 -ApiKey xxxx
    # Dry run - review the output

.EXAMPLE
    .\Set-SonarrQualityConfig.ps1 -BaseUrl http://192.168.1.50:8989 -ApiKey xxxx -Apply -UpdateExistingProfile
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [switch]$Apply,
    [switch]$UpdateExistingProfile,
    [switch]$SkipDefinitions,
    [switch]$SkipProfiles
)

# =============================================================================
# CONFIG - edit these to taste
# =============================================================================

# Size targets in GiB per HOUR. Sonarr stores MB/minute; its UI shows the
# GB/hour figure next to the slider, so these are what you'll see in the web UI.
#
# Calibrated against the library as measured: median 2.08 GiB/h, existing
# WEBDL-1080p averaging 2.75 and Bluray-1080p 2.44. A 3.0 preferred / 4.5 max
# on Bluray-1080p is therefore comfortably above what good releases actually
# land at, while shutting out the 10-18 GiB/h remux-tier files.
$QualityDefinitionTargets = @(
    @{ Quality = 'Bluray-1080p'; MinGiBh = 1.0; PrefGiBh = 3.0; MaxGiBh = 4.5 }
    @{ Quality = 'WEBDL-1080p' ; MinGiBh = 0.8; PrefGiBh = 2.8; MaxGiBh = 4.0 }
    @{ Quality = 'WEBRip-1080p'; MinGiBh = 0.8; PrefGiBh = 2.8; MaxGiBh = 4.0 }
    @{ Quality = 'HDTV-1080p'  ; MinGiBh = 0.8; PrefGiBh = 2.5; MaxGiBh = 3.5 }
    @{ Quality = 'Bluray-720p' ; MinGiBh = 0.5; PrefGiBh = 1.5; MaxGiBh = 2.5 }
    @{ Quality = 'WEBDL-720p'  ; MinGiBh = 0.4; PrefGiBh = 1.5; MaxGiBh = 2.2 }
    @{ Quality = 'WEBRip-720p' ; MinGiBh = 0.4; PrefGiBh = 1.5; MaxGiBh = 2.2 }
    @{ Quality = 'HDTV-720p'   ; MinGiBh = 0.4; PrefGiBh = 1.2; MaxGiBh = 2.0 }
)

# Enabled qualities per profile, ASCENDING priority (last = best / top of UI).
# Entries with Group = list of quality names become a grouped tier.
#
# Sonarr's remux is named 'Bluray-1080p Remux' (Radarr calls its equivalent
# 'Remux-1080p'). It is absent from both lists on purpose.
$Profiles = @(
    @{
        Name  = '1080p TV (720p fallback)'
        Order = @(
            @{ GroupName = 'WEB 720p' ; GroupId = 1001; Group = @('WEBRip-720p', 'WEBDL-720p') }
            @{ Quality = 'Bluray-720p' }
            @{ Quality = 'HDTV-1080p' }
            @{ GroupName = 'WEB 1080p'; GroupId = 1002; Group = @('WEBRip-1080p', 'WEBDL-1080p') }
            @{ Quality = 'Bluray-1080p' }   # <- most preferred
        )
    }
    @{
        Name  = '720p TV'
        Order = @(
            @{ Quality = 'HDTV-720p' }
            @{ GroupName = 'WEB 720p'; GroupId = 1001; Group = @('WEBRip-720p', 'WEBDL-720p') }
            @{ Quality = 'Bluray-720p' }
        )
    }
)

# THE CUTOFF IS THE LOWEST ALLOWED QUALITY, NOT THE HIGHEST. This is the single
# most important line in the file, and it is the opposite of what you'd expect.
#
# Sonarr ranks a file purely by its POSITION in the items array and ignores the
# allowed flag (QualityProfile.GetIndex never reads Allowed). This script writes
# every DISALLOWED quality first, then the allowed ones ascending. "Cutoff unmet"
# is then, exactly, "positioned below the cutoff" (EpisodeCutoffService does
# Items.Take(cutoffIndex)).
#
# Set cutoff = HIGHEST allowed (the intuitive choice, and what this script used
# to do) and every WEBDL-1080p file you own is below it => Sonarr chases
# Bluray-1080p upgrades on your whole library and it GROWS.
#
# Set cutoff = LOWEST allowed and the below-cutoff set is precisely the
# disallowed block - remux, 2160p, SD, DVD, Raw-HD, Unknown. Those get replaced;
# everything already acceptable is left completely alone. That is a shrink.
$CutoffPolicy = 'lowest'   # 'lowest' = shrink only. Don't change this casually.

# Custom format scores (matched by CF name; anything not listed scores 0).
# Sonarr only has custom formats from v4 onward - on older builds the script
# detects their absence and skips this section rather than failing.
$CustomFormatScores = @{
    'LQ'                   = -10000
    'LQ (Release Title)'   = -10000
    'BR-DISK'              = -10000
    'Extras'               = -10000
    'Repack/Proper'        = 5
    'Repack v2'            = 6
    'Repack v3'            = 7

    # NOT scoring 'x265 (HD)' at -10000, which is the usual TRaSH recommendation.
    # That guidance exists because HD x265 releases are often lazy re-encodes of a
    # WEB source. But in THIS library x265 is 1240 files averaging 1.92 GiB/h,
    # against 3.74 for h264 - the x265 content is what is keeping the library
    # lean, and blocking it would push every future grab to h264 and GROW the
    # library. Left neutral so the size caps above do the work instead.
    # Uncomment if you ever decide the encode quality bothers you:
    # 'x265 (HD)'          = -10000
}

$MinFormatScore = 0        # releases scoring below this are rejected outright

# MUST be 0. Sonarr's CutoffNotMet is an OR: quality-cutoff-unmet OR
# custom-format-cutoff-unmet, where the CF test is `currentScore < CutoffFormatScore`.
# Your existing files score 0, so ANY positive value here makes 0 < N true for
# every episode in the library - permanently CF-cutoff-unmet, and the quality
# cutoff above becomes irrelevant. Setting this to 10000 (as this script
# originally did) re-opens exactly the upgrade churn the cutoff policy prevents.
$CutoffFormatScore = 0

# =============================================================================
# Helpers
# =============================================================================

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
        # Invoke-RestMethod hands a JSON array back as ONE non-enumerated object.
        # Returning it directly means `Invoke-SonarrApi ... | Where-Object {...}`
        # sees a single item - the whole array - and `$_.name -eq 'x'` on an array
        # is truthy, so the filter matches EVERYTHING. Bounce it through a
        # variable so PowerShell unrolls it.
        return $result
    }
    catch {
        Write-Host "API call failed: $Method $uri" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
        throw
    }
}

# Sonarr stores definition sizes as MB/minute; the UI displays GB/hour.
function ConvertTo-MBPerMin([double]$GiBPerHour) { [math]::Round($GiBPerHour * 1024 / 60, 1) }
function ConvertTo-GiBPerHour($MBPerMin) {
    if ($null -eq $MBPerMin) { return 'Unlimited' }
    '{0:N1}' -f ($MBPerMin * 60 / 1024)
}

$mode = if ($Apply) { 'APPLY' } else { 'DRY RUN (use -Apply to commit)' }
Write-Host "`n=== Sonarr Quality Config | Mode: $mode ===" -ForegroundColor Cyan

$status = Invoke-SonarrApi -Path 'system/status'
Write-Host "Connected to Sonarr $($status.version) at $BaseUrl`n" -ForegroundColor Green

# =============================================================================
# Part 1: Quality Definitions (the global size caps)
# =============================================================================

if (-not $SkipDefinitions) {
    Write-Host '--- Quality Definitions (GLOBAL - affects every series) ---' -ForegroundColor Cyan

    # Sonarr clamps definition sizes to an instance-specific ceiling, and that
    # ceiling changed between versions (older builds capped at 400 MB/min, newer
    # at 1000). Ask rather than hardcode; fall back quietly on older builds that
    # lack the endpoint.
    $limitMax = $null
    try {
        $limits = Invoke-SonarrApi -Path 'qualitydefinition/limits'
        if ($limits.max) { $limitMax = [double]$limits.max }
    } catch {
        Write-Verbose 'qualitydefinition/limits not available on this Sonarr build.'
    }

    $definitions = Invoke-SonarrApi -Path 'qualitydefinition'
    $defChanges = @()

    foreach ($target in $QualityDefinitionTargets) {
        $def = $definitions | Where-Object { $_.quality.name -eq $target.Quality }
        if (-not $def) {
            Write-Host "  ! Quality '$($target.Quality)' not found - skipping" -ForegroundColor Yellow
            continue
        }

        if ($target.MinGiBh -gt $target.PrefGiBh -or $target.PrefGiBh -gt $target.MaxGiBh) {
            throw ("Bad size target for '{0}': min {1} / pref {2} / max {3} must be ascending." -f `
                $target.Quality, $target.MinGiBh, $target.PrefGiBh, $target.MaxGiBh)
        }

        $newMin  = ConvertTo-MBPerMin $target.MinGiBh
        $newPref = ConvertTo-MBPerMin $target.PrefGiBh
        $newMax  = ConvertTo-MBPerMin $target.MaxGiBh

        if ($null -ne $limitMax -and $newMax -gt $limitMax) {
            Write-Host ("  ! {0}: max {1} MB/min exceeds this Sonarr's ceiling of {2} - clamping" -f `
                $target.Quality, $newMax, $limitMax) -ForegroundColor Yellow
            $newMax = $limitMax
        }

        Write-Host ('  {0,-14} {1,9} -> {2,-9} | {3,9} -> {4,-9} | {5,9} -> {6,-9}' -f `
            $target.Quality,
            (ConvertTo-GiBPerHour $def.minSize),       "$($target.MinGiBh) GiB/h",
            (ConvertTo-GiBPerHour $def.preferredSize), "$($target.PrefGiBh) GiB/h",
            (ConvertTo-GiBPerHour $def.maxSize),       "$($target.MaxGiBh) GiB/h")

        # Sonarr omits "Unlimited" size fields from its JSON entirely, so the
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
            $null = Invoke-SonarrApi -Method 'PUT' -Path "qualitydefinition/$($def.id)" -Body $def
        }
        Write-Host "  Updated $($defChanges.Count) quality definitions." -ForegroundColor Green
    }
}

# =============================================================================
# Part 2: Quality Profiles
# =============================================================================

if ($SkipProfiles) { Write-Host "`nDone (profiles skipped)." -ForegroundColor Cyan; return }

$schema        = Invoke-SonarrApi -Path 'qualityprofile/schema'
$existingProfs = Invoke-SonarrApi -Path 'qualityprofile'

$hasCustomFormats = $schema.PSObject.Properties.Name -contains 'formatItems' -and $schema.formatItems
if (-not $hasCustomFormats) {
    Write-Host "`n  ! This Sonarr build has no custom formats - skipping CF scores." -ForegroundColor Yellow
}
else {
    $existingCfNames = @($schema.formatItems | ForEach-Object { $_.name })
    foreach ($cfName in $CustomFormatScores.Keys) {
        if ($existingCfNames -notcontains $cfName) {
            Write-Host "  ! Custom format '$cfName' not found in Sonarr - score skipped" -ForegroundColor Yellow
        }
    }
}

foreach ($p in $Profiles) {
    Write-Host "`n--- Quality Profile: $($p.Name) ---" -ForegroundColor Cyan

    # Re-fetch the schema each time: we mutate it into the profile body below,
    # so reusing one copy would leak the previous profile's items into the next.
    $sch = Invoke-SonarrApi -Path 'qualityprofile/schema'

    # Flatten schema items to individual quality entries (ungroup any defaults)
    $allQualityItems = @()
    foreach ($item in $sch.items) {
        if ($item.PSObject.Properties.Name -contains 'items' -and $item.items) {
            foreach ($sub in $item.items) { $allQualityItems += $sub }
        }
        else { $allQualityItems += $item }
    }

    function Get-QualityItem([string]$Name) {
        $found = $allQualityItems | Where-Object { $_.quality.name -eq $Name }
        if (-not $found) { throw "Quality '$Name' not found in Sonarr schema." }
        return $found
    }

    $wantedNames = @()
    foreach ($entry in $p.Order) {
        if ($entry.ContainsKey('Group')) { $wantedNames += $entry.Group }
        else { $wantedNames += $entry.Quality }
    }

    # Build items array: unwanted qualities first (allowed=false, schema order),
    # then our enabled qualities/groups in ascending priority. Sonarr's API stores
    # items lowest-priority-first; the UI displays the list top = best.
    $newItems = @()
    foreach ($item in $allQualityItems) {
        if ($wantedNames -notcontains $item.quality.name) {
            $item.allowed = $false
            $newItems += $item
        }
    }

    $disallowedCount = $newItems.Count   # everything appended so far is allowed=false

    foreach ($entry in $p.Order) {
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
        }
        else {
            $qi = Get-QualityItem $entry.Quality
            $qi.allowed = $true
            $newItems += $qi
        }
    }

    # Cutoff = the FIRST allowed item (see $CutoffPolicy above). Note the API
    # only accepts a top-level id: a GROUP is referenced by its group id, and a
    # quality nested INSIDE a group can never be the cutoff - QualityCutoffValidator
    # doesn't descend into groups and the PUT 400s with "Cutoff must be an
    # allowed quality or group".
    $first = $newItems[$disallowedCount]
    $cutoffId = if ($first.PSObject.Properties.Name -contains 'items' -and $first.items) {
        $first.id                # grouped tier -> the group's own id
    } else {
        $first.quality.id        # plain quality
    }
    $cutoffName = if ($first.name) { $first.name } else { $first.quality.name }

    # The "below cutoff == disallowed" equivalence only holds because the allowed
    # items are contiguous at the top. Assert it rather than trust it - a silent
    # violation here means Sonarr re-downloads files you wanted left alone.
    for ($i = 0; $i -lt $newItems.Count; $i++) {
        $shouldBeAllowed = $i -ge $disallowedCount
        if ([bool]$newItems[$i].allowed -ne $shouldBeAllowed) {
            throw "Item ordering invariant violated in '$($p.Name)' at index $i - allowed items must be contiguous at the top."
        }
    }
    if ($null -eq $cutoffId) { throw "Could not resolve a cutoff for '$($p.Name)'." }

    if ($hasCustomFormats) {
        foreach ($fi in $sch.formatItems) {
            $fi.score = if ($CustomFormatScores.ContainsKey($fi.name)) { $CustomFormatScores[$fi.name] } else { 0 }
        }
    }

    # Assemble from the schema template (preserves any newer fields Sonarr adds).
    # Named $profileBody, not $profile - $PROFILE is a PowerShell automatic variable.
    $profileBody = $sch
    $profileBody.name           = $p.Name
    $profileBody.upgradeAllowed = $true
    $profileBody.cutoff         = $cutoffId
    $profileBody.items          = $newItems
    if ($hasCustomFormats) {
        $profileBody.minFormatScore    = $MinFormatScore
        $profileBody.cutoffFormatScore = $CutoffFormatScore
    }

    Write-Host '  Enabled qualities (top = most preferred):'
    $display = @($p.Order)
    [array]::Reverse($display)
    foreach ($entry in $display) {
        $label  = if ($entry.ContainsKey('Group')) { "$($entry.GroupName)  [$($entry.Group -join ', ')]" } else { $entry.Quality }
        $isCut  = if ($entry.ContainsKey('Group')) { $entry.GroupName -eq $cutoffName } else { $entry.Quality -eq $cutoffName }
        $marker = if ($isCut) { '  <- CUTOFF (anything at or above this is left alone)' } else { '' }
        Write-Host ("    {0}{1}" -f $label, $marker) -ForegroundColor $(if ($isCut) { 'Yellow' } else { 'White' })
    }
    Write-Host '    (Bluray-1080p Remux deliberately NOT allowed)' -ForegroundColor DarkGray
    Write-Host "    Below the cutoff -> gets replaced: remux, 2160p, SD/DVD, Raw-HD, Unknown" -ForegroundColor DarkGray

    $existing = $existingProfs | Where-Object { $_.name -eq $p.Name }

    if ($Apply) {
        if ($existing) {
            if (-not $UpdateExistingProfile) {
                Write-Host "  Profile already exists (id $($existing.id)). Re-run with -UpdateExistingProfile to overwrite." -ForegroundColor Yellow
            }
            else {
                $profileBody | Add-Member -NotePropertyName id -NotePropertyValue $existing.id -Force
                $null = Invoke-SonarrApi -Method 'PUT' -Path "qualityprofile/$($existing.id)" -Body $profileBody
                Write-Host "  Updated existing profile (id $($existing.id))." -ForegroundColor Green
            }
        }
        else {
            $created = Invoke-SonarrApi -Method 'POST' -Path 'qualityprofile' -Body $profileBody
            Write-Host "  Created profile (id $($created.id))." -ForegroundColor Green
        }
    }
    elseif ($existing) {
        Write-Host "  NOTE: profile already exists (id $($existing.id)). On -Apply, add -UpdateExistingProfile to overwrite." -ForegroundColor Yellow
    }
    else {
        Write-Host '  Would be created.' -ForegroundColor DarkGray
    }
}

Write-Host "`nDone. $(if (-not $Apply) { 'No changes were made (dry run).' })" -ForegroundColor Cyan
if (-not $Apply) {
    Write-Host 'Next: assign series to these profiles, then re-grab the bloated shows.' -ForegroundColor DarkGray
}
