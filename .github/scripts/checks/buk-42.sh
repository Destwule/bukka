#!/usr/bin/env bash
# BUK-42 checks on the pull request: the audit (the production VPC, subnets
# and route tables), and that the committed infra/cli/buk-42.sh is the one
# that was audited and has no AWS keys in it.

set -uo pipefail

F="artifacts/buk-42-network-audit.txt"
S="infra/cli/buk-42.sh"
EXPECTED_PASSES=19
FAILS=0
ok()  { echo "✓ $1"; }
bad() { echo "::error::$1"; echo "✗ $1"; FAILS=$((FAILS + 1)); }
lc()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
TICKET_N=$(basename "$0" .sh)

[ -f "$F" ] || { bad "$F is missing. Run 'bash scripts/verify/$TICKET_N.sh' with LocalStack running and commit what it writes."; exit 1; }
ok "$F is present"

if grep -q '^FAIL' "$F"; then
  bad "The audit has failed checks:"; grep '^FAIL' "$F" | sed 's/^/    /'
fi
PASSES=$(grep -c '^PASS' "$F" || true)
[ "$PASSES" -ge "$EXPECTED_PASSES" ] && ok "All $EXPECTED_PASSES checks passed" \
  || bad "Expected $EXPECTED_PASSES passed checks in the audit, found $PASSES."

GH_USER=$(sed -n 's/^github_user: //p' "$F")
[ -n "$GH_USER" ] && [ "$(lc "$GH_USER")" = "$(lc "$PR_AUTHOR")" ] && ok "The audit was made with @$PR_AUTHOR's SSH key" \
  || bad "The audit says it was run by @$GH_USER, but this pull request is from @$PR_AUTHOR."

if [ ! -f "$S" ]; then
  bad "$S is missing from the pull request."
else
  [ "$(sha256sum "$S" | cut -d' ' -f1)" = "$(sed -n 's/^script_sha256: //p' "$F")" ] \
    && ok "$S is the version that was audited" \
    || bad "$S changed after the audit. Rebuild on a fresh LocalStack with it, run the verify script again and commit the new audit."
  if grep -nE 'create-access-key' "$S"; then
    bad "$S creates an access key. The server gets its access from the instance profile, not a key."
  else
    ok "$S creates no access keys"
  fi
fi

# AWS keys anywhere in the pull request's files: AKIA... key IDs, or a
# 40-character secret written after its name.
LEAKS=$(git grep -nIE 'AKIA[0-9A-Z]{16}|(aws_secret_access_key|AWS_SECRET_ACCESS_KEY|SecretAccessKey)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+]{40}' 2>/dev/null || true)
if [ -n "$LEAKS" ]; then
  bad "There's an AWS key in the pull request. Remove it, and treat it as leaked: it must be deactivated."
  echo "$LEAKS" | cut -d: -f1,2 | sed 's/^/    /'
else
  ok "No AWS keys in the repo"
fi

[ "$FAILS" -eq 0 ]
