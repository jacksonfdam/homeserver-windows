<#
.SYNOPSIS
    Generates the Homepage dashboard configuration for this stack.

.DESCRIPTION
    Writes settings.yaml, services.yaml, widgets.yaml and bookmarks.yaml into
    CONFIG_ROOT\homepage, with the Sonarr/Radarr/Lidarr/Prowlarr/Bazarr API keys
    read straight out of the running containers.

    A widget is only written once every credential it needs is present. A
    missing one costs you that widget and says so, instead of costing you the
    dashboard: Homepage proxies the call server-side, the app answers 401 in
    plain text, Homepage runs JSON.parse over it and throws, and the page then
    fails to render with a client-side error naming no widget at all.

    Credentials that cannot be read automatically (Jellyfin, Komga, Kavita,
    qBittorrent) are emitted as {{HOMEPAGE_VAR_*}} placeholders. Fill the
    matching entries in .env and the values never touch the config files.

    Existing files are backed up with a .bak-<timestamp> suffix.

.EXAMPLE
    .\New-Dashboard.ps1
    docker compose up -d homepage
#>
[CmdletBinding()]
param(
    [string]$Title = 'Home Server'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Common.ps1')

$repoRoot = Get-RepoRoot
$envPath = Join-Path $repoRoot '.env'
$conf = Get-DotEnv -Path $envPath

$configRoot = Convert-ToWindowsPath (Get-EnvOrDefault -Conf $conf -Key 'CONFIG_ROOT' -Default 'C:/homeserver/config')
$hpDir = Join-Path $configRoot 'homepage'
if (-not (Test-Path -LiteralPath $hpDir)) { New-Item -ItemType Directory -Path $hpDir -Force | Out-Null }

$hostIp = Get-EnvOrDefault -Conf $conf -Key 'HOST_IP' -Default 'localhost'
$hpPort = Get-EnvOrDefault -Conf $conf -Key 'HOMEPAGE_PORT' -Default '3000'

# Allowed hosts must cover every address you open the dashboard from, or
# Homepage returns a blank page with a host validation error.
$allowed = "localhost:$hpPort,127.0.0.1:$hpPort,$hostIp`:$hpPort"
Set-DotEnvValue -Path $envPath -Key 'HOMEPAGE_ALLOWED_HOSTS' -Value $allowed
Write-Ok "HOMEPAGE_ALLOWED_HOSTS = $allowed"

# ------------------------------------------------------------------- api keys
Write-Step "Collecting API keys"

$keys = @{}
foreach ($svc in @('sonarr', 'radarr', 'lidarr', 'prowlarr')) {
    $k = Get-ArrApiKey -Container $svc -TimeoutSec 20
    if ($k) { $keys[$svc] = $k; Write-Ok "$svc" }
    else { $keys[$svc] = ''; Write-Warn "$svc not reachable, widget will be left blank" }
}

$bazarrKey = ''
try {
    $yaml = & docker exec bazarr sh -c "cat /config/config/config.yaml 2>/dev/null || cat /config/config.yaml 2>/dev/null"
    if ($yaml) {
        $m = [regex]::Match(($yaml -join "`n"), 'apikey:\s*([A-Za-z0-9]+)')
        if ($m.Success) { $bazarrKey = $m.Groups[1].Value; Write-Ok "bazarr" }
    }
}
catch { Write-Warn "bazarr key not readable" }

# --------------------------------------------------------------------- writing
function Write-HomepageFile {
    param([string]$Name, [string]$Content)
    $path = Join-Path $hpDir $Name
    if (Test-Path -LiteralPath $path) {
        $backup = "$path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $path -Destination $backup
        Write-Info "existing $Name backed up"
    }
    Set-Content -LiteralPath $path -Value $Content -Encoding UTF8
    Write-Ok "wrote $Name"
}

# A widget whose credential is missing does not degrade quietly. Homepage proxies
# the call server-side, the app answers with a plain-text error, Homepage runs
# JSON.parse over it and throws - and the page then fails to render at all, with
# a client-side "Cannot read properties of undefined" and no clue as to which
# widget caused it. Observed with Kavita answering 401 in text.
#
# So a widget is only written once every credential it needs is actually present.
# A missing credential costs you that one widget instead of the dashboard.
function Get-WidgetOrNothing {
    param(
        [Parameter(Mandatory = $true)][string]$Block,
        [Parameter(Mandatory = $true)][string]$For,
        [Parameter(Mandatory = $true)][string[]]$RequiredKeys
    )
    foreach ($k in $RequiredKeys) {
        if (-not (Get-EnvOrDefault -Conf $conf -Key $k -Default '')) {
            Write-Warn "$For widget skipped: $k is empty in .env"
            return ''
        }
    }
    return $Block
}

# The *arr keys are read out of the running containers, so they come back empty
# when a container is not up. Same hazard: an empty key means a 401 answered in
# text, which is what breaks the render.
function Get-KeyedWidget {
    param(
        [Parameter(Mandatory = $true)][string]$Block,
        [Parameter(Mandatory = $true)][string]$For,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Key
    )
    if (-not $Key) {
        Write-Warn "$For widget skipped: its API key could not be read"
        return ''
    }
    return $Block
}

$jellyfinWidget = Get-WidgetOrNothing -For 'Jellyfin' -RequiredKeys @('HOMEPAGE_VAR_JELLYFIN_KEY') -Block @"

        widget:
          type: jellyfin
          url: http://jellyfin:8096
          key: {{HOMEPAGE_VAR_JELLYFIN_KEY}}
          enableBlocks: true
          enableNowPlaying: true
"@

# Komga and Kavita each accept either an API key or a username and password, and
# what their UIs actually hand you is a key - Kavita shows it inside the OPDS
# URL, Komga under Account settings. Generating only the username form asked for
# the credential you are least likely to have, so the key comes first here and
# the login pair is the fallback.
function Get-ReaderWidget {
    param(
        [Parameter(Mandatory = $true)][string]$For,
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Url,
        # The name to look up in .env, and the name to write into the YAML. They
        # differ on purpose: the key already lives in .env as KOMGA_API_KEY for
        # Import-MangaLists.ps1, while Homepage only substitutes variables
        # carrying its own HOMEPAGE_VAR_ prefix, which docker-compose.yml maps
        # it to. Checking the placeholder name here would always come back empty.
        [Parameter(Mandatory = $true)][string]$KeyEnvVar,
        [Parameter(Mandatory = $true)][string]$KeyPlaceholder,
        [Parameter(Mandatory = $true)][string]$UserVar,
        [Parameter(Mandatory = $true)][string]$PassVar
    )
    $head = "`n`n        widget:`n          type: $Type`n          url: $Url"

    if (Get-EnvOrDefault -Conf $conf -Key $KeyEnvVar -Default '') {
        Write-Info "$For widget will use $KeyEnvVar"
        return "$head`n          key: {{$KeyPlaceholder}}"
    }
    if ((Get-EnvOrDefault -Conf $conf -Key $UserVar -Default '') -and
        (Get-EnvOrDefault -Conf $conf -Key $PassVar -Default '')) {
        return "$head`n          username: {{$UserVar}}`n          password: {{$PassVar}}"
    }

    Write-Warn "$For widget skipped: set $KeyEnvVar, or both $UserVar and $PassVar"
    return ''
}

$komgaWidget = Get-ReaderWidget -For 'Komga' -Type 'komga' -Url 'http://komga:25600' `
    -KeyEnvVar 'KOMGA_API_KEY' -KeyPlaceholder 'HOMEPAGE_VAR_KOMGA_KEY' `
    -UserVar 'HOMEPAGE_VAR_KOMGA_USER' -PassVar 'HOMEPAGE_VAR_KOMGA_PASSWORD'

$kavitaWidget = Get-ReaderWidget -For 'Kavita' -Type 'kavita' -Url 'http://kavita:5000' `
    -KeyEnvVar 'KAVITA_API_KEY' -KeyPlaceholder 'HOMEPAGE_VAR_KAVITA_KEY' `
    -UserVar 'HOMEPAGE_VAR_KAVITA_USER' -PassVar 'HOMEPAGE_VAR_KAVITA_PASSWORD'

$qbtWidget = Get-WidgetOrNothing -For 'qBittorrent' -RequiredKeys @('HOMEPAGE_VAR_QBT_USER', 'HOMEPAGE_VAR_QBT_PASSWORD') -Block @"

        widget:
          type: qbittorrent
          url: http://qbittorrent:8080
          username: {{HOMEPAGE_VAR_QBT_USER}}
          password: {{HOMEPAGE_VAR_QBT_PASSWORD}}
"@

$sonarrWidget = Get-KeyedWidget -For 'Sonarr' -Key $keys['sonarr'] -Block @"

        widget:
          type: sonarr
          url: http://sonarr:8989
          key: $($keys['sonarr'])
          enableQueue: true
"@

$radarrWidget = Get-KeyedWidget -For 'Radarr' -Key $keys['radarr'] -Block @"

        widget:
          type: radarr
          url: http://radarr:7878
          key: $($keys['radarr'])
          enableQueue: true
"@

$lidarrWidget = Get-KeyedWidget -For 'Lidarr' -Key $keys['lidarr'] -Block @"

        widget:
          type: lidarr
          url: http://lidarr:8686
          key: $($keys['lidarr'])
"@

$prowlarrWidget = Get-KeyedWidget -For 'Prowlarr' -Key $keys['prowlarr'] -Block @"

        widget:
          type: prowlarr
          url: http://prowlarr:9696
          key: $($keys['prowlarr'])
"@

$bazarrWidget = Get-KeyedWidget -For 'Bazarr' -Key $bazarrKey -Block @"

        widget:
          type: bazarr
          url: http://bazarr:6767
          key: $bazarrKey
"@

Write-Step "Writing dashboard config"

$settings = @"
---
title: $Title
description: Media, comics and automation
startUrl: http://${hostIp}:$hpPort

theme: dark
color: slate
headerStyle: boxed
hideVersion: true

# The groups below are the answer to "what do I feel like doing right now".
layout:
  Watch:
    style: row
    columns: 3
    icon: mdi-television-play
  Read:
    style: row
    columns: 3
    icon: mdi-book-open-page-variant
  Discover:
    style: row
    columns: 2
    icon: mdi-magnify
  Automation:
    style: row
    columns: 4
    icon: mdi-robot
  Downloads:
    style: row
    columns: 2
    icon: mdi-download
"@

# Container-internal URLs are used for widget API calls (server side), and
# host URLs for the clickable links (browser side). Mixing these up is the
# single most common reason a widget shows "API Error".
$services = @"
---
- Watch:
    - Jellyfin:
        icon: jellyfin.png
        href: http://${hostIp}:$(Get-EnvOrDefault -Conf $conf -Key 'JELLYFIN_PORT' -Default '8096')
        description: Movies, TV and anime$jellyfinWidget

    - Plex:
        icon: plex.png
        href: http://${hostIp}:32400/web
        description: Only running with the plex profile

- Read:
    - Komga:
        icon: komga.png
        href: http://${hostIp}:$(Get-EnvOrDefault -Conf $conf -Key 'KOMGA_PORT' -Default '25600')
        description: Manga and comics$komgaWidget

    - Kavita:
        icon: kavita.png
        href: http://${hostIp}:$(Get-EnvOrDefault -Conf $conf -Key 'KAVITA_PORT' -Default '5001')
        description: Manga, comics and ebooks$kavitaWidget

- Discover:
    - Jellyseerr:
        icon: jellyseerr.png
        href: http://${hostIp}:$(Get-EnvOrDefault -Conf $conf -Key 'JELLYSEERR_PORT' -Default '5055')
        description: Request something new

- Automation:
    - Sonarr:
        icon: sonarr.png
        href: http://${hostIp}:$(Get-EnvOrDefault -Conf $conf -Key 'SONARR_PORT' -Default '8989')
        description: TV and anime$sonarrWidget

    - Radarr:
        icon: radarr.png
        href: http://${hostIp}:$(Get-EnvOrDefault -Conf $conf -Key 'RADARR_PORT' -Default '7878')
        description: Movies$radarrWidget

    - Lidarr:
        icon: lidarr.png
        href: http://${hostIp}:$(Get-EnvOrDefault -Conf $conf -Key 'LIDARR_PORT' -Default '8686')
        description: Music$lidarrWidget

    - Bazarr:
        icon: bazarr.png
        href: http://${hostIp}:$(Get-EnvOrDefault -Conf $conf -Key 'BAZARR_PORT' -Default '6767')
        description: Subtitles$bazarrWidget

- Downloads:
    - qBittorrent:
        icon: qbittorrent.png
        href: http://${hostIp}:$(Get-EnvOrDefault -Conf $conf -Key 'QBT_WEBUI_PORT' -Default '8080')
        description: Torrent client$qbtWidget

    - Prowlarr:
        icon: prowlarr.png
        href: http://${hostIp}:$(Get-EnvOrDefault -Conf $conf -Key 'PROWLARR_PORT' -Default '9696')
        description: Indexer manager$prowlarrWidget
"@

$widgets = @"
---
- resources:
    cpu: true
    memory: true
    disk: /

- search:
    provider: duckduckgo
    target: _blank

- datetime:
    text_size: xl
    format:
      timeStyle: short
      dateStyle: long
"@

$bookmarks = @"
---
- Manage:
    - Portainer:
        - abbr: PT
          href: http://${hostIp}:$(Get-EnvOrDefault -Conf $conf -Key 'PORTAINER_PORT' -Default '9000')

- Docs:
    - Komga:
        - abbr: KO
          href: https://komga.org/docs/introduction
    - Kavita:
        - abbr: KA
          href: https://wiki.kavitareader.com/
    - Servarr wiki:
        - abbr: SW
          href: https://wiki.servarr.com/
"@

Write-HomepageFile -Name 'settings.yaml' -Content $settings
Write-HomepageFile -Name 'services.yaml' -Content $services
Write-HomepageFile -Name 'widgets.yaml' -Content $widgets
Write-HomepageFile -Name 'bookmarks.yaml' -Content $bookmarks

# Homepage looks for this file; an empty one keeps it from logging errors.
$dockerYaml = Join-Path $hpDir 'docker.yaml'
if (-not (Test-Path -LiteralPath $dockerYaml)) { Set-Content -LiteralPath $dockerYaml -Value '---' -Encoding UTF8 }

Write-Step "Next"
Write-Host "    1. Fill these in .env if you want the live widgets:"
Write-Host "       HOMEPAGE_VAR_JELLYFIN_KEY   (Jellyfin > Dashboard > Advanced > API Keys)"
Write-Host "       KOMGA_API_KEY             (Komga > Account settings > API keys)"
Write-Host "         or HOMEPAGE_VAR_KOMGA_USER / _PASSWORD"
Write-Host "       KAVITA_API_KEY            (Kavita > Settings > Account > API Key)"
Write-Host "         or HOMEPAGE_VAR_KAVITA_USER / _PASSWORD   (needs the Admin role)"
Write-Host "       HOMEPAGE_VAR_QBT_USER / _PASSWORD"
Write-Host "    2. docker compose up -d homepage"
Write-Host "    3. http://${hostIp}:$hpPort"
Write-Host ""
Write-Info "the tiles work without any of the above - only the live stats need credentials"
