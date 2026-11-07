#!/usr/bin/env bash
# BUK-63 checks on the pull request: the workflow is checked again here
# (shape + actionlint), and the runs and images named in the audit are
# looked up on GitHub and GHCR, not just trusted.
# Env: PR_AUTHOR; GH_TOKEN (any token that can read public repos).

set -uo pipefail

F="artifacts/buk-63-ci.txt"
WF=".github/workflows/ci.yml"
CHECK=".github/scripts/checks/buk63_check.py"
MIN_PASSES=25
FAILS=0
ok()  { echo "✓ $1"; }
bad() { echo "::error::$1"; echo "✗ $1"; FAILS=$((FAILS + 1)); }
lc()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
field() { sed -n "s/^$1: //p" "$F" | head -n 1; }

if [ ! -f "$F" ]; then
  bad "$F is missing. Run 'bash scripts/verify/buk-63.sh' after your pipeline is green and commit what it writes."
  exit 1
fi
ok "$F is present"
if grep -q '^FAIL' "$F"; then
  bad "The audit has failed checks:"; grep '^FAIL' "$F" | sed 's/^/    /'
fi
PASSES=$(grep -c '^PASS' "$F" || true)
[ "$PASSES" -ge "$MIN_PASSES" ] && ok "The audit has $PASSES passed checks" \
  || bad "Expected at least $MIN_PASSES passed checks in the audit, found $PASSES."
[ "$(lc "$(field github_user)")" = "$(lc "$PR_AUTHOR")" ] && ok "The audit was made with @$PR_AUTHOR's SSH key" \
  || bad "The audit says it was run by @$(field github_user), but this pull request is from @$PR_AUTHOR."

if [ ! -f "$WF" ]; then
  bad "$WF is missing from the pull request."
  exit 1
fi
[ "$(sha256sum "$WF" | cut -d' ' -f1)" = "$(field ci_yml_sha256)" ] && ok "$WF is the version that was audited" \
  || bad "$WF changed after the audit. Push it, wait for a green run, run the verify script again and commit the new audit."

echo
echo "Checking the workflow:"
python3 -c 'import yaml' 2>/dev/null || python3 -m pip install -q --user pyyaml >/dev/null 2>&1 \
  || python3 -m pip install -q --user --break-system-packages pyyaml >/dev/null 2>&1
if python3 "$CHECK" static "$WF" | sed 's/^/  /'; then ok "The workflow has everything the ticket asks for"; else
  bad "The workflow is missing something (see FAIL above)."; fi
if LINT=$(docker run --rm -v "$PWD:/repo" --workdir /repo rhysd/actionlint:1.7.7 "$WF" 2>&1); then
  ok "actionlint finds no problems"
else
  bad "actionlint found problems:"; printf '%s\n' "$LINT" | head -n 30 | sed 's/^/    /'
fi

echo
REPO=$(field repo)
if [ "$(lc "${REPO%%/*}")" != "$(lc "$PR_AUTHOR")" ]; then
  bad "The audit's runs are on $REPO, not on your fork ($PR_AUTHOR/...)."
else
  echo "Looking up your runs and images on GitHub:"
  if python3 "$CHECK" remote --repo "$REPO" --green "$(field green_run_id)" --red "$(field red_run_id)" \
       --workflow-sha256 "$(sha256sum "$WF" | cut -d' ' -f1)" | grep -v '^INFO' | sed 's/^/  /'; then
    ok "The green run, the red run and the published images check out"
  else
    bad "The runs or images in your audit don't check out (see FAIL above)."
  fi
fi

[ "$FAILS" -eq 0 ]
