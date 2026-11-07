#!/usr/bin/env bash
# BUK-70 verify: Bukka on Kubernetes, with rollouts customers don't notice.
# Run from the root of your bukka clone, with kubectl pointing at your kind
# or k3d cluster and the app deployed from k8s/:
#   bash scripts/verify/buk-70.sh
# It checks your manifests and what's running, places an order through
# http://bukka.localhost, then keeps customers ordering while it rolls out
# web, menu-service and order-service (kubectl rollout restart). Not a single
# request may fail. Writes artifacts/buk-70-kubernetes.txt.
# The same checks run again on your PR, on a fresh kind cluster built from
# your Dockerfiles and your manifests.

set -uo pipefail

TICKET="BUK-70"
OUT="${BUK70_OUT:-artifacts/buk-70-kubernetes.txt}"

if [ ! -d .git ] || [ ! -f tickets/BUK-70.md ]; then
  echo "Run this from the root of your bukka clone (the folder with tickets/ in it)."
  exit 2
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl isn't installed. See the Notes in tickets/BUK-70.md."
  exit 2
fi
if ! kubectl get nodes >/dev/null 2>&1; then
  echo "kubectl can't reach a cluster. Start your kind or k3d cluster (kubectl get nodes) and try again."
  exit 2
fi

# Your manifests. The PR check recomputes this hash to make sure what you
# committed is what was verified.
manifest_files() { find k8s -type f 2>/dev/null | LC_ALL=C sort; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
manifests_sha() { manifest_files | while IFS= read -r f; do sha "$f"; done | sha | cut -d' ' -f1; }

echo "== $TICKET verify =="
echo "This takes a few minutes (it waits for an order to be delivered, then rolls out three Deployments)."
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
GH_USER=""
EXTRA=""
if [ -z "${BUK70_CI:-}" ]; then
  if [[ "$BRANCH" == buk-70-* ]]; then EXTRA+="PASS  On a BUK-70 branch ($BRANCH)"$'\n'; else
    EXTRA+="FAIL  On a BUK-70 branch → you're on '$BRANCH'"$'\n'; fi
  GH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
  if [[ "$GH_OUT" =~ Hi\ ([A-Za-z0-9-]+)! ]]; then
    GH_USER="${BASH_REMATCH[1]}"; EXTRA+="PASS  GitHub recognises your SSH key as @$GH_USER"$'\n'
  else
    EXTRA+="FAIL  GitHub recognises your SSH key → run ssh-add, then try again (see BUK-14)"$'\n'
  fi
  CHECK_ARGS=(--rollout ${GH_USER:+--owner "$GH_USER"})
else
  CHECK_ARGS=(--rollout --ci ${BUK70_OWNER:+--owner "$BUK70_OWNER"})
fi

TMP=$(mktemp)
python3 scripts/verify/buk70_check.py "${CHECK_ARGS[@]}" | tee "$TMP" | show
RESULTS=$(cat "$TMP"); rm -f "$TMP"
if [ -n "$EXTRA" ]; then
  echo; printf '%s' "$EXTRA" | show
  RESULTS+=$'\n'"$EXTRA"
fi
FAILS=$(grep -c '^FAIL' <<< "$RESULTS" || true)

mkdir -p "$(dirname "$OUT")"
{
  echo "# $TICKET audit"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "github_user: ${GH_USER:-unknown}"
  echo "branch: $BRANCH"
  echo "manifests_sha256: $(manifests_sha)"
  echo "manifests: $(manifest_files | tr '\n' ' ')"
  grep -E '^INFO  (image|rollout_test|context): ' <<< "$RESULTS" | sed 's/^INFO  //'
  echo "fails: $FAILS"
  echo
  grep -E '^(PASS|FAIL)' <<< "$RESULTS"
} > "$OUT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All checks passed. Wrote $OUT."
  echo "Next: git add k8s artifacts/buk-70-rollout.txt $OUT (and your menu change and loop script), then commit."
  exit 0
else
  echo "$FAILS check(s) failed. Fix the items marked ✗ and run this again."
  exit 1
fi
