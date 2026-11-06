import json

import pytest
from fastapi.testclient import TestClient

from bukka_api.config import Settings
from bukka_api.db import Base
from bukka_api.main import create_app


@pytest.fixture
def client(tmp_path, monkeypatch):
    url = f"sqlite:///{tmp_path / 'test.db'}"
    monkeypatch.setenv("DATABASE_URL", url)
    app = create_app(Settings(database_url=url, host="127.0.0.1", port=8080,
                              log_level="info", environment="test"))
    Base.metadata.create_all(app.state.engine)
    from bukka_api.seed import seed
    seed()
    with TestClient(app) as c:
        yield c


def first_menu(client):
    slug = client.get("/api/restaurants").json()[0]["slug"]
    return slug, client.get(f"/api/restaurants/{slug}/menu").json()


def test_health_and_readiness(client):
    assert client.get("/healthz").json()["status"] == "ok"
    assert client.get("/readyz").json() == {"status": "ready", "database": "up"}


def test_readiness_fails_without_database(tmp_path):
    app = create_app(Settings(database_url="postgresql+psycopg://x:y@127.0.0.1:1/none",
                              host="127.0.0.1", port=8080, log_level="info", environment="test"))
    with TestClient(app) as c:
        assert c.get("/healthz").status_code == 200  # liveness never checks dependencies
        assert c.get("/readyz").status_code == 503


def test_restaurants_and_menu(client):
    restaurants = client.get("/api/restaurants").json()
    assert len(restaurants) == 4
    slug, menu = first_menu(client)
    assert menu["slug"] == slug
    assert len(menu["dishes"]) >= 3
    assert all(isinstance(d["price_kobo"], int) for d in menu["dishes"])
    assert client.get("/api/restaurants/nope/menu").status_code == 404


def test_place_and_track_order(client):
    slug, menu = first_menu(client)
    d1, d2 = menu["dishes"][0], menu["dishes"][1]
    resp = client.post("/api/orders", json={
        "restaurant_slug": slug, "customer_name": "Ada", "delivery_address": "12 Herbert Macaulay Way",
        "items": [{"dish_id": d1["id"], "quantity": 2}, {"dish_id": d2["id"], "quantity": 1}],
    })
    assert resp.status_code == 201
    order = resp.json()
    assert order["status"] == "placed"
    assert order["total_kobo"] == d1["price_kobo"] * 2 + d2["price_kobo"]
    assert client.get(f"/api/orders/{order['id']}").json()["id"] == order["id"]

    kitchen = client.get("/api/kitchen/orders").json()
    assert [o["id"] for o in kitchen] == [order["id"]]

    for status in ["preparing", "out_for_delivery", "delivered"]:
        r = client.patch(f"/api/orders/{order['id']}/status", json={"status": status})
        assert r.status_code == 200 and r.json()["status"] == status
    assert client.get("/api/kitchen/orders").json() == []


def test_status_cannot_skip_steps(client):
    slug, menu = first_menu(client)
    order = client.post("/api/orders", json={
        "restaurant_slug": slug, "customer_name": "Ada", "delivery_address": "Yaba",
        "items": [{"dish_id": menu["dishes"][0]["id"], "quantity": 1}],
    }).json()
    assert client.patch(f"/api/orders/{order['id']}/status", json={"status": "delivered"}).status_code == 409
    assert client.patch(f"/api/orders/{order['id']}/status", json={"status": "eaten"}).status_code == 422


def test_order_rejects_dishes_from_another_restaurant(client):
    restaurants = client.get("/api/restaurants").json()
    other = client.get(f"/api/restaurants/{restaurants[1]['slug']}/menu").json()
    resp = client.post("/api/orders", json={
        "restaurant_slug": restaurants[0]["slug"], "customer_name": "Ada", "delivery_address": "Yaba",
        "items": [{"dish_id": other["dishes"][0]["id"], "quantity": 1}],
    })
    assert resp.status_code == 422


def test_access_log_is_json(client, capsys):
    capsys.readouterr()
    client.get("/api/restaurants")
    lines = [json.loads(l) for l in capsys.readouterr().out.splitlines() if l.startswith("{")]
    req = [l for l in lines if l["msg"] == "request"][-1]
    assert req["method"] == "GET" and req["path"] == "/api/restaurants" and req["status"] == 200
    assert isinstance(req["response_time_ms"], int)
