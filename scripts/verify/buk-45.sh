#!/usr/bin/env bash
# BUK-45 verify: a private PostgreSQL server for the API, and the AWS side on
# LocalStack. Run from the root of your bukka clone, with LocalStack,
# bukka-api-1 and bukka-orders-db running:
#   bash scripts/verify/buk-45.sh
# Writes artifacts/buk-45-data-audit.txt.

set -uo pipefail

TICKET="BUK-45"
API="bukka-api-1"
DB="bukka-orders-db"
URL="http://localhost:18082"
OUT="artifacts/buk-45-data-audit.txt"
FAILS=0
RESULTS=()
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

pass() { RESULTS+=("PASS  $1"); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      → %s\n' "$2"; FAILS=$((FAILS + 1)); }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
psql_db() { docker exec "$DB" psql -U bukka -d bukka -Atc "$1" 2>/dev/null; }

if [ ! -d .git ] || [ ! -f tickets/BUK-45.md ]; then
  echo "Run this from the root of your bukka clone (the folder with tickets/ in it)."
  exit 2
fi
echo "== $TICKET verify =="
echo

# --- The database server ------------------------------------------------------
echo "The database server"
if ! running "$DB"; then
  fail "$DB is running" "Start it with: bash infra/db/orders-db.sh"
  DB_UP=""
else
  pass "$DB is running"; DB_UP=1
fi

if [ -n "$DB_UP" ]; then
  IMG=$(docker inspect -f '{{.Config.Image}}' "$DB")
  [[ "$IMG" == postgres:16* ]] && pass "Runs PostgreSQL 16 ($IMG)" || fail "Runs PostgreSQL 16" "The image is '$IMG'."

  # What it asked for (-p / -P), not just what Docker managed to open.
  BINDS=$(docker inspect -f '{{json .HostConfig.PortBindings}}{{.HostConfig.PublishAllPorts}}' "$DB")
  if [ -z "$(docker port "$DB")" ] && { [ "$BINDS" = "{}false" ] || [ "$BINDS" = "nullfalse" ]; }; then
    pass "No published ports"
  else
    fail "No published ports" "Remove -p / -P from the docker run command (found $BINDS)."
  fi

  NETS=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$DB" | xargs)
  if [ "$NETS" = "bukka-db-net" ]; then pass "Only on bukka-db-net"; else
    fail "Only on bukka-db-net" "It's on: ${NETS:-nothing}."; fi

  if [ "$(docker network inspect -f '{{.Internal}}' bukka-db-net 2>/dev/null)" = "true" ]; then
    pass "bukka-db-net is internal (no route to the internet)"
  else
    fail "bukka-db-net is internal (no route to the internet)" "Create it with: docker network create --internal bukka-db-net"
  fi

  VOL=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Type}}:{{.Name}}{{end}}{{end}}' "$DB")
  [ "$VOL" = "volume:bukka-orders-data" ] && pass "Data lives in the bukka-orders-data volume" \
    || fail "Data lives in the bukka-orders-data volume" "Mount it with -v bukka-orders-data:/var/lib/postgresql/data (found '${VOL:-nothing}')."

  POLICY=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$DB")
  [ "$POLICY" = "unless-stopped" ] || [ "$POLICY" = "always" ] && pass "Restarts by itself ($POLICY)" \
    || fail "Restarts by itself" "The restart policy is '${POLICY:-no}'."

  [ "$(psql_db 'SHOW ssl')" = "on" ] && pass "TLS is on" || fail "TLS is on" "See the TLS note in the ticket."

  if docker exec "$DB" bash -c 'timeout 3 bash -c "exec 3<>/dev/tcp/1.1.1.1/53"' >/dev/null 2>&1; then
    fail "The database can't reach the internet" "It connected to 1.1.1.1. Is it on a network without --internal?"
  else
    pass "The database can't reach the internet"
  fi

  PW=$(docker exec "$DB" printenv POSTGRES_PASSWORD 2>/dev/null || true)
  if [ "${#PW}" -ge 16 ]; then pass "The password is at least 16 characters"; else
    fail "The password is at least 16 characters" "It's ${#PW}."; fi
  if [ -n "$PW" ] && { git grep -qF -- "$PW" 2>/dev/null || git log --all -p 2>/dev/null | grep -F -- "$PW" >/dev/null; }; then
    fail "The password isn't in any file or commit" "It's in your repo. Remove it, and change the password: it's leaked."
  else
    pass "The password isn't in any file or commit"
  fi
fi

# --- The API ------------------------------------------------------------------
echo; echo "The API"
if ! running "$API"; then
  fail "$API is running" "Start it with: bash labs/buk-45/start.sh"
else
  pass "$API is running"
  if docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$API" | grep -q 'bukka-db-net'; then
    pass "$API is connected to bukka-db-net"
  else
    fail "$API is connected to bukka-db-net" "docker network connect bukka-db-net $API"
  fi
  URL_IN_ENV=$(docker exec "$API" sh -c "sed -n 's/^DATABASE_URL=//p' /etc/bukka/api.env" 2>/dev/null)
  if [[ "$URL_IN_ENV" == postgresql* ]] && [[ "$URL_IN_ENV" == *"@bukka-orders-db:5432/bukka"* ]] && [[ "$URL_IN_ENV" == *sslmode=require* ]]; then
    pass "DATABASE_URL points at bukka-orders-db with sslmode=require"
  else
    fail "DATABASE_URL points at bukka-orders-db with sslmode=require" "Check /etc/bukka/api.env on $API."
  fi
  if [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$URL/readyz")" = "200" ] && curl -s -m 5 "$URL/api/restaurants" | grep -q '"slug"'; then
    pass "The API is ready and lists restaurants"
  else
    fail "The API is ready and lists restaurants" "curl -i $URL/readyz"
  fi
fi

if [ -n "$DB_UP" ]; then
  N=$(psql_db 'SELECT count(*) FROM restaurants' || true)
  [ "${N:-0}" -gt 0 ] 2>/dev/null && pass "The restaurants are in PostgreSQL ($N)" \
    || fail "The restaurants are in PostgreSQL" "Run bukka-api migrate and bukka-api seed on $API."
  SSL=$(psql_db "SELECT bool_and(s.ssl) FROM pg_stat_ssl s JOIN pg_stat_activity a USING (pid) WHERE a.usename = 'bukka' AND a.client_addr IS NOT NULL")
  [ "$SSL" = "t" ] && pass "The API's database connections are encrypted" \
    || fail "The API's database connections are encrypted" "No encrypted connections from the API (got '${SSL:-none}'). Restart the API after changing DATABASE_URL."

  DB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DB")
  if docker run --rm --network bukka-web-net postgres:16 pg_isready -q -h "$DB_IP" -p 5432 -t 3 >/dev/null 2>&1; then
    fail "Unreachable from bukka-web-net" "A container on bukka-web-net reached $DB_IP:5432."
  else
    pass "Unreachable from bukka-web-net"
  fi
fi

# --- Scripts ------------------------------------------------------------------
echo; echo "Your scripts"
S="infra/db/orders-db.sh"
if [ -f "$S" ] && grep -q 'BUKKA_DB_PASSWORD' "$S"; then pass "$S reads BUKKA_DB_PASSWORD"; else
  fail "$S reads BUKKA_DB_PASSWORD" "Save the database commands there, reading the password from the environment."; fi
# Run the script without the password, with a stand-in 'docker' that only
# records what it was asked to do, so nothing real is touched.
STUB=$(mktemp -d)
printf '#!/bin/sh\necho "$*" >> "%s/calls"\n' "$STUB" > "$STUB/docker"; chmod +x "$STUB/docker"
if [ -f "$S" ] && ! env -u BUKKA_DB_PASSWORD PATH="$STUB:$PATH" bash "$S" >/dev/null 2>&1 </dev/null \
   && ! grep -qE '^(run|create|container run)' "$STUB/calls" 2>/dev/null; then
  pass "$S refuses to run without BUKKA_DB_PASSWORD"
else
  fail "$S refuses to run without BUKKA_DB_PASSWORD" "Near the top: : \"\${BUKKA_DB_PASSWORD:?set it first}\""
fi
rm -rf "$STUB"
[ -f infra/cli/buk-45.sh ] && pass "infra/cli/buk-45.sh exists" || fail "infra/cli/buk-45.sh exists"

# --- The AWS side (LocalStack) --------------------------------------------------
echo; echo "The AWS side (LocalStack at $AWS_ENDPOINT_URL)"
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  fail "LocalStack is answering" "Start LocalStack (see the ticket's Notes)."
else
  pass "LocalStack is answering"
  VPC=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=bukka-prod-vpc --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
  WEB_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=bukka-web-sg Name=vpc-id,Values="$VPC" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
  DBSG_JSON=$(aws ec2 describe-security-groups --filters Name=group-name,Values=bukka-db-sg Name=vpc-id,Values="$VPC" --query 'SecurityGroups[0]' --output json 2>/dev/null)
  if [ -z "$VPC" ] || [ "$VPC" = "None" ] || [ -z "$WEB_SG" ] || [ "$WEB_SG" = "None" ]; then
    fail "bukka-web-sg exists in bukka-prod-vpc" "Rebuild BUK-42, then create bukka-web-sg in that VPC."
  else
    pass "bukka-web-sg exists in bukka-prod-vpc"
  fi
  if [ -z "$DBSG_JSON" ] || [ "$DBSG_JSON" = "null" ]; then
    fail "bukka-db-sg allows 5432 only from bukka-web-sg" "Create bukka-db-sg in bukka-prod-vpc."
  else
    VERDICT=$(WEB_SG="$WEB_SG" python3 -c '
import json, os, sys
perms = json.load(sys.stdin).get("IpPermissions", [])
ok = (len(perms) == 1 and perms[0].get("IpProtocol") == "tcp" and perms[0].get("FromPort") == 5432
      and perms[0].get("ToPort") == 5432 and not perms[0].get("IpRanges") and not perms[0].get("Ipv6Ranges")
      and [g["GroupId"] for g in perms[0].get("UserIdGroupPairs", [])] == [os.environ["WEB_SG"]])
print("ok" if ok else json.dumps(perms)[:200])' <<< "$DBSG_JSON")
    [ "$VERDICT" = "ok" ] && pass "bukka-db-sg allows 5432 only from bukka-web-sg" \
      || fail "bukka-db-sg allows 5432 only from bukka-web-sg" "Its inbound rules: $VERDICT"
  fi

  BUCKET=$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null | tr '\t' '\n' | grep '^bukka-menu-photos-' | head -1)
  if [ -z "$BUCKET" ]; then
    fail "The menu photos bucket exists" "Rebuild BUK-38 with infra/cli/buk-38.sh."
  else
    pass "The menu photos bucket exists ($BUCKET)"
    PAB=$(aws s3api get-public-access-block --bucket "$BUCKET" --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text 2>/dev/null | tr -s '\t ' ' ')
    [ "$PAB" = "True True True True" ] && pass "Block Public Access: all four on" \
      || fail "Block Public Access: all four on" "Got: ${PAB:-not set}."
    ENC=$(aws s3api get-bucket-encryption --bucket "$BUCKET" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text 2>/dev/null)
    [ "$ENC" = "AES256" ] && pass "Default encryption is SSE-S3 (AES256)" || fail "Default encryption is SSE-S3 (AES256)" "Got: ${ENC:-none}."
    PHOTOS=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix dishes/ --query 'length(Contents || `[]`)' --output text 2>/dev/null)
    [ "${PHOTOS:-0}" -ge 3 ] 2>/dev/null && pass "At least three photos under dishes/ ($PHOTOS)" \
      || fail "At least three photos under dishes/" "Found ${PHOTOS:-0}."
  fi
fi

# --- Branch and identity --------------------------------------------------------
echo
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ "$BRANCH" == buk-45-* ]]; then pass "On a BUK-45 branch ($BRANCH)"; else
  fail "On a BUK-45 branch" "You're on '$BRANCH'."; fi
GH_USER=""
GH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
if [[ "$GH_OUT" =~ Hi\ ([A-Za-z0-9-]+)! ]]; then
  GH_USER="${BASH_REMATCH[1]}"; pass "GitHub recognises your SSH key as @$GH_USER"
else
  fail "GitHub recognises your SSH key" "Run: ssh-add, then try again (see BUK-14)."
fi
if [ -n "$GH_USER" ] && [ -n "${BUCKET:-}" ] && [ "$BUCKET" != "bukka-menu-photos-$(echo "$GH_USER" | tr '[:upper:]' '[:lower:]')" ]; then
  fail "The bucket is named after you" "Expected bukka-menu-photos-$(echo "$GH_USER" | tr '[:upper:]' '[:lower:]'), found $BUCKET."
fi

mkdir -p artifacts
{
  echo "# $TICKET audit"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "github_user: ${GH_USER:-unknown}"
  echo "branch: $BRANCH"
  echo "orders_db_sha256: $( [ -f infra/db/orders-db.sh ] && { sha256sum infra/db/orders-db.sh 2>/dev/null || shasum -a 256 infra/db/orders-db.sh; } | cut -d' ' -f1)"
  echo "fails: $FAILS"
  echo
  printf '%s\n' "${RESULTS[@]}"
} > "$OUT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All checks passed. Wrote $OUT."
  echo "Next: git add infra/ $OUT && git commit -m \"feat: move orders to a private database and menu photos to S3 (BUK-45)\""
  exit 0
else
  echo "$FAILS check(s) failed. Fix the items marked ✗ and run this again."
  exit 1
fi
