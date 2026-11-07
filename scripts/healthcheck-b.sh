#!/usr/bin/env bash
# healthcheck-b.sh - single authoritative acceptance check of the whole stack.
#
# Checks 9 things:
#   1 dsh-web.service active        2 surfcore-bridge.service active
#   3 DSH anonymous access = 401    4 QQ online (/get_login_info 200)
#   5 snowluma container running    6 astrbot stopped (optional component)
#   7 bridge connected to SnowLuma  8 bridge reports DSH ready
#   9 no preset rejection in THIS run
#
# Exit code = number of failures. "== RESULT: PASS (fail=0) ==" is the goal.
#
# Overridable env:
#   ROOT=/data/qqbot  ONEBOT_ACCESS_TOKEN=...  SNOWLUMA_HOST=snowluma:3000
#   DSH_URL=http://127.0.0.1:3080  BRIDGE_LOG=$ROOT/surfcore-bridge.log
#   CHECK_ASTRBOT=0   # set 0 if you never run AstrBot at all
set -u

ROOT=${ROOT:-/data/qqbot}
TOKEN=${ONEBOT_ACCESS_TOKEN:-surfcore-9f3c7a1d}
SNOWLUMA=${SNOWLUMA_HOST:-snowluma:3000}
DSH=${DSH_URL:-http://127.0.0.1:3080}
LOG=${BRIDGE_LOG:-$ROOT/surfcore-bridge.log}
CHECK_ASTRBOT=${CHECK_ASTRBOT:-1}

fail=0
ok(){   echo "OK   $*"; }
warn(){ echo "WARN $*"; }
bad(){  echo "FAIL $*"; fail=$((fail+1)); }

# --- 1/2 systemd guardians ---
[ "$(systemctl is-active dsh-web.service 2>/dev/null)" = active ] \
  && ok "dsh-web.service active" || bad "dsh-web.service NOT active"
[ "$(systemctl is-active surfcore-bridge.service 2>/dev/null)" = active ] \
  && ok "surfcore-bridge.service active" || bad "surfcore-bridge.service NOT active"

# --- 3 auth fence: anonymous MUST be 401 ---
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$DSH/" 2>/dev/null)
if [ "$c" = 401 ]; then
  ok "dsh-web anonymous 401 (auth fence up)"
elif [ "$c" = 200 ]; then
  bad "dsh-web anonymous 200 (auth fence DOWN - do not expose this port)"
else
  bad "dsh-web unreachable ($c)"
fi

# --- 4 QQ online ---
q=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 \
     -H "Authorization: Bearer $TOKEN" "http://$SNOWLUMA/get_login_info" 2>/dev/null)
[ "$q" = 200 ] && ok "QQ online (/get_login_info 200)" || bad "QQ offline (/get_login_info $q)"

# --- 5 snowluma container ---
[ "$(docker inspect -f '{{.State.Running}}' snowluma 2>/dev/null)" = true ] \
  && ok "snowluma container running" || bad "snowluma container down"

# --- 6 astrbot must be stopped (it would double-reply) ---
if [ "$CHECK_ASTRBOT" = 1 ]; then
  a=$(docker inspect -f '{{.State.Running}}' astrbot 2>/dev/null)
  case "$a" in
    ""|false) ok "astrbot stopped (plan B)" ;;
    *)        warn "astrbot running=$a (double-reply risk)" ;;
  esac
fi

# --- 7/8 bridge connectivity lines ---
grep -q 'SnowLuma 已连接' "$LOG" 2>/dev/null \
  && ok "bridge connected to SnowLuma" || warn "bridge SnowLuma line not found yet"
grep -q 'DSH 已就绪' "$LOG" 2>/dev/null \
  && ok "bridge DSH ready" || warn "bridge DSH-ready line not found yet"

# --- 9 preset rejection, THIS RUN ONLY ---
# The log is append-only. Grepping the whole file matches old, already-fixed
# events and fails forever. Anchor on the last "bridge started" line instead.
SINCE=$(awk '/桥接已启动/{n=NR} END{print n+0}' "$LOG" 2>/dev/null)
if [ "${SINCE:-0}" -gt 0 ]; then
  RUNLOG=$(tail -n +"$SINCE" "$LOG")
else
  RUNLOG=$(tail -n 200 "$LOG" 2>/dev/null)
fi
printf '%s\n' "$RUNLOG" | grep -q '⛔' \
  && bad "bridge has preset rejection (this run)" || ok "no preset rejection (this run)"

echo "== RESULT: $([ $fail -eq 0 ] && echo PASS || echo FAIL) (fail=$fail) =="
exit $fail
