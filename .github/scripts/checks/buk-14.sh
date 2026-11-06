#!/usr/bin/env bash
# BUK-14 checks on the pull request: the audit file from scripts/verify/buk-14.sh.

set -uo pipefail

F="artifacts/workstation-audit.txt"
EXPECTED_PASSES=9
FAILS=0
ok()  { echo "✓ $1"; }
bad() { echo "::error::$1"; echo "✗ $1"; FAILS=$((FAILS + 1)); }
lc()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

if [ ! -f "$F" ]; then
  bad "$F is missing. Run 'bash scripts/verify/buk-14.sh' on your machine and commit the file it writes."
  exit 1
fi
ok "$F is present"

if grep -q '^FAIL' "$F"; then
  bad "The audit has failed checks. Fix them, run the verify script again and commit the new file:"
  grep '^FAIL' "$F" | sed 's/^/    /'
fi

PASSES=$(grep -c '^PASS' "$F" || true)
if [ "$PASSES" -ge "$EXPECTED_PASSES" ]; then
  ok "All $EXPECTED_PASSES workstation checks passed"
else
  bad "Expected $EXPECTED_PASSES passed checks in the audit, found $PASSES. Run the verify script again."
fi

GH_USER=$(sed -n 's/^github_user: //p' "$F")
if [ "$(lc "$GH_USER")" = "$(lc "$PR_AUTHOR")" ]; then
  ok "The audit was made with @$PR_AUTHOR's SSH key"
else
  bad "The audit says your SSH key belongs to @$GH_USER, but this pull request is from @$PR_AUTHOR. Run the verify script with your own key."
fi

if grep -q '^whoami: root$' "$F"; then
  bad "The audit was run as root."
fi

[ "$FAILS" -eq 0 ]
