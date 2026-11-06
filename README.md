# Bukka

Bukka is a food ordering platform. Customers browse local restaurants, order
dishes and follow their order from the kitchen to their door. Restaurants see
incoming orders on a kitchen screen.

This repository is where the Bukka platform team works. If you've just joined,
welcome. Start with **[Your first week](#your-first-week)**.

> Bukka is a fictional company used for the EarnWithDevOps Cloud & DevOps
> Apprenticeship. The work, the tools and the way we work are real.

---

## Your first week

1. Read this page and [CONTRIBUTING.md](CONTRIBUTING.md). They explain how
   work moves from a ticket to production.
2. Pick up your onboarding ticket, [BUK-14](tickets/BUK-14.md). It gets your
   machine set up and gives you your own branch in this repo.
3. Ask questions in the team channel early. Nobody expects you to know
   everything in week one.

## How we work

- **Tickets.** Every piece of work has a ticket on the board, with an ID like
  `BUK-21`. The ticket says why the work matters and what "done" means.
  Tickets live in [`tickets/`](tickets/).
- **Your branch.** Each engineer on the team has a long-lived branch,
  `apprentice/<your-github-username>`. Treat it as your production branch:
  nothing lands there without a pull request.
- **Forks and pull requests.** You don't push to this repository directly.
  You work in your own fork and open a pull request into your branch here.
- **Checks.** Every pull request runs the `verify` check. A pull request
  can't be merged until it passes.
- **Review.** Every pull request is reviewed by a teammate before it's
  merged. You'll also review other people's work. Reading code is half the
  job.

The full details are in [CONTRIBUTING.md](CONTRIBUTING.md).

## What's in this repository

```
tickets/          The tickets assigned to the team, one file per ticket
scripts/verify/   Scripts you run on your machine to check your work
team/             One file per team member
runbooks/         What to do when something breaks (the team writes these)
.github/          Pull request template, CI checks and automation
```

The Bukka application itself (web app, API, database and background worker)
arrives here as the team's work reaches it.

## Getting help

Post in the team channel with:

- what you were trying to do
- the exact command you ran
- what you expected, and what happened instead (paste the error or a
  screenshot)

If you've been stuck for 30 minutes, ask. That's how it works on every good
team.
