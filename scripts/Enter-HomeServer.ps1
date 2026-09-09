<#
.SYNOPSIS
    Interactive console for the stack: check state and act, in one place.

.DESCRIPTION
    Every command delegates to a script that already exists in scripts/. Nothing
    here reimplements any of them, and every command prints the equivalent
    command line before running it - so if this console has a bug you can copy
    what it printed and run that instead. The layer is meant to teach, not hide.

    Three guards are the reason it exists:

      * naming counts what is already in the library and refuses a bulk rename
        until you type the word out
      * wire refuses to run against an endpoint that is not answering, because
        registering a provider in an app that has not finished starting is how
        half-configured states are made
      * every command echoes itself, so nothing happens that you could not have
        typed yourself

.PARAMETER Command
    Run one command and exit instead of opening the prompt. Keeps this usable
    from a script and stops it hanging where nothing can type. Commands that
    need confirmation refuse in this mode rather than prompting.

.PARAMETER Argument
    The argument for -Command, where one applies: restart, logs, open.

.EXAMPLE
    .\Enter-HomeServer.ps1

.EXAMPLE
    .\Enter-HomeServer.ps1 -Command status

.EXAMPLE
    .\Enter-HomeServer.ps1 -Command logs -Argument sonarr
#>
[CmdletBinding()]
param(
    [string]$Command,
    [string]$Argument
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Common.ps1')

$root = Get-RepoRoot
$conf = Get-DotEnv -Path (Join-Path $root '.env')
$services = Get-ServiceMap -Conf $conf
$oneShot = ($Command -ne '')

# ------------------------------------------------------------------- plumbing

# Print the command that is about to run. Not decoration: it is what makes this
# console recoverable when it is wrong - you copy the line and run it yourself.
#
# It prints rather than also executing, deliberately. Handing it a scriptblock
# to invoke would have read better, but the block would then depend on
# PowerShell resolving the caller's variables through the call stack, and that
# is a subtlety worth not depending on in code that cannot be run here.
function Show-Command {
    param([Parameter(Mandatory = $true)][string]$Display)
    Write-Host ""
    Write-Host "  > $Display" -ForegroundColor DarkCyan
    Write-Host ""
}

function Get-DeadEndpoints {
    $dead = @()
    $containers = Get-ContainerState
    foreach ($svc in $services) {
        if (-not $svc.arr) { continue }
        if (-not $containers.ContainsKey($svc.container)) {
            $dead += "$($svc.name) (not running)"
            continue
        }
        if (-not (Test-HttpOk -Url "http://localhost:$($svc.port)" -TimeoutSec 3)) {
            $dead += "$($svc.name) (not answering)"
        }
    }
    return @($dead)
}

# Bounded on purpose. An accurate count over a large library on a network share
# is slow, and "more than five thousand" is as good an answer as the exact
# number when the question is whether a bulk rename is a big deal.
function Measure-LibraryFiles {
    param([Parameter(Mandatory = $true)][string]$MediaRoot)
    if (-not (Test-Path -LiteralPath $MediaRoot)) { return 0 }
    $found = @(Get-ChildItem -LiteralPath $MediaRoot -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First 5001)
    return $found.Count
}

function Resolve-ServiceName {
    param([string]$Name)
    if (-not $Name) { return $null }
    foreach ($svc in $services) {
        if ($svc.container -eq $Name.ToLowerInvariant()) { return $svc }
        if ($svc.name.ToLowerInvariant() -eq $Name.ToLowerInvariant()) { return $svc }
    }
    return $null
}

function Show-Help {
    Write-Host ""
    Write-Host "  state" -ForegroundColor White
    Write-Host "    status              what is configured, what is not, what to run next"
    Write-Host ""
    Write-Host "  stack" -ForegroundColor White
    Write-Host "    up                  bring everything up"
    Write-Host "    down                stop, keeping data"
    Write-Host "    restart [service]   restart one service, or all of them"
    Write-Host "    logs <service>      last 200 lines"
    Write-Host "    open <service>      open its web UI"
    Write-Host ""
    Write-Host "  configuration" -ForegroundColor White
    Write-Host "    wire                connect the services to each other"
    Write-Host "    floors              minimum sizes per quality, and the reject filters"
    Write-Host "    naming              file and folder naming  (renames an existing library)"
    Write-Host "    dashboard           regenerate the Homepage config"
    Write-Host ""
    Write-Host "  maintenance" -ForegroundColor White
    Write-Host "    mirror              refresh the MangaBaka mirror"
    Write-Host "    clean               list dead downloads   (clean apply removes them)"
    Write-Host ""
    Write-Host "    help                this"
    Write-Host "    exit                leave"
    Write-Host ""
}

# ------------------------------------------------------------------ dispatch

function Invoke-ConsoleCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Arg
    )

    $scripts = @{
        status    = (Join-Path $PSScriptRoot 'Get-HomeServerStatus.ps1')
        wire      = (Join-Path $PSScriptRoot 'Wire-Services.ps1')
        dashboard = (Join-Path $PSScriptRoot 'New-Dashboard.ps1')
        mirror    = (Join-Path $PSScriptRoot 'Update-MangaBaka.ps1')
        clean     = (Join-Path $PSScriptRoot 'Clear-StalledQueue.ps1')
    }

    switch ($Name) {

        'status' {
            Show-Command -Display ".\scripts\Get-HomeServerStatus.ps1"
            & $scripts.status
        }

        'up' {
            Show-Command -Display "docker compose up -d"
            $null = Invoke-Compose -Arguments @('up', '-d', '--remove-orphans')
        }

        'down' {
            Show-Command -Display "docker compose down"
            $null = Invoke-Compose -Arguments @('down')
        }

        'restart' {
            $composeArgs = @('restart')
            $display = "docker compose restart"
            if ($Arg) {
                $svc = Resolve-ServiceName -Name $Arg
                if (-not $svc) { Write-Fail "unknown service '$Arg'"; return }
                $composeArgs += $svc.container
                $display = "docker compose restart $($svc.container)"
            }
            Show-Command -Display $display
            $null = Invoke-Compose -Arguments $composeArgs
        }

        'logs' {
            $svc = Resolve-ServiceName -Name $Arg
            if (-not $svc) { Write-Fail "which service? try: logs sonarr"; return }
            Show-Command -Display "docker compose logs --tail 200 $($svc.container)"
            $null = Invoke-Compose -Arguments @('logs', '--tail', '200', $svc.container)
        }

        'open' {
            $svc = Resolve-ServiceName -Name $Arg
            if (-not $svc) { Write-Fail "which service? try: open jellyfin"; return }
            $url = "http://localhost:$($svc.port)"
            Show-Command -Display "start $url"
            Start-Process $url
        }

        'wire' {
            # Guard: an app that has not finished starting accepts some calls and
            # rejects others, which is how a half-wired stack happens.
            $dead = Get-DeadEndpoints
            if ($dead.Count -gt 0) {
                Write-Fail "not wiring - these are not ready yet:"
                foreach ($d in $dead) { Write-Host "           $d" -ForegroundColor Yellow }
                Write-Info "'up' first, then give them a minute"
                return
            }
            Show-Command -Display ".\scripts\Wire-Services.ps1"
            & $scripts.wire
        }

        'floors' {
            Show-Command -Display ".\scripts\Wire-Services.ps1 -ApplyQualityFloors"
            & $scripts.wire -ApplyQualityFloors
        }

        'naming' {
            # Guard: this is the only command that rewrites the user's files.
            $mediaRoot = Join-Path (Convert-ToWindowsPath (Get-EnvOrDefault -Conf $conf -Key 'DATA_ROOT' -Default 'C:/media')) 'media'
            Write-Info "counting what is already in $mediaRoot"
            $count = Measure-LibraryFiles -MediaRoot $mediaRoot

            if ($count -gt 0) {
                $shown = "$count"
                if ($count -gt 5000) { $shown = 'more than 5000' }
                Write-Host ""
                Write-Warn "the library already holds $shown file(s)."
                Write-Host "         Turning naming on renames all of them on the next refresh," -ForegroundColor Yellow
                Write-Host "         files and folders, into the new format. It is not undone by" -ForegroundColor Yellow
                Write-Host "         turning the setting back off." -ForegroundColor Yellow
                Write-Host ""
                if ($oneShot) {
                    Write-Fail "refusing in -Command mode: run this from the prompt so it can be confirmed"
                    return
                }
                $answer = Read-Host "         type 'rename' to go ahead, anything else to stop"
                if ($answer -ne 'rename') { Write-Info "left alone"; return }
            }
            else {
                Write-Ok "the library is empty, so nothing will be renamed"
            }

            Show-Command -Display ".\scripts\Wire-Services.ps1 -ApplyNaming"
            & $scripts.wire -ApplyNaming
        }

        'dashboard' {
            Show-Command -Display ".\scripts\New-Dashboard.ps1"
            & $scripts.dashboard
        }

        'mirror' {
            Show-Command -Display ".\scripts\Update-MangaBaka.ps1"
            & $scripts.mirror
        }

        'clean' {
            if ($Arg -eq 'apply') {
                Show-Command -Display ".\scripts\Clear-StalledQueue.ps1 -Apply"
                & $scripts.clean -Apply
            }
            else {
                Show-Command -Display ".\scripts\Clear-StalledQueue.ps1"
                & $scripts.clean
                Write-Info "nothing was removed - 'clean apply' does that"
            }
        }

        'help' { Show-Help }

        default { Write-Fail "unknown command '$Name'. 'help' lists them." }
    }
}

# --------------------------------------------------------------------- entry

if ($oneShot) {
    Invoke-ConsoleCommand -Name $Command.ToLowerInvariant() -Arg $Argument
    return
}

Write-Host ""
Write-Host "  Home server console" -ForegroundColor White
Write-Host "  $root" -ForegroundColor DarkGray
Write-Host "  'help' for commands, 'status' to see where things stand, 'exit' to leave." -ForegroundColor DarkGray

while ($true) {
    Write-Host ""
    $line = Read-Host "homeserver"
    if ($null -eq $line) { break }
    $line = $line.Trim()
    if ($line -eq '') { continue }

    $parts = $line -split '\s+', 2
    $name = $parts[0].ToLowerInvariant()
    $arg = ''
    if ($parts.Count -gt 1) { $arg = $parts[1].Trim() }

    if ($name -eq 'exit' -or $name -eq 'quit') { break }

    try {
        Invoke-ConsoleCommand -Name $name -Arg $arg
    }
    catch {
        # A failing command must not take the console with it, or you lose the
        # state you were in the middle of inspecting.
        Write-Fail $_.Exception.Message
    }
}

Write-Host ""
