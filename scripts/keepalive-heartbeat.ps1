# InstaBox idle heartbeat.
#
# Why this file exists:
#   The Free-tier 30-minute auto-suspend fires when there is "no coding agent
#   working, no terminal or SSH traffic, and no CPU load". A running bridge
#   doing light 10-minute timers does NOT count as work. In a real deployment
#   the box was suspended at 20:51 local time even though both systemd units
#   were active, the QQ account was online, and healthcheck-b.sh was PASS.
#   One real `instabox exec` every 20 minutes resets that idle counter.
#
#   This is DIFFERENT from keepalive-cycle.ps1 (85 min, suspend -> 20s ->
#   resume), which resets the max-run / dynamic-runtime streak. Both are
#   needed. See docs/05-keepalive.md and docs/06-pitfalls.md P-21.
#
#   Official wording: "Listing machines, reading one, and reading its logs
#   never wake it." A GET is NOT enough; it must be a real exec.
#
# Plain ASCII: PS 5.1 mangles UTF-8 .ps1 files without BOM.

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ---- EDIT THESE -----------------------------------------------------------
$Machine = '<MACHINE>'
$Cli     = '<INSTABOX_CLI>'
# Credentials live at $env:XDG_CONFIG_HOME/instabox/credentials.json.
# Set it here too if the CLI runs under a different account / task context.
$env:XDG_CONFIG_HOME = '<XDG_CONFIG_HOME>'
# ---------------------------------------------------------------------------

$LogDir  = Join-Path $env:LOCALAPPDATA 'instabox-keepalive'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir 'keepalive.log'

function Write-Log([string]$msg) {
    $line = '{0} [heartbeat] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogFile -Value $line -Encoding ASCII
    Write-Host $line
}

if (-not (Test-Path $Cli)) { Write-Log 'FATAL instabox CLI not found'; exit 1 }

$ok = $false
for ($i = 0; $i -lt 3; $i++) {
    # `true` is a real exec: counts as work AND wakes a suspended box.
    $null = & $Cli exec $Machine -- true 2>&1
    if ($LASTEXITCODE -eq 0) { $ok = $true; break }
    Start-Sleep -Seconds 10
}

if ($ok) {
    Write-Log 'exec ok, idle counter reset'
    exit 0
} else {
    Write-Log 'exec failed 3 times; next round will retry'
    exit 1
}
