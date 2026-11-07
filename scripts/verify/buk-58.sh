#!/usr/bin/env bash
# BUK-58 verify: your images and the whole stack running under Docker Compose.
# Run from the root of your bukka clone, with the stack up:
#   cp .env.example .env        # first time only, then change the password
#   docker compose up -d --build
#   bash scripts/verify/buk-58.sh
# It places a test order, then runs `docker compose down` and
# `docker compose up -d` to prove the order survives (your data stays: it
# never uses -v). Writes artifacts/buk-58-containers.txt.
# The same checks run again, on a fresh build of your stack, on your PR.

set -uo pipefail

TICKET="BUK-58"
OUT="${BUK58_OUT:-artifacts/buk-58-containers.txt}"

if [ ! -d .git ] || [ ! -f tickets/BUK-58.md ]; then
  echo "Run this from the root of your bukka clone (the folder with tickets/ in it)."
  exit 2
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose isn't available. Start Docker Desktop (or use a Codespace) and try again."
  exit 2
fi

# The files that make up your containers. The PR check recomputes this hash
# to make sure what you committed is what was verified.
build_files() {
  find . \( -path ./.git -o -path ./labs -o -name node_modules -o -name .venv -o -path ./web/dist \) -prune -o -type f \
    \( -name 'Dockerfile*' -o -name '*.Dockerfile' -o -name .dockerignore -o -path ./compose.yaml \
       -o -path ./.env.example -o -path './web/*.conf' \) -print | LC_ALL=C sort
}
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
build_sha() { build_files | while IFS= read -r f; do sha "$f"; done | sha | cut -d' ' -f1; }

echo "== $TICKET verify =="
echo "This takes a couple of minutes (it waits for the worker, and restarts the stack once)."
echo

show() {
  while IFS= read -r l; do
    case "$l" in
      PASS*) printf '  \033[32m✓\033[0m %s\n' "${l#PASS  }";;
      FAIL*) printf '  \033[31m✗\033[0m %s\n' "${l#FAIL  }";;
      *) printf '%s\n' "$l";;
    esac
  done
}
TMP=$(mktemp)
python3 scripts/verify/buk58_check.py --restart | tee "$TMP" | show
RESULTS=$(cat "$TMP"); rm -f "$TMP"

FAILS=$(grep -c '^FAIL' <<< "$RESULTS" || true)

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
GH_USER=""
if [ -z "${BUK58_CI:-}" ]; then
  echo
  if [[ "$BRANCH" == buk-58-* ]]; then RESULTS+=$'\n'"PASS  On a BUK-58 branch ($BRANCH)"; else
    RESULTS+=$'\n'"FAIL  On a BUK-58 branch → you're on '$BRANCH'"; FAILS=$((FAILS + 1)); fi
  GH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
  if [[ "$GH_OUT" =~ Hi\ ([A-Za-z0-9-]+)! ]]; then
    GH_USER="${BASH_REMATCH[1]}"; RESULTS+=$'\n'"PASS  GitHub recognises your SSH key as @$GH_USER"
  else
    RESULTS+=$'\n'"FAIL  GitHub recognises your SSH key → run ssh-add, then try again (see BUK-14)"; FAILS=$((FAILS + 1))
  fi
  tail -n 2 <<< "$RESULTS" | show
fi

mkdir -p "$(dirname "$OUT")"
{
  echo "# $TICKET audit"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "github_user: ${GH_USER:-unknown}"
  echo "branch: $BRANCH"
  echo "build_files_sha256: $(build_sha)"
  echo "build_files: $(build_files | tr '\n' ' ')"
  echo "fails: $FAILS"
  echo
  grep -E '^(PASS|FAIL)' <<< "$RESULTS"
} > "$OUT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All checks passed. Wrote $OUT."
  echo "Next: git add compose.yaml .env.example web api .gitignore $OUT && git commit -m \"feat: containerise the web app, API and worker (BUK-58)\""
  exit 0
else
  echo "$FAILS check(s) failed. Fix the items marked FAIL and run this again."
  exit 1
fi
