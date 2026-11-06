#!/usr/bin/env bash
# BUK-27 verify: the API as a systemd service behind Nginx.
# Run from the root of your bukka clone, with bukka-web-1 running:
#   bash scripts/verify/buk-27.sh
# Writes artifacts/buk-27-audit.txt. Takes about a minute (it restarts the server).

set -uo pipefail

TICKET="BUK-27"
NAME="bukka-web-1"
URL="http://localhost:18081"
OUT="artifacts/buk-27-audit.txt"
UNIT="deploy/systemd/bukka-api.service"
NGINX="deploy/nginx/bukka.conf"
FAILS=0
RESULTS=()

pass() { RESULTS+=("PASS  $1"); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      → %s\n' "$2"; FAILS=$((FAILS + 1)); }
srv() { docker exec "$NAME" sh -c "$1" 2>/dev/null; }
if command -v sha256sum >/dev/null; then sha() { sha256sum | cut -d' ' -f1; }; else sha() { shasum -a 256 | cut -d' ' -f1; }; fi
wait_ok() { for _ in $(seq 1 "${2:-20}"); do curl -sf -m 3 "$1" >/dev/null && return 0; sleep 1; done; return 1; }

if [ ! -d .git ] || [ ! -f tickets/BUK-27.md ]; then
  echo "Run this from the root of your bukka clone (the folder with tickets/ in it)."
  exit 2
fi
echo "== $TICKET verify =="
echo

if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then
  fail "bukka-web-1 is running" "Start it with: bash labs/buk-27/start.sh, then set it up again."
  echo; echo "Can't check anything else without the server."; exit 1
fi
pass "bukka-web-1 is running"

# --- Repo files match the server ------------------------------------------
if [ -f "$UNIT" ] && [ "$(sha < "$UNIT")" = "$(srv 'cat /etc/systemd/system/bukka-api.service' | sha)" ]; then
  pass "$UNIT matches the installed unit"
else
  fail "$UNIT matches the installed unit" "Keep the repo and the server in sync: the repo is the source of truth."
fi
NGINX_SHA=$( [ -f "$NGINX" ] && sha < "$NGINX" )
MATCH=""
for f in $(srv 'ls /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf 2>/dev/null'); do
  [ "$(srv "cat '$f'" | sha)" = "$NGINX_SHA" ] && MATCH="$f"
done
if [ -n "$NGINX_SHA" ] && [ -n "$MATCH" ]; then
  pass "$NGINX is the config Nginx loads ($MATCH)"
else
  fail "$NGINX is the config Nginx loads" "Install it in /etc/nginx/sites-enabled/ (or conf.d/) and remove the default site."
fi

# --- The service --------------------------------------------------------------
if [ "$(srv 'systemctl is-enabled bukka-api')" = "enabled" ] && [ "$(srv 'systemctl is-active bukka-api')" = "active" ]; then
  pass "bukka-api is enabled and running"
else
  fail "bukka-api is enabled and running" "systemctl status bukka-api"
fi
SVC_USER=$(srv 'systemctl show -p User --value bukka-api')
if [ "$SVC_USER" = "bukka" ] && [ "$(srv "ps -o user= -p \$(systemctl show -p MainPID --value bukka-api)" | tr -d ' ')" = "bukka" ]; then
  pass "The API runs as the bukka service account"
else
  fail "The API runs as the bukka service account" "Set User=bukka in the unit (it's '${SVC_USER:-root}')."
fi
RESTART=$(srv 'systemctl show -p Restart --value bukka-api')
if [ "$RESTART" = "always" ] || [ "$RESTART" = "on-failure" ]; then
  pass "Restarts automatically (Restart=$RESTART)"
else
  fail "Restarts automatically" "Restart= is '$RESTART'."
fi
if srv 'ss -ltn' | grep -q '127.0.0.1:8080 ' && ! srv 'ss -ltn' | grep -Eq '(0\.0\.0\.0|\*|\[::\]):8080 '; then
  pass "The API listens on 127.0.0.1:8080 only"
else
  fail "The API listens on 127.0.0.1:8080 only" "ss -ltnp on the server"
fi

# --- Customers --------------------------------------------------------------
if curl -s -m 5 "$URL/" | grep -q '<div id="root">' && curl -s -m 5 "$URL/api/restaurants" | grep -q '"slug"'; then
  pass "Customers get the web app and the API through Nginx on port 80"
else
  fail "Customers get the web app and the API through Nginx on port 80" "curl -i $URL/ and $URL/api/restaurants"
fi
curl -s -m 5 "$URL/api/restaurants" >/dev/null
sleep 1
LAST=$(srv "journalctl -u bukka-api -o cat --no-pager -n 50" | grep '"path": "/api/restaurants"' | tail -1)
if [ -n "$LAST" ] && ! echo "$LAST" | grep -q '"client": "127.0.0.1"'; then
  pass "The API sees the customer's address (forwarded headers)"
else
  fail "The API sees the customer's address (forwarded headers)" "The API logs client 127.0.0.1: set X-Forwarded-For / X-Real-IP in Nginx."
fi

# --- Self-healing -----------------------------------------------------------
PID=$(srv 'systemctl show -p MainPID --value bukka-api')
srv "kill -9 $PID"
sleep 1
if wait_ok "$URL/api/restaurants" 15 && [ "$(srv 'systemctl show -p MainPID --value bukka-api')" != "$PID" ]; then
  pass "Comes back by itself after being killed"
else
  fail "Comes back by itself after being killed" "Check RestartSec= (10 seconds or less)."
fi

# --- Friendly 502 -----------------------------------------------------------
srv 'systemctl stop bukka-api'
CODE=$(curl -s -m 5 -o /tmp/buk27-502 -w '%{http_code}' "$URL/api/restaurants")
if [ "$CODE" = "502" ] && grep -q '"error"[[:space:]]*:[[:space:]]*"kitchen_closed"' /tmp/buk27-502; then
  pass "API down → 502 with the kitchen_closed JSON"
else
  fail "API down → 502 with the kitchen_closed JSON" "Got HTTP $CODE: $(head -c 120 /tmp/buk27-502 2>/dev/null)"
fi
srv 'systemctl start bukka-api'
rm -f /tmp/buk27-502

# --- Survives a reboot ------------------------------------------------------
echo "  … restarting bukka-web-1 to check everything comes back on boot"
docker restart "$NAME" >/dev/null
if wait_ok "$URL/api/restaurants" 40; then
  pass "Everything comes back after a server restart"
else
  fail "Everything comes back after a server restart" "Are bukka-api and nginx both enabled?"
fi

# --- Branch and identity ------------------------------------------------------
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ "$BRANCH" == buk-27-* ]]; then pass "On a BUK-27 branch ($BRANCH)"; else
  fail "On a BUK-27 branch" "You're on '$BRANCH'."; fi
GH_USER=""
GH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
if [[ "$GH_OUT" =~ Hi\ ([A-Za-z0-9-]+)! ]]; then
  GH_USER="${BASH_REMATCH[1]}"; pass "GitHub recognises your SSH key as @$GH_USER"
else
  fail "GitHub recognises your SSH key" "Run: ssh-add, then try again (see BUK-14)."
fi

mkdir -p artifacts
{
  echo "# $TICKET audit"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "github_user: ${GH_USER:-unknown}"
  echo "branch: $BRANCH"
  echo "unit_sha256: $( [ -f "$UNIT" ] && sha < "$UNIT")"
  echo "nginx_sha256: $NGINX_SHA"
  echo "fails: $FAILS"
  echo
  printf '%s\n' "${RESULTS[@]}"
} > "$OUT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All checks passed. Wrote $OUT."
  echo "Next: git add deploy/ $OUT && git commit -m \"feat: run the API under systemd behind nginx (BUK-27)\""
  exit 0
else
  echo "$FAILS check(s) failed. Fix the items marked ✗ and run this again."
  exit 1
fi
