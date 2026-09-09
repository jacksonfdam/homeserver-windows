<#
.SYNOPSIS
    Reports what is actually configured and running, in one place.

.DESCRIPTION
    Answers "what do I need to run now" without opening five web UIs. Every
    line is read from the live system: the engine, .env, the folder tree, the
    containers, the endpoints, and what the *arr apps say about their own
    configuration.

    Read-only. It changes nothing and never prompts, so it is safe to run at any
    time, including while the stack is down.

    Where something is missing it prints the command that fixes it, rather than
    describing the fix in prose.

.PARAMETER Quick
    Skip the *arr configuration probes, which are the slow part - they read an
    API key out of each container and then make five or six calls per app.

.EXAMPLE
    .\Get-HomeServerStatus.ps1

.EXAMPLE
    .\Get-HomeServerStatus.ps1 -Quick
#>
[CmdletBinding()]
param(
    [switch]$Quick
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Common.ps1')

$root = Get-RepoRoot
$envPath = Join-Path $root '.env'
$examplePath = Join-Path $root '.env.example'
$conf = Get-DotEnv -Path $envPath

$dataRootWin = Convert-ToWindowsPath (Get-EnvOrDefault -Conf $conf -Key 'DATA_ROOT' -Default 'C:/media')
$configRootWin = Convert-ToWindowsPath (Get-EnvOrDefault -Conf $conf -Key 'CONFIG_ROOT' -Default 'C:/homeserver/config')
$cacheRoot = Get-EnvOrDefault -Conf $conf -Key 'CACHE_ROOT' -Default 'C:/homeserver/cache'
$mirrorRoot = Get-EnvOrDefault -Conf $conf -Key 'MANGABAKA_ROOT' -Default ''
if (-not $mirrorRoot) { $mirrorRoot = "$cacheRoot/mangabaka" }
$mirrorRootWin = Convert-ToWindowsPath $mirrorRoot

# Collected as they are found and printed together at the end, so the fixes are
# a list to work through rather than something to scroll back for.
$todo = @()

Write-Host ""
Write-Host "  Home server status" -ForegroundColor White
Write-Host "  $root" -ForegroundColor DarkGray

# ------------------------------------------------------------------- 1. engine
Write-Step "Engine"

$docker = Get-DockerState
if (-not $docker.cliFound) {
    Write-Fail $docker.message
    Write-Host ""
    Write-Host "  Nothing else can be checked without the Docker CLI." -ForegroundColor DarkGray
    Write-Host ""
    return
}
if (-not $docker.engineUp) {
    Write-Fail $docker.message
    $todo += 'start Docker Desktop and wait for the whale to stop animating'
}
else {
    Write-Ok "engine up, $($docker.osType) containers, compose $($docker.composeVersion)"
    if ($docker.message) { Write-Warn $docker.message }
}

# ---------------------------------------------------------------- 2. .env
Write-Step "Configuration"

$gaps = Get-EnvGaps -EnvPath $envPath -ExamplePath $examplePath
if (-not $gaps.exampleExists) {
    Write-Fail ".env.example is missing - Setup-HomeServer.ps1 copies it and will throw without it"
    $todo += 'restore .env.example from the repository'
}
if (-not $gaps.envExists) {
    Write-Warn ".env does not exist yet"
    $todo += ".\scripts\Setup-HomeServer.ps1   # creates .env from the template"
}
else {
    Write-Ok ".env present"
    Write-Info "DATA_ROOT   $dataRootWin"
    Write-Info "CONFIG_ROOT $configRootWin"
    if ($gaps.missingKeys.Count -gt 0) {
        Write-Warn "$($gaps.missingKeys.Count) key(s) the template documents are absent from .env:"
        foreach ($k in $gaps.missingKeys) { Write-Host "             $k" -ForegroundColor DarkGray }
        # Compose has a default for every one of these, so nothing breaks - but
        # the dashboard widgets that need credentials render an error until the
        # values are filled in.
        $todo += 'copy the missing keys from .env.example into .env (compose has defaults, so nothing is broken - dashboard widgets stay blank)'
    }
    else {
        Write-Ok "every key from the template is present"
    }
}

# --------------------------------------------------------------- 3. folder tree
Write-Step "Folders"

$paths = Get-PathState -DataRoot $dataRootWin -ConfigRoot $configRootWin
if (-not $paths.dataRootExists) {
    Write-Fail "DATA_ROOT does not exist: $dataRootWin"
    $todo += ".\scripts\Setup-HomeServer.ps1   # creates the folder tree"
}
elseif ($paths.missing.Count -gt 0) {
    Write-Warn "$($paths.missing.Count) folder(s) missing under $dataRootWin"
    foreach ($d in $paths.missing) { Write-Host "             $d" -ForegroundColor DarkGray }
    if ($paths.missing -contains 'recycle') {
        Write-Info "'recycle' is required before -ApplyNaming works: both apps validate it inside the container"
    }
    $todo += ".\scripts\Setup-HomeServer.ps1   # creates the missing folders"
}
else {
    Write-Ok "the whole tree is present"
}

# ---------------------------------------------------------------- 4. containers
Write-Step "Services"

$services = Get-ServiceMap -Conf $conf
$containers = Get-ContainerState
$downCount = 0

foreach ($svc in $services) {
    $url = "http://localhost:$($svc.port)"
    $isRunning = $containers.ContainsKey($svc.container)
    if (-not $isRunning) {
        Write-Host ("    [--]   {0,-12} not running" -f $svc.name) -ForegroundColor DarkGray
        $downCount++
        continue
    }
    if (Test-HttpOk -Url $url -TimeoutSec 3) {
        Write-Host ("    [ok]   {0,-12} {1}" -f $svc.name, $url) -ForegroundColor Green
    }
    else {
        Write-Host ("    [warn] {0,-12} container up but {1} is not answering yet" -f $svc.name, $url) -ForegroundColor Yellow
    }
}

if ($downCount -eq $services.Count) {
    Write-Info "nothing is running"
    $todo += ".\scripts\Setup-HomeServer.ps1   # brings the stack up"
}
elseif ($downCount -gt 0) {
    Write-Info "$downCount service(s) down - some are behind a compose profile (plex, usenet, utils)"
}

# ------------------------------------------------------------------ 5. wiring
if ($Quick) {
    Write-Step "Wiring"
    Write-Info "-Quick set, skipping the per-app configuration probes"
}
else {
    Write-Step "Wiring and tuning"

    $probed = 0
    foreach ($svc in $services) {
        if (-not $svc.arr) { continue }
        if ($svc.container -eq 'prowlarr') { continue }
        if (-not $containers.ContainsKey($svc.container)) { continue }

        $probed++
        $withFormats = ($svc.container -eq 'radarr')
        # Only Sonarr and Radarr are given quality floors: the floor table is in
        # MB per minute of video at 720p/1080p/2160p, which means nothing for
        # music. Reporting Lidarr as unfloored sent you off to run
        # -ApplyQualityFloors for something it will never set.
        $expectsFloors = (@('sonarr', 'radarr') -contains $svc.container)
        $arr = Get-ArrState -Container $svc.container -BaseUrl "http://localhost:$($svc.port)" `
            -Api $svc.api -WithCustomFormats:$withFormats

        Write-Host ("    {0}" -f $svc.name) -ForegroundColor White
        if ($arr.error) {
            Write-Fail "  $($arr.error)"
            continue
        }

        if ($arr.downloadClients -gt 0) { Write-Ok "  download client registered" }
        else {
            Write-Warn "  no download client"
            $todo += ".\scripts\Wire-Services.ps1   # registers qBittorrent and the root folders"
        }

        if ($arr.rootFolders.Count -gt 0) { Write-Ok "  root folders: $($arr.rootFolders -join ', ')" }
        else { Write-Warn "  no root folders" }

        if ($expectsFloors) {
            if ($arr.qualityFloored) { Write-Ok "  quality floors applied" }
            else {
                Write-Warn "  quality definitions still ship a minimum size of zero"
                $todo += ".\scripts\Wire-Services.ps1 -ApplyQualityFloors"
            }
        }

        if ($arr.renaming) { Write-Ok "  renaming on import is on" }
        else { Write-Info "  renaming on import is off (-ApplyNaming turns it on, and renames an existing library)" }

        if ($arr.recycleBin) { Write-Ok "  recycle bin $($arr.recycleBin)" }
        else { Write-Info "  no recycle bin set" }

        if ($arr.propers -and $arr.propers -ne 'doNotPrefer') {
            Write-Info "  propers: $($arr.propers) - -ApplyNaming sets this to doNotPrefer"
        }

        foreach ($cf in $arr.customFormats) {
            if ($cf.score -eq 0) { Write-Warn "  custom format '$($cf.name)' exists but is scored 0, so it rejects nothing" }
            else { Write-Ok "  custom format '$($cf.name)' scored $($cf.score)" }
        }
    }

    if ($probed -eq 0) { Write-Info "no *arr app is running, so there is nothing to probe" }
}

# ------------------------------------------------------------ 6. manga mirror
Write-Step "MangaBaka mirror"

$mirror = Get-MirrorState -Root $mirrorRootWin
if (-not $mirror.present) {
    Write-Info "not downloaded ($mirrorRootWin)"
    Write-Info "only needed for the manga list sync, which is not built yet"
}
else {
    $age = (Get-Date) - $mirror.lastWritten
    Write-Ok "$($mirror.sizeGb) GB, written $([int]$age.TotalDays) day(s) ago"
    if ($age.TotalDays -gt 7) {
        Write-Warn "the dump is refreshed nightly, so this is stale"
        $todo += '.\scripts\Update-MangaBaka.ps1'
    }
}

# ------------------------------------------------------------------ 7. summary
Write-Step "What to run"

if ($todo.Count -eq 0) {
    Write-Ok "nothing - everything this script knows how to check is in place"
}
else {
    # Duplicates are expected: several checks land on the same fix.
    foreach ($cmd in ($todo | Select-Object -Unique)) {
        Write-Host "    $cmd" -ForegroundColor Cyan
    }
}
Write-Host ""
