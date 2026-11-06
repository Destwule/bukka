#!/usr/bin/env bash
# BUK-33 checks on the pull request: re-run the behaviour tests here (not just
# trust the audit), and check the audit belongs to the PR author.
set -uo pipefail
F="artifacts/buk-33-audit.txt"
FAILS=0
ok()  { echo "✓ $1"; }
bad() { echo "::error::$1"; echo "✗ $1"; FAILS=$((FAILS + 1)); }
lc()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

sudo apt-get install -y -qq shellcheck >/dev/null 2>&1 || true
echo "Running the BUK-33 tests against your scripts:"
if python3 .github/scripts/checks/buk33_check.py | sed 's/^/  /'; then
  ok "Your scripts pass every test"
else
  bad "Some tests failed (see the FAIL lines above)."
fi

if [ ! -f "$F" ]; then
  bad "$F is missing. Run 'bash scripts/verify/buk-33.sh' and commit what it writes."
else
  GH_USER=$(sed -n 's/^github_user: //p' "$F")
  [ "$(lc "$GH_USER")" = "$(lc "$PR_AUTHOR")" ] && ok "The audit was made with @$PR_AUTHOR's SSH key" \
    || bad "The audit says it was run by @$GH_USER, but this pull request is from @$PR_AUTHOR."
fi
[ "$FAILS" -eq 0 ]
