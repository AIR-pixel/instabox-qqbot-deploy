# Register / update the InstaBox keepalive scheduled tasks.
#
#   powershell -ExecutionPolicy Bypass -File install-task.ps1
#   powershell -ExecutionPolicy Bypass -File install-task.ps1 -Mode cycle
#   powershell -ExecutionPolicy Bypass -File install-task.ps1 -Uninstall
#
# DEFAULT = both tasks. They are NOT redundant -- they fix two different limits:
#   InstaBox-Keepalive            (85 min) suspend -> 20s -> resume
#                                 resets the max-run / dynamic-runtime streak
#   InstaBox-Keepalive-Heartbeat  (20 min) one real `instabox exec -- true`
#                                 resets the 30-minute idle auto-suspend
# See docs/05-keepalive.md and docs/06-pitfalls.md P-21.
#
# ASCII ONLY (PowerShell 5.1 + UTF-8 without BOM => ParserError).

param(
    [ValidateSet('both', 'cycle', 'heartbeat')]
    [string]$Mode = 'both',
    [int]$CycleIntervalMinutes = 85,
    [int]$HeartbeatIntervalMinutes = 20,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Continue'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

$Tasks = @(
    @{ Name = 'InstaBox-Keepalive';           Script = 'keepalive-cycle.ps1';     Minutes = $CycleIntervalMinutes;     Limit = 10 },
    @{ Name = 'InstaBox-Keepalive-Heartbeat'; Script = 'keepalive-heartbeat.ps1'; Minutes = $HeartbeatIntervalMinutes; Limit = 5  }
)

if ($Mode -eq 'cycle')    { $Tasks = @($Tasks[0]) }
if ($Mode -eq 'heartbeat'){ $Tasks = @($Tasks[1]) }

if ($Uninstall) {
    foreach ($t in $Tasks) {
        $existing = Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $t.Name -Confirm:$false
            Write-Host "removed: $($t.Name)"
        } else {
            Write-Host "not found: $($t.Name)"
        }
    }
    exit 0
}

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited

foreach ($t in $Tasks) {
    $Script = Join-Path $Here $t.Script
    if (-not (Test-Path $Script)) {
        Write-Host "FATAL script not found: $Script"
        exit 1
    }

    $existing = Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "removing existing task $($t.Name)"
        Unregister-ScheduledTask -TaskName $t.Name -Confirm:$false
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Script)

    # Start 2 minutes from now, then repeat forever.
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
        -RepetitionInterval (New-TimeSpan -Minutes $t.Minutes) `
        -RepetitionDuration (New-TimeSpan -Days 3650)

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes $t.Limit)

    Register-ScheduledTask -TaskName $t.Name -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal `
        -Description "InstaBox keepalive ($($t.Name)) every $($t.Minutes) min" | Out-Null

    Write-Host "registered: $($t.Name) (every $($t.Minutes) min)"
}

Write-Host ''
Write-Host '=== scheduled tasks ==='
Get-ScheduledTask | Where-Object { $_.TaskName -like 'InstaBox-Keepalive*' } |
    Select-Object TaskName, State | Format-Table -AutoSize
Write-Host '=== next / last run ==='
foreach ($t in $Tasks) {
    Get-ScheduledTaskInfo -TaskName $t.Name |
        Select-Object @{n='Task';e={$t.Name}}, NextRunTime, LastRunTime, LastTaskResult |
        Format-List
}
