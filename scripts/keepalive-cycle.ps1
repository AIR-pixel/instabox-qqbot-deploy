# InstaBox keepalive cycle (Plan A: active suspend -> 20s -> resume).
#
# Why suspend/resume instead of wake:
#   wake does NOT count as work, so it cannot extend the Free-tier dynamic
#   runtime window, and steady waking prevents the zero-cooldown idle pause.
#   The machine then inevitably hits max-run, whose Free-tier cooldown grows
#   5-20 min -> 60-75 min -> 120-135 min. Suspend is a user-initiated end of
#   the run: zero cooldown, combo counter reset.
#
# Keep the interval well under the dynamic-runtime window (2h) AND under
# maxRunMinutes. 85 min is safe against both.
#
# Usage:  powershell -ExecutionPolicy Bypass -File keepalive-cycle.ps1
#
# ASCII ONLY. PowerShell 5.1 decodes .ps1 as ANSI; UTF-8 without BOM breaks it.

param(
    [string]$MachineId = '<MACHINE_ID>',
    [string]$CredPath  = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$Base   = 'https://api.instabox.sh'
$LogDir = Join-Path $env:LOCALAPPDATA 'instabox-keepalive'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir 'keepalive.log'

function Write-Log([string]$msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogFile -Value $line -Encoding ASCII
    Write-Host $line
}

# --- credentials -----------------------------------------------------------
$candidates = @(
    $CredPath,
    (Join-Path $env:USERPROFILE '.config\instabox\credentials.json'),
    (Join-Path $env:LOCALAPPDATA 'instabox\credentials.json')
) | Where-Object { $_ -and (Test-Path $_) }

if (-not $candidates) { Write-Log 'FATAL credentials.json not found'; exit 1 }
$ApiKey = (Get-Content $candidates[0] -Raw | ConvertFrom-Json).apiKey
if (-not $ApiKey) { Write-Log 'FATAL apiKey empty'; exit 1 }

$Headers = @{ 'X-API-Key' = $ApiKey }

function Get-State {
    try {
        return (Invoke-WebRequest -Uri "$Base/v1/machines/$MachineId" -Headers $Headers `
                -UseBasicParsing -TimeoutSec 25).Content | ConvertFrom-Json
    } catch {
        Write-Log ('GET machine failed: ' + $_.Exception.Message)
        return $null
    }
}

function Post-Op([string]$op) {
    # Every lifecycle call needs a UNIQUE Idempotency-Key (kept 7 days).
    $ik = [guid]::NewGuid().ToString()
    $h  = @{ 'X-API-Key' = $ApiKey; 'Idempotency-Key' = $ik }
    try {
        $r = Invoke-WebRequest -Uri "$Base/v1/machines/$MachineId/$op" -Method Post -Headers $h `
             -Body '' -ContentType 'application/json' -UseBasicParsing -TimeoutSec 60
        Write-Log ("{0} -> HTTP {1}" -f $op, $r.StatusCode)   # 202 = accepted
        return $true
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $sc = [int]$resp.StatusCode
            $body = ''
            try {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $body = $sr.ReadToEnd()
            } catch {}
            if ($sc -eq 409 -and $body -match 'machine_cooldown') {
                Write-Log ("{0} -> 409 machine_cooldown, skip this round" -f $op)
                return $false
            }
            Write-Log ("{0} -> HTTP {1} body={2}" -f $op, $sc, $body)
            return $false
        }
        Write-Log ("{0} -> EXCEPTION {1}" -f $op, $_.Exception.Message)
        return $false
    }
}

# --- main ------------------------------------------------------------------
$m = Get-State
if (-not $m) { exit 1 }

Write-Log ("before: state={0} desired={1} runStartedAt={2} cooldownUntil={3}" -f `
           $m.state, $m.desiredState, $m.runStartedAt, $m.cooldownUntil)

if ($m.state -ne 'running') {
    Write-Log ("machine not running (state={0}); resume instead of cycle" -f $m.state)
    Post-Op 'resume' | Out-Null
    Start-Sleep -Seconds 25
    $m2 = Get-State
    if ($m2) { Write-Log ('after resume: state=' + $m2.state) }
    exit 0
}

if (-not (Post-Op 'suspend')) { exit 0 }
Start-Sleep -Seconds 20
if (-not (Post-Op 'resume')) {
    Write-Log 'resume failed once, retrying after 30s'
    Start-Sleep -Seconds 30
    Post-Op 'resume' | Out-Null
}

# converge check: processes and memory must be preserved across the cycle
for ($i = 0; $i -lt 6; $i++) {
    Start-Sleep -Seconds 10
    $m3 = Get-State
    if ($m3 -and $m3.state -eq 'running') {
        Write-Log ('after: state=running runStartedAt=' + $m3.runStartedAt +
                   ' ready=' + $m3.runtime.ready + ' preserved=' + $m3.runtime.processesPreserved)
        exit 0
    }
}
Write-Log 'WARN did not converge to running within 60s'
exit 0
