<#
.SYNOPSIS
    Downloads manga chapters into the Komga/Kavita library using the AIO
    Webtoon Downloader container.

.DESCRIPTION
    This is the step `Import-MangaLists.ps1` deliberately stops short of. That
    script tells you which titles on your list are not on disk; this one fetches
    them.

    Two things about it are worth knowing before you run it.

    **It is a dry run by default.** Without -Apply it only searches, and prints
    the ranked candidates per title with the site and match score. Read them.
    Downloading is the cheap part; downloading the wrong series into a folder
    named after the right one is the expensive part.

    **One folder per series.** AIO names its output <Title>_Ch_<a>-<b>.cbz and
    writes it flat into --output-dir. Komga and Kavita both treat a directory as
    a series, so a flat pile of files becomes one series per file. This passes
    -o /data/manga/<series> per title instead, which puts each series in its own
    folder inside the library that Komga already mounts - so a finished CBZ is
    in the library with no move and no second copy.

    Which sites the search reaches is AIO's business, and most of them are
    aggregators. Same judgement call as the indexers in Prowlarr: yours.

.EXAMPLE
    # what would be fetched, and from where - downloads nothing
    .\Get-MangaChapters.ps1 -Title 'Dandadan'

.EXAMPLE
    # the backlog Import-MangaLists.ps1 wrote, first ten titles
    .\Get-MangaChapters.ps1 -FromCsv .\lists\missing-2026-09-10.csv -Limit 10 -Apply

.EXAMPLE
    # new chapters for everything already tracked
    .\Get-MangaChapters.ps1 -Update -Apply
#>
[CmdletBinding()]
param(
    # Titles to search for. Quote them.
    [string[]]$Title,

    # A CSV with a 'title' column - missing-<date>.csv from Import-MangaLists.ps1
    # is exactly this shape.
    [string]$FromCsv,

    # Fetch new chapters for series already tracked on disk, instead of
    # searching for anything new.
    [switch]$Update,

    # all, a single chapter (5), a range (1-10), a list (1,3,5-7) or open-ended
    # (5- for "from 5 onwards").
    [string]$Chapters = 'all',

    [string]$Language = 'en',

    # CBZ because it is what Komga and Kavita read natively. EPUB is AIO's own
    # default and is a worse fit for a comic reader.
    [ValidateSet('cbz', 'epub', 'pdf')][string]$Format = 'cbz',

    # AIO's own default is 0.55, which is loose enough to pick a spin-off over
    # the series you meant. Raised here because -Apply acts on the top hit.
    [double]$MinMatch = 0.80,

    # Parallel series. Each one runs a browser for some sites, so this is memory
    # rather than CPU.
    [int]$Jobs = 1,

    # Stop after this many titles. 0 means all of them.
    [int]$Limit = 0,

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Common.ps1')

$repoRoot = Get-RepoRoot
$conf = Get-DotEnv -Path (Join-Path $repoRoot '.env')
$dataRoot = Get-EnvOrDefault -Conf $conf -Key 'DATA_ROOT' -Default ''
if (-not $dataRoot) { throw "DATA_ROOT is not set in .env - run Setup-HomeServer.ps1 first" }

# Concatenated rather than Join-Path'd: Join-Path uses the separator of the
# host it runs on, and this string is a Windows path either way.
$libraryHost = Convert-ToWindowsPath ((Convert-ToDockerPath $dataRoot) + '/media/manga')
$libraryInContainer = '/data/manga'

$outDir = Join-Path $repoRoot 'lists'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# ------------------------------------------------------------------ the container

# Compose builds this on first use, which takes several minutes and lands about
# 2 GB - Chromium and its shared libraries are most of it. Saying so up front is
# better than a silent ten-minute pause.
$imageBuilt = $true
& docker image inspect 'homeserver/aio:latest' 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { $imageBuilt = $false }
if (-not $imageBuilt) {
    Write-Warn "the aio image is not built yet - the first run builds it (several minutes, ~2 GB)"
    Write-Info "to do it separately: docker compose --profile manga build aio"
}

function Invoke-Aio {
    param(
        [Parameter(Mandatory = $true)][string[]]$AioArguments,
        [switch]$Capture
    )
    $composeArgs = @(
        'compose', '--project-directory', $repoRoot,
        '-f', (Join-Path $repoRoot 'docker-compose.yml'),
        '--profile', 'manga', 'run', '--rm', 'aio'
    ) + $AioArguments

    Write-Info ("docker " + ($composeArgs -join ' '))

    if ($Capture) {
        # 2>&1 because AIO logs progress to stderr and prints the JSON to
        # stdout, and PowerShell 5.1 will turn a stderr line into an error
        # record otherwise.
        $out = & docker @composeArgs 2>&1
        return [PSCustomObject]@{ exitCode = $LASTEXITCODE; output = @($out) }
    }

    & docker @composeArgs | Out-Host
    return [PSCustomObject]@{ exitCode = $LASTEXITCODE; output = @() }
}

# AIO prints human-readable progress alongside the candidate JSON, so the JSON
# is found rather than assumed to be the whole of stdout.
function Get-EmbeddedJson {
    param([string[]]$Lines)
    $text = ($Lines | ForEach-Object { [string]$_ }) -join "`n"
    foreach ($opener in @('[', '{')) {
        $start = $text.IndexOf($opener)
        if ($start -lt 0) { continue }
        $closer = '}'
        if ($opener -eq '[') { $closer = ']' }
        $end = $text.LastIndexOf($closer)
        if ($end -le $start) { continue }
        try { return ($text.Substring($start, $end - $start + 1) | ConvertFrom-Json) }
        catch { continue }
    }
    return $null
}

# ------------------------------------------------------------------- what to do

$targets = @()

if ($Update) {
    if ($Title -or $FromCsv) { throw "-Update takes no titles: it acts on what is already tracked on disk" }
    if (-not (Test-Path -LiteralPath $libraryHost)) { throw "the manga library does not exist: $libraryHost" }

    # A tracked series is one with download_params.json under it, which is what
    # --save-params leaves behind. Found on disk rather than by asking AIO to
    # walk the tree, because --update-all takes a single --output-dir and this
    # layout puts one series in each.
    foreach ($dir in @(Get-ChildItem -LiteralPath $libraryHost -Directory -ErrorAction SilentlyContinue)) {
        $params = @(Get-ChildItem -LiteralPath $dir.FullName -Filter 'download_params.json' -Recurse -File -ErrorAction SilentlyContinue)
        if ($params.Count -gt 0) { $targets += [PSCustomObject]@{ title = $dir.Name; folder = $dir.Name } }
    }
    Write-Step "Updating $($targets.Count) tracked series"
}
else {
    $names = @()
    if ($Title) { $names += $Title }
    if ($FromCsv) {
        if (-not (Test-Path -LiteralPath $FromCsv)) { throw "File not found: $FromCsv" }
        $rows = @(Import-Csv -LiteralPath $FromCsv)
        if ($rows.Count -gt 0 -and -not ($rows[0].PSObject.Properties.Name -contains 'title')) {
            throw "$FromCsv has no 'title' column"
        }
        foreach ($r in $rows) { if ($r.title) { $names += [string]$r.title } }
    }
    if ($names.Count -eq 0) { throw "Pass -Title, -FromCsv or -Update" }

    $names = @($names | Select-Object -Unique)
    if ($Limit -gt 0 -and $names.Count -gt $Limit) { $names = @($names | Select-Object -First $Limit) }

    foreach ($n in $names) {
        $targets += [PSCustomObject]@{ title = $n; folder = (ConvertTo-SafeFolderName -Name $n) }
    }
    Write-Step "$($targets.Count) titles"
}

if ($targets.Count -eq 0) {
    Write-Warn "nothing to do"
    return
}

# --------------------------------------------------------------------- dry run

if (-not $Apply) {
    Write-Step "Searching (dry run - nothing is downloaded)"

    $found = 0
    foreach ($t in $targets) {
        if ($Update) {
            Write-Host ("    {0,-45} -> {1}/{2}" -f $t.title, $libraryInContainer, $t.folder)
            continue
        }

        $r = Invoke-Aio -Capture -AioArguments @(
            '--search', $t.title,
            '--search-json',
            '--search-min-match', ([string]$MinMatch),
            '--language', $Language
        )

        $candidates = @(Get-EmbeddedJson -Lines $r.output)
        if ($candidates.Count -eq 0 -or -not $candidates[0]) {
            Write-Warn ("no candidate for '{0}'" -f $t.title)
            continue
        }

        $found++
        Write-Ok ("{0}  ->  {1}/{2}" -f $t.title, $libraryInContainer, $t.folder)
        foreach ($c in ($candidates | Select-Object -First 3)) {
            # Field names come from AIO's own search output, so they are read
            # defensively rather than indexed into.
            $site = ''
            $score = ''
            $url = ''
            foreach ($p in @($c.PSObject.Properties)) {
                if ($p.Name -match '^(site|source|handler)$') { $site = [string]$p.Value }
                if ($p.Name -match '^(score|match|match_score)$') { $score = [string]$p.Value }
                if ($p.Name -match '^(url|link)$') { $url = [string]$p.Value }
            }
            Write-Host ("        {0,-18} {1,-6} {2}" -f $site, $score, $url)
        }
    }

    Write-Info "$found of $($targets.Count) titles have a candidate"
    Write-Warn "dry run - add -Apply to download"
    return
}

# ----------------------------------------------------------------------- apply

Write-Step "Downloading into $libraryHost"

$log = @()
foreach ($t in $targets) {
    $target = "$libraryInContainer/$($t.folder)"

    if ($Update) {
        $aioArgs = @(
            '--update-all',
            '-o', $target,
            '--jobs', ([string]$Jobs),
            '--temp-dir', '/tmp/aio'
        )
    }
    else {
        $aioArgs = @(
            '--search', $t.title,
            '--auto-pick',
            '--multi-source',
            '--search-min-match', ([string]$MinMatch),
            '--chapters', $Chapters,
            '--language', $Language,
            '--format', $Format,
            '--save-params',
            '--jobs', ([string]$Jobs),
            '--temp-dir', '/tmp/aio',
            '-o', $target
        )
    }

    Write-Step $t.title
    $r = Invoke-Aio -AioArguments $aioArgs

    if ($r.exitCode -eq 0) { Write-Ok "$($t.title) done" }
    else { Write-Fail "$($t.title) exited $($r.exitCode)" }

    $log += [PSCustomObject]@{
        title    = $t.title
        folder   = $t.folder
        exitCode = $r.exitCode
    }
}

$stamp = Get-Date -Format 'yyyy-MM-dd'
$logPath = Join-Path $outDir "aio-$stamp.csv"
$log | Export-Csv -LiteralPath $logPath -NoTypeInformation -Encoding UTF8

$ok = @($log | Where-Object { $_.exitCode -eq 0 }).Count
Write-Step "Result"
Write-Ok "$ok of $($log.Count) succeeded"
Write-Info "log: $logPath"

# Komga and Kavita both poll, so this is a nudge rather than a requirement -
# but waiting out a scan interval to find out whether it worked is worse.
Write-Info "rescan the library in Komga or Kavita to pick the new files up now"
