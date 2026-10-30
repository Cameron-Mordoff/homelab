<#
.SYNOPSIS
    Configures the radarr-4k instance: custom formats, 2160p quality definitions
    and a "2160p HDR" quality profile for a small, direct-play 4K library.

.DESCRIPTION
    Three things happen (all support dry-run):

    1. Custom formats
       - HDR / audio / release-tier / unwanted CFs imported from TRaSH Guides JSON,
         pinned to one commit ($TrashCommit) so re-runs are reproducible.
       - The anti-fake CFs (No-RlsGroup, Obfuscated, Retags, Bad Dual Groups,
         LQ (Release Title), Hardsub) cloned from the main 1080p Radarr, so both
         instances reject the same junk.
       Existing CFs with the same name are updated in place.

    2. Quality Definitions (Settings > Quality) for the 2160p qualities only.
       Quality definitions are per instance, so this never touches the 1080p Radarr.

    3. Quality Profile "2160p HDR"
       - One tier: Bluray-2160p + WEBDL-2160p + WEBRip-2160p (no Remux, no 1080p).
         Grouping them makes custom format scores - not the source - pick the release.
       - Ranking: Dolby Vision > lossless audio > release-group tier.
       - SDR 2160p, DV without an HDR10 fallback, AV1, BR-DISK, upscales and the
         anti-fake CFs are rejected.

    Playback target: Apple TV 4K + Infuse direct play (see BookStack "4K & Home
    Theater Primer"). Lossless audio is preferred even though the current soundbar
    can't use it, so a future eARC/Atmos upgrade doesn't need a re-download.

.PARAMETER BaseUrl
    radarr-4k base URL.

.PARAMETER ApiKey
    radarr-4k API key. Defaults to the Radarr4kApiKey secret.

.PARAMETER SourceBaseUrl
    Main (1080p) Radarr, used only to read the anti-fake custom formats.

.PARAMETER SourceApiKey
    Main Radarr API key. Defaults to the RadarrApiKey secret.

.PARAMETER Apply
    Actually write changes. Without this switch the script is a DRY RUN.

.PARAMETER UpdateExistingProfile
    If the profile already exists, update it in place instead of aborting.

.EXAMPLE
    .\Set-Radarr4kProfile.ps1
    # Dry run against http://192.168.1.10:7879

.EXAMPLE
    .\Set-Radarr4kProfile.ps1 -Apply
#>

[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://192.168.1.10:7879',
    [string]$ApiKey,
    [string]$SourceBaseUrl = 'http://192.168.1.10:7878',
    [string]$SourceApiKey,
    [switch]$Apply,
    [switch]$UpdateExistingProfile
)

# =============================================================================
# CONFIG - edit these to taste
# =============================================================================

$ProfileName = '2160p HDR'

# TRaSH Guides commit the CF JSON is read from. Bump deliberately, not by default.
$TrashCommit = 'd24f13ceea5e82ccc20d08b7814fca93840e4046'
$TrashCfUrl  = "https://raw.githubusercontent.com/TRaSH-Guides/Guides/$TrashCommit/docs/json/radarr/cf"

# TRaSH CF file slug -> score. Scale is deliberate:
#   DV (1000) beats any audio/tier combination, so a DV release always wins over
#   an HDR10-only one (the TV and Apple TV both do DV).
#   Lossless audio (300-400) beats the release-group tier (150-300) beats repacks.
$TrashCfScores = [ordered]@{
    # HDR
    'hdr'                = 500     # any HDR format; minFormatScore below makes this effectively required
    'dv-boost'           = 1000
    'hdr10plus-boost'    = 100
    'sdr'                = -10000  # 2160p with no HDR tag
    'dv-wo-hdr-fallback' = -10000  # DV profile 5 WEB: no HDR10 base layer, breaks anything that has to tonemap
    # Audio (TRaSH audio CFs are mutually exclusive)
    'truehd-atmos'       = 400
    'dts-x'              = 375
    'truehd'             = 300
    'dts-hd-ma'          = 300
    'flac'               = 250
    'pcm'                = 250
    'atmos-undefined'    = 200
    'ddplus-atmos'       = 200
    'dts-hd-hra'         = 150
    'ddplus'             = 100
    'dts-es'             = 75
    'dts'                = 50
    'dd'                 = 25
    # Release-group tiers
    'uhd-bluray-tier-01' = 300
    'uhd-bluray-tier-02' = 275
    'uhd-bluray-tier-03' = 250
    'web-tier-01'        = 200
    'web-tier-02'        = 175
    'web-tier-03'        = 150
    'repack-proper'      = 5
    'repack2'            = 6
    'repack3'            = 7
    # Unwanted
    'br-disk'            = -10000
    'lq'                 = -10000
    '3d'                 = -10000
    'upscaled'           = -10000
    'av1'                = -10000  # no AV1 hardware decode on the Apple TV
}

# Cloned from the main Radarr by name (Hardsub is custom, not TRaSH).
$SourceCfScores = [ordered]@{
    'No-RlsGroup'        = -10000
    'Obfuscated'         = -10000
    'Retags'             = -10000
    'Bad Dual Groups'    = -10000
    'LQ (Release Title)' = -10000
    'Hardsub'            = -10000
}

# Size targets in GiB per HOUR (what the Radarr UI sliders display).
# Radarr scales by runtime: a 2h film caps at ~44 GiB Bluray / ~36 GiB WEB,
# a 3h epic at ~66 / ~54. Remuxes (50-80 GB) are excluded by quality, not size.
$QualityDefinitionTargets = @(
    @{ Quality = 'Bluray-2160p'; MinGiBh = 6.0; PrefGiBh = 15.0; MaxGiBh = 22.0 }
    @{ Quality = 'WEBDL-2160p' ; MinGiBh = 4.0; PrefGiBh = 10.0; MaxGiBh = 18.0 }
    @{ Quality = 'WEBRip-2160p'; MinGiBh = 4.0; PrefGiBh = 10.0; MaxGiBh = 18.0 }
)

$GroupName = '2160p'
$GroupId   = 1001
$GroupQualities = @('WEBRip-2160p', 'WEBDL-2160p', 'Bluray-2160p')

# Every acceptable release carries the HDR CF (+500), so 500 doubles as
# "HDR required": an untagged 2160p release that slips past the SDR CF still fails.
$MinFormatScore = 500

# Unlike the 1080p profile (which MUST keep this at 0 - see Set-RadarrQualityConfig.ps1),
# this library is new and tiny, and upgrading HDR10 -> DV is the point. 2000 is met
# by DV + HDR + lossless audio + a decent tier; anything below keeps upgrading, but
# each grab must beat the current file by MinUpgradeFormatScore, so it can't loop.
$CutoffFormatScore     = 2000
$MinUpgradeFormatScore = 50

$ProfileLanguage = @{ id = -2; name = 'Original' }

# =============================================================================
# Helpers
# =============================================================================

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')
$SourceBaseUrl = $SourceBaseUrl.TrimEnd('/')
if (-not $ApiKey)       { $ApiKey       = Get-Secret -Name Radarr4kApiKey -AsPlainText }
if (-not $SourceApiKey) { $SourceApiKey = Get-Secret -Name RadarrApiKey -AsPlainText }

function Invoke-RadarrApi {
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory = $true)][string]$Path,
        $Body = $null,
        [string]$Url = $BaseUrl,
        [string]$Key = $ApiKey
    )
    $uri = "$Url/api/v3/$Path"
    $params = @{ Uri = $uri; Method = $Method; Headers = @{ 'X-Api-Key' = $Key } }
    if ($null -ne $Body) {
        $params.Body = $Body | ConvertTo-Json -Depth 20
        $params.ContentType = 'application/json'
    }
    try {
        # Bounce through a variable so a JSON array unrolls (see Set-RadarrQualityConfig.ps1).
        $result = Invoke-RestMethod @params
        return $result
    }
    catch {
        Write-Host "API call failed: $Method $uri" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
        throw
    }
}

function ConvertTo-MBPerMin([double]$GiBPerHour) { [math]::Round($GiBPerHour * 1024 / 60, 1) }
function ConvertTo-GiBPerHour($MBPerMin) {
    if ($null -eq $MBPerMin) { return 'Unlimited' }
    '{0:N1}' -f ($MBPerMin * 60 / 1024)
}

# TRaSH JSON stores spec fields as an object ({ "value": ... }); the Radarr API
# wants an array of { name, value }.
function ConvertFrom-TrashCf($Json) {
    [pscustomobject]@{
        name                            = $Json.name
        includeCustomFormatWhenRenaming = [bool]$Json.includeCustomFormatWhenRenaming
        specifications                  = @($Json.specifications | ForEach-Object {
            [pscustomobject]@{
                name           = $_.name
                implementation = $_.implementation
                negate         = [bool]$_.negate
                required       = [bool]$_.required
                fields         = @($_.fields.PSObject.Properties | ForEach-Object { @{ name = $_.Name; value = $_.Value } })
            }
        })
    }
}

$mode = if ($Apply) { 'APPLY' } else { 'DRY RUN (use -Apply to commit)' }
Write-Host "`n=== Radarr 4K Config | Mode: $mode ===" -ForegroundColor Cyan
$status = Invoke-RadarrApi -Path 'system/status'
if ($status.instanceName -notmatch '4K') { throw "Refusing to run: $BaseUrl is '$($status.instanceName)', not the 4K instance." }
Write-Host "Connected to $($status.instanceName) $($status.version) at $BaseUrl`n" -ForegroundColor Green

# =============================================================================
# Part 1: Custom Formats
# =============================================================================

Write-Host '--- Custom Formats ---' -ForegroundColor Cyan
$wanted = [ordered]@{}   # CF name -> @{ Body; Score }
foreach ($slug in $TrashCfScores.Keys) {
    $json = Invoke-RestMethod "$TrashCfUrl/$slug.json"
    $wanted[$json.name] = @{ Body = (ConvertFrom-TrashCf $json); Score = $TrashCfScores[$slug] }
}
$sourceCfs = Invoke-RadarrApi -Path 'customformat' -Url $SourceBaseUrl -Key $SourceApiKey
foreach ($name in $SourceCfScores.Keys) {
    $cf = $sourceCfs | Where-Object { $_.name -eq $name }
    if (-not $cf) { throw "Custom format '$name' not found in the main Radarr." }
    $cf.PSObject.Properties.Remove('id')
    $wanted[$name] = @{ Body = $cf; Score = $SourceCfScores[$name] }
}

$existingCfs = @(Invoke-RadarrApi -Path 'customformat')
foreach ($name in $wanted.Keys) {
    $body = $wanted[$name].Body
    $current = $existingCfs | Where-Object { $_.name -eq $name }
    Write-Host ("  {0,-8} {1,-24} {2,7}" -f $(if ($current) { 'update' } else { 'create' }), $name, $wanted[$name].Score)
    if (-not $Apply) { continue }
    if ($current) {
        $body | Add-Member -NotePropertyName id -NotePropertyValue $current.id -Force
        $null = Invoke-RadarrApi -Method 'PUT' -Path "customformat/$($current.id)" -Body $body
    }
    else {
        $null = Invoke-RadarrApi -Method 'POST' -Path 'customformat' -Body $body
    }
}

# =============================================================================
# Part 2: Quality Definitions
# =============================================================================

Write-Host "`n--- Quality Definitions ---" -ForegroundColor Cyan
$definitions = Invoke-RadarrApi -Path 'qualitydefinition'
foreach ($target in $QualityDefinitionTargets) {
    $def = $definitions | Where-Object { $_.quality.name -eq $target.Quality }
    if (-not $def) { throw "Quality '$($target.Quality)' not found." }
    if ($target.MinGiBh -gt $target.PrefGiBh -or $target.PrefGiBh -gt $target.MaxGiBh) {
        throw "Bad size target for '$($target.Quality)': min/pref/max must be ascending."
    }
    Write-Host ('  {0,-14} {1,9} -> {2,-9} | {3,9} -> {4,-9} | {5,9} -> {6,-9}' -f $target.Quality,
        (ConvertTo-GiBPerHour $def.minSize),       "$($target.MinGiBh) GiB/h",
        (ConvertTo-GiBPerHour $def.preferredSize), "$($target.PrefGiBh) GiB/h",
        (ConvertTo-GiBPerHour $def.maxSize),       "$($target.MaxGiBh) GiB/h")
    # Unlimited size fields are omitted from the JSON, hence Add-Member -Force.
    $def | Add-Member -NotePropertyName minSize       -NotePropertyValue (ConvertTo-MBPerMin $target.MinGiBh)  -Force
    $def | Add-Member -NotePropertyName preferredSize -NotePropertyValue (ConvertTo-MBPerMin $target.PrefGiBh) -Force
    $def | Add-Member -NotePropertyName maxSize       -NotePropertyValue (ConvertTo-MBPerMin $target.MaxGiBh)  -Force
    if ($Apply) { $null = Invoke-RadarrApi -Method 'PUT' -Path "qualitydefinition/$($def.id)" -Body $def }
}
Write-Host '  (columns: min | preferred | max, current -> new)' -ForegroundColor DarkGray

# =============================================================================
# Part 3: Quality Profile
# =============================================================================

Write-Host "`n--- Quality Profile: $ProfileName ---" -ForegroundColor Cyan
# Schema after the CF writes, so formatItems includes the new CFs. On a dry run
# CFs not yet created are simply absent - the score list above is the preview.
$schema = Invoke-RadarrApi -Path 'qualityprofile/schema'

$allQualityItems = @()
foreach ($item in $schema.items) {
    if ($item.PSObject.Properties.Name -contains 'items' -and $item.items) { $allQualityItems += $item.items }
    else { $allQualityItems += $item }
}

# Disallowed qualities first, the single allowed group last (= top of the UI list).
# Same positional invariant as the 1080p profile: allowed items contiguous at the top.
$newItems = @($allQualityItems | Where-Object { $GroupQualities -notcontains $_.quality.name } |
    ForEach-Object { $_.allowed = $false; $_ })
$groupItems = foreach ($q in $GroupQualities) {
    $qi = $allQualityItems | Where-Object { $_.quality.name -eq $q }
    if (-not $qi) { throw "Quality '$q' not found in Radarr schema." }
    $qi.allowed = $true; $qi
}
$newItems += [pscustomobject]@{ id = $GroupId; name = $GroupName; allowed = $true; items = @($groupItems) }

foreach ($fi in $schema.formatItems) {
    $fi.score = if ($wanted.Contains($fi.name)) { $wanted[$fi.name].Score } else { 0 }
}

$profileBody = $schema
$profileBody.name                  = $ProfileName
$profileBody.upgradeAllowed        = $true
$profileBody.cutoff                = $GroupId
$profileBody.items                 = $newItems
$profileBody.minFormatScore        = $MinFormatScore
$profileBody.cutoffFormatScore     = $CutoffFormatScore
$profileBody.minUpgradeFormatScore = $MinUpgradeFormatScore
$profileBody.language              = $ProfileLanguage

Write-Host "  Allowed: $GroupName [$($GroupQualities -join ', ')]  <- cutoff"
Write-Host "  Min format score: $MinFormatScore | Upgrade until: $CutoffFormatScore | Min upgrade step: $MinUpgradeFormatScore | Language: $($ProfileLanguage.name)"

$existing = Invoke-RadarrApi -Path 'qualityprofile' | Where-Object { $_.name -eq $ProfileName }
if ($Apply) {
    if ($existing -and -not $UpdateExistingProfile) {
        Write-Host "`n  Profile '$ProfileName' already exists. Re-run with -UpdateExistingProfile to overwrite." -ForegroundColor Yellow
    }
    elseif ($existing) {
        $profileBody | Add-Member -NotePropertyName id -NotePropertyValue $existing.id -Force
        $null = Invoke-RadarrApi -Method 'PUT' -Path "qualityprofile/$($existing.id)" -Body $profileBody
        Write-Host "`n  Updated profile '$ProfileName' (id $($existing.id))." -ForegroundColor Green
    }
    else {
        $created = Invoke-RadarrApi -Method 'POST' -Path 'qualityprofile' -Body $profileBody
        Write-Host "`n  Created profile '$ProfileName' (id $($created.id))." -ForegroundColor Green
    }
}
elseif ($existing) {
    Write-Host "`n  NOTE: profile '$ProfileName' already exists (id $($existing.id)); -Apply needs -UpdateExistingProfile." -ForegroundColor Yellow
}
