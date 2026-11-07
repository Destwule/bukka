"""The menu/order service split, the job queue and the worker.

Redis is faked with fakeredis, so these tests need no Redis server.
"""

import json
import os
import time
import urllib.request

import fakeredis
import pytest
from fastapi.testclient import TestClient

from bukka_api.config import Settings
from bukka_api.db import Base, make_session_factory
from bukka_api.factory import create_app
from bukka_api.jobs import DELAYED_KEY, EVENTS_KEY, HEARTBEAT_PREFIX, QUEUE_KEY, JobQueue, connect
from bukka_api.worker import Worker, start_health_server


def settings(url: str, redis_url: str = "") -> Settings:
    return Settings(database_url=url, host="127.0.0.1", port=8080, log_level="info",
                    environment="test", redis_url=redis_url)


@pytest.fixture
def db_url(tmp_path, monkeypatch):
    url = f"sqlite:///{tmp_path / 'test.db'}"
    monkeypatch.setenv("DATABASE_URL", url)
    app = create_app(settings(url))
    Base.metadata.create_all(app.state.engine)
    from bukka_api.seed import seed
    seed()
    return url


@pytest.fixture
def fake_redis():
    return fakeredis.FakeRedis(decode_responses=True)


def order_body(client):
    restaurants = client.get("/api/restaurants").json()
    slug = restaurants[0]["slug"]
    dish = client.get(f"/api/restaurants/{slug}/menu").json()["dishes"][0]
    return {"restaurant_slug": slug, "customer_name": "Ada", "delivery_address": "Yaba",
            "items": [{"dish_id": dish["id"], "quantity": 2}]}


def test_menu_service_only_serves_menus(db_url):
    with TestClient(create_app(settings(db_url), parts=("menu",), service="menu")) as c:
        assert c.get("/healthz").json()["service"] == "menu"
        assert c.get("/readyz").status_code == 200
        assert len(c.get("/api/restaurants").json()) == 4
        assert c.get("/api/kitchen/orders").status_code == 404
        assert c.post("/api/orders", json={}).status_code in (404, 405)


def test_order_service_only_serves_orders(db_url):
    with TestClient(create_app(settings(db_url), parts=("menu",))) as menu, \
         TestClient(create_app(settings(db_url), parts=("orders",), service="orders")) as orders:
        assert orders.get("/healthz").json()["service"] == "orders"
        assert orders.get("/api/restaurants").status_code == 404
        resp = orders.post("/api/orders", json=order_body(menu))
        assert resp.status_code == 201
        assert [o["id"] for o in orders.get("/api/kitchen/orders").json()] == [resp.json()["id"]]


def test_service_entrypoints_import():
    from bukka_api.services import menu, orders

    paths = set(menu.app.openapi()["paths"])
    assert "/api/restaurants" in paths and "/api/orders" not in paths
    paths = set(orders.app.openapi()["paths"])
    assert "/api/orders" in paths and "/api/restaurants" not in paths


def test_no_redis_url_means_no_queue(db_url):
    app = create_app(settings(db_url))
    assert not app.state.queue.enabled
    with TestClient(app) as c:
        assert c.get("/readyz").json() == {"status": "ready", "database": "up"}
        assert c.post("/api/orders", json=order_body(c)).status_code == 201


def test_placing_an_order_enqueues_a_job(db_url, fake_redis):
    app = create_app(settings(db_url))
    app.state.queue.client = fake_redis  # swap the real client for the fake
    with TestClient(app) as c:
        order = c.post("/api/orders", json=order_body(c)).json()
        assert c.get("/readyz").json()["queue"] == "up"
    job = json.loads(fake_redis.rpop(QUEUE_KEY))
    assert job["type"] == "order_placed" and job["order_id"] == order["id"]


def test_redis_down_does_not_lose_the_order(db_url):
    app = create_app(settings(db_url, redis_url="redis://127.0.0.1:1/0"))
    with TestClient(app) as c:
        resp = c.post("/api/orders", json=order_body(c))
        assert resp.status_code == 201
        assert c.get(f"/api/orders/{resp.json()['id']}").status_code == 200
        ready = c.get("/readyz")
        assert ready.status_code == 200 and ready.json()["queue"] == "down"


def test_worker_moves_an_order_to_delivered(db_url, fake_redis, capsys):
    app = create_app(settings(db_url))
    app.state.queue.client = fake_redis
    with TestClient(app) as c:
        order_id = c.post("/api/orders", json=order_body(c)).json()["id"]

        worker = Worker(JobQueue(fake_redis), make_session_factory(app.state.engine), step_seconds=0, name="w1")
        for _ in range(10):
            worker.run_once(timeout=0)
        assert c.get(f"/api/orders/{order_id}").json()["status"] == "delivered"

    assert fake_redis.get(HEARTBEAT_PREFIX + "w1")
    assert fake_redis.zcard(DELAYED_KEY) == 0
    events = [json.loads(e)["event"] for e in fake_redis.lrange(EVENTS_KEY, 0, -1)]
    assert events == ["notification_sent", "kitchen_ticket_printed"]
    logs = [json.loads(line) for line in capsys.readouterr().out.splitlines() if line.startswith("{")]
    msgs = [(l["msg"], l.get("status")) for l in logs if l.get("worker") == "w1"]
    assert ("kitchen_ticket_printed", None) in msgs
    assert [s for m, s in msgs if m == "order_status"] == ["preparing", "out_for_delivery", "delivered"]


def test_worker_leaves_orders_the_kitchen_already_moved(db_url, fake_redis):
    app = create_app(settings(db_url))
    app.state.queue.client = fake_redis
    with TestClient(app) as c:
        order_id = c.post("/api/orders", json=order_body(c)).json()["id"]
        worker = Worker(JobQueue(fake_redis), make_session_factory(app.state.engine), step_seconds=0, name="w1")
        worker.run_once(timeout=0)  # placed -> preparing
        assert c.patch(f"/api/orders/{order_id}/status", json={"status": "out_for_delivery"}).status_code == 200
        worker.run_once(timeout=0)  # its preparing -> out_for_delivery is now stale: skipped
        assert c.get(f"/api/orders/{order_id}").json()["status"] == "out_for_delivery"


def test_worker_survives_a_bad_job(db_url, fake_redis):
    app = create_app(settings(db_url))
    worker = Worker(JobQueue(fake_redis), make_session_factory(app.state.engine), step_seconds=0, name="w1")
    fake_redis.lpush(QUEUE_KEY, json.dumps({"type": "order_placed", "order_id": 999}))
    fake_redis.lpush(QUEUE_KEY, "not json")
    fake_redis.lpush(QUEUE_KEY, json.dumps({"type": "advance_order", "order_id": 1, "from_status": "nope"}))
    for _ in range(3):
        worker.run_once(timeout=0)
    assert worker.healthy()


def test_worker_health_endpoint(db_url, fake_redis):
    app = create_app(settings(db_url))
    worker = Worker(JobQueue(fake_redis), make_session_factory(app.state.engine), name="w1")
    server = start_health_server(worker, app.state.engine, 0)
    port = server.server_address[1]
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=5) as r:
            assert r.status == 200
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/readyz", timeout=5) as r:
            assert r.status == 200
        worker.last_loop -= 60  # pretend the loop has been stuck for a minute
        with pytest.raises(urllib.error.HTTPError) as err:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=5)
        assert err.value.code == 503
    finally:
        server.shutdown()


def test_worker_refuses_to_start_without_redis(monkeypatch):
    from bukka_api import worker

    monkeypatch.delenv("REDIS_URL", raising=False)
    with pytest.raises(SystemExit) as exit_:
        worker.main()
    assert exit_.value.code == 2


REAL_REDIS = os.getenv("BUKKA_TEST_REDIS_URL", "")


@pytest.mark.skipif(not REAL_REDIS, reason="set BUKKA_TEST_REDIS_URL (e.g. redis://127.0.0.1:6379/15) to run")
def test_order_to_delivered_through_real_redis(db_url):
    """The order service and the worker talking through a real Redis."""
    client = connect(REAL_REDIS)
    client.delete(QUEUE_KEY, DELAYED_KEY, EVENTS_KEY)
    app = create_app(settings(db_url, redis_url=REAL_REDIS), parts=("orders",), service="orders")
    menu = create_app(settings(db_url), parts=("menu",))
    with TestClient(menu) as m, TestClient(app) as c:
        assert c.get("/readyz").json()["queue"] == "up"
        order_id = c.post("/api/orders", json=order_body(m)).json()["id"]
        worker = Worker(JobQueue.from_url(REAL_REDIS), make_session_factory(app.state.engine),
                        step_seconds=0.2, name="w-real")
        deadline = time.time() + 15
        while time.time() < deadline and c.get(f"/api/orders/{order_id}").json()["status"] != "delivered":
            worker.run_once(timeout=1)
        assert c.get(f"/api/orders/{order_id}").json()["status"] == "delivered"
