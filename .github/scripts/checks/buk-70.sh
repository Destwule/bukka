#!/usr/bin/env bash
# BUK-70 checks on the pull request. Doesn't just trust the audit: builds
# your images with your Dockerfiles, deploys your k8s/ manifests to a fresh
# kind cluster here on the runner (with the Secret from
# k8s/examples/secret.example.yaml) and runs the same checks, including the
# zero-downtime rollout test.
# Env: PR_AUTHOR.

set -uo pipefail

F="artifacts/buk-70-kubernetes.txt"
MIN_PASSES=80
FAILS=0
HERE="$(cd "$(dirname "$0")" && pwd)"
ok()  { echo "✓ $1"; }
bad() { echo "::error::$1"; echo "✗ $1"; FAILS=$((FAILS + 1)); }
lc()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Same list and hash as scripts/verify/buk-70.sh.
manifest_files() { find k8s -type f 2>/dev/null | LC_ALL=C sort; }
manifests_sha() { manifest_files | while IFS= read -r f; do sha256sum "$f"; done | sha256sum | cut -d' ' -f1; }

# --- The audit you committed ----------------------------------------------------
if [ ! -f "$F" ]; then
  bad "$F is missing. Run 'bash scripts/verify/buk-70.sh' with your cluster running and commit what it writes."
else
  ok "$F is present"
  if grep -q '^FAIL' "$F"; then
    bad "The audit has failed checks:"; grep '^FAIL' "$F" | sed 's/^/    /'
  fi
  PASSES=$(grep -c '^PASS' "$F" || true)
  [ "$PASSES" -ge "$MIN_PASSES" ] && ok "The audit has $PASSES passed checks" \
    || bad "Expected at least $MIN_PASSES passed checks in the audit, found $PASSES. Run the full verify script."
  GH_USER=$(sed -n 's/^github_user: //p' "$F")
  [ "$(lc "$GH_USER")" = "$(lc "$PR_AUTHOR")" ] && ok "The audit was made with @$PR_AUTHOR's SSH key" \
    || bad "The audit says it was run by @$GH_USER, but this pull request is from @$PR_AUTHOR."
  if [ "$(manifests_sha)" = "$(sed -n 's/^manifests_sha256: //p' "$F")" ]; then
    ok "Your k8s/ manifests are the versions that were audited"
  else
    bad "Your k8s/ manifests changed after the audit. Apply them, run the verify script again and commit the new audit."
    echo "    audited: $(sed -n 's/^manifests: //p' "$F")"
    echo "    now:     $(manifest_files | tr '\n' ' ')"
  fi
fi

if [ ! -d k8s ]; then
  bad "k8s/ is missing from the pull request."
  exit 1
fi
if [ "$FAILS" -gt 0 ]; then
  echo
  echo "Fix the audit first: the fresh-cluster re-run only starts once the checks above pass."
  exit 1
fi

# --- Build, deploy and check it here ---------------------------------------------
echo
echo "Building your images and deploying k8s/ to a fresh kind cluster:"
export BUK70_LOG=/tmp/buk70-cluster.log
: > "$BUK70_LOG"
if bash "$HERE/buk70_cluster.sh" up && bash "$HERE/buk70_cluster.sh" deploy; then
  ok "Your manifests deploy to a fresh cluster"
else
  bad "Deploying to a fresh cluster failed:"
  tail -n 30 "$BUK70_LOG" | sed 's/^/    /'
fi

echo
echo "Running the BUK-70 checks against it (including a rollout under load):"
mkdir -p /tmp/buk70
if BUK70_CI=1 BUK70_OWNER="$PR_AUTHOR" BUK70_OUT=/tmp/buk70/audit.txt bash scripts/verify/buk-70.sh > /tmp/buk70/verify.log 2>&1; then
  ok "Every BUK-70 check passes on a fresh cluster built from your pull request"
  grep '^rollout_test:' /tmp/buk70/audit.txt | sed 's/^/    /'
else
  bad "Some BUK-70 checks fail on a fresh cluster built from your pull request:"
  grep '^FAIL' /tmp/buk70/audit.txt 2>/dev/null | sed 's/^/    /' || tail -n 30 /tmp/buk70/verify.log | sed 's/^/    /'
  echo "    Pods:"
  kubectl -n "${BUK70_NAMESPACE:-bukka}" get pods -o wide 2>&1 | sed 's/^/      /'
  echo "    Recent events:"
  kubectl -n "${BUK70_NAMESPACE:-bukka}" get events --sort-by=.lastTimestamp 2>&1 | tail -n 15 | sed 's/^/      /'
fi
bash "$HERE/buk70_cluster.sh" down

[ "$FAILS" -eq 0 ]
