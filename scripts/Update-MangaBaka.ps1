<#
.SYNOPSIS
    Mirrors the MangaBaka series database locally as SQLite.

.DESCRIPTION
    MangaBaka publishes a full dump nightly at 00:00 UTC. This downloads the
    SQLite build, verifies it against the published SHA1, and swaps it into place
    only once it is known good, so a reader never sees a half-written database.

    The remote checksum is fetched first and compared with the one stored beside
    the local copy. When they match there is nothing to do and the ~530 MB
    download is skipped, which is what makes running this daily cheap.

    Sizes to plan for: the archive is about 530 MB, the database it unpacks to is
    about 3.3 GB, and the previous copy is kept until the new one is in place. So
    a refresh wants roughly 7 GB free on the volume holding the mirror.

    Data is CC BY-NC-SA 4.0 and attribution is required. See README.md.

.PARAMETER Root
    Where the mirror lives. Defaults to MANGABAKA_ROOT in .env, and failing that
    to <CACHE_ROOT>/mangabaka - regenerable data, so deliberately not under
    CONFIG_ROOT, which is what the backup instructions in docs/day-2.md cover.

.PARAMETER Force
    Download and replace even when the checksum says the local copy is current.

.EXAMPLE
    .\Update-MangaBaka.ps1

.EXAMPLE
    # Setup-HomeServer.ps1 -RegisterTasks does this for you. By hand, after the
    # 00:00 UTC dump has been published:
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\path\to\scripts\Update-MangaBaka.ps1"'
    $trigger = New-ScheduledTaskTrigger -Daily -At 3am
    Register-ScheduledTask -TaskName 'homeserver-update-mangabaka' -Action $action -Trigger $trigger
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Common.ps1')

# The dump is published in three formats and two compressions. tar.gz is the one
# picked on purpose: Windows 10 1803+ ships bsdtar as tar.exe, so it unpacks with
# nothing installed, while zst would mean putting a zstd binary on the host.
# The default schema is enough - the "full" build carries every upstream's raw
# response, and what this mirror is for is the cross-ID map and the metadata.
$baseUrl = 'https://api.mangabaka.org/v1/database'
$archiveName = 'series.sqlite.tar.gz'
$archiveUrl = "$baseUrl/$archiveName"
$checksumUrl = "$archiveUrl.sha1"

$conf = Get-DotEnv -Path (Join-Path (Get-RepoRoot) '.env')

if (-not $Root) {
    $Root = Get-EnvOrDefault -Conf $conf -Key 'MANGABAKA_ROOT' -Default ''
}
if (-not $Root) {
    $cacheRoot = Get-EnvOrDefault -Conf $conf -Key 'CACHE_ROOT' -Default 'C:/homeserver/cache'
    $Root = "$cacheRoot/mangabaka"
}
$rootWin = Convert-ToWindowsPath $Root

$dbPath = Join-Path $rootWin 'series.sqlite'
$statePath = Join-Path $rootWin 'series.sqlite.sha1'
$archivePath = Join-Path $rootWin $archiveName
$stagingDir = Join-Path $rootWin '.staging'

Write-Host ""
Write-Host "  MangaBaka mirror" -ForegroundColor White
Write-Host "  $rootWin" -ForegroundColor DarkGray

# ---------------------------------------------------------------- 1. preflight
Write-Step "Preflight"

$tarCmd = Get-Command tar -ErrorAction SilentlyContinue
if (-not $tarCmd) {
    Write-Fail "tar was not found on PATH."
    Write-Host "         Windows 10 1803 and newer ship it as C:\Windows\System32\tar.exe."
    throw "tar missing"
}
Write-Ok "tar is available"

if (-not (Test-Path -LiteralPath $rootWin)) {
    New-Item -ItemType Directory -Path $rootWin -Force | Out-Null
    Write-Ok "created $rootWin"
}

# ------------------------------------------------------------- 2. is it stale?
Write-Step "Checking the published checksum"

# Roughly forty bytes over the wire decide whether the next half gigabyte is
# worth fetching.
$remoteSha = $null
try {
    $response = Invoke-WebRequest -Uri $checksumUrl -UseBasicParsing -TimeoutSec 60
    $text = [System.Text.Encoding]::ASCII.GetString($response.Content)
    # The file is usually "<hash>  <filename>", so take the first 40-hex token
    # rather than trusting the whole line.
    $m = [regex]::Match($text, '[0-9a-fA-F]{40}')
    if ($m.Success) { $remoteSha = $m.Value.ToLowerInvariant() }
}
catch {
    throw "Could not fetch $checksumUrl : $($_.Exception.Message)"
}
if (-not $remoteSha) { throw "No SHA1 found in $checksumUrl" }
Write-Ok "published SHA1 $remoteSha"

$localSha = ''
if (Test-Path -LiteralPath $statePath) {
    $localSha = (Get-Content -LiteralPath $statePath -Raw).Trim().ToLowerInvariant()
}

if ($localSha -eq $remoteSha -and (Test-Path -LiteralPath $dbPath) -and -not $Force) {
    Write-Ok "already current, nothing to download"
    $age = (Get-Item -LiteralPath $dbPath).LastWriteTime
    Write-Info "mirror last written $age"
    return
}
if ($Force) { Write-Info "-Force set, downloading regardless" }

# -------------------------------------------------------------- 3. download it
Write-Step "Downloading $archiveName"

# Invoke-WebRequest draws a progress bar on every chunk under Windows PowerShell
# 5.1, and on a file this size that rendering dominates the transfer. Silencing
# it is the difference between minutes and hours.
$previousProgress = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'
try {
    if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
    $started = Get-Date
    Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing -TimeoutSec 3600
    $elapsed = (Get-Date) - $started
    $sizeMb = [Math]::Round((Get-Item -LiteralPath $archivePath).Length / 1MB, 1)
    Write-Ok "$sizeMb MB in $([int]$elapsed.TotalSeconds) s"
}
finally {
    $ProgressPreference = $previousProgress
}

# ---------------------------------------------------------------- 4. verify it
Write-Step "Verifying"

$actualSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA1).Hash.ToLowerInvariant()
if ($actualSha -ne $remoteSha) {
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    throw "Checksum mismatch: expected $remoteSha, got $actualSha. The download was discarded."
}
Write-Ok "SHA1 matches"

# --------------------------------------------------------------- 5. unpack it
Write-Step "Unpacking"

if (Test-Path -LiteralPath $stagingDir) { Remove-Item -LiteralPath $stagingDir -Recurse -Force }
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

& tar -xf $archivePath -C $stagingDir
if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }

# Look the database up rather than assuming what the archive names it.
$extracted = Get-ChildItem -LiteralPath $stagingDir -Recurse -Filter '*.sqlite' -File | Select-Object -First 1
if (-not $extracted) { throw "No .sqlite file inside $archiveName" }
Write-Ok "found $($extracted.Name), $([Math]::Round($extracted.Length / 1MB, 1)) MB"

# Nothing needs the archive once it has unpacked, and dropping it here rather
# than at the end keeps half a gigabyte off the peak disk usage of the swap.
Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue

# ----------------------------------------------------------------- 6. swap in
Write-Step "Installing"

# Everything above happens beside the live copy so that a failed or interrupted
# run leaves the previous mirror readable. Only this step is destructive, and it
# keeps the old file until the new one is in place.
$previousPath = "$dbPath.previous"
if (Test-Path -LiteralPath $previousPath) { Remove-Item -LiteralPath $previousPath -Force }

try {
    if (Test-Path -LiteralPath $dbPath) { Move-Item -LiteralPath $dbPath -Destination $previousPath }
    Move-Item -LiteralPath $extracted.FullName -Destination $dbPath
    Set-Content -LiteralPath $statePath -Value $remoteSha -Encoding ASCII
    Write-Ok "mirror updated"
}
catch {
    if ((Test-Path -LiteralPath $previousPath) -and -not (Test-Path -LiteralPath $dbPath)) {
        Move-Item -LiteralPath $previousPath -Destination $dbPath
        Write-Warn "install failed, the previous mirror was put back"
    }
    throw
}

Remove-Item -LiteralPath $previousPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

# --------------------------------------------------------------- 7. index it
Write-Step "Indexing"

# The dump arrives with no index at all beyond the implicit primary key, so a
# lookup by tracker ID scans all 559k rows across 3.3 GB. Measured on a real
# dump: 4.5 s per lookup before, 6 ms after. Building both takes about 8 s and
# costs almost nothing on disk, so it is not an optimisation to defer - without
# it, resolving a list of a few hundred titles takes minutes of pure scanning.
#
# Windows PowerShell 5.1 has no SQLite driver and this repository installs
# nothing on the host, so the statement runs in a throwaway container - the same
# reasoning as the hardlink probe in Setup-HomeServer.ps1.
$indexSql = "CREATE INDEX IF NOT EXISTS idx_series_anilist ON series(source_anilist_id) WHERE source_anilist_id IS NOT NULL; CREATE INDEX IF NOT EXISTS idx_series_mal ON series(source_my_anime_list_id) WHERE source_my_anime_list_id IS NOT NULL;"

$dockerRoot = Convert-ToDockerPath $rootWin
& docker run --rm -v "${dockerRoot}:/data" keinos/sqlite3:latest sqlite3 /data/series.sqlite $indexSql | Out-Host
if ($LASTEXITCODE -ne 0) {
    Write-Warn "could not build the indexes - lookups will still work, but each one scans the whole table"
    Write-Host "         Is Docker running? Re-running this script will try again."
}
else {
    Write-Ok "indexed on the AniList and MyAnimeList ids"
}

Write-Step "Done"
Write-Info "$dbPath"
