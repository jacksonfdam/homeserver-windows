<#
.SYNOPSIS
    Smoke test for the shared helpers, plus a parse check of every script.

.DESCRIPTION
    Not a test suite. It covers the two things that have actually broken here,
    both of which are invisible to reading the code:

      1. Parse errors. "$Name:" inside a double-quoted string is read as a
         drive-qualified variable, the way $env:PATH is, and fails to parse.
         Because every script dot-sources _Common.ps1, one of those breaks all
         of them at once - which is exactly what happened.

      2. Parameter binding. A mandatory [string] parameter rejects '' when it
         binds, so a helper can read perfectly and still fail the moment it is
         called with an empty default. Only running it finds that.

    Everything tested here is pure: no Docker, no HTTP, no containers. The parts
    that need a live stack are verified by running the real scripts against one.

    Exits 1 when anything fails, so it can gate a commit.

.EXAMPLE
    .\Test-Common.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Common.ps1')

$passed = 0
$failed = 0

function Test-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    try {
        & $Body
        Write-Host ("    [ok]   {0}" -f $Name) -ForegroundColor Green
        $script:passed++
    }
    catch {
        Write-Host ("    [fail] {0}" -f $Name) -ForegroundColor Red
        Write-Host ("           {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
        $script:failed++
    }
}

# ------------------------------------------------------------- 1. parse check
Write-Step "Parsing every script"

foreach ($file in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' | Sort-Object Name)) {
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        Write-Host ("    [fail] {0}" -f $file.Name) -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host ("           line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor DarkGray
        }
        $failed++
    }
    else {
        Write-Host ("    [ok]   {0}" -f $file.Name) -ForegroundColor Green
        $passed++
    }
}

# --------------------------------------------------------------- 2. the helpers
Write-Step "Helpers"

# GetTempPath rather than $env:TEMP, which is not set outside Windows - this
# script is the one thing here that can usefully be run somewhere else, to check
# the helpers before they reach the box.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("homeserver-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    $livePath = Join-Path $work 'live.env'
    $templatePath = Join-Path $work 'template.env'
    Set-Content -LiteralPath $livePath -Value @('# a comment', 'DATA_ROOT=D:/media', 'EMPTY=', 'PUID=1000') -Encoding ASCII
    Set-Content -LiteralPath $templatePath -Value @('DATA_ROOT=C:/media', 'EMPTY=x', 'PUID=1000', 'NEWKEY=v') -Encoding ASCII

    Test-Case 'Convert-ToDockerPath strips the trailing slash' {
        $r = Convert-ToDockerPath 'D:\media\'
        if ($r -ne 'D:/media') { throw "got '$r'" }
    }

    Test-Case 'Convert-ToWindowsPath goes back' {
        $r = Convert-ToWindowsPath 'D:/media'
        if ($r -ne 'D:\media') { throw "got '$r'" }
    }

    Test-Case 'Get-DotEnv skips comments and reads values' {
        $m = Get-DotEnv -Path $livePath
        if ($m['DATA_ROOT'] -ne 'D:/media') { throw "DATA_ROOT came back '$($m['DATA_ROOT'])'" }
        if ($m.ContainsKey('# a comment')) { throw 'a comment was parsed as a key' }
    }

    Test-Case 'Get-DotEnv on a missing file returns empty' {
        $m = Get-DotEnv -Path (Join-Path $work 'nope.env')
        if ($m.Count -ne 0) { throw "got $($m.Count) keys" }
    }

    Test-Case 'Get-EnvOrDefault falls back' {
        $m = Get-DotEnv -Path $livePath
        $r = Get-EnvOrDefault -Conf $m -Key 'ABSENT' -Default 'fallback'
        if ($r -ne 'fallback') { throw "got '$r'" }
    }

    # This is the one that broke Get-HomeServerStatus.ps1 on its first run: a
    # mandatory [string] rejects '' at bind time, and four callers pass it.
    Test-Case 'Get-EnvOrDefault accepts an EMPTY default' {
        $m = Get-DotEnv -Path $livePath
        $r = Get-EnvOrDefault -Conf $m -Key 'ABSENT' -Default ''
        if ($r -ne '') { throw "got '$r'" }
    }

    Test-Case 'Get-EnvOrDefault treats a present-but-empty key as absent' {
        $m = Get-DotEnv -Path $livePath
        $r = Get-EnvOrDefault -Conf $m -Key 'EMPTY' -Default 'fallback'
        if ($r -ne 'fallback') { throw "got '$r'" }
    }

    Test-Case 'Set-DotEnvValue writes an empty value' {
        Set-DotEnvValue -Path $livePath -Key 'PLEX_CLAIM' -Value ''
        $m = Get-DotEnv -Path $livePath
        if (-not $m.ContainsKey('PLEX_CLAIM')) { throw 'the key was not written' }
    }

    Test-Case 'Set-DotEnvValue replaces rather than appends' {
        Set-DotEnvValue -Path $livePath -Key 'PUID' -Value '1001'
        $lines = @(Get-Content -LiteralPath $livePath | Where-Object { $_ -match '^PUID=' })
        if ($lines.Count -ne 1) { throw "PUID appears $($lines.Count) times" }
        if ($lines[0] -ne 'PUID=1001') { throw "got '$($lines[0])'" }
    }

    Test-Case 'Get-EnvGaps finds a key the template has and .env does not' {
        $g = Get-EnvGaps -EnvPath $livePath -ExamplePath $templatePath
        if ($g.missingKeys -notcontains 'NEWKEY') { throw "missing was: $($g.missingKeys -join ', ')" }
    }

    Test-Case 'Get-EnvGaps finds a key that is present but empty' {
        $g = Get-EnvGaps -EnvPath $livePath -ExamplePath $templatePath
        if ($g.emptyKeys -notcontains 'EMPTY') { throw "empty was: $($g.emptyKeys -join ', ')" }
    }

    Test-Case 'Get-EnvGaps reports a missing .env rather than throwing' {
        $g = Get-EnvGaps -EnvPath (Join-Path $work 'nope.env') -ExamplePath $templatePath
        if ($g.envExists) { throw 'envExists should be false' }
    }

    Test-Case 'Get-ServiceMap covers the default profile' {
        $m = Get-DotEnv -Path $livePath
        $s = @(Get-ServiceMap -Conf $m)
        if ($s.Count -lt 10) { throw "only $($s.Count) services" }
        foreach ($svc in $s) {
            if (-not $svc.name) { throw 'an entry has no name' }
            if (-not $svc.container) { throw "$($svc.name) has no container" }
            if (-not $svc.port) { throw "$($svc.name) has no port" }
        }
    }

    Test-Case 'Get-ServiceMap takes ports from .env' {
        $portPath = Join-Path $work 'ports.env'
        Set-Content -LiteralPath $portPath -Value @('SONARR_PORT=9999') -Encoding ASCII
        $s = @(Get-ServiceMap -Conf (Get-DotEnv -Path $portPath))
        $sonarr = $s | Where-Object { $_.container -eq 'sonarr' }
        if ($sonarr.port -ne '9999') { throw "port came back '$($sonarr.port)'" }
    }

    Test-Case 'Get-PathState lists what is missing' {
        $p = Get-PathState -DataRoot (Join-Path $work 'nope') -ConfigRoot (Join-Path $work 'nope2')
        if ($p.dataRootExists) { throw 'dataRootExists should be false' }
        if (@($p.missing).Count -lt 15) { throw "only $(@($p.missing).Count) missing" }
        if ($p.missing -notcontains 'recycle') { throw 'recycle should be listed' }
    }

    Test-Case 'Get-MirrorState reports an absent mirror' {
        $s = Get-MirrorState -Root (Join-Path $work 'nope')
        if ($s.present) { throw 'present should be false' }
    }

    Test-Case 'ConvertTo-SafeFolderName strips what NTFS refuses' {
        $r = ConvertTo-SafeFolderName -Name 'Is it Wrong to Try? Vol: 1/2 *'
        if ($r -match '[\\/:*?"<>|]') { throw "got '$r'" }
    }

    # Accepted by the API and then unreachable by path, which is the worst
    # possible outcome: the series appears, the files never open.
    Test-Case 'ConvertTo-SafeFolderName drops a trailing dot' {
        $r = ConvertTo-SafeFolderName -Name 'Dr. Stone.'
        if ($r.EndsWith('.')) { throw "got '$r'" }
    }

    Test-Case 'ConvertTo-SafeFolderName caps the length' {
        $r = ConvertTo-SafeFolderName -Name ('x' * 400)
        if ($r.Length -gt 120) { throw "got $($r.Length) characters" }
    }

    Test-Case 'ConvertTo-SafeFolderName never returns nothing' {
        if ((ConvertTo-SafeFolderName -Name '') -ne 'untitled') { throw 'empty name' }
        if ((ConvertTo-SafeFolderName -Name '///') -ne 'untitled') { throw 'all-illegal name' }
    }

    Test-Case 'ConvertFrom-MalProgress reads all three shapes' {
        $a = ConvertFrom-MalProgress -Token '12'
        if ($a.read -ne 12 -or $a.total -ne 0) { throw "bare: $($a.read)/$($a.total)" }
        $b = ConvertFrom-MalProgress -Token '12/34'
        if ($b.read -ne 12 -or $b.total -ne 34) { throw "slash: $($b.read)/$($b.total)" }
        $c = ConvertFrom-MalProgress -Token '12/34 [56]'
        if ($c.read -ne 12 -or $c.total -ne 34 -or $c.available -ne 56) { throw "full: $($c | ConvertTo-Json -Compress)" }
    }

    Test-Case 'ConvertFrom-MalProgress survives an empty cell' {
        $r = ConvertFrom-MalProgress -Token ''
        if ($r.read -ne 0) { throw "got $($r.read)" }
    }

    Test-Case 'ConvertFrom-MalListText assigns the section status' {
        $t = @('Reading', 'Title', 'Score', 'Chapters', 'Volumes', 'Type',
               'Some Series', '9', '122 [152]', '0', 'Manga') -join "`n"
        $e = @(ConvertFrom-MalListText -Text $t)
        if ($e.Count -ne 1) { throw "$($e.Count) entries" }
        if ($e[0].status -ne 'Reading') { throw "status '$($e[0].status)'" }
        if ($e[0].title -ne 'Some Series') { throw "title '$($e[0].title)'" }
        if ($e[0].score -ne '9') { throw "score '$($e[0].score)'" }
        if ($e[0].chaptersAvailable -ne 152) { throw "available $($e[0].chaptersAvailable)" }
    }

    # The trap the whole classifier exists for: MAL omits the Score cell rather
    # than emptying it, so counting columns reads the chapter count as a score.
    Test-Case 'ConvertFrom-MalListText does not invent a score' {
        $t = @('Reading', 'Chainsaw Man', '0/232', '0/24', 'Manga') -join "`n"
        $e = @(ConvertFrom-MalListText -Text $t)
        if ($e[0].score -ne '') { throw "score came back '$($e[0].score)'" }
        if ($e[0].chaptersTotal -ne 232) { throw "chapters $($e[0].chaptersTotal)" }
        if ($e[0].volumesTotal -ne 24) { throw "volumes $($e[0].volumesTotal)" }
    }

    # 'Completed Manga' is a section header, not a series called Completed.
    Test-Case 'ConvertFrom-MalListText reads a header carrying a type' {
        $t = @('Reading', 'A', '1', 'Manga', 'Completed Manga', 'B', '2', 'Manga') -join "`n"
        $e = @(ConvertFrom-MalListText -Text $t)
        if ($e.Count -ne 2) { throw "$($e.Count) entries: $(($e.title) -join ', ')" }
        if ($e[1].status -ne 'Completed') { throw "status '$($e[1].status)'" }
        if ($e[1].title -ne 'B') { throw "title '$($e[1].title)'" }
    }

    Test-Case 'ConvertFrom-MalListText keeps Light Novel apart from Manga' {
        $t = @('Planning', 'Same Title', '0', '0', 'Manga',
               'Same Title', '0/334', '0/26', 'Light Novel') -join "`n"
        $e = @(ConvertFrom-MalListText -Text $t)
        if ($e.Count -ne 2) { throw "$($e.Count) entries" }
        if ($e[1].type -ne 'Light Novel') { throw "type '$($e[1].type)'" }
    }

    Test-Case 'ConvertFrom-MalListText accepts tab-separated rows' {
        $t = "Reading`nTitle`tScore`tChapters`tVolumes`tType`nSome Series`t7`t10/30`t0`tManga"
        $e = @(ConvertFrom-MalListText -Text $t)
        if ($e.Count -ne 1) { throw "$($e.Count) entries" }
        if ($e[0].chaptersRead -ne 10) { throw "read $($e[0].chaptersRead)" }
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------- summary
Write-Step "Result"

if ($failed -eq 0) {
    Write-Ok "$passed passed"
}
else {
    Write-Fail "$failed failed, $passed passed"
    exit 1
}
