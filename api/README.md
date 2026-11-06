# Bukka API

Python (FastAPI) service for restaurants, menus and orders.

| | |
|---|---|
| Port | `8080` (set `BUKKA_PORT`) |
| Listens on | `0.0.0.0`, every interface (set `BUKKA_HOST`) |
| Database | `DATABASE_URL`. Default `sqlite:///./bukka.db`; PostgreSQL in production, e.g. `postgresql+psycopg://bukka:<password>@<host>:5432/bukka` |
| Logs | One JSON line per request on stdout |
| Liveness | `GET /healthz`: the process is up |
| Readiness | `GET /readyz`: the database answers (returns `503` when it doesn't) |

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

Business events use the same shape: `order_placed`, `order_status`,
`startup`, `shutdown`.

## Tests

```bash
.venv/bin/pytest -q
```

## Changing the schema

Edit `bukka_api/models.py`, then:

```bash
.venv/bin/alembic revision --autogenerate -m "describe the change"
.venv/bin/alembic upgrade head
```

Review the generated file in `migrations/versions/` before committing it.
