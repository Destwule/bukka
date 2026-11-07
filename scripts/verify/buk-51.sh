#!/usr/bin/env bash
# BUK-51 verify: production on LocalStack, built and managed by Terraform.
# Run from the root of your bukka clone, with LocalStack running and the
# stack applied (terraform init + terraform apply in infra/terraform):
#   bash scripts/verify/buk-51.sh
# Writes artifacts/buk-51-terraform-audit.txt. It never changes your
# infrastructure: it only reads, and runs `terraform plan`.

set -uo pipefail

TICKET="BUK-51"
TF="infra/terraform"
OUT="artifacts/buk-51-terraform-audit.txt"
MODULES="network compute database storage billing"
FAILS=0
RESULTS=()
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export TF_IN_AUTOMATION=1
export WORK; WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass() { RESULTS+=("PASS  $1"); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      → %s\n' "$2"; FAILS=$((FAILS + 1)); }
check() { local name="$1" hint="$2"; shift 2; if "$@"; then pass "$name"; else fail "$name" "$hint"; fi; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi | cut -d' ' -f1; }
# One fingerprint over every .tf file (path and content), in a fixed order.
tf_sha() {
  find "$TF" -type f -name '*.tf' -not -path '*/.terraform/*' 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sha256 "$f")" "$f"
  done | sha256
}
tfc() { terraform -chdir="$TF" "$@"; }
awsq() { aws "$@" 2>/dev/null; }

if [ ! -d .git ] || [ ! -f tickets/BUK-51.md ]; then
  echo "Run this from the root of your bukka clone (the folder with tickets/ in it)."
  exit 2
fi
for cmd in terraform aws python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd is not installed. See the ticket's Notes."; exit 2; }
done
echo "== $TICKET verify =="
echo

# Secret-looking values in .tf/.tfvars: written-in passwords/keys, and
# variables named like secrets that carry a default.
secret_scan() {
  python3 - "$@" <<'PY'
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
        if m and not m.group(1).lower().startswith("skip_"):
            bad.append(f"{path}:{n}: {m.group(1)} is written in")
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
}

# --- Project layout -------------------------------------------------------------
echo "Project layout"
MISSING=""
for f in versions.tf backend.tf main.tf variables.tf outputs.tf; do [ -f "$TF/$f" ] || MISSING="$MISSING $f"; done
check "$TF has versions.tf, backend.tf, main.tf, variables.tf and outputs.tf" "Missing:$MISSING" [ -z "$MISSING" ]
for m in $MODULES; do
  MISSING=""
  for f in main.tf variables.tf outputs.tf; do [ -f "$TF/modules/$m/$f" ] || MISSING="$MISSING $f"; done
  check "modules/$m has main.tf, variables.tf and outputs.tf" "Missing in $TF/modules/$m:$MISSING" [ -z "$MISSING" ]
done
NOT_CALLED=""
for m in $MODULES; do
  grep -qE "source[[:space:]]*=[[:space:]]*\"\./modules/$m/?\"" "$TF/main.tf" 2>/dev/null || NOT_CALLED="$NOT_CALLED $m"
done
check "The root main.tf calls all five modules" "Not called from $TF/main.tf:$NOT_CALLED" [ -z "$NOT_CALLED" ]
UNDOC=$(python3 - "$TF/variables.tf" <<'PY'
import re, sys
try:
    text = open(sys.argv[1]).read()
except OSError:
    print("(no variables.tf)"); sys.exit()
out = []
for m in re.finditer(r'variable\s+"([^"]+)"\s*\{', text):
    depth, i = 1, m.end()
    while i < len(text) and depth:
        depth += {"{": 1, "}": -1}.get(text[i], 0); i += 1
    body = text[m.end():i]
    if not re.search(r'^\s*type\s*=', body, re.M) or not re.search(r'^\s*description\s*=', body, re.M):
        out.append(m.group(1))
print(" ".join(out))
PY
)
check "Every root variable has a type and a description" "Add them to: $UNDOC" [ -z "$UNDOC" ]
HARD=$(grep -rnoE '"(vpc|subnet|sg|igw|rtb|i|eni|nat)-[0-9a-f]{8,17}"' --include='*.tf' "$TF" 2>/dev/null | grep -v '/.terraform/' | head -3)
check "No hard-coded resource IDs (modules are wired through outputs)" "Pass IDs from one module's outputs into another in main.tf. Found: $HARD" [ -z "$HARD" ]
if [ -f "$TF/backend.tf" ] && grep -qE 'backend[[:space:]]+"s3"' "$TF/backend.tf" && grep -qE 'use_lockfile[[:space:]]*=[[:space:]]*true' "$TF/backend.tf"; then
  pass "backend.tf uses the s3 backend with use_lockfile = true"
else
  fail "backend.tf uses the s3 backend with use_lockfile = true" "terraform { backend \"s3\" { bucket = \"bukka-tfstate-<you>\" ... use_lockfile = true } }"
fi
if [ -f "$TF/backend.tf" ] && ! grep -vE '^[[:space:]]*(#|//)' "$TF/backend.tf" | grep -qiE 'localhost|localstack|4566'; then
  pass "backend.tf has no LocalStack settings (they go in a -backend-config file)"
else
  fail "backend.tf has no LocalStack settings (they go in a -backend-config file)" "Move endpoints and skip_* settings into backend-localstack.hcl and pass it to terraform init."
fi

# --- Code quality -----------------------------------------------------------------
echo; echo "Code quality"
if FMT=$(tfc fmt -check -recursive 2>&1); then pass "terraform fmt -check -recursive"; else
  fail "terraform fmt -check -recursive" "Run: terraform -chdir=$TF fmt -recursive (needs formatting: $(echo $FMT | head -c 150))"; fi
INITED=""
if [ -d "$TF/.terraform" ]; then INITED=1; fi
if [ -z "$INITED" ]; then
  fail "terraform validate" "Run terraform init in $TF first (see the ticket's Notes)."
elif VAL=$(tfc validate -no-color 2>&1); then
  pass "terraform validate"
else
  fail "terraform validate" "$(echo "$VAL" | grep -m1 -iE 'error' | head -c 200)"
fi

# --- Secrets and git hygiene --------------------------------------------------------
echo; echo "Secrets and git hygiene"
TRACKED=$(git ls-files)
STATE_FILES=$(echo "$TRACKED" | grep -E '\.tfstate(\.|$)|(^|/)\.terraform/' || true)
check "No state files or .terraform/ directories are tracked by git" "git rm --cached them: $(echo $STATE_FILES | head -c 150)" [ -z "$STATE_FILES" ]
IGN=""
for p in "$TF/terraform.tfstate" "$TF/terraform.tfstate.backup" "$TF/.terraform/providers" "$TF/modules/network/.terraform/x" "$TF/terraform.tfvars" "$TF/secrets.tfvars.json"; do
  git check-ignore -q --no-index "$p" || IGN="$IGN ${p#$TF/}"
done
check ".gitignore covers *.tfstate, .terraform/ and *.tfvars" "Not ignored:$IGN" [ -z "$IGN" ]
if [ -f "$TF/.terraform.lock.hcl" ] && ! git check-ignore -q --no-index "$TF/.terraform.lock.hcl"; then
  pass ".terraform.lock.hcl exists and isn't ignored (commit it)"
else
  fail ".terraform.lock.hcl exists and isn't ignored (commit it)" "terraform init writes it. It pins the provider versions for your teammates."
fi
SCAN_FILES=$( { find "$TF" -type f \( -name '*.tf' -o -name '*.hcl' \) -not -path '*/.terraform/*' 2>/dev/null; echo "$TRACKED" | grep -E '\.tfvars(\.json)?$'; } | sort -u)
# shellcheck disable=SC2086
LEAKS=$(secret_scan $SCAN_FILES)
check "No passwords, secret defaults or access keys in the Terraform code" "$(echo "$LEAKS" | head -3 | tr '\n' ';')" [ -z "$LEAKS" ]
if git grep -qE 'AKIA[0-9A-Z]{16}' 2>/dev/null || git log --all -p 2>/dev/null | grep -qE '^\+.*AKIA[0-9A-Z]{16}'; then
  fail "No AWS access keys (AKIA...) in any file or commit" "Remove it, and treat that key as leaked."
else
  pass "No AWS access keys (AKIA...) in any file or commit"
fi
OLD=""
for s in buk-38 buk-42 buk-45; do [ -e "infra/cli/$s.sh" ] && OLD="$OLD infra/cli/$s.sh"; done
check "infra/cli/buk-38.sh, buk-42.sh and buk-45.sh are removed" "git rm$OLD" [ -z "$OLD" ]
check "infra/db/orders-db.sh is kept" "Terraform only manages the AWS side. Keep the BUK-45 database script." [ -f infra/db/orders-db.sh ]

# --- Remote state ---------------------------------------------------------------------
echo; echo "Remote state (LocalStack at $AWS_ENDPOINT_URL)"
LS_UP=""
if awsq sts get-caller-identity >/dev/null; then pass "LocalStack is answering"; LS_UP=1; else
  fail "LocalStack is answering" "Start LocalStack (see the ticket's Notes)."; fi
BE_BUCKET=$(sed -nE 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$TF/backend.tf" 2>/dev/null | head -1)
BE_KEY=$(sed -nE 's/^[[:space:]]*key[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$TF/backend.tf" 2>/dev/null | head -1)
STATE_BUCKET=""
if [ -n "$LS_UP" ]; then
  if [[ "$BE_BUCKET" == bukka-tfstate-* ]] && awsq s3api head-bucket --bucket "$BE_BUCKET" >/dev/null; then
    STATE_BUCKET="$BE_BUCKET"; pass "The state bucket exists ($STATE_BUCKET)"
  else
    fail "The state bucket exists" "backend.tf names '${BE_BUCKET:-nothing}'. Create bukka-tfstate-<you> before terraform init."
  fi
fi
if [ -n "$STATE_BUCKET" ]; then
  V=$(awsq s3api get-bucket-versioning --bucket "$STATE_BUCKET" --query Status --output text)
  check "The state bucket has versioning on" "aws s3api put-bucket-versioning --bucket $STATE_BUCKET --versioning-configuration Status=Enabled" [ "$V" = "Enabled" ]
  E=$(awsq s3api get-bucket-encryption --bucket "$STATE_BUCKET" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)
  case "$E" in
    AES256|aws:kms*) pass "The state bucket has default encryption on ($E)" ;;
    *) fail "The state bucket has default encryption on" "aws s3api put-bucket-encryption --bucket $STATE_BUCKET --server-side-encryption-configuration '{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"}}]}'" ;;
  esac
  if [ -n "$BE_KEY" ] && awsq s3api head-object --bucket "$STATE_BUCKET" --key "$BE_KEY" >/dev/null; then
    pass "Terraform's state is in the bucket ($BE_KEY)"
  else
    fail "Terraform's state is in the bucket" "No object at s3://$STATE_BUCKET/${BE_KEY:-<key>}. Did terraform init use the s3 backend?"
  fi
fi

# --- What's in LocalStack ------------------------------------------------------------
if [ -n "$LS_UP" ]; then
echo; echo "The network (BUK-42)"
VPC_COUNT=$(awsq ec2 describe-vpcs --filters Name=tag:Name,Values=bukka-prod-vpc --query 'length(Vpcs)' --output text)
VPC=$(awsq ec2 describe-vpcs --filters Name=tag:Name,Values=bukka-prod-vpc Name=cidr,Values=10.0.0.0/16 --query 'Vpcs[0].VpcId' --output text)
[ "$VPC" = "None" ] && VPC=""
if [ "$VPC_COUNT" = "1" ] && [ -n "$VPC" ]; then pass "Exactly one bukka-prod-vpc, 10.0.0.0/16"; else
  fail "Exactly one bukka-prod-vpc, 10.0.0.0/16" "Found ${VPC_COUNT:-0} VPCs named bukka-prod-vpc. Start from a fresh LocalStack and terraform apply."; fi

if [ -n "$VPC" ]; then
  awsq ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" --output json > "$WORK"/subnets.json
  awsq ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC" --output json > "$WORK"/rts.json
  awsq ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values="$VPC" --output json > "$WORK"/igws.json
  while IFS= read -r line; do
    case "$line" in PASS*) pass "${line#PASS }";; FAIL*) n="${line#FAIL }"; fail "${n%%|*}" "${n#*|}";; esac
  done < <(python3 - <<'PY'
import json, os
subnets = json.load(open(os.environ["WORK"] + "/subnets.json"))["Subnets"]
rts = json.load(open(os.environ["WORK"] + "/rts.json"))["RouteTables"]
igws = json.load(open(os.environ["WORK"] + "/igws.json"))["InternetGateways"]
tags = lambda o: {t["Key"]: t["Value"] for t in o.get("Tags", [])}
want = [("bukka-web-a", "10.0.1.0/24", "us-east-1a", "public"), ("bukka-web-b", "10.0.2.0/24", "us-east-1b", "public"),
        ("bukka-db-a", "10.0.10.0/24", "us-east-1a", "private"), ("bukka-db-b", "10.0.20.0/24", "us-east-1b", "private")]
ids = {}
for name, cidr, az, tier in want:
    found = [s for s in subnets if tags(s).get("Name") == name]
    label = f"{name}: {cidr}, {az}, Tier={tier}, public IP {'on' if tier == 'public' else 'off'}"
    if len(found) != 1:
        print(f"FAIL {label}|Found {len(found)} subnets named {name} in bukka-prod-vpc."); continue
    s = found[0]; ids[name] = s["SubnetId"]
    got = (s["CidrBlock"], s["AvailabilityZone"], tags(s).get("Tier"), bool(s.get("MapPublicIpOnLaunch")))
    if got == (cidr, az, tier, tier == "public"):
        print(f"PASS {label}")
    else:
        print(f"FAIL {label}|Got CIDR {got[0]}, AZ {got[1]}, Tier {got[2]}, MapPublicIpOnLaunch {got[3]}.")
igw = [g for g in igws if tags(g).get("Name") == "bukka-prod-igw"]
igw_id = igw[0]["InternetGatewayId"] if len(igw) == 1 else None
print("PASS bukka-prod-igw is attached to bukka-prod-vpc" if igw_id else
      f"FAIL bukka-prod-igw is attached to bukka-prod-vpc|Found {len(igw)} attached gateways named bukka-prod-igw.")
def assoc(rt): return {a.get("SubnetId") for a in rt.get("Associations", []) if a.get("SubnetId")}
def internet(rt): return [r for r in rt.get("Routes", []) if r.get("DestinationCidrBlock") == "0.0.0.0/0" or r.get("DestinationIpv6CidrBlock") == "::/0"]
pub = [r for r in rts if tags(r).get("Name") == "bukka-public-rt"]
web = {ids.get("bukka-web-a"), ids.get("bukka-web-b")}
if len(pub) == 1 and igw_id and any(r.get("GatewayId") == igw_id for r in internet(pub[0])) and web <= assoc(pub[0]) and None not in web:
    print("PASS bukka-public-rt sends 0.0.0.0/0 to the gateway, for both web subnets")
else:
    print("FAIL bukka-public-rt sends 0.0.0.0/0 to the gateway, for both web subnets|Check its 0.0.0.0/0 route and its subnet associations.")
priv = [r for r in rts if tags(r).get("Name") == "bukka-private-rt"]
db = {ids.get("bukka-db-a"), ids.get("bukka-db-b")}
if len(priv) == 1 and not internet(priv[0]) and all(r.get("GatewayId") == "local" for r in priv[0].get("Routes", [])) and db <= assoc(priv[0]) and None not in db:
    print("PASS bukka-private-rt has only the local route, for both database subnets")
else:
    print("FAIL bukka-private-rt has only the local route, for both database subnets|Check its routes and its subnet associations.")
main = [r for r in rts if any(a.get("Main") for a in r.get("Associations", []))]
leaky = []
for name in ("bukka-db-a", "bukka-db-b"):
    sid = ids.get(name)
    rt = [r for r in rts if sid in assoc(r)] or main
    if not sid or not rt or internet(rt[0]):
        leaky.append(name)
print("PASS No route table sends the database subnets to the internet (main table included)" if not leaky else
      f"FAIL No route table sends the database subnets to the internet (main table included)|Internet route for: {', '.join(leaky)}.")
PY
)
fi

echo; echo "The API server (BUK-38)"
BUCKET=$(awsq s3api list-buckets --query 'Buckets[].Name' --output text | tr '\t' '\n' | grep '^bukka-menu-photos-' | head -1)
check "The menu photos bucket exists (${BUCKET:-none})" "terraform apply should create bukka-menu-photos-<you>." [ -n "$BUCKET" ]
TRUST=$(awsq iam get-role --role-name bukka-api-server-role --query 'Role.AssumeRolePolicyDocument' --output json)
TRUST_OK=$(python3 -c '
import json, sys, urllib.parse
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
    if isinstance(d, str): d = json.loads(urllib.parse.unquote(d))
except Exception:
    print("no"); sys.exit()
st = d.get("Statement", []); st = st if isinstance(st, list) else [st]
pr = set()
for s in st:
    if s.get("Effect") != "Allow": continue
    p = s.get("Principal", {})
    if not isinstance(p, dict) or set(p) != {"Service"}: print("no"); sys.exit()
    v = p["Service"]; pr |= set(v if isinstance(v, list) else [v])
print("yes" if pr == {"ec2.amazonaws.com"} else "no")' <<< "${TRUST:-null}")
check "bukka-api-server-role can only be used by EC2" "Its trust policy must allow ec2.amazonaws.com and nothing else." [ "$TRUST_OK" = "yes" ]

# Every policy on the role, inline and attached.
POLS="[]"
for p in $(awsq iam list-role-policies --role-name bukka-api-server-role --query 'PolicyNames[]' --output text); do
  DOC=$(awsq iam get-role-policy --role-name bukka-api-server-role --policy-name "$p" --query PolicyDocument --output json)
  POLS=$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); a.append(json.loads(sys.argv[2])); print(json.dumps(a))' "$POLS" "${DOC:-null}")
done
for arn in $(awsq iam list-attached-role-policies --role-name bukka-api-server-role --query 'AttachedPolicies[].PolicyArn' --output text); do
  VER=$(awsq iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId --output text)
  DOC=$(awsq iam get-policy-version --policy-arn "$arn" --version-id "$VER" --query PolicyVersion.Document --output json)
  POLS=$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); a.append(json.loads(sys.argv[2])); print(json.dumps(a))' "$POLS" "${DOC:-null}")
done
PERM=$(BUCKET="$BUCKET" python3 -c '
import json, os, sys, urllib.parse
b = os.environ["BUCKET"]
want = {("s3:getobject", f"arn:aws:s3:::{b}/*"), ("s3:listbucket", f"arn:aws:s3:::{b}")}
got = set()
for d in json.loads(sys.argv[1]):
    if isinstance(d, str): d = json.loads(urllib.parse.unquote(d))
    if not d: continue
    st = d.get("Statement", []); st = st if isinstance(st, list) else [st]
    for s in st:
        if s.get("Effect") != "Allow": continue
        if "NotAction" in s or "NotResource" in s: print("uses NotAction/NotResource"); sys.exit()
        a = s.get("Action", []); r = s.get("Resource", [])
        for x in (a if isinstance(a, list) else [a]):
            for y in (r if isinstance(r, list) else [r]):
                got.add((x.lower(), y))
print("ok" if b and got == want else "allows: " + ", ".join(sorted(f"{x} on {y}" for x, y in got))[:200])' "$POLS")
check "The role allows only s3:GetObject and s3:ListBucket on the photos bucket" "${PERM}" [ "$PERM" = "ok" ]
PROFILE_ROLE=$(awsq iam get-instance-profile --instance-profile-name bukka-api-server-profile --query 'InstanceProfile.Roles[].RoleName' --output text)
check "bukka-api-server-profile holds bukka-api-server-role" "Got: '${PROFILE_ROLE:-no profile}'." [ "$PROFILE_ROLE" = "bukka-api-server-role" ]

WEB_SG=""
if [ -n "$VPC" ]; then
  WEB_JSON=$(awsq ec2 describe-security-groups --filters Name=group-name,Values=bukka-web-sg Name=vpc-id,Values="$VPC" --query 'SecurityGroups[0]' --output json)
  WEB_SG=$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "null"); print((d or {}).get("GroupId",""))' <<< "${WEB_JSON:-null}")
  WEB_OK=$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "null")
if not d: print("bukka-web-sg not found in bukka-prod-vpc"); sys.exit()
seen = set(); bad = []
for p in d.get("IpPermissions", []):
    port = (p.get("IpProtocol"), p.get("FromPort"), p.get("ToPort"))
    cidrs = [r["CidrIp"] for r in p.get("IpRanges", [])] + [r["CidrIpv6"] for r in p.get("Ipv6Ranges", [])]
    if port in (("tcp", 80, 80), ("tcp", 443, 443)) and "0.0.0.0/0" in cidrs and not p.get("UserIdGroupPairs"):
        seen.add(port[1])
    elif port == ("tcp", 22, 22) and cidrs and all(c.endswith("/32") and ":" not in c for c in cidrs) and not p.get("UserIdGroupPairs"):
        pass
    else:
        src = cidrs or [g.get("GroupId") for g in p.get("UserIdGroupPairs", [])]
        bad.append(f"{port} from {src}")
print("ok" if seen == {80, 443} and not bad else ("extra rules: " + "; ".join(bad) if bad else "80 and 443 must be open to 0.0.0.0/0"))' <<< "${WEB_JSON:-null}")
  check "bukka-web-sg: 80 and 443 from anywhere, SSH closed or one /32, nothing else" "$WEB_OK" [ "$WEB_OK" = "ok" ]
else
  fail "bukka-web-sg: 80 and 443 from anywhere, SSH closed or one /32, nothing else" "No bukka-prod-vpc to look in."
fi

INST=$(awsq ec2 describe-instances --filters Name=tag:Name,Values=bukka-api-1 Name=instance-state-name,Values=pending,running,stopping,stopped --output json)
INST_OK=$(WEB_SG="$WEB_SG" SUBNETS="$(python3 -c 'import json, os; print(" ".join(s["SubnetId"] for s in json.load(open(os.environ["WORK"] + "/subnets.json"))["Subnets"] if {t["Key"]:t["Value"] for t in s.get("Tags",[])}.get("Tier")=="public"))' 2>/dev/null)" python3 -c '
import json, os, sys
d = json.loads(sys.stdin.read() or "null") or {}
inst = [i for r in d.get("Reservations", []) for i in r.get("Instances", [])]
if len(inst) != 1: print(f"found {len(inst)} instances named bukka-api-1, expected exactly 1"); sys.exit()
i = inst[0]; problems = []
if i.get("InstanceType") != "t3.micro": problems.append("type is " + str(i.get("InstanceType")))
if [g["GroupId"] for g in i.get("SecurityGroups", [])] != [os.environ["WEB_SG"]]: problems.append("security groups are not just bukka-web-sg")
if not i.get("IamInstanceProfile", {}).get("Arn", "").endswith("/bukka-api-server-profile"): problems.append("no bukka-api-server-profile")
if i.get("SubnetId") not in os.environ["SUBNETS"].split(): problems.append("not in a web subnet of bukka-prod-vpc")
print("ok" if not problems else "; ".join(problems))' <<< "${INST:-null}")
check "One bukka-api-1 (t3.micro) in a web subnet, with bukka-web-sg and the instance profile" "$INST_OK" [ "$INST_OK" = "ok" ]

TOPIC=$(awsq sns list-topics --query 'Topics[].TopicArn' --output text | tr '\t' '\n' | grep ':bukka-billing-alerts$' | head -1)
SUBS=$( [ -n "$TOPIC" ] && awsq sns list-subscriptions-by-topic --topic-arn "$TOPIC" --query 'Subscriptions[?Protocol==`email`].Endpoint' --output text)
check "bukka-billing-alerts has an email subscribed" "Subscribe your email to the topic in the billing module." test -n "$TOPIC" -a -n "$SUBS"
ALARM=$(awsq cloudwatch describe-alarms --alarm-names bukka-spend-above-zero --query 'MetricAlarms[0]' --output json)
ALARM_OK=$(TOPIC="$TOPIC" python3 -c '
import json, os, sys
a = json.loads(sys.stdin.read() or "null")
if not a: print("bukka-spend-above-zero not found"); sys.exit()
dims = {d["Name"]: d["Value"] for d in a.get("Dimensions", [])}
ok = (a.get("Namespace") == "AWS/Billing" and a.get("MetricName") == "EstimatedCharges" and dims.get("Currency") == "USD"
      and float(a.get("Threshold", -1)) == 0 and a.get("ComparisonOperator") == "GreaterThanThreshold"
      and os.environ["TOPIC"] and os.environ["TOPIC"] in a.get("AlarmActions", []))
print("ok" if ok else " ".join(str(x) for x in (a.get("Namespace"), a.get("MetricName"), dims, a.get("ComparisonOperator"), a.get("Threshold"), "->", a.get("AlarmActions")))[:200])' <<< "${ALARM:-null}")
check "bukka-spend-above-zero: EstimatedCharges (USD) above 0 notifies bukka-billing-alerts" "$ALARM_OK" [ "$ALARM_OK" = "ok" ]

echo; echo "The database firewall and the photos bucket (BUK-45)"
DBSG_JSON=$( [ -n "$VPC" ] && awsq ec2 describe-security-groups --filters Name=group-name,Values=bukka-db-sg Name=vpc-id,Values="$VPC" --query 'SecurityGroups[0]' --output json)
DB_SG=$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "null"); print((d or {}).get("GroupId",""))' <<< "${DBSG_JSON:-null}")
DB_OK=$(WEB_SG="$WEB_SG" python3 -c '
import json, os, sys
d = json.loads(sys.stdin.read() or "null")
if not d: print("bukka-db-sg not found in bukka-prod-vpc"); sys.exit()
perms = d.get("IpPermissions", [])
ok = (len(perms) == 1 and perms[0].get("IpProtocol") == "tcp" and perms[0].get("FromPort") == 5432
      and perms[0].get("ToPort") == 5432 and not perms[0].get("IpRanges") and not perms[0].get("Ipv6Ranges")
      and [g["GroupId"] for g in perms[0].get("UserIdGroupPairs", [])] == [os.environ["WEB_SG"]])
print("ok" if ok else "inbound rules: " + json.dumps(perms)[:180])' <<< "${DBSG_JSON:-null}")
check "bukka-db-sg allows 5432 only from bukka-web-sg" "$DB_OK" [ "$DB_OK" = "ok" ]
if [ -n "$BUCKET" ]; then
  PAB=$(awsq s3api get-public-access-block --bucket "$BUCKET" --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text | tr -s '\t ' ' ')
  check "Block Public Access: all four on" "Got: ${PAB:-not set}." [ "$PAB" = "True True True True" ]
  ENC=$(awsq s3api get-bucket-encryption --bucket "$BUCKET" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)
  check "Default encryption is SSE-S3 (AES256)" "Got: ${ENC:-none}." [ "$ENC" = "AES256" ]
else
  fail "Block Public Access: all four on" "No menu photos bucket."
  fail "Default encryption is SSE-S3 (AES256)" "No menu photos bucket."
fi
fi

# --- Terraform owns it -----------------------------------------------------------------
echo; echo "Terraform owns it"
if [ -n "$INITED" ] && [ -n "$LS_UP" ]; then
  STATE=$(tfc state list 2>/dev/null)
  NOSTATE=""
  for m in $MODULES; do echo "$STATE" | grep -q "^module\.$m\." || NOSTATE="$NOSTATE $m"; done
  check "Every module has resources in the Terraform state" "Nothing in state for:$NOSTATE. Did terraform apply finish?" [ -z "$NOSTATE" ]
  OUTS=$(tfc output -json 2>/dev/null | python3 -c 'import json,sys; print(" ".join(str(v["value"]) for v in json.load(sys.stdin).values()))' 2>/dev/null)
  INST_ID=$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "null") or {}; print(" ".join(i["InstanceId"] for r in d.get("Reservations",[]) for i in r["Instances"]))' <<< "${INST:-null}")
  MISSING_OUT=""
  for v in "$VPC" "$INST_ID" "$DB_SG" "$BUCKET"; do
    { [ -n "$v" ] && [[ " $OUTS " == *" $v "* ]]; } || MISSING_OUT="$MISSING_OUT ${v:-?}"
  done
  check "Outputs give the VPC ID, API server ID, bukka-db-sg ID and bucket name" "Missing from terraform output:$MISSING_OUT" [ -z "$MISSING_OUT" ]
  tfc plan -detailed-exitcode -input=false -no-color > "$WORK"/plan.txt 2>&1; RC=$?
  if [ "$RC" -eq 0 ]; then
    pass "terraform plan shows no changes"
  elif [ "$RC" -eq 2 ]; then
    fail "terraform plan shows no changes" "$(grep -m1 -E '^Plan:' "$WORK/plan.txt"). Something drifted, or the code doesn't match what's built. Run terraform plan and read it."
  else
    fail "terraform plan shows no changes" "terraform plan failed: $(grep -m1 -iE 'error' "$WORK/plan.txt" | head -c 200)"
  fi
else
  fail "Every module has resources in the Terraform state" "Needs terraform init and LocalStack."
  fail "Outputs give the VPC ID, API server ID, bukka-db-sg ID and bucket name" "Needs terraform init and LocalStack."
  fail "terraform plan shows no changes" "Needs terraform init and LocalStack."
fi

# --- Branch and identity ------------------------------------------------------------------
echo
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ "$BRANCH" == buk-51-* ]]; then pass "On a BUK-51 branch ($BRANCH)"; else
  fail "On a BUK-51 branch" "You're on '$BRANCH'."; fi
GH_USER=""
GH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
if [[ "$GH_OUT" =~ Hi\ ([A-Za-z0-9-]+)! ]]; then
  GH_USER="${BASH_REMATCH[1]}"; pass "GitHub recognises your SSH key as @$GH_USER"
else
  fail "GitHub recognises your SSH key" "Run: ssh-add, then try again (see BUK-14)."
fi
if [ -n "$GH_USER" ]; then
  ME=$(echo "$GH_USER" | tr '[:upper:]' '[:lower:]')
  [ -n "${BUCKET:-}" ] && [ "$BUCKET" != "bukka-menu-photos-$ME" ] && fail "The photos bucket is named after you" "Expected bukka-menu-photos-$ME, found $BUCKET."
  [ -n "$BE_BUCKET" ] && [ "$BE_BUCKET" != "bukka-tfstate-$ME" ] && fail "The state bucket is named after you" "Expected bukka-tfstate-$ME, backend.tf says $BE_BUCKET."
fi

mkdir -p artifacts
{
  echo "# $TICKET audit"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "github_user: ${GH_USER:-unknown}"
  echo "branch: $BRANCH"
  echo "terraform_sha256: $(tf_sha)"
  echo "terraform_version: $(terraform version 2>/dev/null | head -1)"
  echo "fails: $FAILS"
  echo
  printf '%s\n' "${RESULTS[@]}"
} > "$OUT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All checks passed. Wrote $OUT."
  echo "Next: git add infra/ $OUT && git commit -m \"feat: manage production infrastructure with Terraform (BUK-51)\""
  exit 0
else
  echo "$FAILS check(s) failed. Fix the items marked ✗ and run this again."
  exit 1
fi
