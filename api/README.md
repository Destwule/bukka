# Bukka API

Python (FastAPI) code for restaurants, menus and orders, plus the background
worker. One package, several ways to run it:

| Process | Command | Routes / job |
|---|---|---|
| **API (monolith)** | `python -m bukka_api.main` | Every route below, in one process |
| **Menu service** | `python -m bukka_api.services.menu` | `/api/restaurants*` |
| **Order service** | `python -m bukka_api.services.orders` | `/api/orders*`, `/api/kitchen*` |
| **Worker** | `python -m bukka_api.worker` | Takes jobs off Redis and moves orders along |

The monolith is what you run on your laptop and what the Month 1 and 2
tickets use. From Month 3 Bukka runs as separate services (see
[Services](#services)). They all share one database and one schema.

| | |
|---|---|
| Port | `8080` (set `BUKKA_PORT`), for the monolith and each service |
| Listens on | `0.0.0.0`, every interface (set `BUKKA_HOST`) |
| Database | `DATABASE_URL`. Default `sqlite:///./bukka.db`; PostgreSQL in production, e.g. `postgresql+psycopg://bukka:<password>@<host>:5432/bukka` |
| Logs | One JSON line per request on stdout |
| Liveness | `GET /healthz`: the process is up |
| Readiness | `GET /readyz`: the database answers (returns `503` when it doesn't) |
| Job queue | `REDIS_URL`, e.g. `redis://redis:6379/0`. Optional: when it's not set, nothing is queued and the API works exactly as before |

## Run it

```bash
python3 -m venv .venv
.venv/bin/pip install -e '.[dev]'
.venv/bin/alembic upgrade head        # create or upgrade the schema
.venv/bin/python -m bukka_api.seed    # demo restaurants (safe to repeat)
.venv/bin/python -m bukka_api.main    # serve on :8080
```

Or from the repo root: `make setup` then `make api-run`.

## Endpoints

| Method | Path | What it does |
|---|---|---|
| GET | `/api/restaurants` | List restaurants |
| GET | `/api/restaurants/{slug}/menu` | A restaurant and its dishes |
| POST | `/api/orders` | Place an order |
| GET | `/api/orders/{id}` | Order details and status |
| GET | `/api/kitchen/orders` | Orders not yet delivered, oldest first |
| PATCH | `/api/orders/{id}/status` | Move an order to its next status |

Interactive docs at `/docs` while it's running.

Order statuses always move forward one step at a time:
`placed → preparing → out_for_delivery → delivered`.

Prices are integers in kobo (₦1 = 100 kobo) and are always taken from the
database, never from the client.

## Log format

```json
{"ts": "2026-11-07T10:42:31.331+00:00", "level": "info", "msg": "request", "method": "GET", "path": "/api/restaurants", "status": 200, "response_time_ms": 4, "client": "10.0.0.5"}
```

Business events use the same shape: `order_placed`, `job_enqueued`,
`order_status`, `startup`, `shutdown`. The `startup` line says which
`service` started (`api`, `menu` or `orders`) and whether the queue is on.

## Services

```
browser ──► web (Nginx) ──┬── /                    static React app
                          ├── /api/restaurants* ─► menu service :8080 ──┐
                          └── /api/orders*      ─► order service :8080 ─┼─► PostgreSQL
                              /api/kitchen*            │                │
                                                       ▼ LPUSH job      │
                                                     Redis ◄── BRPOP ── worker
```

- The **menu service** only reads restaurants and menus. It's busy (every
  customer browses) and easy to scale.
- The **order service** writes orders. When an order is placed it saves it,
  then pushes an `order_placed` job onto Redis if `REDIS_URL` is set. If
  Redis is down the order is still saved (an `enqueue_failed` line is
  logged) and `/readyz` reports `"queue": "down"` without failing.
- Each service has its own `/healthz` and `/readyz`, and returns `404` for
  the other service's routes.
- Database migrations (`alembic upgrade head`) and the seed are run once,
  separately, before the services start. Don't run them from every replica
  at the same time.

## The worker

`python -m bukka_api.worker` waits for jobs on the Redis list `bukka:jobs`.
For each `order_placed` job it:

1. logs a `kitchen_ticket_printed` line with the dishes,
2. moves the order `placed → preparing`, then one step every
   `WORKER_STEP_SECONDS` to `delivered`,
3. logs `notification_sent` when it's delivered.

It only moves an order from the status it expects, so if someone in the
kitchen clicks first, the worker leaves that order alone. Later steps wait in
the Redis sorted set `bukka:jobs:delayed`, so a restarted worker carries on
where the last one stopped.

| Variable | Default | |
|---|---|---|
| `DATABASE_URL` | `sqlite:///./bukka.db` | Same database as the services |
| `REDIS_URL` | (required) | The worker exits with an error without it |
| `WORKER_STEP_SECONDS` | `5` | Seconds between status changes |
| `WORKER_HEALTH_PORT` | `8081` | `GET /healthz` (the job loop is running; `503` if it's stuck for 30s) and `GET /readyz` (Redis and the database answer). `0` turns it off |

It also keeps a heartbeat key `bukka:worker:heartbeat:<hostname>` in Redis
(expires after 30s) and the last 100 things it did in `bukka:events`.
On `SIGTERM` it finishes the current job and stops.

Worker log lines:

```json
{"ts": "...", "level": "info", "msg": "kitchen_ticket_printed", "worker": "a1b2c3", "order_id": 42, "customer": "Ada", "dishes": ["2 x Jollof Rice & Chicken"]}
{"ts": "...", "level": "info", "msg": "order_status", "worker": "a1b2c3", "order_id": 42, "status": "preparing"}
```

## Run the services and the worker on your machine

You need a Redis server for the worker (`brew install redis` or
`docker run -p 6379:6379 redis:7`). In separate terminals, from `api/`:

```bash
BUKKA_PORT=8081 .venv/bin/python -m bukka_api.services.menu
BUKKA_PORT=8082 REDIS_URL=redis://127.0.0.1:6379/0 .venv/bin/python -m bukka_api.services.orders
REDIS_URL=redis://127.0.0.1:6379/0 .venv/bin/python -m bukka_api.worker
```

Or from the repo root: `make menu-run`, `make orders-run`, `make worker-run`.

## Tests

```bash
.venv/bin/pytest -q
```

Redis is faked in the tests (`fakeredis`). To also run the end-to-end worker
test against a real Redis, set `BUKKA_TEST_REDIS_URL=redis://127.0.0.1:6379/15`.

## Changing the schema

Edit `bukka_api/models.py`, then:

```bash
.venv/bin/alembic revision --autogenerate -m "describe the change"
.venv/bin/alembic upgrade head
```

Review the generated file in `migrations/versions/` before committing it.
