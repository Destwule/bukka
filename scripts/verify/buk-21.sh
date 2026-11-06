#!/usr/bin/env bash
# BUK-21 verify: menu page fails to load for customers.
# Run from the root of your bukka clone, with the lab server still running:
#   bash scripts/verify/buk-21.sh
# Writes artifacts/buk-21-triage.txt, which you commit in your pull request.

set -uo pipefail

TICKET="BUK-21"
NAME="bukka-prod-1"
OUT="artifacts/buk-21-triage.txt"
RUNBOOK="runbooks/menu-page-fails.md"
FAILS=0
RESULTS=()

pass() { RESULTS+=("PASS  $1"); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      → %s\n' "$2"; FAILS=$((FAILS + 1)); }
on_server() { docker exec "$NAME" sh -c "$1" 2>/dev/null; }

if [ ! -d .git ] || [ ! -f tickets/BUK-21.md ]; then
  echo "Run this from the root of your bukka clone (the folder with tickets/ in it)."
  exit 2
fi

echo "== $TICKET verify =="
echo

# 1. The server is up
if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = "true" ]; then
  pass "bukka-prod-1 is running"
  UP=1
else
  fail "bukka-prod-1 is running" "Start it with: bash labs/buk-21/start.sh (then fix it again; it starts broken)."
  UP=0
fi

# 2. Customers can load the menu (from outside the server)
BODY=$(curl -s -m 5 http://localhost:18080/api/restaurants || true)
if [[ "$BODY" == \[*\"slug\"* ]]; then
  pass "Customers can load restaurants from http://localhost:18080"
else
  fail "Customers can load restaurants from http://localhost:18080" "From your machine, curl -v http://localhost:18080/api/restaurants still fails."
fi

if [ "$UP" -eq 1 ]; then
  # 3. API listens on every interface, not just localhost
  if on_server "ss -ltn" | grep -Eq '(0\.0\.0\.0|\*|\[::\]):8080 '; then
    pass "The API listens on all interfaces on port 8080"
  else
    fail "The API listens on all interfaces on port 8080" "Check what address it's bound to: ss -ltnp on the server."
  fi

  # 4. Firewall is still on (default-deny), not switched off
  if on_server "iptables -S INPUT" | grep -q '^-P INPUT DROP'; then
    pass "Firewall still blocks by default (INPUT policy DROP)"
  else
    fail "Firewall still blocks by default" "Don't disable the firewall: allow only what's needed."
  fi

  # 5. ...with a rule that lets port 8080 in
  if on_server "iptables -S INPUT" | grep -Eq -- '-p tcp .*--dport 8080 .*-j ACCEPT'; then
    pass "Firewall allows TCP 8080"
  else
    fail "Firewall allows TCP 8080" "Inbound traffic to the API port is still dropped. Look at: sudo iptables -L INPUT -n -v"
  fi

  # 6. The server can resolve names again
  if on_server "getent hosts github.com" >/dev/null; then
    pass "The server resolves DNS names again"
  else
    fail "The server resolves DNS names again" "Try: dig github.com on the server, then look at /etc/resolv.conf"
  fi
else
  for c in "The API listens on all interfaces on port 8080" "Firewall still blocks by default" \
           "Firewall allows TCP 8080" "The server resolves DNS names again"; do
    fail "$c" "The server isn't running."
  done
fi

# 7. Runbook written
if [ -f "$RUNBOOK" ] && grep -q '^## How you know' "$RUNBOOK" && grep -q '^## Check first' "$RUNBOOK" \
   && grep -q '^## Fix' "$RUNBOOK" && grep -q '^## Why it happens' "$RUNBOOK"; then
  pass "Runbook $RUNBOOK has all four sections"
else
  fail "Runbook $RUNBOOK has all four sections" "Use the template in runbooks/README.md."
fi

# 8. On the ticket branch
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ "$BRANCH" == buk-21-* ]]; then
  pass "On a BUK-21 branch ($BRANCH)"
else
  fail "On a BUK-21 branch" "You're on '$BRANCH'. Run: git checkout -b buk-21-menu-page-fails upstream/apprentice/<you>"
fi

# 9. Who ran this
GH_USER=""
GH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
if [[ "$GH_OUT" =~ Hi\ ([A-Za-z0-9-]+)! ]]; then
  GH_USER="${BASH_REMATCH[1]}"
  pass "GitHub recognises your SSH key as @$GH_USER"
else
  fail "GitHub recognises your SSH key" "Run: ssh-add, then try again (see BUK-14)."
fi

mkdir -p artifacts
{
  echo "# $TICKET triage audit"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "github_user: ${GH_USER:-unknown}"
  echo "branch: $BRANCH"
  echo "fails: $FAILS"
  echo
  printf '%s\n' "${RESULTS[@]}"
} > "$OUT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All checks passed. Wrote $OUT."
  echo "Next: git add $OUT $RUNBOOK && git commit -m \"fix: restore menu access on bukka-prod-1 (BUK-21)\""
  exit 0
else
  echo "$FAILS check(s) failed. Fix the items marked ✗ and run this again."
  exit 1
fi
