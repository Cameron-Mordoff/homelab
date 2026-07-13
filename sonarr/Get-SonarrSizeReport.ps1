<#
.SYNOPSIS
    Reports Sonarr library sizes and ranks shows by how much space you'd
    reclaim from a 720p downgrade vs. what you'd give up.

.DESCRIPTION
    TV is not movies. The biggest show is rarely the best target - what matters
    is episode-hours, because that's what a per-hour bitrate multiplies against.
    Downgrading The Office (201 x 22min) to 720p reclaims a lot; downgrading
    Band of Brothers (10 x 60min) reclaims little and costs you the one show
    you actually wanted in HD.

    So this reports three things:

      1. DOWNGRADE CANDIDATES - long-running, short-episode shows where 720p
         buys a lot of space. Ranked by GB saved.
      2. BLOATED SHOWS - shows well above the 1080p target rate, worth
         re-grabbing at 1080p without dropping resolution.
      3. (-Detailed) SEASON + FILE breakdown - catches the common case where
         one season is a remux and the other six are fine.

    Read-only. Makes no changes to Sonarr.

.PARAMETER Detailed
    Also pull per-season and per-file data for flagged shows. Costs 2 extra API
    calls per show, so it's off by default.

.EXAMPLE
    .\Get-SonarrSizeReport.ps1 -BaseUrl http://192.168.1.50:8989 -ApiKey xxxx

.EXAMPLE
    .\Get-SonarrSizeReport.ps1 -BaseUrl http://192.168.1.50:8989 -ApiKey xxxx -Detailed
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [string]$OutputDir = '.',

    # Target rates in GiB per hour of runtime. Sonarr stores MB/min internally
    # but its UI shows GB/hour, same as Radarr, so these are UI-comparable.
    [double]$Target1080GiBh = 3.0,
    [double]$Target720GiBh  = 1.5,

    # A show is a 720p candidate when it has a lot of short episodes: that's
    # where the runtime-hours (and therefore the savings) actually pile up.
    [int]$LongRunEpisodes      = 40,
    [int]$ShortEpisodeMinutes  = 45,

    # A show is "bloated" when it exceeds the 1080p target by this factor.
    [double]$BloatFactor = 1.15,

    [double]$MinSavingsGB = 5,
    [int]$TopN = 25,
    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')
$Headers = @{ 'X-Api-Key' = $ApiKey }

function Invoke-SonarrApi([string]$Path) {
    # Invoke-RestMethod hands a JSON array back as ONE non-enumerated object.
    # Returning it straight out of a function means @(...) wraps the array in
    # another array, and piping it to Where-Object filters nothing (the whole
    # array is one item, and `$_.name -eq 'x'` on an array is truthy). Bouncing
    # it through a variable makes PowerShell unroll it like a normal collection.
    $result = Invoke-RestMethod -Uri "$BaseUrl/api/v3/$Path" -Headers $Headers
    return $result
}

# mediaInfo.runTime is a STRING, and Sonarr formats it conditionally:
#   under an hour -> "22:15"   (M:SS, minutes unpadded)
#   an hour or over -> "1:02:15" (H:MM:SS)
# Splitting on ':' and assuming a fixed field count silently breaks on one of
# those two shapes, so handle both explicitly.
function ConvertTo-Minutes([string]$RunTime) {
    if ([string]::IsNullOrWhiteSpace($RunTime)) { return 0 }
    $p = $RunTime.Split(':')
    try {
        switch ($p.Count) {
            2 { return [double]$p[0] + ([double]$p[1] / 60) }
            3 { return ([double]$p[0] * 60) + [double]$p[1] + ([double]$p[2] / 60) }
            default { return 0 }
        }
    } catch { return 0 }
}

function Get-Rate([double]$SizeGB, [double]$Hours) {
    if ($Hours -le 0) { return 0 }
    [math]::Round($SizeGB / $Hours, 2)
}

$status = Invoke-SonarrApi 'system/status'
Write-Host "Connected to Sonarr $($status.version) at $BaseUrl" -ForegroundColor Green
Write-Host 'Fetching series...' -ForegroundColor Cyan

$series   = Invoke-SonarrApi 'series'
$profiles = @{}; foreach ($p in (Invoke-SonarrApi 'qualityprofile')) { $profiles[$p.id] = $p.name }
$tagNames = @{}; foreach ($t in (Invoke-SonarrApi 'tag'))            { $tagNames[$t.id] = $t.label }

# =============================================================================
# Series-level pass (one API call - series.statistics has everything we need)
# =============================================================================

$report = foreach ($s in $series) {
    $files = 0
    if ($s.statistics) { $files = [int]$s.statistics.episodeFileCount }
    if ($files -le 0) { continue }   # nothing on disk, nothing to reclaim

    $sizeGB  = [math]::Round($s.statistics.sizeOnDisk / 1GB, 1)
    $runtime = [int]$s.runtime

    # Episode-hours on disk. Nominal (episodeFileCount x series runtime) rather
    # than summing real durations - that would cost an API call per show, and
    # -Detailed does it properly for the shows that actually matter.
    $hours = if ($runtime -gt 0) { [math]::Round(($files * $runtime) / 60, 1) } else { 0 }

    $gibh    = Get-Rate $sizeGB $hours
    $est1080 = [math]::Round($hours * $Target1080GiBh, 1)
    $est720  = [math]::Round($hours * $Target720GiBh, 1)

    $save1080 = if ($sizeGB -gt $est1080) { [math]::Round($sizeGB - $est1080, 1) } else { 0 }
    $save720  = if ($sizeGB -gt $est720)  { [math]::Round($sizeGB - $est720, 1) }  else { 0 }

    # These are TWO independent decisions and must not be collapsed into one:
    #
    #   1. What resolution should this show be? (a taste call - miniseries and
    #      prestige stay 1080p, long-running short-episode shows drop to 720p)
    #   2. Is the file fatter than it needs to be AT that resolution? (a pure
    #      bitrate question, and it applies to a 1080p keeper just as much)
    #
    # Collapsing them means a bloated miniseries reads as "keep 1080p" = do
    # nothing, and its savings vanish from the report. A 200 GB remux docuseries
    # should still be re-grabbed at 1080p - "keep 1080p" means don't drop the
    # resolution, NOT don't touch it.
    $class =
        if     ($s.statistics.seasonCount -le 1 -and $files -le 12)                 { 'miniseries' }
        elseif ($runtime -le $ShortEpisodeMinutes -and $files -ge $LongRunEpisodes) { 'long-run' }
        else                                                                        { 'standard' }

    $bloated = $gibh -gt ($Target1080GiBh * $BloatFactor)

    $suggest =
        if     ($class -eq 'long-run' -and $save720 -ge $MinSavingsGB) { '720p (long run, short eps)' }
        elseif ($bloated -and $save1080 -ge $MinSavingsGB)             { 'trim at 1080p (bloated)' }
        else                                                           { 'ok' }

    # TargetRes drives Set-SonarrSeriesProfile.ps1, so it must be a RECOMMENDATION,
    # not a classification. Being a long-running sitcom is not sufficient: if the
    # show is already at or below the 720p rate (King of the Hill sits at 0.38
    # GiB/h - it's DVD), moving it to a 720p profile makes Sonarr rank the file
    # BELOW the cutoff and "upgrade" it UP to 720p. That re-downloads the whole
    # show and makes the library BIGGER. Only send a show to 720p when the
    # downgrade actually reclaims something.
    $targetRes = if ($suggest -like '720p*') { '720p' } else { '1080p' }

    # Savings from the SUGGESTED action - and the column the CSV is sorted on.
    # Sorting on raw SaveIf720GB instead would put the biggest prestige shows on
    # top (a 47-min drama "saves" more at 720p than The Office does), which is
    # the exact mistake this report exists to prevent.
    $actionSave =
        if     ($suggest -like '720p*') { $save720 }
        elseif ($suggest -like 'trim*') { $save1080 }
        else                            { 0 }

    [pscustomobject]@{
        Title         = $s.title
        Year          = $s.year
        Status        = $s.status
        Type          = $s.seriesType
        Profile       = $profiles[$s.qualityProfileId]
        Tags          = (@($s.tags | ForEach-Object { $tagNames[$_] }) -join ';')
        Seasons       = $s.statistics.seasonCount
        EpisodeFiles  = $files
        RuntimeMin    = $runtime
        Hours         = $hours
        SizeGB        = $sizeGB
        GiBPerHour    = $gibh
        EstAt1080GB   = $est1080
        EstAt720GB    = $est720
        SaveIf1080GB  = $save1080
        SaveIf720GB   = $save720
        Class         = $class
        TargetRes     = $targetRes
        Suggest       = $suggest
        ActionSaveGB  = $actionSave
        SeriesId      = $s.id
    }
}

$report = @($report | Sort-Object ActionSaveGB -Descending)
if ($report.Count -eq 0) {
    Write-Host 'No series with files on disk.' -ForegroundColor Yellow
    return
}

$seriesCsv = Join-Path $OutputDir 'SonarrSeriesReport.csv'
$report | Export-Csv -Path $seriesCsv -NoTypeInformation -Encoding UTF8

# =============================================================================
# Console: the two tables that drive a decision
# =============================================================================

$downgrade = @($report | Where-Object { $_.Suggest -like '720p*' })
$bloated   = @($report | Where-Object { $_.Suggest -like 'trim*' })

Write-Host "`n=== 720p DOWNGRADE CANDIDATES (long-running, short episodes) ===" -ForegroundColor Cyan
Write-Host "    Ranked by GB reclaimed. These are the shows where episode-hours pile up." -ForegroundColor DarkGray
if ($downgrade.Count -gt 0) {
    $downgrade | Select-Object -First $TopN |
        Format-Table Title, Year, EpisodeFiles, RuntimeMin, Hours, SizeGB, GiBPerHour, EstAt720GB, SaveIf720GB -AutoSize
} else {
    Write-Host '    (none over the savings threshold)' -ForegroundColor DarkGray
}

Write-Host "=== BLOATED AT CURRENT RESOLUTION (re-grab at 1080p, keep the res) ===" -ForegroundColor Cyan
Write-Host "    Above ${Target1080GiBh} GiB/h x $BloatFactor. Worth fixing regardless of the 720p question." -ForegroundColor DarkGray
if ($bloated.Count -gt 0) {
    $bloated | Sort-Object SaveIf1080GB -Descending | Select-Object -First $TopN |
        Format-Table Title, Year, Class, EpisodeFiles, Hours, SizeGB, GiBPerHour, EstAt1080GB, SaveIf1080GB -AutoSize
} else {
    Write-Host '    (none over the savings threshold)' -ForegroundColor DarkGray
}

# Genuinely nothing to do: a 1080p keeper that is already at a sane bitrate.
$keep = @($report | Where-Object { $_.Class -eq 'miniseries' -and $_.Suggest -eq 'ok' })
if ($keep.Count -gt 0) {
    Write-Host "=== HANDS OFF - miniseries already at a sane rate ===" -ForegroundColor Cyan
    $keep | Sort-Object SizeGB -Descending | Select-Object -First 10 |
        Format-Table Title, Year, EpisodeFiles, Hours, SizeGB, GiBPerHour -AutoSize
}

# =============================================================================
# Optional: per-season and per-file drill-down for the shows that matter
# =============================================================================

if ($Detailed) {
    $targets = @($report | Where-Object { $_.SaveIf720GB -ge $MinSavingsGB -or $_.GiBPerHour -gt ($Target1080GiBh * $BloatFactor) })
    Write-Host "`nPulling season/file detail for $($targets.Count) flagged shows..." -ForegroundColor Cyan

    $seasonRows = New-Object System.Collections.Generic.List[object]
    $fileRows   = New-Object System.Collections.Generic.List[object]
    $i = 0

    foreach ($t in $targets) {
        $i++
        Write-Progress -Activity 'Fetching episode files' -Status $t.Title -PercentComplete (($i / $targets.Count) * 100)

        try {
            $epFiles  = @(Invoke-SonarrApi "episodefile?seriesId=$($t.SeriesId)")
            $episodes = @(Invoke-SonarrApi "episode?seriesId=$($t.SeriesId)")
        } catch {
            Write-Host "  ! Failed to fetch detail for '$($t.Title)' - skipping" -ForegroundColor Yellow
            continue
        }

        # An episode file has no back-reference to its episodes, so build the
        # reverse map. A file covering 2 episodes is a double-length file and
        # its nominal runtime must be doubled or its GiB/h reads twice as bad.
        $epsPerFile = @{}
        foreach ($e in $episodes) {
            if ($e.episodeFileId -and $e.episodeFileId -gt 0) {
                if ($epsPerFile.ContainsKey($e.episodeFileId)) { $epsPerFile[$e.episodeFileId]++ }
                else { $epsPerFile[$e.episodeFileId] = 1 }
            }
        }

        foreach ($f in $epFiles) {
            $fSizeGB = [math]::Round($f.size / 1GB, 2)

            # Prefer the real duration from mediaInfo; fall back to nominal.
            $mins = 0
            if ($f.mediaInfo -and $f.mediaInfo.runTime) { $mins = ConvertTo-Minutes $f.mediaInfo.runTime }
            if ($mins -le 0) {
                $covered = 1
                if ($epsPerFile.ContainsKey($f.id)) { $covered = $epsPerFile[$f.id] }
                $mins = $t.RuntimeMin * $covered
            }
            $fHours = [math]::Round($mins / 60, 3)

            # Sonarr often reports videoBitrate as 0 (it depends on what the
            # muxer wrote into the container). Fall back to the overall rate
            # derived from size/duration, which is never missing.
            $mbps = 0
            if ($f.mediaInfo -and $f.mediaInfo.videoBitrate -gt 0) {
                $mbps = [math]::Round($f.mediaInfo.videoBitrate / 1000000, 2)   # bits/sec -> Mbps
            } elseif ($mins -gt 0) {
                $mbps = [math]::Round(($f.size * 8) / ($mins * 60) / 1000000, 2)
            }

            $fileRows.Add([pscustomobject]@{
                Series       = $t.Title
                Season       = $f.seasonNumber
                File         = $f.relativePath
                Quality      = $f.quality.quality.name
                Resolution   = $(if ($f.mediaInfo) { $f.mediaInfo.resolution } else { '' })
                Codec        = $(if ($f.mediaInfo) { $f.mediaInfo.videoCodec } else { '' })
                ReleaseGroup = $f.releaseGroup
                Minutes      = [math]::Round($mins, 1)
                SizeGB       = $fSizeGB
                GiBPerHour   = (Get-Rate $fSizeGB $fHours)
                Mbps         = $mbps
            })
        }

        # Season rollup, from the series object's own season statistics.
        $full = $series | Where-Object { $_.id -eq $t.SeriesId }
        foreach ($sn in $full.seasons) {
            if (-not $sn.statistics -or $sn.statistics.episodeFileCount -le 0) { continue }
            $snFiles  = [int]$sn.statistics.episodeFileCount
            $snSizeGB = [math]::Round($sn.statistics.sizeOnDisk / 1GB, 1)
            $snHours  = if ($t.RuntimeMin -gt 0) { [math]::Round(($snFiles * $t.RuntimeMin) / 60, 1) } else { 0 }
            $snQual   = @($fileRows | Where-Object { $_.Series -eq $t.Title -and $_.Season -eq $sn.seasonNumber } |
                          Select-Object -ExpandProperty Quality -Unique) -join ';'

            $seasonRows.Add([pscustomobject]@{
                Series       = $t.Title
                Season       = $sn.seasonNumber
                EpisodeFiles = $snFiles
                Hours        = $snHours
                SizeGB       = $snSizeGB
                GiBPerHour   = (Get-Rate $snSizeGB $snHours)
                Qualities    = $snQual
                EstAt720GB   = [math]::Round($snHours * $Target720GiBh, 1)
                SaveIf720GB  = [math]::Round([math]::Max(0, $snSizeGB - ($snHours * $Target720GiBh)), 1)
            })
        }
    }
    Write-Progress -Activity 'Fetching episode files' -Completed

    $seasonCsv = Join-Path $OutputDir 'SonarrSeasonReport.csv'
    $fileCsv   = Join-Path $OutputDir 'SonarrFileReport.csv'
    $seasonRows | Sort-Object GiBPerHour -Descending | Export-Csv -Path $seasonCsv -NoTypeInformation -Encoding UTF8
    $fileRows   | Sort-Object GiBPerHour -Descending | Export-Csv -Path $fileCsv   -NoTypeInformation -Encoding UTF8

    Write-Host "`n=== WORST SEASONS BY RATE (the 'one season is a remux' case) ===" -ForegroundColor Cyan
    $seasonRows | Sort-Object GiBPerHour -Descending | Select-Object -First 20 |
        Format-Table Series, Season, EpisodeFiles, SizeGB, GiBPerHour, Qualities -AutoSize

    Write-Host "=== WORST INDIVIDUAL FILES BY RATE ===" -ForegroundColor Cyan
    $fileRows | Sort-Object GiBPerHour -Descending | Select-Object -First 20 |
        Format-Table Series, Season, Quality, Resolution, Codec, SizeGB, GiBPerHour, Mbps -AutoSize

    Write-Host "Season report: $seasonCsv" -ForegroundColor Green
    Write-Host "File report:   $fileCsv"   -ForegroundColor Green
}

# =============================================================================
# Summary
# =============================================================================

$totalGB   = [math]::Round(($report | Measure-Object SizeGB -Sum).Sum, 1)
$totalHrs  = [math]::Round(($report | Measure-Object Hours  -Sum).Sum, 0)
$dgSave    = [math]::Round((@($downgrade | Measure-Object SaveIf720GB  -Sum).Sum), 1)
$blSave    = [math]::Round((@($bloated   | Measure-Object SaveIf1080GB -Sum).Sum), 1)

Write-Host "`n--------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ("Library: {0} shows | {1} episode files | {2} hours | {3} GB" -f `
    $report.Count, ($report | Measure-Object EpisodeFiles -Sum).Sum, $totalHrs, $totalGB) -ForegroundColor Green
Write-Host ("Reclaimable by downgrading {0} long-run shows to 720p:  ~{1} GB" -f $downgrade.Count, $dgSave) -ForegroundColor Green
Write-Host ("Reclaimable by re-grabbing {0} bloated shows at 1080p:  ~{1} GB" -f $bloated.Count, $blSave) -ForegroundColor Green
Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "Series report: $seriesCsv" -ForegroundColor Green
if (-not $Detailed) {
    Write-Host 'Re-run with -Detailed for per-season and per-file breakdown.' -ForegroundColor DarkGray
}
