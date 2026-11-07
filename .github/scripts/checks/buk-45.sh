#!/usr/bin/env bash
# BUK-45 checks on the pull request: the audit, and that the committed
# database script is the one that was audited and has no secrets in it.

set -uo pipefail

F="artifacts/buk-45-data-audit.txt"
S="infra/db/orders-db.sh"
EXPECTED_PASSES=30
FAILS=0
ok()  { echo "✓ $1"; }
bad() { echo "::error::$1"; echo "✗ $1"; FAILS=$((FAILS + 1)); }
lc()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

[ -f "$F" ] || { bad "$F is missing. Run 'bash scripts/verify/buk-45.sh' with everything running and commit what it writes."; exit 1; }
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

if [ ! -f "$S" ]; then
  bad "$S is missing from the pull request."
else
  [ "$(sha256sum "$S" | cut -d' ' -f1)" = "$(sed -n 's/^orders_db_sha256: //p' "$F")" ] \
    && ok "$S is the version that was audited" \
    || bad "$S changed after the audit. Rebuild the database with it, run the verify script again and commit the new audit."
  grep -q -- '--internal' "$S" && ok "$S creates an internal network" || bad "$S should create bukka-db-net with --internal."
  if grep -vE 'pg_isready|psql' "$S" | grep -nE '(^|[[:space:]])(-p|--publish)([[:space:]=]|$)|(^|[[:space:]])-P([[:space:]]|$)'; then
    bad "$S publishes a port. The database must not be reachable from outside bukka-db-net."
  else
    ok "$S publishes no ports"
  fi
fi

# A password written into a file, rather than read from the environment.
LEAKS=$(grep -rnE 'POSTGRES_PASSWORD=[^$"[:space:]]|POSTGRES_PASSWORD="[^$"]|postgresql(\+psycopg)?://[^:/@]+:[^@<$]{6,}@' infra/ 2>/dev/null || true)
if [ -n "$LEAKS" ]; then
  bad "There's a password written into infra/. Read it from BUKKA_DB_PASSWORD instead, and change it: it's leaked."
  echo "$LEAKS" | sed -E 's/(PASSWORD=|:\/\/[^:]+:)[^@[:space:]]+/\1********/' | sed 's/^/    /'
else
  ok "No passwords written into infra/"
fi

[ "$FAILS" -eq 0 ]
