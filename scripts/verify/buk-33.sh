#!/usr/bin/env bash
# BUK-33 verify: runs your health check and traffic report against generated
# logs and fake servers, and compares the results.
#   bash scripts/verify/buk-33.sh
# Writes artifacts/buk-33-audit.txt. The same tests run again on your PR.
set -uo pipefail
OUT="artifacts/buk-33-audit.txt"
if [ ! -d .git ] || [ ! -f tickets/BUK-33.md ]; then
  echo "Run this from the root of your bukka clone (the folder with tickets/ in it)."; exit 2
fi
echo "== BUK-33 verify =="; echo
command -v shellcheck >/dev/null || echo "  (shellcheck isn't installed, so that test runs only on your PR. Install it to check locally.)"
RESULTS=$(python3 .github/scripts/checks/buk33_check.py); STATUS=$?

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ "$BRANCH" == buk-33-* ]]; then RESULTS+=$'\n'"PASS  On a BUK-33 branch ($BRANCH)"; else
  RESULTS+=$'\n'"FAIL  On a BUK-33 branch (you're on '$BRANCH')"; STATUS=1; fi
GH_USER=""
GH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
if [[ "$GH_OUT" =~ Hi\ ([A-Za-z0-9-]+)! ]]; then GH_USER="${BASH_REMATCH[1]}"
  RESULTS+=$'\n'"PASS  GitHub recognises your SSH key as @$GH_USER"; else
  RESULTS+=$'\n'"FAIL  GitHub recognises your SSH key (run ssh-add, see BUK-14)"; STATUS=1; fi

while IFS= read -r l; do
  case "$l" in PASS*) printf '  \033[32m✓\033[0m %s\n' "${l#PASS  }";; FAIL*) printf '  \033[31m✗\033[0m %s\n' "${l#FAIL  }";; esac
done <<< "$RESULTS"

mkdir -p artifacts
{ echo "# BUK-33 audit"; echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "github_user: ${GH_USER:-unknown}"
  echo "branch: $BRANCH"; echo; echo "$RESULTS"; } > "$OUT"
echo
if [ "$STATUS" -eq 0 ]; then
  echo "All checks passed. Wrote $OUT."
  echo "Next: git add scripts/ops deploy/cron $OUT && git commit -m \"feat: add health check and daily traffic report (BUK-33)\""
else
  echo "Some checks failed. Fix the items marked ✗ and run this again."; exit 1
fi
