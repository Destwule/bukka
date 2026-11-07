# BUK-58: Containerise the web app, API and worker

| | |
|---|---|
| **Type** | Task |
| **Priority** | High |
| **Epic** | BUK-3 Containers and continuous delivery |
| **Month** | 3 |
| **Sprint** | 9 |
| **Reporter** | Hussein Alamutu (Product Manager & Lead DevOps Engineer) |
| **Assignee** | You |
| **Due** | End of Sprint 9 |

## Context

### Why this matters

At the last deploy, the API passed every test on a laptop and then fell over
on the server because of a different Python version and a missing system
library. The kitchen screen was blank for most of the 12 o'clock rush and
three restaurant partners called to ask if we'd gone down. "Works on my
machine" can't be how we ship food orders, especially now that Bukka is
growing into several services.

### What I need from you

- The app now has more moving parts on `main`: separate **menu** and
  **order** services, a **worker** that takes jobs off a **Redis** queue, and
  PostgreSQL. You don't write that code; you package and run it.
- Every part built into a small, non-root image.
- One command that starts the whole stack the same way on any laptop, with
  the data surviving a restart and no secrets in the repo.

— Hussein Alamutu, Product Manager & Lead DevOps Engineer

## Acceptance criteria

### Build the images

1. Add a `Dockerfile` for each part of the app: `web/Dockerfile`,
   `api/Dockerfile`, and one for the worker. If the worker uses the same
   code and dependencies as the API, it can reuse the API image with a
   different command. Say which you chose and why in your design note.
2. Every Dockerfile is a **multi-stage build**: a build stage that installs
   tools and dependencies, and a small final stage that only has what's
   needed to run.
   - `web`: build the React app with Node, then copy `dist/` into an Nginx
     image. The final image has no Node in it.
   - `api` and worker: install dependencies in the build stage and copy only
     the result into a slim Python runtime.
3. **Keep the final images small:**
   - `web` is under **60 MB**
   - `api` and worker are each under **250 MB**

   Check with `docker image ls`.
4. **No container runs as root.** Each final stage sets a `USER` that isn't
   root (a name or a numeric ID like `10001`). `docker run --rm <image> id`
   must not print `uid=0`.
5. Add a `.dockerignore` next to each Dockerfile so `node_modules`, `.venv`,
   local databases and `.git` never end up in an image.

### Run the whole stack with Docker Compose

6. Add `compose.yaml` at the repo root with five services:

   | Service | What it runs |
   |---|---|
   | `web` | Nginx serving the built React app and forwarding `/api/` to `api` |
   | `api` | The Bukka API on port 8080 |
   | `worker` | The background worker |
   | `redis` | Redis 7, the worker's queue |
   | `db` | PostgreSQL 16 |

7. All five services join one network called `bukka-net` and find each
   other by service name (for example `db:5432`, `redis:6379`, `api:8080`).
   No IP addresses anywhere.
8. **Only `web` is published to your machine**, on
   `http://localhost:8000`. The API, worker, Redis and PostgreSQL are
   reachable inside the network only.
9. **Healthchecks:**
   - `api` checks `/healthz`
   - `db` uses `pg_isready`
   - `redis` uses `redis-cli ping`
   - `web` checks that Nginx answers

   Use `depends_on` with `condition: service_healthy` so the API waits for
   the database and Redis, and `web` waits for the API.
10. **The database survives a restart.** PostgreSQL data lives in a named
    volume. Place an order, run `docker compose down` (without `-v`) and
    `docker compose up -d`, and the order is still there.
11. **Configuration comes from environment variables**, not from values baked
    into the image. Commit a `.env.example` with safe placeholder values and
    make sure your real `.env` is in `.gitignore`. This repo is public: never
    commit a real password.
12. **A fresh start just works.** On a clean machine,
    `cp .env.example .env && docker compose up -d --build` runs the database
    migrations, loads the demo restaurants and brings every service to
    `healthy` (check with `docker compose ps`).

### Prove it works end to end

13. Open `http://localhost:8000`, order some jollof, and watch the worker
    move it from `placed` towards `delivered` on the kitchen screen without
    anyone clicking. `docker compose logs worker` shows it picking up the
    job.

### Submit

14. Work on a branch called `buk-58-containerise-app`, created from
    `upstream/apprentice/<your-github-username>`.
15. With the stack still running, run `bash scripts/verify/buk-58.sh`. It
    writes `artifacts/buk-58-containers.txt`.
16. Commit your Dockerfiles, `.dockerignore` files, `compose.yaml`,
    `.env.example` and the audit file, push, and open a pull request into
    `apprentice/<your-github-username>`, titled
    `feat: containerise the web app, API and worker (BUK-58)`.
17. In the pull request description, add a short **design note** (a few
    sentences each is plenty):
    - the size of each final image, and one thing you did to make it smaller
    - whether the worker has its own image or reuses the API image, and why
    - how the migrations run on start-up, and what happens if two copies of
      the API start at the same time

## Definition of done

- [ ] `docker compose up -d --build` on a clean clone brings every service to `healthy`
- [ ] An order placed in the browser is moved along by the worker
- [ ] `verify` passes on your pull request
- [ ] A teammate has reviewed and approved your pull request

## Notes

- **Why multi-stage builds?** Compilers, build tools and Node are needed to
  build the app, not to run it. Leaving them out makes the image smaller,
  faster to pull during a deploy, and gives an attacker less to work with.
- **Why not root?** If someone breaks into a container running as root,
  they are root inside it, and one container escape bug away from root on
  the host. A normal user limits the damage.
- **Why healthchecks?** "The container is running" doesn't mean "the app is
  ready". Without them, the API starts before PostgreSQL accepts
  connections and crashes on its first query.
- **Why a named volume?** Containers are meant to be thrown away. Anything
  written inside a container is gone when it's removed. Orders must not be.
- **Nginx as a normal user** can't listen on port 80 (ports below 1024 need
  root). The `nginxinc/nginx-unprivileged` image listens on 8080 instead, and
  Compose can map `8000:8080`.
- Read the worker's code and README on `main` first: they tell you how to
  start it and which environment variables it needs (it will at least need
  the database and Redis).
- Useful commands: `docker build -t bukka-api ./api`, `docker image ls`,
  `docker history <image>`, `docker compose up -d --build`,
  `docker compose ps`, `docker compose logs -f <service>`,
  `docker compose exec db psql -U bukka`, `docker compose down`.
- If Docker won't run on your machine, use a GitHub Codespace on your fork:
  Docker is already installed there.
