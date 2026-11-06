#!/usr/bin/env bash
# BUK-21 checks on the pull request: triage audit + runbook.

set -uo pipefail

F="artifacts/buk-21-triage.txt"
RUNBOOK="runbooks/menu-page-fails.md"
EXPECTED_PASSES=9
FAILS=0
ok()  { echo "✓ $1"; }
bad() { echo "::error::$1"; echo "✗ $1"; FAILS=$((FAILS + 1)); }
lc()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

if [ ! -f "$F" ]; then
  bad "$F is missing. Run 'bash scripts/verify/buk-21.sh' with the lab server running, and commit the file it writes."
  exit 1
fi
ok "$F is present"

if grep -q '^FAIL' "$F"; then
  bad "The audit has failed checks:"
  grep '^FAIL' "$F" | sed 's/^/    /'
fi
PASSES=$(grep -c '^PASS' "$F" || true)
if [ "$PASSES" -ge "$EXPECTED_PASSES" ]; then
  ok "All $EXPECTED_PASSES triage checks passed"
else
  bad "Expected $EXPECTED_PASSES passed checks in the audit, found $PASSES."
fi

GH_USER=$(sed -n 's/^github_user: //p' "$F")
if [ "$(lc "$GH_USER")" = "$(lc "$PR_AUTHOR")" ]; then
  ok "The audit was made with @$PR_AUTHOR's SSH key"
else
  bad "The audit says it was run by @$GH_USER, but this pull request is from @$PR_AUTHOR."
fi

if [ ! -f "$RUNBOOK" ]; then
  bad "$RUNBOOK is missing."
else
  for h in "## How you know" "## Check first" "## Fix" "## Why it happens"; do
    grep -q "^$h" "$RUNBOOK" || bad "$RUNBOOK needs a '$h' section."
  done
  grep -qi "refused" "$RUNBOOK" || bad "$RUNBOOK should explain what 'Connection refused' told you."
  grep -qiE "timed out|timeout" "$RUNBOOK" || bad "$RUNBOOK should explain what a timeout told you."
  WORDS=$(wc -w < "$RUNBOOK" | tr -d ' ')
  if [ "$WORDS" -lt 150 ]; then
    bad "$RUNBOOK is $WORDS words. Write enough that someone else could follow it at 2am (150+ words)."
  else
    ok "Runbook has all sections ($WORDS words)"
  fi
fi

[ "$FAILS" -eq 0 ]
