$ErrorActionPreference = 'Continue'

# Publish this repo to github.com/AIR-pixel/instabox-qqbot-deploy
# Uses curl.exe for the API (Invoke-RestMethod fails here: schannel "base
# connection closed" on api.github.com). Git push uses a one-shot extraheader
# so the token never lands in .git/config.
$repo = 'C:\Users\27081\Documents\deepseek-harness\default-workspace\instabox-qqbot-deploy'
$git  = 'C:\Users\27081\AppData\Local\github-copilot-git-2.53.0-4\cmd\git.exe'
$curl = 'C:\Windows\System32\curl.exe'
$token = (Get-Content (Join-Path $repo '.gh-token.json') -Raw | ConvertFrom-Json).access_token
if (-not $token) { throw 'no token' }

$owner = 'AIR-pixel'
$name  = 'instabox-qqbot-deploy'

# --- 1. identity check ------------------------------------------------------
$me = & $curl -s --max-time 20 --ssl-no-revoke `
    -H "Authorization: Bearer $token" -H 'Accept: application/vnd.github+json' `
    -H 'User-Agent: instabox-setup' 'https://api.github.com/user' 2>$null | ConvertFrom-Json
Write-Output "AUTHENTICATED_AS=$($me.login) ID=$($me.id)"
if ($me.login -ne $owner) { throw "token belongs to $($me.login), expected $owner" }

# --- 2. create repo (idempotent) -------------------------------------------
$payload = Join-Path $repo '.repo-create.json'
@{
  name        = $name
  description = 'Deploy a 24/7 QQ chatbot (SnowLuma + headless DSH + SurfCore) onto an InstaBox VPS - agent-executable runbook, pitfall library, platform facts.'
  private     = $false
  has_issues  = $true
  has_wiki    = $false
} | ConvertTo-Json | Set-Content -Path $payload -Encoding utf8

$resp = & $curl -s --max-time 30 --ssl-no-revoke -X POST `
    -H "Authorization: Bearer $token" -H 'Accept: application/vnd.github+json' `
    -H 'User-Agent: instabox-setup' -H 'Content-Type: application/json' `
    --data-binary "@$payload" 'https://api.github.com/user/repos' 2>$null
$created = $resp | ConvertFrom-Json
if ($created.full_name) {
    Write-Output "CREATED=$($created.full_name)"
} elseif ($resp -match 'already exists') {
    Write-Output 'ALREADY_EXISTS'
} else {
    Write-Output "CREATE_RESP=$resp"
}

# --- 3. push ----------------------------------------------------------------
Push-Location $repo
try {
    & $git remote remove origin 2>$null
    & $git remote add origin "https://github.com/$owner/$name.git"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$token"))
    & $git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $b64" `
           -c credential.helper= `
           -c http.sslVerify=true `
           push -u origin main --force 2>&1 | Out-String | Write-Output
    Write-Output "PUSH_EXIT=$LASTEXITCODE"
} finally { Pop-Location }

Write-Output '=== verify remote head ==='
& $git -C $repo -c credential.helper= ls-remote "https://github.com/$owner/$name.git" refs/heads/main 2>&1 | Out-String | Write-Output
