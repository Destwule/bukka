#!/usr/bin/env bash
# BUK-42 verify: the production VPC, its public and private subnets in two
# availability zones, and the route tables, on LocalStack. Run from the root
# of your bukka clone, with LocalStack running and your network created:
#   bash scripts/verify/buk-42.sh
# Writes artifacts/buk-42-network-audit.txt.

set -uo pipefail

TICKET="BUK-42"
OUT="artifacts/buk-42-network-audit.txt"
S="infra/cli/buk-42.sh"
FAILS=0
RESULTS=()
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_PAGER=""

pass() { RESULTS+=("PASS  $1"); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      → %s\n' "$2"; FAILS=$((FAILS + 1)); }
none() { [ -z "$1" ] || [ "$1" = "None" ] || [ "$1" = "null" ]; }

if [ ! -d .git ] || [ ! -f tickets/BUK-42.md ]; then
  echo "Run this from the root of your bukka clone (the folder with tickets/ in it)."
  exit 2
fi
echo "== $TICKET verify =="
echo

echo "LocalStack at $AWS_ENDPOINT_URL"
VPC=""
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  fail "LocalStack is answering" "Start LocalStack and point the AWS CLI at it (see the ticket's Notes)."
else
  pass "LocalStack is answering"

  # --- The VPC ----------------------------------------------------------------
  echo; echo "The VPC"
  VPCS=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=bukka-prod-vpc --query 'Vpcs[].[VpcId,CidrBlock]' --output text 2>/dev/null)
  N_VPC=$(printf '%s' "$VPCS" | grep -c . || true)
  if [ "$N_VPC" = "0" ]; then
    fail "One VPC tagged Name=bukka-prod-vpc" "aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=bukka-prod-vpc}]'"
  else
    if [ "$N_VPC" = "1" ]; then pass "One VPC tagged Name=bukka-prod-vpc"; else
      fail "One VPC tagged Name=bukka-prod-vpc" "Found $N_VPC (did you run your script twice?). Restart LocalStack and run it once."; fi
    read -r VPC VPC_CIDR <<< "$(printf '%s\n' "$VPCS" | head -1)"
    [ "$VPC_CIDR" = "10.0.0.0/16" ] && pass "bukka-prod-vpc is 10.0.0.0/16" || fail "bukka-prod-vpc is 10.0.0.0/16" "It's $VPC_CIDR."
  fi
fi

if [ -n "$VPC" ]; then
  # Everything in the VPC, judged in one go.
  DIR=$(mktemp -d)
  aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" --query 'Subnets' --output json > "$DIR/subnets.json" 2>/dev/null || echo '[]' > "$DIR/subnets.json"
  aws ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC" --query 'RouteTables' --output json > "$DIR/rts.json" 2>/dev/null || echo '[]' > "$DIR/rts.json"
  aws ec2 describe-internet-gateways --query 'InternetGateways' --output json > "$DIR/igws.json" 2>/dev/null || echo '[]' > "$DIR/igws.json"
  # One line per check: "PASS|<name>" or "FAIL|<name>|<hint>".
  CHECKS=$(VPC="$VPC" python3 - "$DIR" <<'PY' 2>&1
import json, os, sys
d, vpc = sys.argv[1], os.environ["VPC"]
load = lambda n: json.load(open(os.path.join(d, n))) or []
subnets, rts, igws = load("subnets.json"), load("rts.json"), load("igws.json")
tags = lambda o: {t["Key"]: t["Value"] for t in o.get("Tags") or []}
named = lambda objs, n: [o for o in objs if tags(o).get("Name") == n]
out = []
def check(ok, name, hint=""):
    out.append("PASS|" + name if ok else "FAIL|" + name + "|" + hint)

WANT = [("bukka-web-a", "10.0.1.0/24", "us-east-1a", "public"),
        ("bukka-web-b", "10.0.2.0/24", "us-east-1b", "public"),
        ("bukka-db-a", "10.0.10.0/24", "us-east-1a", "private"),
        ("bukka-db-b", "10.0.20.0/24", "us-east-1b", "private")]
sub_id = {}
for name, cidr, az, tier in WANT:
    found = named(subnets, name)
    label = "%s: %s in %s, Tier=%s" % (name, cidr, az, tier)
    if not found:
        check(False, label, "No subnet tagged Name=%s in bukka-prod-vpc." % name); continue
    s = found[0]
    sub_id[name] = s["SubnetId"]
    got = (s.get("CidrBlock"), s.get("AvailabilityZone"), tags(s).get("Tier"))
    if len(found) > 1:
        check(False, label, "There are %d subnets called %s. Delete the extras." % (len(found), name))
    else:
        check(got == (cidr, az, tier), label, "It's %s in %s with Tier=%s." % got)

def mapip(name):
    s = named(subnets, name)
    return bool(s and s[0].get("MapPublicIpOnLaunch"))
web_map = [n for n in ("bukka-web-a", "bukka-web-b") if not mapip(n)]
check(not web_map, "The web subnets give instances a public IP (MapPublicIpOnLaunch)",
      "Not set on %s: aws ec2 modify-subnet-attribute --subnet-id <id> --map-public-ip-on-launch" % ", ".join(web_map))
db_map = [n for n in ("bukka-db-a", "bukka-db-b") if mapip(n)]
check(not db_map, "The database subnets don't give out public IPs",
      "Set on %s: aws ec2 modify-subnet-attribute --subnet-id <id> --no-map-public-ip-on-launch" % ", ".join(db_map))

igw = named(igws, "bukka-prod-igw")
igw_id = igw[0]["InternetGatewayId"] if igw else None
attached = bool(igw) and any(a.get("VpcId") == vpc for a in igw[0].get("Attachments") or [])
check(attached, "Internet gateway bukka-prod-igw is attached to bukka-prod-vpc",
      "No IGW tagged Name=bukka-prod-igw." if not igw else "aws ec2 attach-internet-gateway --internet-gateway-id %s --vpc-id %s" % (igw_id, vpc))

def internet_routes(rt):
    bad = []
    for r in rt.get("Routes") or []:
        gw = r.get("GatewayId") or ""
        dest = r.get("DestinationCidrBlock") or r.get("DestinationIpv6CidrBlock") or r.get("DestinationPrefixListId") or "?"
        if gw == "local":
            continue
        if gw.startswith("igw-") or gw.startswith("eigw-") or r.get("NatGatewayId") or r.get("EgressOnlyInternetGatewayId") \
                or dest in ("0.0.0.0/0", "::/0"):
            bad.append("%s -> %s" % (dest, gw or r.get("NatGatewayId") or r.get("EgressOnlyInternetGatewayId") or r.get("InstanceId") or r.get("NetworkInterfaceId") or "?"))
    return bad
assoc = lambda rt: {a.get("SubnetId") for a in rt.get("Associations") or [] if a.get("SubnetId")}

pub = named(rts, "bukka-public-rt")
if not pub:
    check(False, "bukka-public-rt sends 0.0.0.0/0 to bukka-prod-igw", "No route table tagged Name=bukka-public-rt in bukka-prod-vpc.")
    check(False, "bukka-public-rt is associated with both web subnets", "Create bukka-public-rt first.")
else:
    ok = any(r.get("DestinationCidrBlock") == "0.0.0.0/0" and igw_id and r.get("GatewayId") == igw_id for r in pub[0].get("Routes") or [])
    check(ok, "bukka-public-rt sends 0.0.0.0/0 to bukka-prod-igw",
          "aws ec2 create-route --route-table-id %s --destination-cidr-block 0.0.0.0/0 --gateway-id <igw id>" % pub[0]["RouteTableId"])
    missing = [n for n in ("bukka-web-a", "bukka-web-b") if sub_id.get(n) not in assoc(pub[0])]
    check(not missing, "bukka-public-rt is associated with both web subnets", "Not associated: " + ", ".join(missing))

priv = named(rts, "bukka-private-rt")
if not priv:
    check(False, "bukka-private-rt has only the local route", "No route table tagged Name=bukka-private-rt in bukka-prod-vpc.")
    check(False, "bukka-private-rt is associated with both database subnets", "Create bukka-private-rt first.")
else:
    extra = ["%s -> %s" % (r.get("DestinationCidrBlock") or r.get("DestinationIpv6CidrBlock") or "?",
                          r.get("GatewayId") or r.get("NatGatewayId") or r.get("InstanceId") or r.get("NetworkInterfaceId") or "?")
             for r in priv[0].get("Routes") or [] if r.get("GatewayId") != "local"]
    check(not extra, "bukka-private-rt has only the local route", "Delete: " + "; ".join(extra))
    missing = [n for n in ("bukka-db-a", "bukka-db-b") if sub_id.get(n) not in assoc(priv[0])]
    check(not missing, "bukka-private-rt is associated with both database subnets", "Not associated: " + ", ".join(missing))

# The table that actually routes each database subnet: its own association, or
# the VPC's main route table if it has none.
main = [rt for rt in rts if any(a.get("Main") for a in rt.get("Associations") or [])]
leaks = []
for n in ("bukka-db-a", "bukka-db-b"):
    sid = sub_id.get(n)
    if not sid:
        leaks.append(n + " is missing"); continue
    rt = next((rt for rt in rts if sid in assoc(rt)), main[0] if main else None)
    if rt is None:
        leaks.append(n + " has no route table"); continue
    for b in internet_routes(rt):
        leaks.append("%s uses %s (%s), which routes %s" % (n, tags(rt).get("Name", "the main route table" if rt in main else rt["RouteTableId"]), rt["RouteTableId"], b))
check(not leaks, "No route table sends database subnet traffic to the internet", "; ".join(leaks)[:300])

for line in out:
    print(line)
PY
)
  rm -rf "$DIR"
  if ! printf '%s\n' "$CHECKS" | grep -q '^PASS|\|^FAIL|'; then
    fail "Could read the network from LocalStack" "$(printf '%s' "$CHECKS" | tail -3)"
  fi
  echo; echo "Subnets and routing"
  while IFS='|' read -r R NAME HINT; do
    case "$R" in
      PASS) pass "$NAME" ;;
      FAIL) fail "$NAME" "$HINT" ;;
    esac
  done <<< "$CHECKS"
fi

# --- Your script ----------------------------------------------------------------
echo; echo "Your script"
if [ -f "$S" ]; then
  pass "$S exists"
  bash -n "$S" 2>/dev/null && pass "$S is valid bash" || fail "$S is valid bash" "bash -n $S shows the error."
else
  fail "$S exists" "Save every command you ran, in order, in $S."
fi

# --- Branch and identity --------------------------------------------------------
echo
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ "$BRANCH" == buk-42-* ]]; then pass "On a BUK-42 branch ($BRANCH)"; else
  fail "On a BUK-42 branch" "You're on '$BRANCH'."; fi
GH_USER=""
GH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
if [[ "$GH_OUT" =~ Hi\ ([A-Za-z0-9-]+)! ]]; then
  GH_USER="${BASH_REMATCH[1]}"; pass "GitHub recognises your SSH key as @$GH_USER"
else
  fail "GitHub recognises your SSH key" "Run: ssh-add, then try again (see BUK-14)."
fi

mkdir -p artifacts
{
  echo "# $TICKET audit"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "github_user: ${GH_USER:-unknown}"
  echo "branch: $BRANCH"
  echo "script_sha256: $( [ -f "$S" ] && { sha256sum "$S" 2>/dev/null || shasum -a 256 "$S"; } | cut -d' ' -f1)"
  echo "vpc_id: ${VPC:-none}"
  echo "fails: $FAILS"
  echo
  printf '%s\n' "${RESULTS[@]}"
} > "$OUT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All checks passed. Wrote $OUT."
  echo "Next: git add $S $OUT && git commit -m \"feat: create production VPC with public and private subnets (BUK-42)\""
  exit 0
else
  echo "$FAILS check(s) failed. Fix the items marked ✗ and run this again."
  exit 1
fi
