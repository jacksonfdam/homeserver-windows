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
