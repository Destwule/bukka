"""Menu service: restaurants and menus (read-only, cache-friendly).

Routes: GET /api/restaurants, GET /api/restaurants/{slug}/menu,
        GET /healthz, GET /readyz
Run:    python -m bukka_api.services.menu     (listens on BUKKA_PORT, default 8080)
Needs:  DATABASE_URL
"""

from bukka_api.factory import create_app, serve

app = create_app(parts=("menu",), service="menu")


def run() -> None:
    serve("bukka_api.services.menu:app")


if __name__ == "__main__":
    run()
