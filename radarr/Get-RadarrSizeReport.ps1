<#
.SYNOPSIS
    Reports Radarr library file sizes to find oversized movies worth re-grabbing.

.DESCRIPTION
    Pulls every movie with a file, calculates size, GiB-per-hour bitrate, and
    estimated savings if re-grabbed at the new preferred rate (6.5 GiB/h,
    ~13 GB for a 2h movie). Prints the top offenders to the console and writes
    the full list to CSV, sorted largest first.

.EXAMPLE
    .\Get-RadarrSizeReport.ps1 -BaseUrl https://radarr.example.com -ApiKey xxxx
    .\Get-RadarrSizeReport.ps1 -BaseUrl https://radarr.example.com -ApiKey xxxx -MinSizeGB 16
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [string]$ApiKey,                 # default: RadarrApiKey from SecretManagement
    [string]$OutputPath = '.\RadarrSizeReport.csv',
    [double]$MinSizeGB = 0,          # only include files at least this big
    [double]$TargetGiBPerHour = 6.5  # your preferred rate; used for savings estimate
)

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')
if (-not $ApiKey) {
    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) { throw 'Pass -ApiKey, or install Microsoft.PowerShell.SecretManagement and Set-Secret -Name RadarrApiKey.' }
    $ApiKey = Get-Secret -Name RadarrApiKey -AsPlainText
}
$Headers = @{ 'X-Api-Key' = $ApiKey }

Write-Host 'Fetching movie library...' -ForegroundColor Cyan
$movies = Invoke-RestMethod -Uri "$BaseUrl/api/v3/movie" -Headers $Headers

$report = foreach ($m in $movies) {
    if (-not $m.hasFile -or -not $m.movieFile -or -not $m.movieFile.size) { continue }

    $sizeGB  = [math]::Round($m.movieFile.size / 1GB, 1)
    if ($sizeGB -lt $MinSizeGB) { continue }

    $runtimeMin = $m.runtime
    $gibPerHour = if ($runtimeMin -gt 0) {
        [math]::Round(($m.movieFile.size / 1GB) / ($runtimeMin / 60), 1)
    } else { $null }

    $estNewGB = if ($runtimeMin -gt 0) {
        [math]::Round(($runtimeMin / 60) * $TargetGiBPerHour, 1)
    } else { $null }

    $savings = if ($null -ne $estNewGB -and $sizeGB -gt $estNewGB) {
        [math]::Round($sizeGB - $estNewGB, 1)
    } else { 0 }

    [pscustomobject]@{
        Title            = $m.title
        Year             = $m.year
        Quality          = $m.movieFile.quality.quality.name
        ReleaseGroup     = $m.movieFile.releaseGroup
        RuntimeMin       = $runtimeMin
        SizeGB           = $sizeGB
        GiBPerHour       = $gibPerHour
        EstNewSizeGB     = $estNewGB
        PotentialSaveGB  = $savings
    }
}

# @() so a zero- or one-movie result still behaves like a collection (.Count etc)
$report = @($report | Sort-Object SizeGB -Descending)

if ($report.Count -eq 0) {
    Write-Host "No movies with files matched (MinSizeGB = $MinSizeGB)." -ForegroundColor Yellow
    return
}

$report | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

$totalSize    = [math]::Round(($report | Measure-Object SizeGB -Sum).Sum, 1)
$totalSavings = [math]::Round(($report | Measure-Object PotentialSaveGB -Sum).Sum, 1)

Write-Host "`n=== Top 25 largest files ===" -ForegroundColor Cyan
$report | Select-Object -First 25 |
    Format-Table Title, Year, Quality, ReleaseGroup, SizeGB, GiBPerHour, PotentialSaveGB -AutoSize

Write-Host ("Movies with files: {0} | Total size: {1} GB | Estimated recoverable: ~{2} GB" -f `
    $report.Count, $totalSize, $totalSavings) -ForegroundColor Green
Write-Host "Full report written to: $OutputPath" -ForegroundColor Green
