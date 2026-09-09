<#
.SYNOPSIS
    Removes downloads that have been stuck in the Sonarr/Radarr/Lidarr queue and
    blocklists the release so the app looks for another source.

.DESCRIPTION
    Same idea as the daily cron job in the original article, as a Windows
    Scheduled Task. It only touches items that are genuinely dead:
      - status warning/failed, or a message mentioning stalled / metadata
      - added more than -MinAgeHours ago (default 72)
      - NOT waiting for manual import (those are usually good files)

    Dry run by default. Add -Apply to actually delete.

.EXAMPLE
    .\Clear-StalledQueue.ps1
    .\Clear-StalledQueue.ps1 -Apply -MinAgeHours 48

.EXAMPLE
    # Setup-HomeServer.ps1 -RegisterTasks does this for you. By hand:
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\path\to\scripts\Clear-StalledQueue.ps1" -Apply'
    $trigger = New-ScheduledTaskTrigger -Daily -At 5am
    Register-ScheduledTask -TaskName 'homeserver-clear-stalled' -Action $action -Trigger $trigger
#>
[CmdletBinding()]
param(
    [int]$MinAgeHours = 72,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Common.ps1')

$conf = Get-DotEnv -Path (Join-Path (Get-RepoRoot) '.env')

$targets = @(
    @{ svc = 'sonarr'; api = 'v3'; url = "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'SONARR_PORT' -Default '8989')" },
    @{ svc = 'radarr'; api = 'v3'; url = "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'RADARR_PORT' -Default '7878')" },
    @{ svc = 'lidarr'; api = 'v1'; url = "http://localhost:$(Get-EnvOrDefault -Conf $conf -Key 'LIDARR_PORT' -Default '8686')" }
)

if (-not $Apply) { Write-Warn "dry run - nothing will be deleted. Add -Apply to act." }

$cutoff = (Get-Date).ToUniversalTime().AddHours(-1 * $MinAgeHours)
$total = 0

foreach ($t in $targets) {
    $key = Get-ArrApiKey -Container $t.svc -TimeoutSec 20
    if (-not $key) {
        Write-Warn "$($t.svc) is not reachable, skipping"
        continue
    }

    Write-Step "$($t.svc) queue"
    try {
        $queue = Invoke-ArrApi -BaseUrl $t.url -ApiKey $key -Path "/api/$($t.api)/queue?pageSize=200&includeUnknownMovieItems=true&includeUnknownSeriesItems=true&includeUnknownArtistItems=true"
    }
    catch {
        Write-Fail "$($t.svc): $($_.Exception.Message)"
        continue
    }

    $records = @()
    if ($queue -and ($queue.PSObject.Properties.Name -contains 'records')) { $records = @($queue.records) }

    foreach ($r in $records) {
        $messages = ''
        if ($r.PSObject.Properties.Name -contains 'errorMessage' -and $r.errorMessage) { $messages += " $($r.errorMessage)" }
        if ($r.PSObject.Properties.Name -contains 'statusMessages' -and $r.statusMessages) {
            foreach ($sm in @($r.statusMessages)) {
                if ($sm.PSObject.Properties.Name -contains 'messages') { $messages += ' ' + (@($sm.messages) -join ' ') }
            }
        }

        $looksStalled = ($messages -match '(?i)stalled|no connections|downloading metadata') -or ($r.status -eq 'warning' -and $r.sizeleft -eq $r.size)
        $awaitingImport = ($r.PSObject.Properties.Name -contains 'trackedDownloadState') -and ($r.trackedDownloadState -match '(?i)importPending|importBlocked|manual')

        $added = $null
        if ($r.PSObject.Properties.Name -contains 'added' -and $r.added) {
            try { $added = ([datetime]$r.added).ToUniversalTime() } catch { $added = $null }
        }
        $oldEnough = ($added -ne $null -and $added -lt $cutoff)

        if ($looksStalled -and $oldEnough -and -not $awaitingImport) {
            $span = (Get-Date).ToUniversalTime() - $added
            $age = [int]$span.TotalHours
            Write-Host "    stalled ${age}h : $($r.title)"
            $total++
            if ($Apply) {
                try {
                    $null = Invoke-ArrApi -BaseUrl $t.url -ApiKey $key `
                        -Path "/api/$($t.api)/queue/$($r.id)?removeFromClient=true&blocklist=true&skipRedownload=false" -Method DELETE
                    Write-Ok "removed and blocklisted"
                }
                catch {
                    Write-Fail "could not remove id $($r.id): $($_.Exception.Message)"
                }
            }
        }
    }
}

Write-Step ("$total stuck item(s) " + $(if ($Apply) { 'removed' } else { 'would be removed' }))
