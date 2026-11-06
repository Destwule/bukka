#!/usr/bin/env bash
# BUK-27 checks on the pull request: audit, and that the committed config is
# the config that was audited.

set -uo pipefail

F="artifacts/buk-27-audit.txt"
UNIT="deploy/systemd/bukka-api.service"
NGINX="deploy/nginx/bukka.conf"
EXPECTED_PASSES=14
FAILS=0
ok()  { echo "✓ $1"; }
bad() { echo "::error::$1"; echo "✗ $1"; FAILS=$((FAILS + 1)); }
lc()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

[ -f "$F" ] || { bad "$F is missing. Run 'bash scripts/verify/buk-27.sh' with the server running and commit what it writes."; exit 1; }
ok "$F is present"

if grep -q '^FAIL' "$F"; then
  bad "The audit has failed checks:"; grep '^FAIL' "$F" | sed 's/^/    /'
fi
PASSES=$(grep -c '^PASS' "$F" || true)
[ "$PASSES" -ge "$EXPECTED_PASSES" ] && ok "All $EXPECTED_PASSES server checks passed" \
  || bad "Expected $EXPECTED_PASSES passed checks in the audit, found $PASSES."

GH_USER=$(sed -n 's/^github_user: //p' "$F")
[ "$(lc "$GH_USER")" = "$(lc "$PR_AUTHOR")" ] && ok "The audit was made with @$PR_AUTHOR's SSH key" \
  || bad "The audit says it was run by @$GH_USER, but this pull request is from @$PR_AUTHOR."

for pair in "$UNIT:unit_sha256" "$NGINX:nginx_sha256"; do
  file="${pair%%:*}"; key="${pair##*:}"
  if [ ! -f "$file" ]; then bad "$file is missing from the pull request."; continue; fi
  if [ "$(sha256sum "$file" | cut -d' ' -f1)" = "$(sed -n "s/^$key: //p" "$F")" ]; then
    ok "$file is the version that was audited"
  else
    bad "$file changed after the audit. Reinstall it on the server, run the verify script again and commit the new audit."
  fi
done

if [ -f "$UNIT" ]; then
  grep -q '^User=bukka' "$UNIT" || bad "$UNIT should run as User=bukka."
  grep -qE '^Restart=(always|on-failure)' "$UNIT" || bad "$UNIT needs Restart=always or Restart=on-failure."
  grep -q '^EnvironmentFile=/etc/bukka/api.env' "$UNIT" || bad "$UNIT should load EnvironmentFile=/etc/bukka/api.env."
  grep -q '^WantedBy=multi-user.target' "$UNIT" || bad "$UNIT should be WantedBy=multi-user.target so it starts on boot."
fi

[ "$FAILS" -eq 0 ]
