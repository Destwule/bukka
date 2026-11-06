#!/usr/bin/env bash
# BUK-14 verify: secure workstation and repository access.
# Run from the root of your clone of your fork:  bash scripts/verify/buk-14.sh
# Writes artifacts/workstation-audit.txt, which you commit in your pull request.

set -uo pipefail

TICKET="BUK-14"
OUT="artifacts/workstation-audit.txt"
FAILS=0
RESULTS=()

pass() { RESULTS+=("PASS  $1"); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      → %s\n' "$2"; FAILS=$((FAILS + 1)); }

perm_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo "?"; }

if [ ! -d .git ] || [ ! -f tickets/BUK-14.md ]; then
  echo "Run this from the root of your bukka clone (the folder with tickets/ in it)."
  exit 2
fi

echo "== $TICKET verify =="
echo

# 1. Not root
if [ "$(id -u)" -eq 0 ]; then
  fail "Working as a normal user" "You're root. Create a normal user and log in as them."
else
  pass "Working as a normal user ($(whoami))"
fi

# 2. That user can use sudo (member of an admin group)
GROUPS_NOW=" $(id -Gn) "
if [[ "$GROUPS_NOW" =~ \ (sudo|wheel|admin)\  ]]; then
  pass "User can use sudo (member of an admin group)"
elif sudo -n true 2>/dev/null; then
  pass "User can use sudo (allowed in sudoers)"
else
  fail "User can use sudo" "Add your user to the sudo group (Linux: sudo usermod -aG sudo $(whoami), then log out and in)."
fi

# 3. SSH key and permissions
KEY=""
for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa" "$HOME/.ssh/id_rsa"; do
  [ -f "$k" ] && { KEY="$k"; break; }
done
if [ -z "$KEY" ]; then
  fail "SSH private key exists" "Create one: ssh-keygen -t ed25519 -C \"<your email>\""
else
  KP=$(perm_of "$KEY")
  if [ "$KP" = "600" ] || [ "$KP" = "400" ]; then
    pass "Private key $(basename "$KEY") is readable only by you ($KP)"
  else
    fail "Private key is readable only by you" "$KEY is $KP. Run: chmod 600 $KEY"
  fi
  case "$KEY" in *id_ed25519) ;; *) RESULTS+=("NOTE  Key type is $(basename "$KEY"); ed25519 is preferred") ;; esac
fi
if [ -d "$HOME/.ssh" ]; then
  DP=$(perm_of "$HOME/.ssh")
  if [ "$DP" = "700" ]; then
    pass "~/.ssh is private (700)"
  else
    fail "~/.ssh is private" "~/.ssh is $DP. Run: chmod 700 ~/.ssh"
  fi
else
  fail "~/.ssh exists" "Create an SSH key first; that creates ~/.ssh."
fi

# 4. GitHub knows you by your key
GH_USER=""
GH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
if [[ "$GH_OUT" =~ Hi\ ([A-Za-z0-9-]+)! ]]; then
  GH_USER="${BASH_REMATCH[1]}"
  pass "GitHub recognises your SSH key as @$GH_USER"
else
  fail "GitHub recognises your SSH key" "Add your public key (~/.ssh/*.pub) at github.com/settings/keys. If it has a passphrase, run: ssh-add first. GitHub said: ${GH_OUT:0:120}"
fi

# 5. Git identity
GIT_NAME=$(git config user.name || true)
GIT_EMAIL=$(git config user.email || true)
if [ -n "$GIT_NAME" ] && [ -n "$GIT_EMAIL" ]; then
  pass "Git identity set ($GIT_NAME <$GIT_EMAIL>)"
else
  fail "Git identity set" "Run: git config --global user.name \"Your Name\" and git config --global user.email you@example.com"
fi

# 6. Cloned from your fork over SSH, with upstream set
ORIGIN=$(git remote get-url origin 2>/dev/null || true)
UPSTREAM=$(git remote get-url upstream 2>/dev/null || true)
if [[ "$ORIGIN" =~ ^git@github\.com:([A-Za-z0-9-]+)/bukka(\.git)?$ ]]; then
  ORIGIN_OWNER="${BASH_REMATCH[1]}"
  lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
  if [ -n "$GH_USER" ] && [ "$(lc "$ORIGIN_OWNER")" != "$(lc "$GH_USER")" ]; then
    fail "origin is your fork over SSH" "origin belongs to $ORIGIN_OWNER, but your SSH key is @$GH_USER."
  else
    pass "origin is your fork over SSH ($ORIGIN)"
  fi
elif [[ "$ORIGIN" == https://* ]]; then
  fail "origin is your fork over SSH" "origin uses HTTPS. Run: git remote set-url origin git@github.com:<you>/bukka.git"
else
  fail "origin is your fork over SSH" "origin is '$ORIGIN'. Clone your fork: git clone git@github.com:<you>/bukka.git"
fi
if [[ "$UPSTREAM" =~ github\.com[:/]alamz-tech/bukka(\.git)?$ ]]; then
  pass "upstream points to alamz-tech/bukka"
else
  fail "upstream points to alamz-tech/bukka" "Run: git remote add upstream https://github.com/alamz-tech/bukka.git"
fi

# 7. On the ticket branch
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ "$BRANCH" == buk-14-* ]]; then
  pass "On a BUK-14 branch ($BRANCH)"
else
  fail "On a BUK-14 branch" "You're on '$BRANCH'. Run: git checkout -b buk-14-workstation-setup upstream/apprentice/<you>"
fi

# Write the audit file
mkdir -p artifacts
{
  echo "# $TICKET workstation audit"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "github_user: ${GH_USER:-unknown}"
  echo "whoami: $(whoami)"
  echo "id: $(id)"
  echo "uname: $(uname -a)"
  echo "git_identity: $GIT_NAME <$GIT_EMAIL>"
  echo "origin: $ORIGIN"
  echo "upstream: $UPSTREAM"
  echo "branch: $BRANCH"
  echo "fails: $FAILS"
  echo
  printf '%s\n' "${RESULTS[@]}"
} > "$OUT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All checks passed. Wrote $OUT."
  echo "Next: git add $OUT && git commit -m \"chore: set up secure workstation and SSH access (BUK-14)\""
  exit 0
else
  echo "$FAILS check(s) failed. Fix the items marked ✗ and run this again."
  echo "($OUT was written so you can see the details, but don't commit it until everything passes.)"
  exit 1
fi
