"""Bukka API: restaurants, menus and orders.

Run locally:   uvicorn bukka_api.main:app --host 0.0.0.0 --port 8080
Health checks: GET /healthz (process is up), GET /readyz (database reachable)
"""

from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from bukka_api import __version__
from bukka_api.access_log import AccessLogMiddleware, log_event
from bukka_api.config import Settings, get_settings
from bukka_api.db import make_engine, make_session_factory, ping, session_scope
from bukka_api.models import ORDER_STATUSES, Dish, Order, OrderItem, Restaurant
from bukka_api.schemas import MenuOut, OrderIn, OrderOut, RestaurantOut, StatusIn


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    engine = make_engine(settings.database_url)
    sessions = make_session_factory(engine)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        log_event("info", "startup", version=__version__, environment=settings.environment)
        yield
        # Uvicorn stops accepting new connections and waits for in-flight
        # requests before we get here: a graceful shutdown.
        engine.dispose()
        log_event("info", "shutdown")

    app = FastAPI(title="Bukka API", version=__version__, lifespan=lifespan)
    app.add_middleware(AccessLogMiddleware)
    app.state.engine = engine

    def db():
        yield from session_scope(sessions)

    # --- Health -----------------------------------------------------------

    @app.get("/healthz", tags=["ops"])
    def healthz():
        """Liveness: the process is running. Never checks dependencies."""
        return {"status": "ok", "version": __version__}

    @app.get("/readyz", tags=["ops"])
    def readyz():
        """Readiness: safe to send traffic here (the database answers)."""
        if not ping(engine):
            return JSONResponse({"status": "unavailable", "database": "down"}, status_code=503)
        return {"status": "ready", "database": "up"}

    # --- Restaurants and menus -------------------------------------------

    @app.get("/api/restaurants", response_model=list[RestaurantOut], tags=["menu"])
    def list_restaurants(session: Session = Depends(db)):
        return session.scalars(select(Restaurant).order_by(Restaurant.name)).all()

    @app.get("/api/restaurants/{slug}/menu", response_model=MenuOut, tags=["menu"])
    def get_menu(slug: str, session: Session = Depends(db)):
        restaurant = session.scalars(
            select(Restaurant).where(Restaurant.slug == slug).options(selectinload(Restaurant.dishes))
        ).first()
        if restaurant is None:
            raise HTTPException(404, "Restaurant not found")
        return restaurant

    # --- Orders -----------------------------------------------------------

    def order_out(order: Order) -> OrderOut:
        return OrderOut(
            id=order.id,
            restaurant_id=order.restaurant_id,
            restaurant_name=order.restaurant.name,
            customer_name=order.customer_name,
            delivery_address=order.delivery_address,
            status=order.status,
            total_kobo=order.total_kobo,
            created_at=order.created_at,
            updated_at=order.updated_at,
            items=order.items,
        )

    def load_order(session: Session, order_id: int) -> Order:
        order = session.scalars(
            select(Order).where(Order.id == order_id)
            .options(selectinload(Order.items), selectinload(Order.restaurant))
        ).first()
        if order is None:
            raise HTTPException(404, "Order not found")
        return order

    @app.post("/api/orders", response_model=OrderOut, status_code=201, tags=["orders"])
    def place_order(body: OrderIn, session: Session = Depends(db)):
        restaurant = session.scalars(select(Restaurant).where(Restaurant.slug == body.restaurant_slug)).first()
        if restaurant is None:
            raise HTTPException(404, "Restaurant not found")
        dish_ids = [i.dish_id for i in body.items]
        dishes = {
            d.id: d for d in session.scalars(
                select(Dish).where(Dish.id.in_(dish_ids), Dish.restaurant_id == restaurant.id)
            )
        }
        missing = [i for i in dish_ids if i not in dishes]
        if missing:
            raise HTTPException(422, f"Dishes not on this restaurant's menu: {missing}")

        # Prices come from the database, never from the client.
        items = [
            OrderItem(
                dish_id=i.dish_id,
                dish_name=dishes[i.dish_id].name,
                unit_price_kobo=dishes[i.dish_id].price_kobo,
                quantity=i.quantity,
            )
            for i in body.items
        ]
        order = Order(
            restaurant_id=restaurant.id,
            customer_name=body.customer_name.strip(),
            delivery_address=body.delivery_address.strip(),
            status="placed",
            total_kobo=sum(i.unit_price_kobo * i.quantity for i in items),
            items=items,
        )
        session.add(order)
        session.commit()
        log_event("info", "order_placed", order_id=order.id, restaurant=restaurant.slug,
                  total_kobo=order.total_kobo, dishes=[i.dish_name for i in items])
        return order_out(load_order(session, order.id))

    @app.get("/api/orders/{order_id}", response_model=OrderOut, tags=["orders"])
    def get_order(order_id: int, session: Session = Depends(db)):
        return order_out(load_order(session, order_id))

    # --- Kitchen ----------------------------------------------------------

    @app.get("/api/kitchen/orders", response_model=list[OrderOut], tags=["kitchen"])
    def kitchen_orders(session: Session = Depends(db)):
        """Orders the kitchen still has to deal with, oldest first."""
        orders = session.scalars(
            select(Order).where(Order.status != "delivered").order_by(Order.created_at)
            .options(selectinload(Order.items), selectinload(Order.restaurant))
        ).all()
        return [order_out(o) for o in orders]

    @app.patch("/api/orders/{order_id}/status", response_model=OrderOut, tags=["kitchen"])
    def update_status(order_id: int, body: StatusIn, session: Session = Depends(db)):
        order = load_order(session, order_id)
        if body.status not in ORDER_STATUSES:
            raise HTTPException(422, f"Unknown status. Use one of: {ORDER_STATUSES}")
        if ORDER_STATUSES.index(body.status) != ORDER_STATUSES.index(order.status) + 1:
            raise HTTPException(409, f"An order that is '{order.status}' can't move to '{body.status}'")
        order.status = body.status
        session.commit()
        log_event("info", "order_status", order_id=order.id, status=order.status)
        return order_out(load_order(session, order_id))

    @app.exception_handler(Exception)
    async def unhandled(request: Request, exc: Exception):
        log_event("error", "unhandled_exception", path=request.url.path, error=type(exc).__name__)
        return JSONResponse({"detail": "Internal server error"}, status_code=500)

    return app


app = create_app()


def run() -> None:
    """Entry point for `bukka-api` / `python -m bukka_api.main`."""
    import uvicorn

    settings = get_settings()
    # On SIGTERM (systemd stop, Kubernetes pod shutdown) uvicorn stops taking
    # new connections and gives in-flight requests up to 20s to finish.
    uvicorn.run(
        "bukka_api.main:app",
        host=settings.host,
        port=settings.port,
        log_level=settings.log_level,
        access_log=False,  # our JSON access log replaces uvicorn's
        timeout_graceful_shutdown=20,
    )


if __name__ == "__main__":
    run()
