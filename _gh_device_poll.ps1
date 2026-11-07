$ErrorActionPreference = 'Continue'
# Poll GitHub device-flow token using curl (urllib would pick up the dead WinINET proxy).
$curl = 'C:\Windows\System32\curl.exe'
$repo = 'C:\Users\27081\Documents\deepseek-harness\default-workspace\instabox-qqbot-deploy'
$out  = Join-Path $repo '.gh-token.json'
$clientId = '178c6fc778ccc68e1d6a'
$deviceCode = $args[0]
$interval = 5
$deadline = (Get-Date).AddMinutes(14)

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $interval
    $raw = & $curl -s --max-time 25 --ssl-no-revoke --noproxy '*' `
        -X POST 'https://github.com/login/oauth/access_token' `
        -H 'Accept: application/json' `
        -d "client_id=$clientId&device_code=$deviceCode&grant_type=urn:ietf:params:oauth:grant-type:device_code" 2>$null
    if (-not $raw) { Write-Output 'empty response'; continue }
    try { $j = $raw | ConvertFrom-Json } catch { Write-Output "unparsable: $raw"; continue }

    if ($j.error -eq 'authorization_pending') { continue }
    if ($j.error -eq 'slow_down') { $interval += 5; continue }
    if ($j.access_token) {
        @{ access_token = $j.access_token; scope = $j.scope; token_type = $j.token_type } |
            ConvertTo-Json | Set-Content -Path $out -Encoding ascii
        Write-Output "AUTHORIZED scope=$($j.scope)"
        exit 0
    }
    Write-Output "unexpected: $raw"
    exit 2
}
Write-Output 'TIMEOUT'
exit 3
