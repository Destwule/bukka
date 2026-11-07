"""Bukka API (the monolith): restaurants, menus and orders in one process.

Run locally:   python -m bukka_api.main   (or: uvicorn bukka_api.main:app --host 0.0.0.0 --port 8080)
Health checks: GET /healthz (process is up), GET /readyz (database reachable)

The same routes can also run as two services; see bukka_api/services/.
"""

from bukka_api.factory import create_app, serve

__all__ = ["app", "create_app", "run"]

app = create_app()


def run() -> None:
    """Entry point for `bukka-api` / `python -m bukka_api.main`."""
    serve("bukka_api.main:app")


if __name__ == "__main__":
    run()
