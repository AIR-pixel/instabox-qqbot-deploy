# Register / update the InstaBox keepalive scheduled task.
#
#   powershell -ExecutionPolicy Bypass -File install-task.ps1
#   powershell -ExecutionPolicy Bypass -File install-task.ps1 -IntervalMinutes 85
#   powershell -ExecutionPolicy Bypass -File install-task.ps1 -Uninstall
#
# ASCII ONLY (PowerShell 5.1 + UTF-8 without BOM => ParserError).

param(
    [ValidateSet('cycle', 'exec')]
    [string]$Mode = 'cycle',
    [int]$IntervalMinutes = 85,
    [string]$TaskName = 'InstaBox-Keepalive',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Continue'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Uninstall) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "removed: $TaskName"
    } else {
        Write-Host "not found: $TaskName"
    }
    exit 0
}

$Script = Join-Path $Here 'keepalive-cycle.ps1'
if (-not (Test-Path $Script)) { Write-Host "FATAL script not found: $Script"; exit 1 }

# replace any existing task with the same name
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "removing existing task $TaskName"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Script)

# Start 2 minutes from now, then repeat forever.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

# Limited = no elevation needed; the task only makes HTTPS calls.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description "InstaBox keepalive ($Mode) every $IntervalMinutes min" | Out-Null

Write-Host "registered: $TaskName (every $IntervalMinutes min)"
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State | Format-Table -AutoSize
Get-ScheduledTaskInfo -TaskName $TaskName |
    Select-Object NextRunTime, LastRunTime, LastTaskResult | Format-List
