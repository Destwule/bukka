"""Load demo restaurants and dishes. Safe to run more than once.

Usage: python -m bukka_api.seed
"""

from sqlalchemy import select

from bukka_api.access_log import log_event
from bukka_api.config import get_settings
from bukka_api.db import make_engine, make_session_factory
from bukka_api.models import Dish, Restaurant

N = 100  # kobo per naira

RESTAURANTS = [
    {
        "slug": "mama-put-yaba", "name": "Mama Put Yaba", "cuisine": "Nigerian", "area": "Yaba",
        "delivery_minutes": 30, "emoji": "🍲",
        "dishes": [
            ("Jollof Rice & Chicken", "Party jollof, smoky bottom, with grilled chicken", 3500, "🍛"),
            ("Amala & Ewedu", "With gbegiri and assorted meat", 3000, "🥣"),
            ("Fried Plantain (Dodo)", "A generous side of sweet dodo", 1000, "🍌"),
            ("Moi Moi", "Steamed bean pudding with egg", 800, "🫘"),
        ],
    },
    {
        "slug": "suya-spot-lekki", "name": "Suya Spot Lekki", "cuisine": "Grill", "area": "Lekki",
        "delivery_minutes": 40, "emoji": "🔥",
        "dishes": [
            ("Beef Suya", "Spicy yaji, onions and tomatoes", 4000, "🍢"),
            ("Chicken Suya", "Tender chicken, extra yaji on request", 4500, "🍗"),
            ("Kilishi", "Dried spiced beef jerky", 2500, "🥩"),
        ],
    },
    {
        "slug": "calabar-kitchen-ikeja", "name": "Calabar Kitchen", "cuisine": "Nigerian", "area": "Ikeja",
        "delivery_minutes": 35, "emoji": "🥘",
        "dishes": [
            ("Edikang Ikong & Fufu", "Vegetable soup loaded with meat and fish", 5000, "🥬"),
            ("Afang Soup & Garri", "Rich afang with periwinkle", 4800, "🍲"),
            ("Pepper Soup (Catfish)", "Hot and peppery", 4200, "🐟"),
        ],
    },
    {
        "slug": "chop-and-go-surulere", "name": "Chop & Go", "cuisine": "Fast food", "area": "Surulere",
        "delivery_minutes": 20, "emoji": "🍔",
        "dishes": [
            ("Shawarma (Chicken)", "Double sausage, extra cream", 3000, "🌯"),
            ("Meat Pie", "Fresh from the oven", 700, "🥧"),
            ("Chapman", "Our classic mocktail", 1200, "🍹"),
            ("Puff-Puff (6 pieces)", "Sweet and fluffy", 600, "🍩"),
        ],
    },
]


def seed() -> int:
    settings = get_settings()
    engine = make_engine(settings.database_url)
    sessions = make_session_factory(engine)
    added = 0
    with sessions() as session:
        for r in RESTAURANTS:
            if session.scalars(select(Restaurant).where(Restaurant.slug == r["slug"])).first():
                continue
            restaurant = Restaurant(
                slug=r["slug"], name=r["name"], cuisine=r["cuisine"], area=r["area"],
                delivery_minutes=r["delivery_minutes"], emoji=r["emoji"],
            )
            restaurant.dishes = [
                Dish(name=n, description=d, price_kobo=p * N, emoji=e) for n, d, p, e in r["dishes"]
            ]
            session.add(restaurant)
            added += 1
        session.commit()
    log_event("info", "seed_complete", restaurants_added=added)
    return added


if __name__ == "__main__":
    seed()
