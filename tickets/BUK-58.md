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

Bukka now runs as separate pieces (see the architecture in the top-level
`README.md` and `api/README.md`):

```
browser ──► web (Nginx) ─┬── /api/restaurants*            ─► menu-service ──┐
                         └── /api/orders*, /api/kitchen*  ─► order-service ─┼─► db (PostgreSQL)
                                                                 │          │
                                                                 ▼          │
                                                               redis ─► worker
```

`menu-service`, `order-service` and `worker` are all the same Python package
in `api/`, started with different commands.

### Build the images

1. Add a `Dockerfile` for each part of the app: `web/Dockerfile`,
   `api/Dockerfile`, and one for the worker if it needs its own. The menu
   service, the order service and the worker use the same code and
   dependencies, so they can all reuse the API image with a different
   command. Say which you chose and why in your design note.
2. Every Dockerfile is a **multi-stage build**: a build stage that installs
   tools and dependencies, and a small final stage that only has what's
   needed to run.
   - `web`: build the React app with Node, then copy `dist/` into an Nginx
     image. The final image has no Node in it.
   - `api` (and the worker, if it has its own): install dependencies in the
     build stage and copy only the result into a slim Python runtime.
3. **Keep the final images small:**
   - `web` is under **60 MB**
   - `api` (and worker) are each under **250 MB**

   Check with `docker image ls`.
4. **No container runs as root.** Each final stage sets a `USER` that isn't
   root (a name or a numeric ID like `10001`). `docker run --rm <image> id`
   must not print `uid=0`.
5. Each Dockerfile has a **`HEALTHCHECK`**, so `docker ps` can tell a
   running container from a working one.
6. Add a `.dockerignore` next to each Dockerfile so `node_modules`, `.venv`,
   local databases and `.git` never end up in an image.

### Run the whole stack with Docker Compose

7. Add `compose.yaml` at the repo root with these six services:

   | Service | What it runs |
   |---|---|
   | `web` | Nginx serving the built React app and forwarding `/api/` to the right service |
   | `menu-service` | `python -m bukka_api.services.menu` on port 8080: restaurants and menus |
   | `order-service` | `python -m bukka_api.services.orders` on port 8080: orders and the kitchen screen |
   | `worker` | `python -m bukka_api.worker`: the background worker |
   | `redis` | Redis 7, the worker's queue |
   | `db` | PostgreSQL 16 |

   You may add one-shot helpers (for example a `migrate` service that runs
   the migrations and exits).
8. **Nginx sends each request to the service that owns it:**
   `/api/restaurants*` to `menu-service:8080`, and `/api/orders*` and
   `/api/kitchen*` to `order-service:8080`. Everything else is the React
   app. Put your Nginx config next to `web/Dockerfile` (for example
   `web/nginx.conf`).
9. All six services join one network called `bukka-net` and find each
   other by service name (for example `db:5432`, `redis:6379`,
   `order-service:8080`). No IP addresses anywhere.
10. **Only `web` is published to your machine**, on
    `http://localhost:8000`. The services, worker, Redis and PostgreSQL are
    reachable inside the network only.
11. **Healthchecks on every service:**
    - `menu-service` and `order-service` check `/healthz`
    - `worker` checks its own `/healthz` (read the worker's README to find
      the port)
    - `db` uses `pg_isready`
    - `redis` uses `redis-cli ping`
    - `web` checks that Nginx answers

    Use `depends_on` with `condition: service_healthy` so the menu service
    waits for the database, the order service and the worker wait for the
    database and Redis, and `web` waits for both services.
12. **The database survives a restart.** PostgreSQL data lives in a named
    volume. Place an order, run `docker compose down` (without `-v`) and
    `docker compose up -d`, and the order is still there.
13. **Configuration comes from environment variables**, not from values baked
    into an image or written into `compose.yaml`. The database password
    lives in a `.env` file that is in `.gitignore`, and `compose.yaml` reads
    it with `${POSTGRES_PASSWORD}`. Commit a `.env.example` with safe
    placeholder values. This repo is public: never commit a real password.
14. **A fresh start just works.** On a clean machine,
    `cp .env.example .env && docker compose up -d --build` runs the database
    migrations once, loads the demo restaurants and brings every service to
    `healthy` (check with `docker compose ps`).

### Prove it works end to end

15. Open `http://localhost:8000`, order some jollof, and watch the worker
    move it from `placed` to `delivered` on the kitchen screen without
    anyone clicking. `docker compose logs worker` shows a
    `kitchen_ticket_printed` line for your order.

### Submit

16. Work on a branch called `buk-58-containerise-app`, created from
    `upstream/apprentice/<your-github-username>`.
17. With the stack still running, run `bash scripts/verify/buk-58.sh`. It
    places a test order, restarts the stack once to check the order
    survives, and writes `artifacts/buk-58-containers.txt`.
18. Commit your Dockerfiles, `.dockerignore` files, Nginx config,
    `compose.yaml`, `.env.example`, `.gitignore` and the audit file, push,
    and open a pull request into `apprentice/<your-github-username>`,
    titled `feat: containerise the web app, API and worker (BUK-58)`. The
    `verify` check builds your images and starts your stack from scratch,
    with `.env` copied from `.env.example`, and runs the same checks again.
19. In the pull request description, add a short **design note** under
    **Anything the reviewer should look at closely?** (a few sentences each
    is plenty):
    - the size of each final image, and one thing you did to make it smaller
    - whether the worker and the two services share one image, and why
    - how the migrations run on start-up, and what would happen if both
      services (or two copies of one) ran them at the same time

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
  ready". Without them, the services start before PostgreSQL accepts
  connections and crash on their first query.
- **Why a named volume?** Containers are meant to be thrown away. Anything
  written inside a container is gone when it's removed. Orders must not be.
- **Why split menu and orders?** Everyone browses menus; far fewer people
  place orders. Separate services can be scaled, deployed and restarted on
  their own: a bad deploy of the menu page doesn't stop orders reaching
  the kitchen. Nginx is what makes the split invisible to the browser.
- **Nginx as a normal user** can't listen on port 80 (ports below 1024 need
  root). The `nginxinc/nginx-unprivileged` image listens on 8080 instead, and
  Compose can map `8000:8080`.
- **Migrations:** run `alembic upgrade head` (from the `api/` folder, where
  `alembic.ini` and `migrations/` live) and `python -m bukka_api.seed`
  once, before the services start. A one-shot service plus
  `condition: service_completed_successfully` is one tidy way.
- Read the worker's code and `api/README.md` on `main` first: they tell you
  how to start each piece and which environment variables it needs
  (`DATABASE_URL` for all of them, `REDIS_URL` for the order service and
  the worker). The services use a PostgreSQL URL like
  `postgresql+psycopg://<user>:<password>@db:5432/<database>`.
- Useful commands: `docker build -t bukka-api ./api`, `docker image ls`,
  `docker history <image>`, `docker compose up -d --build`,
  `docker compose ps`, `docker compose logs -f <service>`,
  `docker compose exec db psql -U bukka`, `docker compose down`.
- If Docker won't run on your machine, use a GitHub Codespace on your fork:
  Docker is already installed there.
