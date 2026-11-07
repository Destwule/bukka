#!/usr/bin/env bash
# BUK-38 verify: an IAM role (not a key) for the API server, a tight security
# group, and a billing alarm, all on LocalStack. Run from the root of your
# bukka clone, with LocalStack running and your resources created:
#   bash scripts/verify/buk-38.sh
# Writes artifacts/buk-38-iam-audit.txt.

set -uo pipefail

TICKET="BUK-38"
OUT="artifacts/buk-38-iam-audit.txt"
S="infra/cli/buk-38.sh"
ROLE="bukka-api-server-role"
PROFILE="bukka-api-server-profile"
FAILS=0
RESULTS=()
KEY_RE='AKIA[0-9A-Z]{16}'
SECRET_RE='(aws_secret_access_key|AWS_SECRET_ACCESS_KEY|SecretAccessKey)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+]{40}'
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_PAGER=""

pass() { RESULTS+=("PASS  $1"); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      → %s\n' "$2"; FAILS=$((FAILS + 1)); }
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
none() { [ -z "$1" ] || [ "$1" = "None" ] || [ "$1" = "null" ]; }

if [ ! -d .git ] || [ ! -f tickets/BUK-38.md ]; then
  echo "Run this from the root of your bukka clone (the folder with tickets/ in it)."
  exit 2
fi
echo "== $TICKET verify =="
echo

# Who you are on GitHub (reported at the end; used to find your bucket).
GH_USER=""
GH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
[[ "$GH_OUT" =~ Hi\ ([A-Za-z0-9-]+)! ]] && GH_USER="${BASH_REMATCH[1]}"

BUCKET=""
echo "LocalStack at $AWS_ENDPOINT_URL"
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  fail "LocalStack is answering" "Start LocalStack and point the AWS CLI at it (see the ticket's Notes)."
  LS_UP=""
else
  pass "LocalStack is answering"; LS_UP=1
fi

if [ -n "$LS_UP" ]; then
  # --- The bucket -------------------------------------------------------------
  echo; echo "The bucket"
  BUCKETS=$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null | tr '\t' '\n' | grep '^bukka-menu-photos-' || true)
  if [ -n "$GH_USER" ] && echo "$BUCKETS" | grep -qx "bukka-menu-photos-$(lc "$GH_USER")"; then
    BUCKET="bukka-menu-photos-$(lc "$GH_USER")"
  else
    BUCKET=$(echo "$BUCKETS" | head -1)
  fi
  if [ -z "$BUCKET" ]; then
    fail "The menu photos bucket exists" "aws s3api create-bucket --bucket bukka-menu-photos-<your-github-username>"
  else
    pass "The menu photos bucket exists ($BUCKET)"
  fi

  # --- The role ---------------------------------------------------------------
  echo; echo "An identity for the server, not a key"
  ROLE_JSON=$(aws iam get-role --role-name "$ROLE" --output json 2>/dev/null)
  if [ -z "$ROLE_JSON" ]; then
    fail "$ROLE exists" "aws iam create-role --role-name $ROLE --assume-role-policy-document file://trust.json"
  else
    pass "$ROLE exists"
    TRUST=$(python3 -c '
import json, sys, urllib.parse
doc = json.load(sys.stdin)["Role"]["AssumeRolePolicyDocument"]
if isinstance(doc, str):
    doc = json.loads(urllib.parse.unquote(doc))
sts = doc.get("Statement", [])
sts = [sts] if isinstance(sts, dict) else sts
allows = [s for s in sts if s.get("Effect") == "Allow"]
seen = []
ok = bool(allows)
for s in allows:
    p = s.get("Principal")
    seen.append(json.dumps(p))
    if not isinstance(p, dict) or set(p) != {"Service"}:
        ok = False; continue
    svc = p["Service"]
    svc = [svc] if isinstance(svc, str) else svc
    if not svc or any(x != "ec2.amazonaws.com" for x in svc):
        ok = False
    acts = s.get("Action", [])
    acts = [acts] if isinstance(acts, str) else acts
    if [a.lower() for a in acts] != ["sts:assumerole"]:
        ok = False; seen.append("actions " + json.dumps(acts))
print("ok" if ok else ("; ".join(seen) or "no Allow statement")[:200])' <<< "$ROLE_JSON" 2>/dev/null)
    [ "$TRUST" = "ok" ] && pass "Only EC2 can use the role (trust policy: ec2.amazonaws.com, sts:AssumeRole)" \
      || fail "Only EC2 can use the role (trust policy: ec2.amazonaws.com, sts:AssumeRole)" "The trust policy allows: ${TRUST:-unreadable}. It should name only the ec2.amazonaws.com service."

    # Every policy on the role: inline and attached.
    POL_DIR=$(mktemp -d)
    i=0
    for p in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text 2>/dev/null); do
      i=$((i + 1))
      aws iam get-role-policy --role-name "$ROLE" --policy-name "$p" --query PolicyDocument --output json > "$POL_DIR/$i.json" 2>/dev/null \
        || echo "{\"_unreadable\": \"inline policy $p\"}" > "$POL_DIR/$i.json"
    done
    for arn in $(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      i=$((i + 1))
      V=$(aws iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId --output text 2>/dev/null)
      aws iam get-policy-version --policy-arn "$arn" --version-id "$V" --query PolicyVersion.Document --output json > "$POL_DIR/$i.json" 2>/dev/null \
        || echo "{\"_unreadable\": \"$arn\"}" > "$POL_DIR/$i.json"
    done
    POL=$(BUCKET="$BUCKET" python3 - "$POL_DIR" <<'PY' 2>/dev/null
import glob, json, os, sys, urllib.parse
b = os.environ["BUCKET"]
obj, bkt = f"arn:aws:s3:::{b}/*", f"arn:aws:s3:::{b}"
get = lst = False
extra = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    try:
        doc = json.load(open(f))
        if isinstance(doc, str):
            doc = json.loads(urllib.parse.unquote(doc))
    except Exception:
        extra.append("a policy that can't be read"); continue
    if "_unreadable" in doc:
        extra.append("can't read " + doc["_unreadable"]); continue
    sts = doc.get("Statement", [])
    sts = [sts] if isinstance(sts, dict) else sts
    for s in sts:
        if s.get("Effect") != "Allow":
            continue
        if "NotAction" in s or "NotResource" in s:
            extra.append("NotAction/NotResource"); continue
        acts = s.get("Action", []); acts = [acts] if isinstance(acts, str) else acts
        res = s.get("Resource", []); res = [res] if isinstance(res, str) else res
        for a in acts:
            for r in res:
                if b and a.lower() == "s3:getobject" and r == obj:
                    get = True
                elif b and a.lower() == "s3:listbucket" and r == bkt:
                    lst = True
                else:
                    extra.append(f"{a} on {r}")
print("get" if get else "-")
print("list" if lst else "-")
print("; ".join(dict.fromkeys(extra))[:300] or "ok")
PY
)
    rm -rf "$POL_DIR"
    { read -r P_GET; read -r P_LIST; read -r P_EXTRA; } <<< "$POL"
    [ "${P_GET:-}" = "get" ] && pass "The role can s3:GetObject on $BUCKET/*" \
      || fail "The role can s3:GetObject on ${BUCKET:-your bucket}/*" "Add a statement allowing s3:GetObject on arn:aws:s3:::${BUCKET:-bukka-menu-photos-<username>}/* (aws iam put-role-policy)."
    [ "${P_LIST:-}" = "list" ] && pass "The role can s3:ListBucket on $BUCKET" \
      || fail "The role can s3:ListBucket on ${BUCKET:-your bucket}" "Add a statement allowing s3:ListBucket on arn:aws:s3:::${BUCKET:-bukka-menu-photos-<username>} (the bucket itself, no /*)."
    [ "${P_EXTRA:-}" = "ok" ] && pass "The role allows nothing else (no *, no writes, no other buckets)" \
      || fail "The role allows nothing else (no *, no writes, no other buckets)" "Also allowed: ${P_EXTRA:-unreadable}. Remove it: least privilege."
  fi

  IP_ROLES=$(aws iam get-instance-profile --instance-profile-name "$PROFILE" --query 'InstanceProfile.Roles[].RoleName' --output text 2>/dev/null)
  if [ -z "$IP_ROLES" ] && ! aws iam get-instance-profile --instance-profile-name "$PROFILE" >/dev/null 2>&1; then
    fail "$PROFILE exists and holds $ROLE" "aws iam create-instance-profile --instance-profile-name $PROFILE"
  elif [ "$IP_ROLES" = "$ROLE" ]; then
    pass "$PROFILE exists and holds $ROLE"
  else
    fail "$PROFILE exists and holds $ROLE" "It holds: ${IP_ROLES:-no role}. aws iam add-role-to-instance-profile --instance-profile-name $PROFILE --role-name $ROLE"
  fi

  # --- The security group -----------------------------------------------------
  echo; echo "The API server"
  SG_JSON=$(aws ec2 describe-security-groups --filters Name=group-name,Values=bukka-web-sg --query 'SecurityGroups' --output json 2>/dev/null)
  SG_IDS=$(python3 -c 'import json,sys; print(" ".join(g["GroupId"] for g in json.load(sys.stdin)))' <<< "${SG_JSON:-[]}" 2>/dev/null)
  if [ -z "$SG_IDS" ]; then
    fail "bukka-web-sg exists" "aws ec2 create-security-group --group-name bukka-web-sg --description \"Bukka API servers\""
  else
    pass "bukka-web-sg exists ($SG_IDS)"
    SGV=$(python3 -c '
import json, sys
web_bad, ssh_bad, other = [], [], []
for sg in json.load(sys.stdin):
    open_ports = set()
    for p in sg.get("IpPermissions", []):
        proto, fp, tp = p.get("IpProtocol"), p.get("FromPort"), p.get("ToPort")
        v4 = [r["CidrIp"] for r in p.get("IpRanges", [])]
        v6 = [r["CidrIpv6"] for r in p.get("Ipv6Ranges", [])]
        rest = p.get("UserIdGroupPairs", []) + p.get("PrefixListIds", [])
        if proto == "tcp" and fp == tp and fp in (80, 443):
            if "0.0.0.0/0" in v4:
                open_ports.add(fp)
        elif proto == "tcp" and fp == tp == 22:
            if v6 or rest or any(not c.endswith("/32") or c.startswith("0.0.0.0") for c in v4):
                ssh_bad.append(", ".join(v4 + v6) or "a group")
        else:
            port = str(fp) if fp == tp else "%s-%s" % (fp, tp)
            src = ", ".join(v4 + v6) or "a group"
            other.append("all traffic from " + src if proto == "-1" else "%s %s from %s" % (proto, port, src))
    for port in (80, 443):
        if port not in open_ports:
            web_bad.append("%s not open to 0.0.0.0/0 in %s" % (port, sg["GroupId"]))
print("; ".join(web_bad) or "ok")
print("; ".join(ssh_bad)[:200] or "ok")
print("; ".join(other)[:200] or "ok")' <<< "$SG_JSON" 2>/dev/null)
    { read -r SG_WEB; read -r SG_SSH; read -r SG_OTHER; } <<< "$SGV"
    [ "${SG_WEB:-}" = "ok" ] && pass "bukka-web-sg: TCP 80 and 443 open to 0.0.0.0/0" \
      || fail "bukka-web-sg: TCP 80 and 443 open to 0.0.0.0/0" "${SG_WEB:-unreadable}. aws ec2 authorize-security-group-ingress --group-id <id> --protocol tcp --port 80 --cidr 0.0.0.0/0"
    [ "${SG_SSH:-}" = "ok" ] && pass "bukka-web-sg: SSH closed, or open only to one /32" \
      || fail "bukka-web-sg: SSH closed, or open only to one /32" "SSH is open to ${SG_SSH:-?}. Revoke it, or allow only <your-ip>/32."
    [ "${SG_OTHER:-}" = "ok" ] && pass "bukka-web-sg: no other inbound rules" \
      || fail "bukka-web-sg: no other inbound rules" "Also open: ${SG_OTHER:-?}. Revoke it with aws ec2 revoke-security-group-ingress."
  fi

  # --- The instance -----------------------------------------------------------
  INST_JSON=$(aws ec2 describe-instances --filters Name=tag:Name,Values=bukka-api-1 Name=instance-state-name,Values=pending,running \
    --query 'Reservations[].Instances[]' --output json 2>/dev/null)
  N_INST=$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' <<< "${INST_JSON:-[]}" 2>/dev/null)
  if [ "${N_INST:-0}" = "0" ]; then
    fail "One running instance tagged Name=bukka-api-1" "aws ec2 run-instances ... --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bukka-api-1}]'"
  else
    if [ "$N_INST" = "1" ]; then
      pass "One running instance tagged Name=bukka-api-1"
    else
      fail "One running instance tagged Name=bukka-api-1" "Found $N_INST. Terminate the extras (did you run your script twice?)."
    fi
    INSTV=$(SG_IDS="$SG_IDS" python3 -c '
import json, os, sys
i = json.load(sys.stdin)[0]
print(i["InstanceId"])
print(i.get("InstanceType", "?"))
sgs = [g["GroupId"] for g in i.get("SecurityGroups", [])]
print("ok" if set(sgs) & set(os.environ["SG_IDS"].split()) else (" ".join(sgs) or "none"))
arn = (i.get("IamInstanceProfile") or {}).get("Arn", "")
print("ok" if arn.endswith("/bukka-api-server-profile") else (arn or "none"))' <<< "$INST_JSON" 2>/dev/null)
    { read -r INST_ID; read -r INST_TYPE; read -r INST_SG; read -r INST_IP; } <<< "$INSTV"
    [ "${INST_TYPE:-}" = "t3.micro" ] && pass "bukka-api-1 is a t3.micro" || fail "bukka-api-1 is a t3.micro" "It's a ${INST_TYPE:-?}."
    [ "${INST_SG:-}" = "ok" ] && pass "bukka-api-1 uses bukka-web-sg" \
      || fail "bukka-api-1 uses bukka-web-sg" "Its security groups: ${INST_SG:-?}. Launch it with --security-group-ids <bukka-web-sg id>."
    [ "${INST_IP:-}" = "ok" ] && pass "bukka-api-1 has the $PROFILE instance profile" \
      || fail "bukka-api-1 has the $PROFILE instance profile" "Its profile: ${INST_IP:-none}. Launch it with --iam-instance-profile Name=$PROFILE."
    UD=$(aws ec2 describe-instance-attribute --instance-id "$INST_ID" --attribute userData --query 'UserData.Value' --output text 2>/dev/null)
    UD_TEXT=$(python3 -c 'import base64,sys; s=sys.stdin.read().strip(); print(base64.b64decode(s).decode("utf-8","replace") if s and s!="None" else "")' <<< "${UD:-}" 2>/dev/null || true)
    if printf '%s' "$UD_TEXT" | grep -E "$KEY_RE|$SECRET_RE" >/dev/null; then
      fail "No access keys in bukka-api-1's user data" "The user data has an AWS key in it. The instance profile is how the server gets access."
    else
      pass "No access keys in bukka-api-1's user data"
    fi
  fi

  # --- Billing alarm ----------------------------------------------------------
  echo; echo "No surprise bills"
  TOPIC=$(aws sns list-topics --query 'Topics[].TopicArn' --output text 2>/dev/null | tr '\t' '\n' | grep ':bukka-billing-alerts$' | head -1)
  if [ -z "$TOPIC" ]; then
    fail "SNS topic bukka-billing-alerts exists" "aws sns create-topic --name bukka-billing-alerts"
  else
    pass "SNS topic bukka-billing-alerts exists"
    EMAILS=$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC" --query "Subscriptions[?Protocol=='email'].Endpoint" --output text 2>/dev/null)
    if echo "$EMAILS" | grep -q '@'; then pass "An email address is subscribed to bukka-billing-alerts"; else
      fail "An email address is subscribed to bukka-billing-alerts" "aws sns subscribe --topic-arn $TOPIC --protocol email --notification-endpoint you@example.com"; fi
  fi
  ALARM_JSON=$(aws cloudwatch describe-alarms --alarm-names bukka-spend-above-zero --query 'MetricAlarms[0]' --output json 2>/dev/null)
  if none "$ALARM_JSON"; then
    fail "CloudWatch alarm bukka-spend-above-zero exists" "aws cloudwatch put-metric-alarm --alarm-name bukka-spend-above-zero ... (see the ticket)"
  else
    pass "CloudWatch alarm bukka-spend-above-zero exists"
    ALV=$(TOPIC="$TOPIC" python3 -c '
import json, os, sys
a = json.load(sys.stdin)
dims = {d.get("Name"): d.get("Value") for d in a.get("Dimensions", [])}
print("ok" if a.get("Namespace") == "AWS/Billing" and a.get("MetricName") == "EstimatedCharges" and dims.get("Currency") == "USD"
      else "%s %s %s" % (a.get("Namespace"), a.get("MetricName"), dims))
print("ok" if a.get("ComparisonOperator") == "GreaterThanThreshold" and float(a.get("Threshold", -1)) == 0
      else "%s %s" % (a.get("ComparisonOperator"), a.get("Threshold")))
t = os.environ["TOPIC"]
print("ok" if t and t in a.get("AlarmActions", []) else (" ".join(a.get("AlarmActions", [])) or "nothing"))' <<< "$ALARM_JSON" 2>/dev/null)
    { read -r AL_METRIC; read -r AL_THRESH; read -r AL_ACTION; } <<< "$ALV"
    [ "${AL_METRIC:-}" = "ok" ] && pass "The alarm watches AWS/Billing EstimatedCharges in USD" \
      || fail "The alarm watches AWS/Billing EstimatedCharges in USD" "It watches: ${AL_METRIC:-?}. Use --namespace AWS/Billing --metric-name EstimatedCharges --dimensions Name=Currency,Value=USD."
    [ "${AL_THRESH:-}" = "ok" ] && pass "The alarm fires when charges go above 0" \
      || fail "The alarm fires when charges go above 0" "It has: ${AL_THRESH:-?}. Use --comparison-operator GreaterThanThreshold --threshold 0."
    [ "${AL_ACTION:-}" = "ok" ] && pass "The alarm notifies bukka-billing-alerts" \
      || fail "The alarm notifies bukka-billing-alerts" "It notifies: ${AL_ACTION:-?}. Use --alarm-actions <topic arn>."
  fi
fi

# --- Your script and your repo ----------------------------------------------------
echo; echo "Your script and your repo"
if [ -f "$S" ]; then
  pass "$S exists"
  bash -n "$S" 2>/dev/null && pass "$S is valid bash" || fail "$S is valid bash" "bash -n $S shows the error."
  if grep -qE 'create-access-key' "$S"; then
    fail "$S doesn't create access keys" "Remove aws iam create-access-key: the server gets access from its role."
  else
    pass "$S doesn't create access keys"
  fi
else
  fail "$S exists" "Save every command you ran, in order, in $S."
fi
if git grep -qIE "$KEY_RE|$SECRET_RE" 2>/dev/null || { [ -f "$S" ] && grep -qE "$KEY_RE|$SECRET_RE" "$S"; }; then
  fail "No AWS access keys in your files" "git grep -nE '$KEY_RE' shows where. Delete it, and treat that key as leaked."
else
  pass "No AWS access keys in your files"
fi
if git log --all -p 2>/dev/null | grep -E "$KEY_RE|$SECRET_RE" >/dev/null; then
  fail "No AWS access keys in your commit history" "A key is in an old commit. Deleting the file isn't enough: the key is leaked. Ask your lead for help."
else
  pass "No AWS access keys in your commit history"
fi

# --- Branch and identity --------------------------------------------------------
echo
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ "$BRANCH" == buk-38-* ]]; then pass "On a BUK-38 branch ($BRANCH)"; else
  fail "On a BUK-38 branch" "You're on '$BRANCH'."; fi
if [ -n "$GH_USER" ]; then
  pass "GitHub recognises your SSH key as @$GH_USER"
else
  fail "GitHub recognises your SSH key" "Run: ssh-add, then try again (see BUK-14)."
fi
if [ -n "$GH_USER" ] && [ -n "$BUCKET" ] && [ "$BUCKET" != "bukka-menu-photos-$(lc "$GH_USER")" ]; then
  fail "The bucket is named after you" "Expected bukka-menu-photos-$(lc "$GH_USER"), found $BUCKET."
fi

mkdir -p artifacts
{
  echo "# $TICKET audit"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "github_user: ${GH_USER:-unknown}"
  echo "branch: $BRANCH"
  echo "script_sha256: $( [ -f "$S" ] && { sha256sum "$S" 2>/dev/null || shasum -a 256 "$S"; } | cut -d' ' -f1)"
  echo "fails: $FAILS"
  echo
  printf '%s\n' "${RESULTS[@]}"
} > "$OUT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All checks passed. Wrote $OUT."
  echo "Next: git add $S $OUT && git commit -m \"feat: give the API server read-only access to menu photos (BUK-38)\""
  exit 0
else
  echo "$FAILS check(s) failed. Fix the items marked ✗ and run this again."
  exit 1
fi
