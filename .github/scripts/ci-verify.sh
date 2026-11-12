#!/usr/bin/env bash
# CI gate for every pull request into alamz-tech/bukka.
# Inputs (env): PR_AUTHOR, PR_TITLE, PR_BODY, BASE_REF, HEAD_REF.
# Runs on the merge commit GitHub builds for the PR; HEAD^1 is the base.

set -uo pipefail

MAINTAINERS="husseinalamutu"
FAILS=0

ok()   { echo "✓ $1"; }
bad()  { echo "::error::$1"; echo "✗ $1"; FAILS=$((FAILS + 1)); }
lc()   { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

AUTHOR_LC=$(lc "$PR_AUTHOR")
echo "PR by @$PR_AUTHOR: $HEAD_REF → $BASE_REF"
echo "Title: $PR_TITLE"
echo

for m in $MAINTAINERS; do
  if [ "$AUTHOR_LC" = "$(lc "$m")" ]; then
    echo "Maintainer pull request: skipping apprentice checks."
    exit 0
  fi
done

CHANGED=$(git diff --name-only HEAD^1 HEAD)
echo "Files changed:"
echo "$CHANGED" | sed 's/^/  /'
echo

CONVENTIONAL='^(feat|fix|chore|docs|ci|refactor|test|perf|build)(\([a-z0-9-]+\))?!?: .+ \((BUK-[0-9]+)\)$'

if [ "$BASE_REF" = "main" ]; then
  # Only joining the team (own team file) and shared runbooks may target main.
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      team/*.md)
        name=$(basename "$f" .md)
        if [ "$(lc "$name")" = "$AUTHOR_LC" ]; then
          ok "$f is your own team file"
          if [ ! -s "$f" ]; then
            bad "$f is empty. Fill in the template from team/README.md."
          elif ! grep -qi "@$PR_AUTHOR" "$f"; then
            bad "$f should include your GitHub handle (@$PR_AUTHOR), as in the template."
          fi
        else
          bad "$f: your team file must be named team/$PR_AUTHOR.md (your GitHub username)."
        fi
        ;;
      runbooks/*.md)
        ok "$f is a runbook"
        ;;
      *)
        bad "$f: pull requests into main may only add your team file or runbooks. Ticket work goes into apprentice/$PR_AUTHOR."
        ;;
    esac
  done <<< "$CHANGED"

elif [[ "$BASE_REF" == apprentice/* ]]; then
  OWNER="${BASE_REF#apprentice/}"
  if [ "$(lc "$OWNER")" = "$AUTHOR_LC" ]; then
    ok "Targets your own branch ($BASE_REF)"
  else
    bad "This pull request targets $BASE_REF, which belongs to @$OWNER. Change the base branch to apprentice/$PR_AUTHOR."
  fi

  if [[ "$HEAD_REF" =~ ^buk-([0-9]+)-[a-z0-9-]+$ ]]; then
    BRANCH_TICKET="BUK-${BASH_REMATCH[1]}"
    ok "Branch name $HEAD_REF follows buk-<number>-<description>"
  else
    BRANCH_TICKET=""
    bad "Branch '$HEAD_REF' should look like buk-<number>-<short-description>, e.g. buk-14-workstation-setup."
  fi

  if [[ "$PR_TITLE" =~ $CONVENTIONAL ]]; then
    TITLE_TICKET="${BASH_REMATCH[3]}"
    ok "Title follows Conventional Commits and names $TITLE_TICKET"
    if [ -n "$BRANCH_TICKET" ] && [ "$TITLE_TICKET" != "$BRANCH_TICKET" ]; then
      bad "Title names $TITLE_TICKET but the branch is for $BRANCH_TICKET."
    fi
  else
    bad "Title should look like 'chore: set up secure workstation and SSH access (BUK-14)': a type, a colon, a summary, then the ticket in brackets."
  fi

  if [ -n "$BRANCH_TICKET" ]; then
    CHECK=".github/scripts/checks/$(lc "$BRANCH_TICKET").sh"
    if [ -f "$CHECK" ]; then
      echo
      echo "== Ticket checks for $BRANCH_TICKET =="
      if ! PR_AUTHOR="$PR_AUTHOR" bash "$CHECK"; then
        FAILS=$((FAILS + 1))
      fi
    else
      echo "No automated checks for $BRANCH_TICKET yet; review only."
    fi
  fi

else
  bad "Pull requests must target main (joining the team) or apprentice/$PR_AUTHOR (ticket work), not $BASE_REF."
fi

# --- The description ------------------------------------------------------
# A reviewer reads it first: which ticket, what changed, how you tested it.
echo
echo "== Pull request description =="
if [[ "$BASE_REF" == apprentice/* ]]; then
  DESC_TICKET="${BRANCH_TICKET:-}"; DESC_OPTS=""
else
  # Joining the team is BUK-14; a runbook PR names its ticket in the title.
  if [[ "$PR_TITLE" =~ \((BUK-[0-9]+)\)$ ]]; then DESC_TICKET="${BASH_REMATCH[1]}"
  elif echo "$CHANGED" | grep '^team/' >/dev/null; then DESC_TICKET="BUK-14"
  else DESC_TICKET=""; fi
  DESC_OPTS="--no-checklist"
fi
if ! PR_BODY="${PR_BODY:-}" python3 .github/scripts/pr_description_check.py $DESC_TICKET $DESC_OPTS; then
  FAILS=$((FAILS + 1))
  echo "  Edit the description on GitHub (… menu → Edit). This check re-runs by itself; no new commit needed."
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "verify passed"
else
  echo "verify failed: fix the items marked ✗ above. Push for file changes; for the description, just edit it on GitHub."
  exit 1
fi
