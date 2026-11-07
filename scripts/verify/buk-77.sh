#!/usr/bin/env bash
# BUK-77 verify: the launch readiness review.
# Run from the root of your bukka clone, with your cluster up and Bukka
# deployed from k8s/, after your Lunch Rush and rollback rehearsal:
#   bash scripts/verify/buk-77.sh
# It checks your readiness review, runbook and evidence files, re-runs the
# BUK-70 cluster checks (without the rollout: the Lunch Rush did that) and
# that the running images were built from your branch.
# Writes artifacts/buk-77-launch.txt.

set -uo pipefail

TICKET="BUK-77"
OUT="artifacts/buk-77-launch.txt"

if [ ! -d .git ] || [ ! -f tickets/BUK-77.md ]; then
  echo "Run this from the root of your bukka clone (the folder with tickets/ in it)."
  exit 2
fi
if ! command -v kubectl >/dev/null 2>&1 || ! kubectl get nodes >/dev/null 2>&1; then
  echo "kubectl can't reach a cluster. Start your kind or k3d cluster (kubectl get nodes) and try again."
  exit 2
fi

manifest_files() { find k8s -type f 2>/dev/null | LC_ALL=C sort; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
manifests_sha() { manifest_files | while IFS= read -r f; do sha "$f"; done | sha | cut -d' ' -f1; }

echo "== $TICKET verify =="
echo

show() {
  while IFS= read -r l; do
    case "$l" in
      PASS*) printf '  \033[32m✓\033[0m %s\n' "${l#PASS  }";;
      FAIL*) printf '  \033[31m✗\033[0m %s\n' "${l#FAIL  }";;
      INFO*) ;;
      *) printf '%s\n' "$l";;
    esac
  done
}

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
EXTRA=""
if [[ "$BRANCH" == buk-77-* ]]; then EXTRA+="PASS  On a BUK-77 branch ($BRANCH)"$'\n'; else
  EXTRA+="FAIL  On a BUK-77 branch → you're on '$BRANCH'"$'\n'; fi
GH_USER=""
GH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
if [[ "$GH_OUT" =~ Hi\ ([A-Za-z0-9-]+)! ]]; then
  GH_USER="${BASH_REMATCH[1]}"; EXTRA+="PASS  GitHub recognises your SSH key as @$GH_USER"$'\n'
else
  EXTRA+="FAIL  GitHub recognises your SSH key → run ssh-add, then try again (see BUK-14)"$'\n'
fi

TMP=$(mktemp)
python3 scripts/verify/buk77_check.py ${GH_USER:+--owner "$GH_USER"} | tee "$TMP" | show
RESULTS=$(cat "$TMP"); rm -f "$TMP"
echo; printf '%s' "$EXTRA" | show
RESULTS+=$'\n'"$EXTRA"
FAILS=$(grep -c '^FAIL' <<< "$RESULTS" || true)

mkdir -p artifacts
{
  echo "# $TICKET audit"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "github_user: ${GH_USER:-unknown}"
  echo "branch: $BRANCH"
  echo "manifests_sha256: $(manifests_sha)"
  grep -E '^INFO  (image|context): ' <<< "$RESULTS" | sed 's/^INFO  //'
  echo "fails: $FAILS"
  echo
  grep -E '^(PASS|FAIL)' <<< "$RESULTS"
} > "$OUT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All checks passed. Wrote $OUT."
  echo "Next: git add docs runbooks .github/workflows/ci.yml artifacts && git commit -m \"feat: launch readiness review and Lunch Rush test (BUK-77)\""
  exit 0
else
  echo "$FAILS check(s) failed. Fix the items marked ✗ and run this again."
  exit 1
fi
