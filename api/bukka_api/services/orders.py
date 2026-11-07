"""Order service: placing and tracking orders, and the kitchen screen.

Routes: POST /api/orders, GET /api/orders/{id}, PATCH /api/orders/{id}/status,
        GET /api/kitchen/orders, GET /healthz, GET /readyz
Run:    python -m bukka_api.services.orders   (listens on BUKKA_PORT, default 8080)
Needs:  DATABASE_URL; REDIS_URL to hand new orders to the worker (optional)
"""

from bukka_api.factory import create_app, serve

app = create_app(parts=("orders",), service="orders")


def run() -> None:
    serve("bukka_api.services.orders:app")


if __name__ == "__main__":
    run()
