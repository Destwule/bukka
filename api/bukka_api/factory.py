"""Builds the Bukka API app.

The same code runs three ways:
  - the monolith, every route in one process    (bukka_api.main)
  - the menu service: restaurants and menus      (bukka_api.services.menu)
  - the order service: orders and the kitchen    (bukka_api.services.orders)
All three share one database. Each has its own /healthz and /readyz.
"""

from contextlib import asynccontextmanager

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from bukka_api import __version__
from bukka_api.access_log import AccessLogMiddleware, log_event
from bukka_api.config import Settings, get_settings
from bukka_api.db import make_engine, make_session_factory, ping, session_scope
from bukka_api.jobs import JobQueue
from bukka_api.models import ORDER_STATUSES, Dish, Order, OrderItem, Restaurant
from bukka_api.schemas import MenuOut, OrderIn, OrderOut, RestaurantOut, StatusIn

ALL_PARTS = ("menu", "orders")


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


def menu_router(db) -> APIRouter:
    router = APIRouter()

    @router.get("/api/restaurants", response_model=list[RestaurantOut], tags=["menu"])
    def list_restaurants(session: Session = Depends(db)):
        return session.scalars(select(Restaurant).order_by(Restaurant.name)).all()

    @router.get("/api/restaurants/{slug}/menu", response_model=MenuOut, tags=["menu"])
    def get_menu(slug: str, session: Session = Depends(db)):
        restaurant = session.scalars(
            select(Restaurant).where(Restaurant.slug == slug).options(selectinload(Restaurant.dishes))
        ).first()
        if restaurant is None:
            raise HTTPException(404, "Restaurant not found")
        return restaurant

    return router


def orders_router(db, queue: JobQueue) -> APIRouter:
    router = APIRouter()

    def load_order(session: Session, order_id: int) -> Order:
        order = session.scalars(
            select(Order).where(Order.id == order_id)
            .options(selectinload(Order.items), selectinload(Order.restaurant))
        ).first()
        if order is None:
            raise HTTPException(404, "Order not found")
        return order

    @router.post("/api/orders", response_model=OrderOut, status_code=201, tags=["orders"])
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
        # After the commit, so the worker always finds the order in the database.
        if queue.enqueue("order_placed", order_id=order.id):
            log_event("info", "job_enqueued", job="order_placed", order_id=order.id)
        return order_out(load_order(session, order.id))

    @router.get("/api/orders/{order_id}", response_model=OrderOut, tags=["orders"])
    def get_order(order_id: int, session: Session = Depends(db)):
        return order_out(load_order(session, order_id))

    @router.get("/api/kitchen/orders", response_model=list[OrderOut], tags=["kitchen"])
    def kitchen_orders(session: Session = Depends(db)):
        """Orders the kitchen still has to deal with, oldest first."""
        orders = session.scalars(
            select(Order).where(Order.status != "delivered").order_by(Order.created_at)
            .options(selectinload(Order.items), selectinload(Order.restaurant))
        ).all()
        return [order_out(o) for o in orders]

    @router.patch("/api/orders/{order_id}/status", response_model=OrderOut, tags=["kitchen"])
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

    return router


def create_app(settings: Settings | None = None, *, parts=ALL_PARTS, service: str = "api") -> FastAPI:
    settings = settings or get_settings()
    engine = make_engine(settings.database_url)
    sessions = make_session_factory(engine)
    queue = JobQueue.from_url(settings.redis_url) if "orders" in parts else JobQueue(None)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        log_event("info", "startup", service=service, version=__version__, environment=settings.environment,
                  queue="redis" if queue.enabled else "disabled")
        yield
        # Uvicorn stops accepting new connections and waits for in-flight
        # requests before we get here: a graceful shutdown.
        engine.dispose()
        log_event("info", "shutdown", service=service)

    title = "Bukka API" if service == "api" else f"Bukka {service} service"
    app = FastAPI(title=title, version=__version__, lifespan=lifespan)
    app.add_middleware(AccessLogMiddleware)
    app.state.engine = engine
    app.state.queue = queue
    app.state.service = service

    def db():
        yield from session_scope(sessions)

    # --- Health -----------------------------------------------------------

    @app.get("/healthz", tags=["ops"])
    def healthz():
        """Liveness: the process is running. Never checks dependencies."""
        return {"status": "ok", "version": __version__, "service": service}

    @app.get("/readyz", tags=["ops"])
    def readyz():
        """Readiness: safe to send traffic here (the database answers).

        The queue is reported but doesn't make the service unready: orders
        are still saved when Redis is down, the worker just catches up later
        (or the kitchen moves them by hand)."""
        body = {"status": "ready", "database": "up"}
        if queue.enabled:
            body["queue"] = "up" if queue.ping() else "down"
        if not ping(engine):
            body.update(status="unavailable", database="down")
            return JSONResponse(body, status_code=503)
        return body

    if "menu" in parts:
        app.include_router(menu_router(db))
    if "orders" in parts:
        app.include_router(orders_router(db, queue))

    @app.exception_handler(Exception)
    async def unhandled(request: Request, exc: Exception):
        log_event("error", "unhandled_exception", path=request.url.path, error=type(exc).__name__)
        return JSONResponse({"detail": "Internal server error"}, status_code=500)

    return app


def serve(app_path: str) -> None:
    """Run an app with uvicorn, configured from the environment."""
    import uvicorn

    settings = get_settings()
    # On SIGTERM (systemd stop, Kubernetes pod shutdown) uvicorn stops taking
    # new connections and gives in-flight requests up to 20s to finish.
    uvicorn.run(
        app_path,
        host=settings.host,
        port=settings.port,
        log_level=settings.log_level,
        access_log=False,  # our JSON access log replaces uvicorn's
        timeout_graceful_shutdown=20,
    )
