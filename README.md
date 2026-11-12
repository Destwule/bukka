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
api/              The Bukka API (Python, FastAPI): restaurants, menus, orders
web/              The Bukka web app (React): customer site and kitchen screen
tickets/          The tickets assigned to the team, one file per ticket
scripts/verify/   Scripts you run on your machine to check your work
labs/             Environments for tickets that need something broken on purpose
team/             One file per team member
runbooks/         What to do when something breaks (the team writes these)
.github/          Pull request template, CI checks and automation
```

## Running Bukka on your machine

You need Python 3.10+ and Node.js 20+.

```bash
make setup      # install, create the database, load demo restaurants, build the web app
make api-run    # API on http://localhost:8080
make web-dev    # in a second terminal: web app on http://localhost:5173
```

Open http://localhost:5173, order some jollof, then watch it on the kitchen
screen at http://localhost:5173/#/kitchen.

That runs the API as one process (the "monolith"), which is all you need
for most tickets. In production Bukka is split into services:

```
                         ┌── /                  static files (React app)
browser ──► web (Nginx) ─┼── /api/restaurants* ─► menu-service  :8080 ──┐
                         └── /api/orders*,      ─► order-service :8080 ──┼──► PostgreSQL
                             /api/kitchen*              │                │
                                                        ▼ order_placed   │
                                                      Redis ──► worker ──┘
```

| Piece | What it does | Run it with |
|---|---|---|
| web | Nginx serving the built React app, forwarding `/api/` to the services | `web/dist` + Nginx |
| menu-service | Restaurants and menus | `python -m bukka_api.services.menu` |
| order-service | Orders and the kitchen screen; queues a job for each new order | `python -m bukka_api.services.orders` |
| worker | Prints the kitchen ticket and moves orders to `delivered` | `python -m bukka_api.worker` |
| Redis | The job queue between the order service and the worker | |
| PostgreSQL | Restaurants, menus and orders, shared by the services | |

All the Python pieces come from the same `api/` package. Without Redis
(`REDIS_URL` unset) nothing is queued and the kitchen moves orders by hand.

Details: [api/README.md](api/README.md) and [web/README.md](web/README.md).

## Getting help

When you ask for help, include:

- what you were trying to do
- the exact command you ran
- what you expected, and what happened instead (paste the error or a
  screenshot)

If you've been stuck for 30 minutes, ask. That's how it works on every good
team.

## License

Bukka is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE.md).
Copyright 2026 Alamz Tech Ltd.

- **You may** use, copy and change it for learning, personal projects, research
  and teaching, including in your own fork and your portfolio.
- **You may not** use it, or anything built from it, for commercial purposes:
  for example selling it, running it as a paid service, or using the tickets
  and labs in a paid course or bootcamp.

For commercial use, contact Alamz Tech at info@alamztech.com.
