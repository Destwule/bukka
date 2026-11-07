#!/usr/bin/env bash
# BUK-63 verify: your pipeline in .github/workflows/ci.yml, and proof from
# GitHub that it ran on your fork (a green run, a red run, and public images
# tagged with the green run's commit SHA on GHCR).
# Needs: the GitHub CLI, logged in (gh auth login), and Docker (for actionlint).
# Run from the root of your bukka clone, on your buk-63 branch, after the
# pipeline has gone green on your fork:
#   bash scripts/verify/buk-63.sh
# Writes artifacts/buk-63-ci.txt.

set -uo pipefail

TICKET="BUK-63"
OUT="artifacts/buk-63-ci.txt"
WF=".github/workflows/ci.yml"
CHECK=".github/scripts/checks/buk63_check.py"
ACTIONLINT_IMAGE="rhysd/actionlint:1.7.7"

if [ ! -d .git ] || [ ! -f tickets/BUK-63.md ]; then
  echo "Run this from the root of your bukka clone (the folder with tickets/ in it)."
  exit 2
fi

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
RESULTS=""
add() { RESULTS+="$1"$'\n'; printf '%s\n' "$1" | show; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

echo "== $TICKET verify =="
echo

# PyYAML: from python3, or from the API's virtualenv (make api-install).
PY=""
for p in python3 api/.venv/bin/python; do
  if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import yaml' 2>/dev/null; then PY="$p"; break; fi
done
OUT_STATIC=$("${PY:-python3}" "$CHECK" static "$WF")
RESULTS+="$OUT_STATIC"$'\n'; printf '%s\n' "$OUT_STATIC" | show

echo
if command -v actionlint >/dev/null 2>&1; then
  LINT=$(actionlint "$WF" 2>&1); LINT_RC=$?
elif docker info >/dev/null 2>&1; then
  LINT=$(docker run --rm -v "$PWD:/repo" --workdir /repo "$ACTIONLINT_IMAGE" "$WF" 2>&1); LINT_RC=$?
else
  LINT="neither actionlint nor Docker is available"; LINT_RC=2
fi
if [ "$LINT_RC" -eq 0 ]; then add "PASS  actionlint finds no problems in $WF"; else
  add "FAIL  actionlint finds no problems in $WF → see below"; printf '%s\n' "$LINT" | head -n 30 | sed 's/^/      /'; fi

# --- Identity and the fork ----------------------------------------------------
echo
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ "$BRANCH" == buk-63-* ]]; then add "PASS  On a BUK-63 branch ($BRANCH)"; else
  add "FAIL  On a BUK-63 branch → you're on '$BRANCH'"; fi
GH_USER=""
GH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
if [[ "$GH_OUT" =~ Hi\ ([A-Za-z0-9-]+)! ]]; then
  GH_USER="${BASH_REMATCH[1]}"; add "PASS  GitHub recognises your SSH key as @$GH_USER"
else
  add "FAIL  GitHub recognises your SSH key → run ssh-add, then try again (see BUK-14)"
fi

ORIGIN=$(git remote get-url origin 2>/dev/null || true)
REPO="${BUK63_REPO:-$(printf '%s' "$ORIGIN" | sed -E 's#^(git@github\.com:|https://github\.com/|ssh://git@github\.com/)##; s#\.git$##')}"
OWNER="${REPO%%/*}"
if [ -n "$GH_USER" ]; then  # (without your identity there's nothing to compare with)
  if [ "$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$GH_USER" | tr '[:upper:]' '[:lower:]')" ]; then
    add "PASS  origin is your fork ($REPO)"
  else
    add "FAIL  origin is your fork → origin is '${REPO:-not set}'; it should be $GH_USER/bukka"
  fi
fi

if ! command -v gh >/dev/null 2>&1; then
  add "FAIL  The GitHub CLI (gh) is installed → https://cli.github.com, then gh auth login"
else
  OUT_REMOTE=$("${PY:-python3}" "$CHECK" remote --repo "$REPO" --workflow-sha256 "$( [ -f "$WF" ] && sha "$WF" | cut -d' ' -f1)")
  RESULTS+="$OUT_REMOTE"$'\n'; printf '%s\n' "$OUT_REMOTE" | show
fi

info() { grep "^INFO  $1: " <<< "$RESULTS" | head -n 1 | sed "s/^INFO  $1: //"; }
FAILS=$(grep -c '^FAIL' <<< "$RESULTS" || true)
mkdir -p artifacts
{
  echo "# $TICKET audit"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "github_user: ${GH_USER:-unknown}"
  echo "branch: $BRANCH"
  echo "repo: $REPO"
  echo "ci_yml_sha256: $( [ -f "$WF" ] && sha "$WF" | cut -d' ' -f1)"
  echo "green_run: $(info green_run)"
  echo "green_run_id: $(info green_run_id)"
  echo "green_sha: $(info green_sha)"
  echo "red_run: $(info red_run)"
  echo "red_run_id: $(info red_run_id)"
  grep '^INFO  image: ' <<< "$RESULTS" | sed 's/^INFO  image: /image: /'
  echo "fails: $FAILS"
  echo
  grep -E '^(PASS|FAIL)' <<< "$RESULTS"
} > "$OUT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All checks passed. Wrote $OUT."
  echo "Next: git add $WF $OUT && git commit -m \"ci: test, build and publish images on every change (BUK-63)\""
  exit 0
else
  echo "$FAILS check(s) failed. Fix the items marked ✗ and run this again."
  exit 1
fi
