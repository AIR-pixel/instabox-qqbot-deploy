#!/usr/bin/env bash
# postscan.sh - run ONCE after the QQ QR scan, and re-run any time SnowLuma
# rewrites onebot_<uin>.json.
#
# WHY: SnowLuma's per-account config is an OVERLAY document. Every field lives
# under "networks" (not at the top level). If it drops the fixed accessToken or
# the wsClients entry, the bridge / downstream consumers silently stop
# connecting.
#
# IDEMPOTENT + SAFE: when every account config is already correct this touches
# nothing and does NOT restart the container, so a live QQ session is never
# disturbed (no re-scan, no WebUI password rotation).
#
# Usage:  bash /data/qqbot/scripts/postscan.sh
set -u

ROOT=${ROOT:-/data/qqbot}
COMPOSE="$ROOT/compose"
TOKEN=${ONEBOT_ACCESS_TOKEN:-surfcore-9f3c7a1d}
# Leave WS_URL empty to skip wsClients merging entirely (recommended when no
# reverse-WS consumer such as AstrBot exists).
WS_NAME=${WS_NAME:-astrbot}
WS_URL=${WS_URL:-}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$COMPOSE" || exit 2

echo '=== postscan: verify/merge per-account onebot_<uin>.json ==='

mapfile -t FILES < <(docker exec snowluma sh -lc 'ls /app/data/config/onebot_*.json 2>/dev/null')
if [ "${#FILES[@]}" -eq 0 ]; then
  echo 'NO_ACCOUNT_FILE: QQ has not been scanned/logged in yet.'
  echo 'Re-run after the scan. Global template check:'
  docker exec snowluma sh -lc 'grep -c accessToken /app/data/config/onebot.json'
  exit 0
fi

CHANGED=0
for f in "${FILES[@]}"; do
  f=$(echo "$f" | tr -d '\r')
  base=$(basename "$f")
  echo "-- $base --"
  docker cp "snowluma:$f" "$TMP/$base" 2>/dev/null || { echo "COPY_OUT_FAIL $base"; continue; }

  STATUS=$(TOKEN="$TOKEN" WS_URL="$WS_URL" WS_NAME="$WS_NAME" python3 - "$TMP/$base" <<'PY'
import json, os, sys

p   = sys.argv[1]
tok = os.environ['TOKEN']
ws  = os.environ.get('WS_URL', '')
nm  = os.environ.get('WS_NAME', 'astrbot')

d = json.load(open(p, encoding='utf-8'))

# CRITICAL: the overlay nests everything under "networks".
nets = d.setdefault('networks', {})

ok = True
for key in ('httpServers', 'wsServers'):
    arr = nets.get(key, [])
    if not arr:
        continue
    for s in arr:
        if s.get('accessToken') != tok:
            ok = False
if ws and not any(c.get('url') == ws for c in nets.get('wsClients', [])):
    ok = False

if ok:
    print('OK')
    raise SystemExit(0)

for key in ('httpServers', 'wsServers'):
    arr = nets.setdefault(key, [])
    if not arr:
        continue
    for s in arr:
        s['accessToken'] = tok
        s['enabled'] = True
        s['host'] = '0.0.0.0'

if ws:
    entry = {'name': nm, 'enabled': True, 'url': ws,
             'role': 'Universal', 'reconnectIntervalMs': 5000}
    found = False
    for c in nets.setdefault('wsClients', []):
        if c.get('name') == nm or c.get('url') == ws:
            c.update(entry)
            found = True
    if not found:
        nets['wsClients'].append(entry)

json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('MERGED')
PY
)
  echo "  status=$STATUS"

  if [ "$STATUS" = 'MERGED' ]; then
    docker cp "$TMP/$base" "snowluma:$f" 2>/dev/null || { echo "COPY_IN_FAIL $base"; continue; }
    docker exec snowluma chown node:node "$f" 2>/dev/null
    CHANGED=1
  fi
done

if [ "$CHANGED" -eq 1 ]; then
  echo '=== config changed -> restart snowluma to apply ==='
  docker compose --env-file .env restart snowluma >/dev/null 2>&1
  sleep 5
else
  echo '=== all account configs already correct -> no rewrite, NO restart (live session kept) ==='
fi

echo '=== verify (text-level, works on networks.* too) ==='
for f in "${FILES[@]}"; do
  f=$(echo "$f" | tr -d '\r')
  tok=$(docker exec snowluma sh -lc "grep -c $TOKEN $f" 2>/dev/null)
  echo "  $(basename "$f"): token_hits=$tok"
done

echo '=== healthcheck ==='
bash "$ROOT/scripts/healthcheck-b.sh"
echo '=== END ==='
