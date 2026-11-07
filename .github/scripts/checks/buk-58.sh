#!/usr/bin/env bash
# BUK-58 checks on the pull request. Doesn't just trust the audit: builds
# your images from scratch and runs the same checks against a fresh
# `docker compose up` here on the runner (with .env copied from .env.example).

set -uo pipefail

F="artifacts/buk-58-containers.txt"
MIN_PASSES=40
FAILS=0
ok()  { echo "✓ $1"; }
bad() { echo "::error::$1"; echo "✗ $1"; FAILS=$((FAILS + 1)); }
lc()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Same list and hash as scripts/verify/buk-58.sh.
build_files() {
  find . \( -path ./.git -o -path ./labs -o -name node_modules -o -name .venv -o -path ./web/dist \) -prune -o -type f \
    \( -name 'Dockerfile*' -o -name '*.Dockerfile' -o -name .dockerignore -o -path ./compose.yaml \
       -o -path ./.env.example -o -path './web/*.conf' \) -print | LC_ALL=C sort
}
build_sha() { build_files | while IFS= read -r f; do sha256sum "$f"; done | sha256sum | cut -d' ' -f1; }

# --- The audit you committed ----------------------------------------------------
if [ ! -f "$F" ]; then
  bad "$F is missing. Run 'bash scripts/verify/buk-58.sh' with the stack running and commit what it writes."
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
  if [ "$(build_sha)" = "$(sed -n 's/^build_files_sha256: //p' "$F")" ]; then
    ok "Your Dockerfiles, compose.yaml and .env.example are the versions that were audited"
  else
    bad "Your Dockerfiles, compose.yaml, .dockerignore, Nginx config or .env.example changed after the audit. Run the verify script again and commit the new audit."
    echo "    audited: $(sed -n 's/^build_files: //p' "$F")"
    echo "    now:     $(build_files | tr '\n' ' ')"
  fi
fi

if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  bad ".env is committed. Remove it (git rm --cached .env), add it to .gitignore, and change the passwords in it."
fi

# --- Build and run it here --------------------------------------------------------
if [ ! -f compose.yaml ] || [ ! -f .env.example ]; then
  bad "compose.yaml and .env.example must both be committed at the repo root."
  exit 1
fi
echo
echo "Building and starting your stack from scratch (cp .env.example .env; docker compose up -d --build):"
[ -f .env ] || cp .env.example .env
if docker compose up -d --build > /tmp/buk58-up.log 2>&1; then
  ok "docker compose up -d --build works on a clean machine"
else
  bad "docker compose up -d --build failed on a clean machine:"
  tail -n 30 /tmp/buk58-up.log | sed 's/^/    /'
  docker compose ps -a 2>&1 | sed 's/^/    /'
fi

echo
echo "Running the BUK-58 checks against it:"
mkdir -p /tmp/buk58
if BUK58_CI=1 BUK58_OUT=/tmp/buk58/audit.txt bash scripts/verify/buk-58.sh > /tmp/buk58/verify.log 2>&1; then
  ok "Every BUK-58 check passes on a fresh build of your stack"
else
  bad "Some BUK-58 checks fail on a fresh build of your stack:"
  grep '^FAIL' /tmp/buk58/audit.txt 2>/dev/null | sed 's/^/    /' || tail -n 30 /tmp/buk58/verify.log | sed 's/^/    /'
  echo "    Last log lines from each service:"
  docker compose logs --tail 15 2>&1 | sed 's/^/      /'
fi
docker compose down -v >/dev/null 2>&1 || true

[ "$FAILS" -eq 0 ]
