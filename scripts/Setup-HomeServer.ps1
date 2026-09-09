<#
.SYNOPSIS
    Brings up and wires a self-hosted media server stack on Windows with Docker Desktop.

.DESCRIPTION
    Windows port of https://github.com/akitaonrails/plex_home_server_docker.
    Runs preflight checks, creates the folder layout, writes .env, seeds the
    qBittorrent configuration, starts the stack and then calls Wire-Services.ps1
    to connect the services to each other over their REST APIs.

    Safe to re-run: every step is idempotent.

.EXAMPLE
    .\Setup-HomeServer.ps1 -DataRoot C:\media -ConfigRoot C:\homeserver\config

.EXAMPLE
    .\Setup-HomeServer.ps1 -Profiles plex,usenet,utils
#>
[CmdletBinding()]
param(
    [string]$DataRoot,
    [string]$ConfigRoot,
    [string]$CacheRoot,
    [string]$TimeZone,
    [string]$HostIp,

    # plex   -> Plex Media Server (Jellyfin is always included)
    # usenet -> SABnzbd
    # utils  -> Portainer + Watchtower
    [ValidateSet('plex', 'usenet', 'utils')]
    [string[]]$Profiles = @(),

    [switch]$SkipPull,
    [switch]$SkipWiring
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Common.ps1')

$root = Get-RepoRoot
$envPath = Join-Path $root '.env'
$examplePath = Join-Path $root '.env.example'

Write-Host ""
Write-Host "  Self-hosted media server - Windows bootstrap" -ForegroundColor White
Write-Host "  project root: $root" -ForegroundColor DarkGray

# ---------------------------------------------------------------- 1. preflight
Write-Step "Preflight"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "PowerShell 5.1 or newer is required. Found $($PSVersionTable.PSVersion)."
}

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-Fail "docker was not found on PATH."
    Write-Host "         Install Docker Desktop and enable the WSL2 backend: https://docs.docker.com/desktop/install/windows-install/"
    throw "docker missing"
}
Write-Ok "docker CLI: $((& docker --version) -join '')"

$serverOs = & docker info --format '{{.OSType}}' 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "The Docker engine is not responding. Start Docker Desktop and wait until the whale icon stops animating."
    throw "docker engine unavailable"
}
if ($serverOs -ne 'linux') {
    Write-Fail "Docker is in '$serverOs' container mode. These images are Linux-only."
    Write-Host "         Right-click the Docker tray icon and choose 'Switch to Linux containers'."
    throw "wrong container mode"
}
Write-Ok "engine is in Linux container mode"

$composeVersion = & docker compose version --short 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Compose v2 is required (docker compose ...). Update Docker Desktop."
}
Write-Ok "compose v2: $composeVersion"

# WSL2 is not strictly required, but Hyper-V mode has much worse mount performance.
$wslInfo = & wsl.exe -l -v 2>$null
if ($LASTEXITCODE -eq 0 -and $wslInfo) {
    Write-Ok "WSL is present"
}
else {
    Write-Warn "Could not query WSL. If Docker Desktop is using the Hyper-V backend, expect slow file access on /data."
}

# -------------------------------------------------------------------- 2. .env
Write-Step "Configuration (.env)"

if (-not (Test-Path -LiteralPath $envPath)) {
    Copy-Item -LiteralPath $examplePath -Destination $envPath
    Write-Ok "created .env from .env.example"
}
else {
    Write-Info ".env already exists, only overriding what you passed as parameters"
}

if ($DataRoot) { Set-DotEnvValue -Path $envPath -Key 'DATA_ROOT' -Value (Convert-ToDockerPath $DataRoot) }
if ($ConfigRoot) { Set-DotEnvValue -Path $envPath -Key 'CONFIG_ROOT' -Value (Convert-ToDockerPath $ConfigRoot) }
if ($CacheRoot) { Set-DotEnvValue -Path $envPath -Key 'CACHE_ROOT' -Value (Convert-ToDockerPath $CacheRoot) }
if ($TimeZone) { Set-DotEnvValue -Path $envPath -Key 'TZ' -Value $TimeZone }

# Auto-detect the LAN address unless one was given. Plex and Jellyfin need it
# because host networking does not exist on Docker Desktop for Windows.
if (-not $HostIp) {
    $candidate = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
        Sort-Object -Property SkipAsSource, InterfaceMetric |
        Select-Object -First 1
    if ($candidate) { $HostIp = $candidate.IPAddress }
}
if ($HostIp) {
    Set-DotEnvValue -Path $envPath -Key 'HOST_IP' -Value $HostIp
    Write-Ok "HOST_IP = $HostIp"
}

$conf = Get-DotEnv -Path $envPath
$dataRootDocker = Get-EnvOrDefault -Conf $conf -Key 'DATA_ROOT' -Default 'C:/media'
$configRootDocker = Get-EnvOrDefault -Conf $conf -Key 'CONFIG_ROOT' -Default 'C:/homeserver/config'
$cacheRootDocker = Get-EnvOrDefault -Conf $conf -Key 'CACHE_ROOT' -Default 'C:/homeserver/cache'

# Normalise anything hand-edited with backslashes: Compose mishandles them.
Set-DotEnvValue -Path $envPath -Key 'DATA_ROOT' -Value (Convert-ToDockerPath $dataRootDocker)
Set-DotEnvValue -Path $envPath -Key 'CONFIG_ROOT' -Value (Convert-ToDockerPath $configRootDocker)
Set-DotEnvValue -Path $envPath -Key 'CACHE_ROOT' -Value (Convert-ToDockerPath $cacheRootDocker)

$dataRootWin = Convert-ToWindowsPath $dataRootDocker
$configRootWin = Convert-ToWindowsPath $configRootDocker
$cacheRootWin = Convert-ToWindowsPath $cacheRootDocker

Write-Ok "DATA_ROOT   = $dataRootWin"
Write-Ok "CONFIG_ROOT = $configRootWin"
Write-Ok "CACHE_ROOT  = $cacheRootWin"

# --------------------------------------------------------------- 3. folder tree
Write-Step "Folder layout"

# One root, downloads and library as siblings under it. This is what lets
# Sonarr/Radarr do an instant move (or a hardlink) instead of a full copy.
$dataDirs = @(
    'torrents', 'torrents/incomplete', 'torrents/movies', 'torrents/tv', 'torrents/music', 'torrents/manga',
    'usenet', 'usenet/incomplete',
    # Sonarr and Radarr refuse the recycle bin setting unless the folder already
    # exists and is writable inside the container, so it is created here. A
    # sibling of media/ and torrents/, so deleting into it is a move, not a copy.
    'recycle',
    'media', 'media/movies', 'media/tv', 'media/anime', 'media/music', 'media/manga', 'media/comics', 'media/books'
)
foreach ($d in $dataDirs) {
    $full = Join-Path $dataRootWin (Convert-ToWindowsPath $d)
    if (-not (Test-Path -LiteralPath $full)) { New-Item -ItemType Directory -Path $full -Force | Out-Null }
}
Write-Ok "$($dataDirs.Count) directories under $dataRootWin"

$configDirs = @('qbittorrent', 'sabnzbd', 'prowlarr', 'sonarr', 'radarr', 'lidarr', 'bazarr', 'jellyfin', 'plex', 'jellyseerr', 'komga', 'kavita')
foreach ($d in $configDirs) {
    $full = Join-Path $configRootWin $d
    if (-not (Test-Path -LiteralPath $full)) { New-Item -ItemType Directory -Path $full -Force | Out-Null }
}
foreach ($d in @('jellyfin-transcode', 'plex-transcode')) {
    $full = Join-Path $cacheRootWin $d
    if (-not (Test-Path -LiteralPath $full)) { New-Item -ItemType Directory -Path $full -Force | Out-Null }
}
Write-Ok "config and cache directories ready"

# ------------------------------------------------------------ 4. hardlink probe
Write-Step "Hardlink probe on DATA_ROOT"

# The single biggest difference from the Linux original: on Docker Desktop for
# Windows, a bind mount of an NTFS drive usually cannot do hardlinks. Without
# them, every import is a full copy, so you need free space equal to the file
# being imported and seeding holds a second copy. Worth knowing up front.
$probe = & docker run --rm -v "${dataRootDocker}:/probe" busybox:latest sh -c "cd /probe && rm -f .hardlink_probe* && touch .hardlink_probe && ln .hardlink_probe .hardlink_probe2 2>/dev/null && echo HARDLINK_OK || echo HARDLINK_FAIL; rm -f .hardlink_probe*" 2>$null
if ($probe -match 'HARDLINK_OK') {
    Write-Ok "hardlinks work on this mount - imports will be instant and space-efficient"
}
else {
    Write-Warn "hardlinks are NOT available on $dataRootWin (normal for NTFS bind mounts)."
    Write-Host "         Consequence: Sonarr/Radarr will copy instead of hardlink on import."
    Write-Host "         Options: (a) accept it and keep free space, (b) turn off seeding retention,"
    Write-Host "                  (c) move DATA_ROOT into the WSL2 filesystem (\\wsl`$\...) where hardlinks work."
}

# ------------------------------------------------- 5. seed qBittorrent settings
Write-Step "qBittorrent seed configuration"

$qbtConfDir = Join-Path $configRootWin 'qbittorrent\qBittorrent'
$qbtConf = Join-Path $qbtConfDir 'qBittorrent.conf'
if (-not (Test-Path -LiteralPath $qbtConf)) {
    if (-not (Test-Path -LiteralPath $qbtConfDir)) { New-Item -ItemType Directory -Path $qbtConfDir -Force | Out-Null }
    $torrentPort = Get-EnvOrDefault -Conf $conf -Key 'QBT_TORRENT_PORT' -Default '6881'

    # Excluded file names is the malware defence Akita describes: a "complete"
    # torrent whose only payload is a renamed executable never reaches disk, the
    # import fails, and Sonarr/Radarr blocklist the release and move on.
    $excluded = '*.exe\n*.scr\n*.bat\n*.cmd\n*.msi\n*.lnk\n*.com\n*.vbs\n*.pif\n*.ps1\n*.js\n*.iso'

    $qbtLines = @(
        '[BitTorrent]',
        'Session\DefaultSavePath=/data/torrents',
        'Session\TempPathEnabled=true',
        'Session\TempPath=/data/torrents/incomplete',
        "Session\Port=$torrentPort",
        "Session\ExcludedFileNames=`"$excluded`"",
        'Session\ReannounceWhenAddressChanged=true',
        'Session\GlobalMaxSeedingMinutes=-1',
        '',
        '[Preferences]',
        'Downloads\SavePath=/data/torrents/',
        'Downloads\TempPathEnabled=true',
        'Downloads\TempPath=/data/torrents/incomplete/',
        # Pre-allocation on. It costs a slower start and more SSD writes, and it
        # buys the thing that actually goes wrong here: hardlinks usually fail on
        # an NTFS bind mount, so every import is a full copy and the peak space
        # needed is roughly double the file. Running out mid-import is what this
        # prevents, and the whole point of the stack is that nobody is watching.
        'Downloads\PreAllocation=true',
        'General\Locale=en',
        'WebUI\Port=8080',
        'WebUI\CSRFProtection=false',
        'WebUI\HostHeaderValidation=false',
        'WebUI\LocalHostAuth=false',
        # Docker's own bridge range only. The *arr containers and requests coming
        # through the port mapping land here, so automation needs no password.
        # LAN clients still get the login prompt.
        'WebUI\AuthSubnetWhitelistEnabled=true',
        'WebUI\AuthSubnetWhitelist=172.16.0.0/12'
    )
    Set-Content -LiteralPath $qbtConf -Value $qbtLines -Encoding ASCII
    Write-Ok "wrote $qbtConf (save paths, random-port, executable blocklist)"
}
else {
    Write-Info "qBittorrent.conf already exists, not touching it"
}

# ------------------------------------------------------------------- 6. compose
Write-Step "Starting the stack"

$activeProfiles = @($Profiles)
Write-Info ("profiles: " + ((@('default') + $activeProfiles) -join ', '))

if (-not $SkipPull) {
    Write-Info "pulling images (first run takes a while)"
    $null = Invoke-Compose -Profiles $activeProfiles -Arguments @('pull', '--quiet')
}

$code = Invoke-Compose -Profiles $activeProfiles -Arguments @('up', '-d', '--remove-orphans')
if ($code -ne 0) { throw "docker compose up failed with exit code $code" }
Write-Ok "containers started"

# --------------------------------------------------------------- 7. wait for UI
Write-Step "Waiting for services"

$endpoints = [ordered]@{
    'qBittorrent' = "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'QBT_WEBUI_PORT' -Default '8080')"
    'Prowlarr'    = "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'PROWLARR_PORT' -Default '9696')"
    'Sonarr'      = "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'SONARR_PORT' -Default '8989')"
    'Radarr'      = "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'RADARR_PORT' -Default '7878')"
    'Lidarr'      = "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'LIDARR_PORT' -Default '8686')"
    'Bazarr'      = "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'BAZARR_PORT' -Default '6767')"
    'Jellyfin'    = "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'JELLYFIN_PORT' -Default '8096')"
    'Jellyseerr'  = "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'JELLYSEERR_PORT' -Default '5055')"
    'Komga'       = "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'KOMGA_PORT' -Default '25600')"
    'Kavita'      = "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'KAVITA_PORT' -Default '5001')"
}
foreach ($name in $endpoints.Keys) {
    $null = Wait-HttpOk -Name $name -Url $endpoints[$name] -TimeoutSec 240
}

# -------------------------------------------------------------------- 8. wiring
if (-not $SkipWiring) {
    & (Join-Path $PSScriptRoot 'Wire-Services.ps1')
}
else {
    Write-Warn "-SkipWiring set: services are running but not connected to each other"
}

# ------------------------------------------------------------------- 9. summary
Write-Step "Done"
Write-Host ""
Write-Host ("  {0,-14} {1}" -f 'SERVICE', 'URL') -ForegroundColor White
foreach ($name in $endpoints.Keys) {
    Write-Host ("  {0,-14} {1}" -f $name, $endpoints[$name])
}
if ($activeProfiles -contains 'plex') { Write-Host ("  {0,-14} {1}" -f 'Plex', 'http://localhost:32400/web') }
if ($activeProfiles -contains 'usenet') { Write-Host ("  {0,-14} {1}" -f 'SABnzbd', "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'SABNZBD_PORT' -Default '8085')") }
if ($activeProfiles -contains 'utils') { Write-Host ("  {0,-14} {1}" -f 'Portainer', "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'PORTAINER_PORT' -Default '9000')") }
Write-Host ""
Write-Host "  Remaining manual steps are listed in README.md under 'What the script cannot do'." -ForegroundColor DarkGray
Write-Host ""
