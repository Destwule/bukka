from datetime import datetime, timezone

from sqlalchemy import DateTime, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from bukka_api.db import Base

# Orders move through these statuses in this order.
ORDER_STATUSES = ["placed", "preparing", "out_for_delivery", "delivered"]


def _now() -> datetime:
    return datetime.now(timezone.utc)


class Restaurant(Base):
    __tablename__ = "restaurants"

    id: Mapped[int] = mapped_column(primary_key=True)
    slug: Mapped[str] = mapped_column(String(80), unique=True, index=True)
    name: Mapped[str] = mapped_column(String(120))
    cuisine: Mapped[str] = mapped_column(String(80))
    area: Mapped[str] = mapped_column(String(80))
    delivery_minutes: Mapped[int] = mapped_column(Integer)
    emoji: Mapped[str] = mapped_column(String(16), default="🍽️")

    dishes: Mapped[list["Dish"]] = relationship(back_populates="restaurant", order_by="Dish.id")


class Dish(Base):
    __tablename__ = "dishes"

    id: Mapped[int] = mapped_column(primary_key=True)
    restaurant_id: Mapped[int] = mapped_column(ForeignKey("restaurants.id"), index=True)
    name: Mapped[str] = mapped_column(String(120))
    description: Mapped[str] = mapped_column(Text, default="")
    # Money is stored in kobo (1 naira = 100 kobo) as an integer, never a float.
    price_kobo: Mapped[int] = mapped_column(Integer)
    emoji: Mapped[str] = mapped_column(String(16), default="🍲")
    # Filled in once menu photos move to object storage (S3).
    photo_key: Mapped[str] = mapped_column(String(255), default="")

    restaurant: Mapped[Restaurant] = relationship(back_populates="dishes")


class Order(Base):
    __tablename__ = "orders"

    id: Mapped[int] = mapped_column(primary_key=True)
    restaurant_id: Mapped[int] = mapped_column(ForeignKey("restaurants.id"), index=True)
    customer_name: Mapped[str] = mapped_column(String(120))
    delivery_address: Mapped[str] = mapped_column(String(255))
    status: Mapped[str] = mapped_column(String(32), default="placed", index=True)
    total_kobo: Mapped[int] = mapped_column(Integer)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)

    restaurant: Mapped[Restaurant] = relationship()
    items: Mapped[list["OrderItem"]] = relationship(back_populates="order", cascade="all, delete-orphan")


class OrderItem(Base):
    __tablename__ = "order_items"

    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), index=True)
    dish_id: Mapped[int] = mapped_column(ForeignKey("dishes.id"))
    dish_name: Mapped[str] = mapped_column(String(120))  # snapshot at order time
    unit_price_kobo: Mapped[int] = mapped_column(Integer)  # snapshot at order time
    quantity: Mapped[int] = mapped_column(Integer)

    order: Mapped[Order] = relationship(back_populates="items")
