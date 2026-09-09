# Shared helpers. Dot-sourced by the other scripts, not meant to be run directly.
# Targets Windows PowerShell 5.1 as well as PowerShell 7+, so no ?., ?? or ternaries.

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    [ok]   $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "    ....   $Message" -ForegroundColor Gray }
function Write-Warn { param([string]$Message) Write-Host "    [warn] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "    [fail] $Message" -ForegroundColor Red }

function Get-RepoRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

# Docker Desktop accepts forward slashes for Windows paths and Compose parses
# them far more reliably than backslashes inside volume definitions.
function Convert-ToDockerPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $p = $Path.Trim().Replace('\', '/')
    while ($p.EndsWith('/') -and $p.Length -gt 3) { $p = $p.Substring(0, $p.Length - 1) }
    return $p
}

function Convert-ToWindowsPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $Path.Trim().Replace('/', '\')
}

function Get-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        $idx = $trimmed.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()
        $map[$key] = $value
    }
    return $map
}

function Set-DotEnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )
    $lines = @()
    if (Test-Path -LiteralPath $Path) { $lines = @(Get-Content -LiteralPath $Path) }
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$([regex]::Escape($Key))\s*=") {
            $lines[$i] = "$Key=$Value"
            $found = $true
        }
    }
    if (-not $found) { $lines += "$Key=$Value" }
    Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
}

function Get-EnvOrDefault {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Conf,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Default
    )
    if ($Conf.ContainsKey($Key) -and $Conf[$Key] -ne '') { return $Conf[$Key] }
    return $Default
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string[]]$Profiles = @()
    )
    $root = Get-RepoRoot
    $composeArgs = @('compose', '--project-directory', $root, '-f', (Join-Path $root 'docker-compose.yml'))
    foreach ($p in $Profiles) { $composeArgs += @('--profile', $p) }
    $composeArgs += $Arguments
    # Out-Host keeps docker's output on screen instead of returning it, so the
    # caller gets the exit code and nothing else.
    & docker @composeArgs | Out-Host
    return $LASTEXITCODE
}

function Test-HttpOk {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSec = 5
    )
    try {
        $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $true
    }
    catch {
        # A 401/403 still proves the listener is up, which is all we need here.
        $ex = $_.Exception
        if ($ex -and ($ex.PSObject.Properties.Name -contains 'Response') -and $ex.Response) { return $true }
        return $false
    }
}

function Wait-HttpOk {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSec = 180
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-HttpOk -Url $Url) {
            Write-Ok "$Name is answering on $Url"
            return $true
        }
        Start-Sleep -Seconds 3
    }
    Write-Warn "$Name did not answer on $Url within $TimeoutSec s"
    return $false
}

# Sonarr/Radarr/Lidarr/Prowlarr all write their API key into /config/config.xml
# on first start. Reading it from inside the container avoids depending on how
# the bind mount surfaces on the Windows side.
function Get-ArrApiKey {
    param(
        [Parameter(Mandatory = $true)][string]$Container,
        [int]$TimeoutSec = 120
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $xml = & docker exec $Container cat /config/config.xml 2>$null
        if ($LASTEXITCODE -eq 0 -and $xml) {
            $joined = ($xml -join "`n")
            $m = [regex]::Match($joined, '<ApiKey>([^<]+)</ApiKey>')
            if ($m.Success) { return $m.Groups[1].Value }
        }
        Start-Sleep -Seconds 3
    }
    return $null
}

function Invoke-ArrApi {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method = 'GET',
        $Body = $null
    )
    $headers = @{ 'X-Api-Key' = $ApiKey; 'Accept' = 'application/json' }
    $uri = "$BaseUrl$Path"
    if ($Body -ne $null) {
        $json = $Body | ConvertTo-Json -Depth 20 -Compress
        return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -ContentType 'application/json' -Body $json -TimeoutSec 60
    }
    return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -TimeoutSec 60
}

# Every *arr provider (download client, indexer, application) is defined by a
# schema the app itself publishes. Fetching the schema and only overriding the
# fields we care about keeps this script working across app versions instead of
# hardcoding a field list that breaks on the next release.
function New-ProviderFromSchema {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [Parameter(Mandatory = $true)][string]$SchemaPath,      # e.g. /api/v3/downloadclient/schema
        [Parameter(Mandatory = $true)][string]$CreatePath,      # e.g. /api/v3/downloadclient
        [Parameter(Mandatory = $true)][string]$Implementation,  # e.g. QBittorrent
        [Parameter(Mandatory = $true)][string]$Name,
        [hashtable]$Fields = @{},
        [hashtable]$TopLevel = @{}
    )
    $existing = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $ApiKey -Path $CreatePath
    foreach ($item in @($existing)) {
        if ($item -and $item.name -eq $Name) {
            Write-Info "$Name already registered, leaving it alone"
            return $item
        }
    }

    $schemas = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $ApiKey -Path $SchemaPath
    $schema = $null
    foreach ($s in @($schemas)) {
        if ($s.implementation -eq $Implementation) { $schema = $s; break }
    }
    if ($schema -eq $null) { throw "No schema with implementation '$Implementation' at $SchemaPath" }

    $schema.name = $Name
    foreach ($key in $TopLevel.Keys) {
        $schema | Add-Member -NotePropertyName $key -NotePropertyValue $TopLevel[$key] -Force
    }
    foreach ($field in @($schema.fields)) {
        if ($Fields.ContainsKey($field.name)) {
            $field | Add-Member -NotePropertyName 'value' -NotePropertyValue $Fields[$field.name] -Force
        }
    }

    $created = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $ApiKey -Path $CreatePath -Method POST -Body $schema
    Write-Ok "registered $Name"
    return $created
}

# ============================================================== state probes
# Everything below answers "what is actually true right now" and returns data
# rather than printing it, so a caller can render it, diff it, or act on it.
# Get-HomeServerStatus.ps1 is the first caller. None of these mutate anything.

# The canonical service list. Port, container name and whether the wiring script
# is expected to have configured it. Setup-HomeServer.ps1 and Wire-Services.ps1
# each still carry their own port lookups; they should adopt this eventually,
# which is why it lives here rather than in the status script.
function Get-ServiceMap {
    param([Parameter(Mandatory = $true)][hashtable]$Conf)
    return @(
        @{ name = 'qBittorrent'; container = 'qbittorrent'; port = (Get-EnvOrDefault -Conf $Conf -Key 'QBT_WEBUI_PORT' -Default '8080'); arr = $false }
        @{ name = 'Prowlarr';    container = 'prowlarr';    port = (Get-EnvOrDefault -Conf $Conf -Key 'PROWLARR_PORT' -Default '9696'); arr = $true; api = 'v1' }
        @{ name = 'Sonarr';      container = 'sonarr';      port = (Get-EnvOrDefault -Conf $Conf -Key 'SONARR_PORT' -Default '8989'); arr = $true; api = 'v3' }
        @{ name = 'Radarr';      container = 'radarr';      port = (Get-EnvOrDefault -Conf $Conf -Key 'RADARR_PORT' -Default '7878'); arr = $true; api = 'v3' }
        @{ name = 'Lidarr';      container = 'lidarr';      port = (Get-EnvOrDefault -Conf $Conf -Key 'LIDARR_PORT' -Default '8686'); arr = $true; api = 'v1' }
        @{ name = 'Bazarr';      container = 'bazarr';      port = (Get-EnvOrDefault -Conf $Conf -Key 'BAZARR_PORT' -Default '6767'); arr = $false }
        @{ name = 'Jellyfin';    container = 'jellyfin';    port = (Get-EnvOrDefault -Conf $Conf -Key 'JELLYFIN_PORT' -Default '8096'); arr = $false }
        @{ name = 'Jellyseerr';  container = 'jellyseerr';  port = (Get-EnvOrDefault -Conf $Conf -Key 'JELLYSEERR_PORT' -Default '5055'); arr = $false }
        @{ name = 'Komga';       container = 'komga';       port = (Get-EnvOrDefault -Conf $Conf -Key 'KOMGA_PORT' -Default '25600'); arr = $false }
        @{ name = 'Kavita';      container = 'kavita';      port = (Get-EnvOrDefault -Conf $Conf -Key 'KAVITA_PORT' -Default '5001'); arr = $false }
        @{ name = 'Homepage';    container = 'homepage';    port = (Get-EnvOrDefault -Conf $Conf -Key 'HOMEPAGE_PORT' -Default '3000'); arr = $false }
    )
}

function Get-DockerState {
    $state = [PSCustomObject]@{
        cliFound       = $false
        engineUp       = $false
        osType         = ''
        composeVersion = ''
        message        = ''
    }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        $state.message = 'docker is not on PATH'
        return $state
    }
    $state.cliFound = $true

    $osType = & docker info --format '{{.OSType}}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        $state.message = 'the engine is not responding - is Docker Desktop running?'
        return $state
    }
    $state.engineUp = $true
    $state.osType = ($osType -join '').Trim()
    if ($state.osType -ne 'linux') {
        $state.message = "engine is in '$($state.osType)' mode, but these images are Linux-only"
    }

    $composeVersion = & docker compose version --short 2>$null
    if ($LASTEXITCODE -eq 0) { $state.composeVersion = ($composeVersion -join '').Trim() }
    else { $state.message = 'Compose v2 is missing' }

    return $state
}

# Keys the template documents but the live .env does not carry. This is the
# check that explains a blank Homepage widget without opening anything: the
# HOMEPAGE_VAR_* values were added to the template long after most .env files
# were created, and Setup-HomeServer.ps1 only ever writes back five keys.
function Get-EnvGaps {
    param(
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $true)][string]$ExamplePath
    )
    $result = [PSCustomObject]@{
        envExists     = (Test-Path -LiteralPath $EnvPath)
        exampleExists = (Test-Path -LiteralPath $ExamplePath)
        missingKeys   = @()
        emptyKeys     = @()
    }
    if (-not $result.envExists -or -not $result.exampleExists) { return $result }

    $live = Get-DotEnv -Path $EnvPath
    $template = Get-DotEnv -Path $ExamplePath
    $missing = @()
    $empty = @()
    foreach ($key in $template.Keys) {
        if (-not $live.ContainsKey($key)) { $missing += $key }
        elseif ($live[$key] -eq '' -and $template[$key] -ne '') { $empty += $key }
    }
    $result.missingKeys = @($missing | Sort-Object)
    $result.emptyKeys = @($empty | Sort-Object)
    return $result
}

# The folder tree Setup-HomeServer.ps1 creates. 'recycle' is the one most likely
# to be absent on an older install, and Sonarr and Radarr reject the recycle bin
# setting outright when it is.
function Get-PathState {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$ConfigRoot
    )
    $expected = @(
        'torrents', 'torrents/incomplete', 'torrents/movies', 'torrents/tv',
        'torrents/music', 'torrents/manga', 'usenet', 'usenet/incomplete', 'recycle',
        'media', 'media/movies', 'media/tv', 'media/anime', 'media/music',
        'media/manga', 'media/comics', 'media/books'
    )
    $missing = @()
    foreach ($d in $expected) {
        $full = Join-Path $DataRoot (Convert-ToWindowsPath $d)
        if (-not (Test-Path -LiteralPath $full)) { $missing += $d }
    }
    return [PSCustomObject]@{
        dataRootExists   = (Test-Path -LiteralPath $DataRoot)
        configRootExists = (Test-Path -LiteralPath $ConfigRoot)
        missing          = @($missing)
    }
}

function Get-ContainerState {
    $running = @{}
    $lines = & docker ps --format '{{.Names}}|{{.Status}}' 2>$null
    if ($LASTEXITCODE -ne 0) { return $running }
    foreach ($line in @($lines)) {
        if (-not $line) { continue }
        $parts = $line.Split('|')
        if ($parts.Count -ge 2) { $running[$parts[0]] = $parts[1] }
    }
    return $running
}

# Everything the wiring script is responsible for, read back from the app.
# -WithCustomFormats is off by default because only Radarr is configured with
# them here, and asking an app that has none just adds a request.
function Get-ArrState {
    param(
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Api,
        [switch]$WithCustomFormats
    )
    $state = [PSCustomObject]@{
        apiKeyFound    = $false
        downloadClients = 0
        rootFolders    = @()
        qualityFloored = $false
        renaming       = $false
        recycleBin     = ''
        propers        = ''
        customFormats  = @()
        error          = ''
    }

    $key = Get-ArrApiKey -Container $Container -TimeoutSec 10
    if (-not $key) {
        $state.error = 'could not read the API key from the container'
        return $state
    }
    $state.apiKeyFound = $true

    try {
        $clients = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $key -Path "/api/$Api/downloadclient"
        $state.downloadClients = @($clients).Count

        $folders = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $key -Path "/api/$Api/rootfolder"
        $paths = @()
        foreach ($f in @($folders)) { if ($f -and $f.path) { $paths += $f.path } }
        $state.rootFolders = @($paths)

        # A single definition with a non-zero minimum is enough to know the
        # floors were applied: they all ship at zero.
        $defs = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $key -Path "/api/$Api/qualitydefinition"
        foreach ($d in @($defs)) {
            if ($d -and $d.minSize -and $d.minSize -gt 0) { $state.qualityFloored = $true; break }
        }

        $naming = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $key -Path "/api/$Api/config/naming"
        # Sonarr calls it renameEpisodes and Radarr renameMovies, so check both
        # rather than branching on which app this is.
        foreach ($prop in @('renameEpisodes', 'renameMovies')) {
            if (($naming.PSObject.Properties.Name -contains $prop) -and $naming.$prop) { $state.renaming = $true }
        }

        $mm = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $key -Path "/api/$Api/config/mediamanagement"
        if ($mm.PSObject.Properties.Name -contains 'recycleBin') { $state.recycleBin = $mm.recycleBin }
        if ($mm.PSObject.Properties.Name -contains 'downloadPropersAndRepacks') { $state.propers = $mm.downloadPropersAndRepacks }

        if ($WithCustomFormats) {
            $formats = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $key -Path "/api/$Api/customformat"
            $profiles = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $key -Path "/api/$Api/qualityprofile"
            $seen = @()
            foreach ($f in @($formats)) {
                if (-not $f) { continue }
                # A format that exists but is never scored rejects nothing, so
                # the score is the part worth reporting, not the name.
                $score = 0
                foreach ($p in @($profiles)) {
                    foreach ($item in @($p.formatItems)) {
                        if ($item.format -eq $f.id -and $item.score -ne 0) { $score = $item.score }
                    }
                }
                $seen += [PSCustomObject]@{ name = $f.name; score = $score }
            }
            $state.customFormats = @($seen)
        }
    }
    catch {
        $state.error = $_.Exception.Message
    }
    return $state
}

function Get-MirrorState {
    param([Parameter(Mandatory = $true)][string]$Root)
    $dbPath = Join-Path $Root 'series.sqlite'
    $shaPath = Join-Path $Root 'series.sqlite.sha1'
    $state = [PSCustomObject]@{
        present     = (Test-Path -LiteralPath $dbPath)
        sizeGb      = 0
        lastWritten = $null
        sha         = ''
    }
    if (-not $state.present) { return $state }
    $item = Get-Item -LiteralPath $dbPath
    $state.sizeGb = [Math]::Round($item.Length / 1GB, 2)
    $state.lastWritten = $item.LastWriteTime
    if (Test-Path -LiteralPath $shaPath) {
        $state.sha = (Get-Content -LiteralPath $shaPath -Raw).Trim()
    }
    return $state
}
