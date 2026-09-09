<#
.SYNOPSIS
    Connects the running containers to each other over their REST APIs.

.DESCRIPTION
    Everything here is idempotent and driven by each app's own /schema endpoint,
    so it survives version bumps instead of hardcoding field lists.

    What it does:
      1. reads the API key of Prowlarr / Sonarr / Radarr / Lidarr from config.xml
      2. registers qBittorrent as the download client in all three *arr apps
         (one category each, so downloads never get mixed up)
      3. creates the root folders inside /data/media
      4. registers Sonarr / Radarr / Lidarr as applications in Prowlarr, plus
         qBittorrent, so Prowlarr is the single place that manages indexers
      5. points Bazarr at Sonarr and Radarr (best effort - see README)
      6. optionally applies minimum file sizes per quality, plus custom formats
         scored into the floor for release shapes never worth downloading:
         executable payloads, whole-disc rips and stereoscopic 3D. Sonarr gets
         a release profile for the first, Radarr gets all three
         (-ApplyQualityFloors)

    It deliberately does NOT add indexers. Which indexers you use, and whether
    you are entitled to what you pull from them, is your call to make.

.EXAMPLE
    .\Wire-Services.ps1 -ApplyQualityFloors
#>
[CmdletBinding()]
param(
    [switch]$ApplyQualityFloors
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Common.ps1')

$root = Get-RepoRoot
$conf = Get-DotEnv -Path (Join-Path $root '.env')

$ports = @{
    prowlarr = Get-EnvOrDefault -Conf $conf -Key 'PROWLARR_PORT' -Default '9696'
    sonarr   = Get-EnvOrDefault -Conf $conf -Key 'SONARR_PORT' -Default '8989'
    radarr   = Get-EnvOrDefault -Conf $conf -Key 'RADARR_PORT' -Default '7878'
    lidarr   = Get-EnvOrDefault -Conf $conf -Key 'LIDARR_PORT' -Default '8686'
    bazarr   = Get-EnvOrDefault -Conf $conf -Key 'BAZARR_PORT' -Default '6767'
}

# Host-side URLs are used by this script; container-side URLs are what the
# services must use to reach each other (Compose DNS resolves service names).
$hostUrl = @{
    prowlarr = "http://localhost:$($ports.prowlarr)"
    sonarr   = "http://localhost:$($ports.sonarr)"
    radarr   = "http://localhost:$($ports.radarr)"
    lidarr   = "http://localhost:$($ports.lidarr)"
    bazarr   = "http://localhost:$($ports.bazarr)"
}

Write-Step "Reading API keys"
$apiKey = @{}
foreach ($svc in @('prowlarr', 'sonarr', 'radarr', 'lidarr')) {
    $key = Get-ArrApiKey -Container $svc
    if (-not $key) { throw "Could not read the API key from container '$svc'. Is it running? (docker logs $svc)" }
    $apiKey[$svc] = $key
    Write-Ok "$svc api key found"
}

# ------------------------------------------------- download client in each *arr
Write-Step "qBittorrent as download client"

$qbtCommon = @{
    'host'     = 'qbittorrent'
    'port'     = 8080
    'useSsl'   = $false
    'urlBase'  = ''
    'username' = ''
    'password' = ''
}

$clients = @(
    @{ svc = 'sonarr'; api = 'v3'; categoryField = 'tvCategory'; category = 'tv-sonarr' },
    @{ svc = 'radarr'; api = 'v3'; categoryField = 'movieCategory'; category = 'radarr' },
    @{ svc = 'lidarr'; api = 'v1'; categoryField = 'musicCategory'; category = 'lidarr' }
)

foreach ($c in $clients) {
    $fields = $qbtCommon.Clone()
    $fields[$c.categoryField] = $c.category
    try {
        $null = New-ProviderFromSchema -BaseUrl $hostUrl[$c.svc] -ApiKey $apiKey[$c.svc] `
            -SchemaPath "/api/$($c.api)/downloadclient/schema" `
            -CreatePath "/api/$($c.api)/downloadclient" `
            -Implementation 'QBittorrent' -Name 'qBittorrent' -Fields $fields `
            -TopLevel @{ enable = $true; priority = 1; removeCompletedDownloads = $true; removeFailedDownloads = $true }
    }
    catch {
        Write-Fail "$($c.svc): $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------ root folders
Write-Step "Root folders"

$rootFolders = @(
    @{ svc = 'sonarr'; api = 'v3'; path = '/data/media/tv' },
    @{ svc = 'sonarr'; api = 'v3'; path = '/data/media/anime' },
    @{ svc = 'radarr'; api = 'v3'; path = '/data/media/movies' },
    @{ svc = 'lidarr'; api = 'v1'; path = '/data/media/music' }
)

foreach ($rf in $rootFolders) {
    try {
        $existing = Invoke-ArrApi -BaseUrl $hostUrl[$rf.svc] -ApiKey $apiKey[$rf.svc] -Path "/api/$($rf.api)/rootfolder"
        $already = $false
        foreach ($item in @($existing)) {
            if ($item -and $item.path -and $item.path.TrimEnd('/') -eq $rf.path) { $already = $true }
        }
        if ($already) {
            Write-Info "$($rf.svc): $($rf.path) already present"
            continue
        }
        $body = @{ path = $rf.path }
        # Lidarr additionally wants a metadata/quality profile on the root folder.
        if ($rf.svc -eq 'lidarr') {
            $qp = Invoke-ArrApi -BaseUrl $hostUrl.lidarr -ApiKey $apiKey.lidarr -Path '/api/v1/qualityprofile'
            $mp = Invoke-ArrApi -BaseUrl $hostUrl.lidarr -ApiKey $apiKey.lidarr -Path '/api/v1/metadataprofile'
            $body['name'] = 'Music'
            $body['defaultQualityProfileId'] = @($qp)[0].id
            $body['defaultMetadataProfileId'] = @($mp)[0].id
            $body['defaultMonitorOption'] = 'all'
            $body['defaultNewItemMonitorOption'] = 'all'
            $body['defaultTags'] = @()
        }
        $null = Invoke-ArrApi -BaseUrl $hostUrl[$rf.svc] -ApiKey $apiKey[$rf.svc] -Path "/api/$($rf.api)/rootfolder" -Method POST -Body $body
        Write-Ok "$($rf.svc): $($rf.path)"
    }
    catch {
        Write-Fail "$($rf.svc) root folder $($rf.path): $($_.Exception.Message)"
    }
}

# --------------------------------------------------------------- Prowlarr apps
Write-Step "Prowlarr application sync"

# Prowlarr becomes the only place indexers are managed. It pushes them into the
# other apps, which is why you should not add indexers directly in Sonarr/Radarr.
$apps = @(
    @{ impl = 'Sonarr'; name = 'Sonarr'; url = 'http://sonarr:8989'; key = $apiKey.sonarr },
    @{ impl = 'Radarr'; name = 'Radarr'; url = 'http://radarr:7878'; key = $apiKey.radarr },
    @{ impl = 'Lidarr'; name = 'Lidarr'; url = 'http://lidarr:8686'; key = $apiKey.lidarr }
)

foreach ($a in $apps) {
    try {
        $null = New-ProviderFromSchema -BaseUrl $hostUrl.prowlarr -ApiKey $apiKey.prowlarr `
            -SchemaPath '/api/v1/applications/schema' -CreatePath '/api/v1/applications' `
            -Implementation $a.impl -Name $a.name `
            -Fields @{ 'prowlarrUrl' = 'http://prowlarr:9696'; 'baseUrl' = $a.url; 'apiKey' = $a.key } `
            -TopLevel @{ syncLevel = 'fullSync' }
    }
    catch {
        Write-Fail "Prowlarr -> $($a.name): $($_.Exception.Message)"
    }
}

try {
    $null = New-ProviderFromSchema -BaseUrl $hostUrl.prowlarr -ApiKey $apiKey.prowlarr `
        -SchemaPath '/api/v1/downloadclient/schema' -CreatePath '/api/v1/downloadclient' `
        -Implementation 'QBittorrent' -Name 'qBittorrent' `
        -Fields $qbtCommon -TopLevel @{ enable = $true; priority = 1 }
}
catch {
    Write-Fail "Prowlarr -> qBittorrent: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------- Bazarr
Write-Step "Bazarr integration"

# Bazarr keeps its API key in config.yaml and its settings endpoint takes form
# data rather than JSON. This is the flakiest part of the wiring, so failures
# here are reported and skipped instead of aborting the run.
try {
    $yaml = & docker exec bazarr sh -c "cat /config/config/config.yaml 2>/dev/null || cat /config/config.yaml 2>/dev/null"
    $bazarrKey = $null
    if ($yaml) {
        $m = [regex]::Match(($yaml -join "`n"), 'apikey:\s*([A-Za-z0-9]+)')
        if ($m.Success) { $bazarrKey = $m.Groups[1].Value }
    }
    if (-not $bazarrKey) { throw "could not read Bazarr's API key from config.yaml" }

    $form = @{
        'settings-general-use_sonarr'  = 'True'
        'settings-sonarr-ip'           = 'sonarr'
        'settings-sonarr-port'         = '8989'
        'settings-sonarr-base_url'     = '/'
        'settings-sonarr-ssl'          = 'False'
        'settings-sonarr-apikey'       = $apiKey.sonarr
        'settings-general-use_radarr'  = 'True'
        'settings-radarr-ip'           = 'radarr'
        'settings-radarr-port'         = '7878'
        'settings-radarr-base_url'     = '/'
        'settings-radarr-ssl'          = 'False'
        'settings-radarr-apikey'       = $apiKey.radarr
        'settings-general-serie_default_enabled'  = 'True'
        'settings-general-movie_default_enabled'  = 'True'
    }
    $null = Invoke-RestMethod -Uri "$($hostUrl.bazarr)/api/system/settings" -Method POST `
        -Headers @{ 'X-API-KEY' = $bazarrKey } -Body $form -TimeoutSec 60
    Write-Ok "Bazarr now talks to Sonarr and Radarr"
    Write-Info "still manual: subtitle providers and a language profile (Bazarr ignores items without one)"
}
catch {
    Write-Warn "Bazarr wiring skipped: $($_.Exception.Message)"
    Write-Host "         Set it by hand in Bazarr > Settings > Sonarr/Radarr (host 'sonarr' port 8989, host 'radarr' port 7878)."
}

# ------------------------------------------------------- optional hardening bits
if ($ApplyQualityFloors) {
    Write-Step "Quality floors and executable filter"

    # Both apps ship every quality definition with a minimum size of zero, which
    # lets a 600 MB file claim to be a 2160p release. These floors are in
    # MB per minute of runtime.
    $floors = @{
        'HDTV-720p' = 3; 'WEBDL-720p' = 3; 'WEBRip-720p' = 3; 'Bluray-720p' = 3
        'HDTV-1080p' = 5; 'WEBDL-1080p' = 5; 'WEBRip-1080p' = 5; 'Bluray-1080p' = 8; 'Remux-1080p' = 25
        'HDTV-2160p' = 10; 'WEBDL-2160p' = 10; 'WEBRip-2160p' = 10; 'Bluray-2160p' = 15; 'Remux-2160p' = 50
    }

    foreach ($pair in @(@{ svc = 'sonarr'; api = 'v3' }, @{ svc = 'radarr'; api = 'v3' })) {
        try {
            $defs = Invoke-ArrApi -BaseUrl $hostUrl[$pair.svc] -ApiKey $apiKey[$pair.svc] -Path "/api/$($pair.api)/qualitydefinition"
            $changed = 0
            foreach ($def in @($defs)) {
                if ($def.quality -and $floors.ContainsKey($def.quality.name)) {
                    $def | Add-Member -NotePropertyName 'minSize' -NotePropertyValue $floors[$def.quality.name] -Force
                    # Saving the whole collection at once does not persist minSize
                    # reliably, so each definition is saved on its own.
                    $null = Invoke-ArrApi -BaseUrl $hostUrl[$pair.svc] -ApiKey $apiKey[$pair.svc] `
                        -Path "/api/$($pair.api)/qualitydefinition/$($def.id)" -Method PUT -Body $def
                    $changed++
                }
            }
            Write-Ok "$($pair.svc): $changed quality definitions given a minimum size"
        }
        catch {
            Write-Fail "$($pair.svc) quality floors: $($_.Exception.Message)"
        }
    }

    # Release profile that rejects releases advertising an executable payload.
    # Sonarr exposes this as /releaseprofile; Radarr has no such endpoint, so the
    # same protection is built there as a custom format instead - see below.
    try {
        $ignored = @('.exe', '.scr', '.bat', '.cmd', '.msi', '.lnk', '.vbs', '.pif')
        $existing = Invoke-ArrApi -BaseUrl $hostUrl.sonarr -ApiKey $apiKey.sonarr -Path '/api/v3/releaseprofile'
        $has = $false
        foreach ($p in @($existing)) { if ($p -and $p.name -eq 'block-executables') { $has = $true } }
        if (-not $has) {
            $body = @{
                name     = 'block-executables'
                enabled  = $true
                required = @()
                ignored  = $ignored
                indexerId = 0
                tags     = @()
            }
            $null = Invoke-ArrApi -BaseUrl $hostUrl.sonarr -ApiKey $apiKey.sonarr -Path '/api/v3/releaseprofile' -Method POST -Body $body
            Write-Ok "sonarr: release profile 'block-executables' created"
        }
        else {
            Write-Info "sonarr: release profile already present"
        }
    }
    catch {
        Write-Fail "sonarr release profile: $($_.Exception.Message)"
    }

    # Radarr has no release profile endpoint, so anything to be rejected is a
    # custom format scored far below the quality profile's minimum. The default
    # minFormatScore is 0, so a release carrying any of these scores -10000 and
    # is refused.
    #
    # Specifications inside one custom format are ANDed, so each of these is a
    # single ReleaseTitleSpecification with an alternation rather than several
    # specifications. The specification comes from /customformat/schema for the
    # same reason providers do: the field list is the app's to define, not ours.
    #
    # The idea of scoring unwanted release shapes into the floor comes from the
    # TRaSH Guides; the patterns here are our own and were checked against a
    # live Radarr, which compiles the regex when the format is created.
    $radarrFormats = @(
        @{
            name     = 'block-executables'
            specName = 'executable payload'
            # A "complete" release whose payload is a renamed executable.
            pattern  = '\.(exe|scr|bat|cmd|msi|lnk|vbs|pif)\b'
        },
        @{
            name     = 'BR-DISK'
            specName = 'full disc rip'
            # Whole-disc rips. Enormous, and most players will not play them.
            pattern  = '\b(br-?disks?|bd(25|50|66|100)|(complete|full)[ ._-]?bluray)\b'
        },
        @{
            name     = '3D'
            specName = 'stereoscopic'
            # Side-by-side and over-under, which look broken on a flat screen.
            pattern  = '\b(3d|bluray3d|(half|full)[ ._-]?(ou|sbs)|sbs)\b'
        }
    )
    $rejectScore = -10000

    try {
        $existingFormats = Invoke-ArrApi -BaseUrl $hostUrl.radarr -ApiKey $apiKey.radarr -Path '/api/v3/customformat'
        $schemas = Invoke-ArrApi -BaseUrl $hostUrl.radarr -ApiKey $apiKey.radarr -Path '/api/v3/customformat/schema'
        $schemaTemplate = $null
        foreach ($s in @($schemas)) {
            if ($s.implementation -eq 'ReleaseTitleSpecification') { $schemaTemplate = $s; break }
        }
        if ($schemaTemplate -eq $null) { throw "no ReleaseTitleSpecification in /api/v3/customformat/schema" }

        # Format id -> score. Collected first so the quality profiles are read
        # and written once rather than once per format.
        $wantedScores = @{}

        foreach ($fmt in $radarrFormats) {
            $cf = $null
            foreach ($f in @($existingFormats)) { if ($f -and $f.name -eq $fmt.name) { $cf = $f } }

            if ($cf -eq $null) {
                # Round-trip through JSON to get a deep copy: the schema object
                # is shared, and editing it in place would leak each pattern
                # into the next format built from it.
                $spec = $schemaTemplate | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                $spec.name = $fmt.specName
                $spec | Add-Member -NotePropertyName 'negate' -NotePropertyValue $false -Force
                $spec | Add-Member -NotePropertyName 'required' -NotePropertyValue $true -Force
                foreach ($field in @($spec.fields)) {
                    if ($field.name -eq 'value') {
                        $field | Add-Member -NotePropertyName 'value' -NotePropertyValue $fmt.pattern -Force
                    }
                }

                $cfBody = @{
                    name                            = $fmt.name
                    includeCustomFormatWhenRenaming = $false
                    specifications                  = @($spec)
                }
                $cf = Invoke-ArrApi -BaseUrl $hostUrl.radarr -ApiKey $apiKey.radarr -Path '/api/v3/customformat' -Method POST -Body $cfBody
                Write-Ok "radarr: custom format '$($fmt.name)' created"
            }
            else {
                Write-Info "radarr: custom format '$($fmt.name)' already present"
            }

            if ($cf -and $cf.id) { $wantedScores[[int]$cf.id] = $rejectScore }
        }

        # Creating a format changes nothing on its own - it only rejects once it
        # carries a negative score inside each quality profile. A profile read
        # after the formats exist already lists them, at score 0.
        $profiles = Invoke-ArrApi -BaseUrl $hostUrl.radarr -ApiKey $apiKey.radarr -Path '/api/v3/qualityprofile'
        $scored = 0
        foreach ($qualityProfile in @($profiles)) {
            $needsSave = $false
            foreach ($item in @($qualityProfile.formatItems)) {
                if ($wantedScores.ContainsKey([int]$item.format) -and $item.score -ne $rejectScore) {
                    $item | Add-Member -NotePropertyName 'score' -NotePropertyValue $rejectScore -Force
                    $needsSave = $true
                }
            }
            if ($needsSave) {
                $null = Invoke-ArrApi -BaseUrl $hostUrl.radarr -ApiKey $apiKey.radarr `
                    -Path "/api/v3/qualityprofile/$($qualityProfile.id)" -Method PUT -Body $qualityProfile
                $scored++
            }
        }
        if ($scored -gt 0) { Write-Ok "radarr: $($radarrFormats.Count) formats scored in $scored quality profile(s)" }
        else { Write-Info "radarr: quality profiles already scored" }
    }
    catch {
        Write-Fail "radarr custom formats: $($_.Exception.Message)"
    }
}

Write-Step "Wiring finished"
