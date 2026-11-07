#!/usr/bin/env bash
# BUK-77 checks on the pull request: the audit, then the readiness review,
# runbook, CI job and evidence files are checked again here, and k8s/ is
# validated with kubeconform. (Your cluster was re-deployed from scratch in
# the BUK-70 check.)
# Env: PR_AUTHOR.

set -uo pipefail

F="artifacts/buk-77-launch.txt"
MIN_PASSES=70
KUBECONFORM_VERSION="v0.6.7"
FAILS=0
OUT=""
ok()  { echo "✓ $1"; }
bad() { echo "::error::$1"; echo "✗ $1"; FAILS=$((FAILS + 1)); }
lc()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
manifest_files() { find k8s -type f 2>/dev/null | LC_ALL=C sort; }
manifests_sha() { manifest_files | while IFS= read -r f; do sha256sum "$f"; done | sha256sum | cut -d' ' -f1; }

if [ ! -f "$F" ]; then
  bad "$F is missing. Run 'bash scripts/verify/buk-77.sh' with your cluster up and commit what it writes."
  exit 1
fi
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
[ "$(manifests_sha)" = "$(sed -n 's/^manifests_sha256: //p' "$F")" ] && ok "Your k8s/ manifests are the versions that were audited" \
  || bad "Your k8s/ manifests changed after the audit. Apply them, run the verify script again and commit the new audit."

echo
echo "Checking your files again:"
python3 -c 'import yaml' 2>/dev/null || python3 -m pip install -q --user pyyaml >/dev/null 2>&1 \
  || python3 -m pip install -q --user --break-system-packages pyyaml >/dev/null 2>&1
if python3 scripts/verify/buk77_check.py --files --owner "$PR_AUTHOR" > /tmp/buk77-files.txt 2>&1; then
  ok "The readiness review, runbook, CI job and evidence all check out"
else
  bad "Some of your files don't check out:"
  grep '^FAIL' /tmp/buk77-files.txt | sed 's/^/    /' || tail -n 20 /tmp/buk77-files.txt | sed 's/^/    /'
fi

echo
echo "Validating k8s/ with kubeconform $KUBECONFORM_VERSION:"
if curl -fsSL "https://github.com/yannh/kubeconform/releases/download/$KUBECONFORM_VERSION/kubeconform-linux-amd64.tar.gz" \
     | tar -xz -C /tmp kubeconform; then
  mapfile -t files < <(find k8s -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) ! -name 'kustomization.y*ml' | LC_ALL=C sort)
  if [ "${#files[@]}" -gt 0 ] && OUT=$(/tmp/kubeconform -strict -ignore-missing-schemas -summary "${files[@]}" 2>&1); then
    ok "kubeconform finds no problems in k8s/ ($(tail -n 1 <<< "$OUT"))"
  else
    bad "kubeconform found problems in k8s/:"; printf '%s\n' "$OUT" | head -n 30 | sed 's/^/    /'
  fi
else
  bad "Couldn't download kubeconform (a problem on our side: re-run the check)."
fi

[ "$FAILS" -eq 0 ]
