<#
.SYNOPSIS
    Exports a reading list from MangaDex or MangaFire, matches it against your
    Komga or Kavita library, and creates a collection / reading list from what
    matched.

.DESCRIPTION
    A list is a set of TITLES. Komga and Kavita only know about FILES on disk.
    So this does two things and is honest about the split:

      matched    -> series you already have, grouped into a Komga collection or
                    a Kavita Want-to-read / reading list
      unmatched  -> written to missing.csv, which is your acquisition backlog

    Dry run by default: it writes the reports and touches nothing until -Apply.

.EXAMPLE
    # public MDList (no auth at all - the UUID is in the mangadex.org/list/<uuid> URL)
    .\Import-MangaLists.ps1 -Source MangaDex -ListId 1b8e5d1a-... -Target Komga

.EXAMPLE
    # your own follows (prompts for a personal API client)
    .\Import-MangaLists.ps1 -Source MangaDex -Follows -Target Kavita -Apply

.EXAMPLE
    # MangaFire, from the JSON dumped by the browser snippet in docs/manga-lists.md
    .\Import-MangaLists.ps1 -Source MangaFire -Path .\mangafire.json -Target Komga -Apply

.EXAMPLE
    # MyAnimeList, from the official XML export or from a copy-pasted list page
    .\Import-MangaLists.ps1 -Source MyAnimeList -Path .\lists\mal.txt -Status Reading -Target Komga
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('MangaDex', 'MangaFire', 'MyAnimeList')]
    [string]$Source,

    # MangaDex
    [string]$ListId,
    [switch]$Follows,
    [string]$AccessToken,

    # MangaFire: a .json from the browser snippet, or a saved .html page
    # MyAnimeList: the .xml (or .xml.gz) export, or a .txt of the pasted page
    [string]$Path,

    # MyAnimeList only: keep just these list statuses. Everything by default,
    # because which of them is worth acquiring is a decision, not a default -
    # Planning is a wishlist and Paused is usually a much bigger backlog than
    # Reading.
    [ValidateSet('Reading', 'Completed', 'Paused', 'Dropped', 'Planning')]
    [string[]]$Status,

    [ValidateSet('None', 'Komga', 'Kavita')]
    [string]$Target = 'None',

    [string]$KomgaUrl,
    [string]$KomgaApiKey,
    [string]$KavitaUrl,
    [string]$KavitaApiKey,

    [string]$CollectionName,
    [switch]$KavitaReadingList,

    [double]$AutoThreshold = 0.85,
    [double]$ReviewThreshold = 0.60,

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Common.ps1')

$repoRoot = Get-RepoRoot
$conf = Get-DotEnv -Path (Join-Path $repoRoot '.env')
$outDir = Join-Path $repoRoot 'lists'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

if (-not $KomgaUrl) { $KomgaUrl = "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'KOMGA_PORT' -Default '25600')" }
if (-not $KavitaUrl) { $KavitaUrl = "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'KAVITA_PORT' -Default '5001')" }
if (-not $KomgaApiKey) { $KomgaApiKey = Get-EnvOrDefault -Conf $conf -Key 'KOMGA_API_KEY' -Default '' }
if (-not $KavitaApiKey) { $KavitaApiKey = Get-EnvOrDefault -Conf $conf -Key 'KAVITA_API_KEY' -Default '' }
if (-not $CollectionName) {
    $CollectionName = "$Source import"
    # A collection called "MyAnimeList import" is useless once you import twice
    # with different statuses, so the filter names it.
    if ($Status) { $CollectionName = "$Source $($Status -join ' + ')" }
}

# =============================================================== title handling

function ConvertTo-NormalizedTitle {
    param([string]$Title)
    if (-not $Title) { return '' }
    $t = $Title.ToLowerInvariant()
    $t = $t -replace '[\u2018\u2019\u201c\u201d]', ''
    $t = $t -replace '[^a-z0-9\u3000-\u9fff]+', ' '
    $t = $t -replace '\b(the|a|an)\b', ' '
    return ($t -replace '\s+', ' ').Trim()
}

function Get-Similarity {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return 0.0 }
    if ($A -eq $B) { return 1.0 }
    $n = $A.Length; $m = $B.Length
    $prev = New-Object 'int[]' ($m + 1)
    $cur = New-Object 'int[]' ($m + 1)
    for ($j = 0; $j -le $m; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        $cur[0] = $i
        for ($j = 1; $j -le $m; $j++) {
            $cost = 1
            if ($A[$i - 1] -eq $B[$j - 1]) { $cost = 0 }
            $del = $prev[$j] + 1
            $ins = $cur[$j - 1] + 1
            $sub = $prev[$j - 1] + $cost
            $min = $del
            if ($ins -lt $min) { $min = $ins }
            if ($sub -lt $min) { $min = $sub }
            $cur[$j] = $min
        }
        for ($j = 0; $j -le $m; $j++) { $prev[$j] = $cur[$j] }
    }
    $max = [Math]::Max($n, $m)
    return [Math]::Round(1.0 - ($prev[$m] / $max), 3)
}

# ==================================================================== MangaDex

$mdxApi = 'https://api.mangadex.org'

function Invoke-MangaDex {
    param([string]$Uri, [string]$Token)
    $headers = @{ 'Accept' = 'application/json' }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    # MangaDex rate limits at roughly 5 requests/second globally.
    Start-Sleep -Milliseconds 250
    return Invoke-RestMethod -Uri $Uri -Headers $headers -TimeoutSec 60
}

function Get-MangaDexToken {
    # Personal API client: register one under Settings > API Clients on
    # mangadex.org, wait for approval, then this exchanges it for a token.
    # Nothing is written to disk; the token lives in memory for this run only.
    Write-Info "MangaDex personal API client (Settings > API Clients on mangadex.org)"
    $clientId = Read-Host 'client id'
    $clientSecret = Read-Host 'client secret'
    $username = Read-Host 'mangadex username'
    $secure = Read-Host 'mangadex password' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

    $body = @{
        grant_type    = 'password'
        username      = $username
        password      = $plain
        client_id     = $clientId
        client_secret = $clientSecret
    }
    $resp = Invoke-RestMethod -Method POST -TimeoutSec 60 `
        -Uri 'https://auth.mangadex.org/realms/mangadex/protocol/openid-connect/token' -Body $body
    $plain = $null
    return $resp.access_token
}

function Get-MangaTitles {
    param($Attributes)
    $titles = @()
    if ($Attributes.title) {
        $props = @($Attributes.title.PSObject.Properties)
        $en = $props | Where-Object { $_.Name -eq 'en' } | Select-Object -First 1
        if ($en) { $titles += [string]$en.Value }
        foreach ($p in $props) { if ($p.Value -and ($titles -notcontains [string]$p.Value)) { $titles += [string]$p.Value } }
    }
    if ($Attributes.altTitles) {
        foreach ($alt in @($Attributes.altTitles)) {
            foreach ($p in @($alt.PSObject.Properties)) {
                if ($p.Value -and ($titles -notcontains [string]$p.Value)) { $titles += [string]$p.Value }
            }
        }
    }
    return $titles
}

function Get-MangaDexEntries {
    param([string]$Token, [string]$List)

    $ids = @()
    if ($List) {
        Write-Info "reading list $List"
        $resp = Invoke-MangaDex -Uri "$mdxApi/list/$List" -Token $Token
        foreach ($rel in @($resp.data.relationships)) {
            if ($rel.type -eq 'manga') { $ids += $rel.id }
        }
        Write-Ok "$($ids.Count) titles in the list"
    }
    else {
        Write-Info "reading your follows (paged)"
        $offset = 0
        while ($true) {
            $resp = Invoke-MangaDex -Uri "$mdxApi/user/follows/manga?limit=100&offset=$offset" -Token $Token
            $batch = @($resp.data)
            if ($batch.Count -eq 0) { break }
            foreach ($m in $batch) { $ids += $m.id }
            $offset += 100
            Write-Info "  $($ids.Count) so far"
            if ($offset -ge $resp.total) { break }
        }
        Write-Ok "$($ids.Count) followed titles"
    }

    # Hydrate titles in batches of 100.
    $entries = @()
    for ($i = 0; $i -lt $ids.Count; $i += 100) {
        $slice = $ids[$i..([Math]::Min($i + 99, $ids.Count - 1))]
        $query = ($slice | ForEach-Object { "ids[]=$_" }) -join '&'
        $resp = Invoke-MangaDex -Uri "$mdxApi/manga?limit=100&$query" -Token $Token
        foreach ($m in @($resp.data)) {
            $titles = Get-MangaTitles -Attributes $m.attributes
            if ($titles.Count -eq 0) { continue }
            $entries += [PSCustomObject]@{
                source    = 'MangaDex'
                sourceId  = $m.id
                title     = $titles[0]
                altTitles = ($titles | Select-Object -Skip 1) -join ' | '
                url       = "https://mangadex.org/title/$($m.id)"
                status    = ''
                chaptersAvailable = 0
            }
        }
    }
    return $entries
}

# ==================================================================== MangaFire

function Get-MangaFireEntries {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { throw "File not found: $File" }
    $ext = [IO.Path]::GetExtension($File).ToLowerInvariant()

    if ($ext -eq '.json') {
        # Output of the browser console snippet in docs/manga-lists.md
        $raw = Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($raw) | ForEach-Object {
            [PSCustomObject]@{
                source    = 'MangaFire'
                sourceId  = $_.slug
                title     = $_.title
                altTitles = ''
                url       = $_.url
                status    = ''
                chaptersAvailable = 0
            }
        }
    }

    # Fallback: a page saved with Ctrl+S. MangaFire's markup changes, so this
    # takes every anchor pointing at /manga/<slug> and de-duplicates by slug.
    $html = Get-Content -LiteralPath $File -Raw -Encoding UTF8
    $matches = [regex]::Matches($html, '<a[^>]+href="(?:https?://[^"]*)?/manga/([^"?#]+)"[^>]*>(?<t>[^<]{2,200})</a>')
    $seen = @{}
    $entries = @()
    foreach ($m in $matches) {
        $slug = $m.Groups[1].Value
        $title = [System.Net.WebUtility]::HtmlDecode($m.Groups['t'].Value).Trim()
        if (-not $title -or $seen.ContainsKey($slug)) { continue }
        $seen[$slug] = $true
        $entries += [PSCustomObject]@{
            source    = 'MangaFire'
            sourceId  = $slug
            title     = $title
            altTitles = ''
            url       = "https://mangafire.to/manga/$slug"
            status    = ''
            chaptersAvailable = 0
        }
    }
    return $entries
}

# ================================================================ MyAnimeList

# Two shapes, and the difference matters. The XML export carries
# manga_mangadb_id, which is the MAL id MangaBaka cross-maps to AniList and
# MangaUpdates - so it survives a retitling. A pasted page carries titles only,
# and title matching is exactly the part of this script that is fuzzy. Prefer
# the export; the paste exists because MAL's API needs a registered client id
# and the export needs a working account page, and a copy always works.
function Get-MyAnimeListEntries {
    param([string]$File, [string[]]$Keep)

    if (-not (Test-Path -LiteralPath $File)) { throw "File not found: $File" }
    $name = [IO.Path]::GetFileName($File).ToLowerInvariant()

    $records = @()
    if ($name.EndsWith('.xml') -or $name.EndsWith('.xml.gz') -or $name.EndsWith('.gz')) {
        # MAL hands out the export gzipped and does not always name it .gz.
        $bytes = [IO.File]::ReadAllBytes($File)
        $xmlText = ''
        if ($bytes.Length -gt 2 -and $bytes[0] -eq 0x1f -and $bytes[1] -eq 0x8b) {
            $inStream = New-Object IO.MemoryStream(, $bytes)
            $gz = New-Object IO.Compression.GzipStream($inStream, [IO.Compression.CompressionMode]::Decompress)
            $reader = New-Object IO.StreamReader($gz)
            try { $xmlText = $reader.ReadToEnd() } finally { $reader.Dispose(); $gz.Dispose(); $inStream.Dispose() }
        }
        else {
            $xmlText = [Text.Encoding]::UTF8.GetString($bytes)
        }

        $xml = [xml]$xmlText
        foreach ($m in @($xml.myanimelist.manga)) {
            if (-not $m) { continue }
            $records += [PSCustomObject]@{
                status            = ($m.my_status -replace 'On-Hold', 'Paused') -replace 'Plan to Read', 'Planning'
                title             = [string]$m.manga_title
                type              = ''
                score             = [string]$m.my_score
                chaptersRead      = 0
                chaptersTotal     = 0
                chaptersAvailable = 0
                volumesRead       = 0
                volumesTotal      = 0
                malId             = [string]$m.manga_mangadb_id
            }
        }
    }
    else {
        $text = Get-Content -LiteralPath $File -Raw -Encoding UTF8
        foreach ($r in (ConvertFrom-MalListText -Text $text)) {
            $records += ($r | Add-Member -NotePropertyName 'malId' -NotePropertyValue '' -PassThru -Force)
        }
    }

    if ($Keep -and $Keep.Count -gt 0) {
        $records = @($records | Where-Object { $Keep -contains $_.status })
    }

    $entries = @()
    foreach ($r in $records) {
        $url = ''
        if ($r.malId) { $url = "https://myanimelist.net/manga/$($r.malId)" }
        $entries += [PSCustomObject]@{
            source    = 'MyAnimeList'
            sourceId  = $r.malId
            title     = $r.title
            altTitles = ''
            url       = $url
            status    = $r.status
            # Carried through because it is the only number here that says
            # anything about acquisition: how many chapters exist to fetch.
            chaptersAvailable = $r.chaptersAvailable
        }
    }
    return $entries
}

# ======================================================================= Komga

function Search-Komga {
    param([string]$Query)
    $headers = @{ 'X-API-Key' = $KomgaApiKey; 'Accept' = 'application/json' }
    $body = @{ fullTextSearch = $Query } | ConvertTo-Json -Compress
    # GET /api/v1/series?search= is deprecated; the search DSL lives on
    # POST /api/v1/series/list.
    $resp = Invoke-RestMethod -Uri "$KomgaUrl/api/v1/series/list?size=10" -Method POST `
        -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 60
    $out = @()
    foreach ($s in @($resp.content)) {
        $names = @($s.name)
        if ($s.metadata -and $s.metadata.title) { $names += $s.metadata.title }
        $out += [PSCustomObject]@{ id = $s.id; names = $names }
    }
    return $out
}

function Add-KomgaCollection {
    param([string]$Name, [string[]]$SeriesIds)
    $headers = @{ 'X-API-Key' = $KomgaApiKey; 'Accept' = 'application/json' }
    $all = Invoke-RestMethod -Uri "$KomgaUrl/api/v1/collections?size=1000" -Headers $headers -TimeoutSec 60
    $existing = $null
    foreach ($c in @($all.content)) { if ($c.name -eq $Name) { $existing = $c } }

    if ($existing) {
        $current = Invoke-RestMethod -Uri "$KomgaUrl/api/v1/collections/$($existing.id)" -Headers $headers -TimeoutSec 60
        $merged = @($current.seriesIds) + $SeriesIds | Select-Object -Unique
        $body = @{ seriesIds = $merged } | ConvertTo-Json -Compress
        $null = Invoke-RestMethod -Uri "$KomgaUrl/api/v1/collections/$($existing.id)" -Method PATCH `
            -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 60
        Write-Ok "collection '$Name' updated, now $($merged.Count) series"
    }
    else {
        $body = @{ name = $Name; ordered = $false; seriesIds = $SeriesIds } | ConvertTo-Json -Compress
        $null = Invoke-RestMethod -Uri "$KomgaUrl/api/v1/collections" -Method POST `
            -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 60
        Write-Ok "collection '$Name' created with $($SeriesIds.Count) series"
    }
}

# ====================================================================== Kavita

$script:KavitaJwt = $null

function Connect-Kavita {
    if ($script:KavitaJwt) { return $script:KavitaJwt }
    if (-not $KavitaApiKey) { throw "Kavita needs an API key (Settings > Account > API Key, or KAVITA_API_KEY in .env)" }
    $uri = "$KavitaUrl/api/Plugin/authenticate?apiKey=$([uri]::EscapeDataString($KavitaApiKey))&pluginName=homeserver-import"
    $resp = Invoke-RestMethod -Uri $uri -Method POST -TimeoutSec 60
    $script:KavitaJwt = $resp.token
    return $script:KavitaJwt
}

function Search-Kavita {
    param([string]$Query)
    $headers = @{ Authorization = "Bearer $(Connect-Kavita)"; 'Accept' = 'application/json' }
    $uri = "$KavitaUrl/api/Search/search?queryString=$([uri]::EscapeDataString($Query))"
    $resp = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 60
    $out = @()
    foreach ($s in @($resp.series)) {
        $names = @($s.name)
        foreach ($n in @($s.originalName, $s.localizedName)) { if ($n) { $names += $n } }
        $out += [PSCustomObject]@{ id = $s.seriesId; names = $names }
    }
    return $out
}

function Add-KavitaSeries {
    param([int[]]$SeriesIds, [string]$Name, [switch]$AsReadingList)
    $headers = @{ Authorization = "Bearer $(Connect-Kavita)"; 'Accept' = 'application/json' }

    if ($AsReadingList) {
        $created = Invoke-RestMethod -Uri "$KavitaUrl/api/ReadingList/create" -Method POST -Headers $headers `
            -ContentType 'application/json' -Body (@{ title = $Name } | ConvertTo-Json -Compress) -TimeoutSec 60
        $body = @{ readingListId = $created.id; seriesIds = $SeriesIds } | ConvertTo-Json -Compress
        $null = Invoke-RestMethod -Uri "$KavitaUrl/api/ReadingList/update-by-multiple-series" -Method POST `
            -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 60
        Write-Ok "reading list '$Name' created with $($SeriesIds.Count) series"
    }
    else {
        $body = @{ seriesIds = $SeriesIds } | ConvertTo-Json -Compress
        $null = Invoke-RestMethod -Uri "$KavitaUrl/api/want-to-read/add-series" -Method POST `
            -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 60
        Write-Ok "$($SeriesIds.Count) series added to Want to read"
    }
}

# ======================================================================== main

Write-Step "Exporting from $Source"

$entries = @()
if ($Source -eq 'MangaDex') {
    if (-not $ListId -and -not $Follows) { throw "Pass -ListId <uuid> or -Follows" }
    $token = $AccessToken
    if ($Follows -and -not $token) { $token = Get-MangaDexToken }
    $entries = Get-MangaDexEntries -Token $token -List $ListId
}
elseif ($Source -eq 'MangaFire') {
    if (-not $Path) { throw "Pass -Path to the .json from the browser snippet or a saved .html page" }
    $entries = Get-MangaFireEntries -File $Path
}
else {
    if (-not $Path) { throw "Pass -Path to the MAL .xml export or a .txt of the pasted list page" }
    $entries = Get-MyAnimeListEntries -File $Path -Keep $Status
    if ($Status) { Write-Info "kept: $($Status -join ', ')" }
    $byStatus = $entries | Group-Object status | Sort-Object Name
    foreach ($g in $byStatus) { Write-Info ("{0,-10} {1}" -f $g.Name, $g.Count) }
}

if ($entries.Count -eq 0) { throw "Nothing was exported - check the list id / file" }

$stamp = Get-Date -Format 'yyyy-MM-dd'
$exportPath = Join-Path $outDir "$($Source.ToLower())-$stamp.csv"
$entries | Export-Csv -LiteralPath $exportPath -NoTypeInformation -Encoding UTF8
Write-Ok "$($entries.Count) titles -> $exportPath"

if ($Target -eq 'None') {
    Write-Info "no -Target given, stopping after the export"
    return
}

Write-Step "Matching against $Target"

$results = @()
$i = 0
foreach ($e in $entries) {
    $i++
    if ($i % 25 -eq 0) { Write-Info "$i / $($entries.Count)" }

    $candidateTitles = @($e.title)
    if ($e.altTitles) { $candidateTitles += ($e.altTitles -split '\s\|\s') }

    $best = $null
    $bestScore = 0.0
    foreach ($q in ($candidateTitles | Select-Object -First 3)) {
        if (-not $q) { continue }
        try {
            if ($Target -eq 'Komga') { $hits = Search-Komga -Query $q } else { $hits = Search-Kavita -Query $q }
        }
        catch {
            Write-Warn "search failed for '$q': $($_.Exception.Message)"
            continue
        }
        foreach ($h in $hits) {
            foreach ($hn in $h.names) {
                foreach ($ct in $candidateTitles) {
                    $score = Get-Similarity -A (ConvertTo-NormalizedTitle $hn) -B (ConvertTo-NormalizedTitle $ct)
                    if ($score -gt $bestScore) { $bestScore = $score; $best = [PSCustomObject]@{ id = $h.id; name = $hn } }
                }
            }
        }
        if ($bestScore -ge $AutoThreshold) { break }
    }

    $verdict = 'missing'
    if ($bestScore -ge $AutoThreshold) { $verdict = 'matched' }
    elseif ($bestScore -ge $ReviewThreshold) { $verdict = 'review' }

    $matchId = ''
    $matchName = ''
    if ($best) { $matchId = $best.id; $matchName = $best.name }

    $results += [PSCustomObject]@{
        verdict     = $verdict
        title       = $e.title
        libraryName = $matchName
        score       = $bestScore
        libraryId   = $matchId
        url         = $e.url
    }
}

$matched = @($results | Where-Object { $_.verdict -eq 'matched' })
$review = @($results | Where-Object { $_.verdict -eq 'review' })
$missing = @($results | Where-Object { $_.verdict -eq 'missing' })

$reportPath = Join-Path $outDir "match-report-$stamp.csv"
$missingPath = Join-Path $outDir "missing-$stamp.csv"
$results | Sort-Object verdict, title | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
$missing | Export-Csv -LiteralPath $missingPath -NoTypeInformation -Encoding UTF8

Write-Ok "$($matched.Count) matched, $($review.Count) need review, $($missing.Count) not in the library"
Write-Info "report:  $reportPath"
Write-Info "backlog: $missingPath"

if ($review.Count -gt 0) {
    Write-Info "borderline matches (raise -AutoThreshold or fix the metadata title):"
    foreach ($r in ($review | Select-Object -First 10)) {
        Write-Host ("      {0,-5} {1}  ~  {2}" -f $r.score, $r.title, $r.libraryName)
    }
}

if (-not $Apply) {
    Write-Warn "dry run - nothing was written to $Target. Add -Apply."
    return
}

if ($matched.Count -eq 0) {
    Write-Warn "nothing matched, so there is nothing to create"
    return
}

Write-Step "Writing to $Target"
if ($Target -eq 'Komga') {
    Add-KomgaCollection -Name $CollectionName -SeriesIds @($matched.libraryId)
}
else {
    $ids = @($matched.libraryId | ForEach-Object { [int]$_ })
    Add-KavitaSeries -SeriesIds $ids -Name $CollectionName -AsReadingList:$KavitaReadingList
}
