# Contributing to Bukka

This is how work moves from a ticket to your production branch.

## 1. One-time setup

1. **Fork** `alamz-tech/bukka` to your GitHub account (the **Fork** button,
   top right).
2. **Clone your fork over SSH** (BUK-14 sets up your SSH key):
   ```bash
   git clone git@github.com:<your-username>/bukka.git
   cd bukka
   ```
3. **Add this repository as `upstream`**, so you can pull in new work from
   the team:
   ```bash
   git remote add upstream https://github.com/alamz-tech/bukka.git
   git fetch upstream
   ```

After this, `origin` is your fork and `upstream` is the team's repository.

## 2. Branches

| Branch | Lives in | What it's for |
|---|---|---|
| `main` | upstream | The team's shared base: tickets, scripts, the app. Maintained by the engineering lead. |
| `apprentice/<username>` | upstream | Your production branch. Created for you when you join the team. |
| `buk-<number>-<short-description>` | your fork | Your work on one ticket, e.g. `buk-21-menu-page-fails` |

Always start ticket work from the latest version of your production branch:

```bash
git fetch upstream
git checkout -b buk-21-menu-page-fails upstream/apprentice/<username>
```

## 3. Commits

We use [Conventional Commits](https://www.conventionalcommits.org/). Start
each message with a type, and mention the ticket at the end:

```
feat: serve the web app through nginx (BUK-27)
fix: bind the API to all interfaces (BUK-21)
chore: set up secure workstation and SSH access (BUK-14)
docs: add runbook for 502 errors (BUK-27)
```

Common types: `feat` (new behaviour), `fix` (a bug), `chore` (setup and
maintenance), `docs`, `ci`, `refactor`, `test`.

Small commits with clear messages are easier to review than one big one.

## 4. Pull requests

1. Push your branch to your fork: `git push -u origin buk-21-menu-page-fails`
2. Open a pull request on GitHub:
   - **base repository:** `alamz-tech/bukka`
   - **base branch:** `apprentice/<your-username>`. Never `main`, and never
     someone else's branch.
   - **compare:** your ticket branch
3. Title it like a commit: `fix: bind the API to all interfaces (BUK-21)`
4. Fill in the pull request template.

Then:

- The **`verify`** check runs automatically. If it fails, read its output,
  fix the problem and push again. The pull request updates itself.
- A **teammate reviews it.** Reply to every comment, either with a change or
  an explanation.
- When `verify` passes and the review is approved, the engineering lead
  merges it.

The only pull requests that target `main` are your joining-the-team pull
request in BUK-14, and fixes to shared files like runbooks.

## 5. Bringing in new work from the team

New tickets and app changes land on `main`. To bring them into your branch,
open a pull request from `upstream/main` into your branch, or ask the
engineering lead to sync it. Never rewrite history on a shared branch.

## 6. Reviewing a teammate's pull request

Good reviews are specific and kind:

- **Ask questions** rather than giving orders: "What happens if the port is
  already in use?"
- **Point to the exact line** and suggest the change.
- **Say what's good too.**
- **Approve** when you'd be comfortable with this running in production.
