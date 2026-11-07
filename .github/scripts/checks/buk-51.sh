#!/usr/bin/env bash
# BUK-51 checks on the pull request: the audit, that the committed Terraform
# is the code that was audited, and the checks that need no LocalStack
# (git hygiene, secrets, terraform fmt and validate).

set -uo pipefail

F="artifacts/buk-51-terraform-audit.txt"
TF="infra/terraform"
MODULES="network compute database storage billing"
TF_VERSION="${TF_VERSION:-1.16.7}"
EXPECTED_PASSES=49
FAILS=0
ok()  { echo "✓ $1"; }
bad() { echo "::error::$1"; echo "✗ $1"; FAILS=$((FAILS + 1)); }
lc()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi | cut -d' ' -f1; }
# Must match tf_sha in scripts/verify/buk-51.sh.
tf_sha() {
  find "$TF" -type f -name '*.tf' -not -path '*/.terraform/*' 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sha256 "$f")" "$f"
  done | sha256
}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- The audit ------------------------------------------------------------------
[ -f "$F" ] || { bad "$F is missing. Run 'bash scripts/verify/buk-51.sh' with the stack applied and commit what it writes."; exit 1; }
ok "$F is present"

if grep -q '^FAIL' "$F"; then
  bad "The audit has failed checks:"; grep '^FAIL' "$F" | sed 's/^/    /'
fi
PASSES=$(grep -c '^PASS' "$F" || true)
[ "$PASSES" -ge "$EXPECTED_PASSES" ] && ok "All $EXPECTED_PASSES checks passed" \
  || bad "Expected $EXPECTED_PASSES passed checks in the audit, found $PASSES."

GH_USER=$(sed -n 's/^github_user: //p' "$F")
[ "$(lc "$GH_USER")" = "$(lc "$PR_AUTHOR")" ] && ok "The audit was made with @$PR_AUTHOR's SSH key" \
  || bad "The audit says it was run by @$GH_USER, but this pull request is from @$PR_AUTHOR."

if [ ! -d "$TF" ]; then
  bad "$TF is missing from the pull request."
  exit 1
fi
[ "$(tf_sha)" = "$(sed -n 's/^terraform_sha256: //p' "$F")" ] \
  && ok "The Terraform code is the version that was audited" \
  || bad "The .tf files changed after the audit. Apply them, run the verify script again and commit the new audit."

# --- Layout and git hygiene ---------------------------------------------------------
MISSING=""
for f in versions.tf backend.tf main.tf variables.tf outputs.tf .terraform.lock.hcl; do [ -f "$TF/$f" ] || MISSING="$MISSING $f"; done
for m in $MODULES; do for f in main.tf variables.tf outputs.tf; do
  [ -f "$TF/modules/$m/$f" ] || MISSING="$MISSING modules/$m/$f"
done; done
[ -z "$MISSING" ] && ok "All the Terraform files are committed, with .terraform.lock.hcl" || bad "Missing from $TF:$MISSING"

TRACKED=$(git ls-files)
STATE_FILES=$(echo "$TRACKED" | grep -E '\.tfstate(\.|$)|(^|/)\.terraform/' || true)
if [ -n "$STATE_FILES" ]; then
  bad "State files or .terraform/ are committed. State can hold secrets: git rm --cached them and add them to .gitignore."
  echo "$STATE_FILES" | head -5 | sed 's/^/    /'
else
  ok "No state files or .terraform/ committed"
fi

for s in buk-38 buk-42 buk-45; do
  [ -e "infra/cli/$s.sh" ] && bad "infra/cli/$s.sh should be removed: Terraform is now the only way the AWS side is built."
done
[ -f infra/db/orders-db.sh ] && ok "infra/db/orders-db.sh is kept" || bad "Keep infra/db/orders-db.sh from BUK-45."

grep -qE 'use_lockfile[[:space:]]*=[[:space:]]*true' "$TF/backend.tf" 2>/dev/null \
  && ok "The backend locks state (use_lockfile = true)" || bad "backend.tf should set use_lockfile = true."

# --- Secrets ----------------------------------------------------------------------------
SCAN_FILES=$( { find infra -type f \( -name '*.tf' -o -name '*.hcl' -o -name '*.tfvars' -o -name '*.tfvars.json' -o -name '*.sh' \) -not -path '*/.terraform/*' 2>/dev/null; echo "$TRACKED" | grep -E '\.tfvars(\.json)?$'; } | sort -u)
# shellcheck disable=SC2086
LEAKS=$(python3 - $SCAN_FILES <<'PY'
import re, sys
bad = []
assign = re.compile(r'^\s*"?([A-Za-z0-9_]*(password|passwd|secret|token|access_key|private_key)[A-Za-z0-9_]*)"?\s*=\s*"([^"$]+)"', re.I)
var = re.compile(r'variable\s+"([^"]+)"\s*\{', re.I)
for path in sys.argv[1:]:
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    for n, line in enumerate(text.splitlines(), 1):
        if re.search(r'AKIA[0-9A-Z]{16}', line):
            bad.append(f"{path}:{n}: an AWS access key")
        m = assign.match(line)
        if m and not path.endswith(".sh") and not m.group(1).lower().startswith("skip_"):
            bad.append(f"{path}:{n}: {m.group(1)} is written in")
    if path.endswith(".sh"):
        continue
    for m in var.finditer(text):
        if not re.search(r'password|passwd|secret|token|key', m.group(1), re.I):
            continue
        depth, i = 1, m.end()
        while i < len(text) and depth:
            depth += {"{": 1, "}": -1}.get(text[i], 0); i += 1
        if re.search(r'^\s*default\s*=', text[m.end():i], re.M):
            bad.append(f"{path}: variable \"{m.group(1)}\" has a default value")
print("\n".join(bad))
PY
)
if [ -n "$LEAKS" ]; then
  bad "Secrets in infra/: no passwords, secret defaults or access keys in code. Pass secrets in at run time, and change any that were committed."
  echo "$LEAKS" | head -5 | sed 's/^/    /'
else
  ok "No passwords, secret defaults or access keys in infra/"
fi

# --- terraform fmt and validate (no LocalStack, no backend) -----------------------------
if ! command -v terraform >/dev/null 2>&1; then
  case "$(uname -m)" in x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) ARCH=amd64;; esac
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  BASE="https://releases.hashicorp.com/terraform/$TF_VERSION"
  ZIP="terraform_${TF_VERSION}_${OS}_${ARCH}.zip"
  if curl -sfL -o "$WORK/$ZIP" "$BASE/$ZIP" && curl -sfL -o "$WORK/SUMS" "$BASE/terraform_${TF_VERSION}_SHA256SUMS" \
     && [ "$(grep " $ZIP\$" "$WORK/SUMS" | cut -d' ' -f1)" = "$(sha256 "$WORK/$ZIP")" ]; then
    mkdir -p "$WORK/bin" && unzip -qo "$WORK/$ZIP" -d "$WORK/bin" && PATH="$WORK/bin:$PATH"
  fi
fi
if ! command -v terraform >/dev/null 2>&1; then
  bad "Couldn't install Terraform $TF_VERSION to run fmt and validate. Re-run the check."
else
  echo "Using $(terraform version | head -1)"
  terraform -chdir="$TF" fmt -check -recursive >/dev/null 2>&1 \
    && ok "terraform fmt -check -recursive" || bad "terraform fmt -check -recursive fails. Run terraform fmt -recursive in $TF and commit."
  cp -R "$TF" "$WORK/tf" && rm -rf "$WORK/tf/.terraform"
  if ! INIT=$(terraform -chdir="$WORK/tf" init -backend=false -input=false -no-color 2>&1); then
    bad "terraform init -backend=false fails:"; echo "$INIT" | grep -iE -m3 'error' | sed 's/^/    /'
  elif ! VAL=$(terraform -chdir="$WORK/tf" validate -no-color 2>&1); then
    bad "terraform validate fails:"; echo "$VAL" | grep -iE -A2 -m3 'error' | sed 's/^/    /'
  else
    ok "terraform validate"
  fi
fi

[ "$FAILS" -eq 0 ]
