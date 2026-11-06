from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field


class DishOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    name: str
    description: str
    price_kobo: int
    emoji: str


class RestaurantOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    slug: str
    name: str
    cuisine: str
    area: str
    delivery_minutes: int
    emoji: str


class MenuOut(RestaurantOut):
    dishes: list[DishOut]


class OrderItemIn(BaseModel):
    dish_id: int
    quantity: int = Field(ge=1, le=20)


class OrderIn(BaseModel):
    restaurant_slug: str
    customer_name: str = Field(min_length=1, max_length=120)
    delivery_address: str = Field(min_length=1, max_length=255)
    items: list[OrderItemIn] = Field(min_length=1, max_length=30)


class OrderItemOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    dish_id: int
    dish_name: str
    unit_price_kobo: int
    quantity: int


class OrderOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    restaurant_id: int
    restaurant_name: str
    customer_name: str
    delivery_address: str
    status: str
    total_kobo: int
    created_at: datetime
    updated_at: datetime
    items: list[OrderItemOut]


class StatusIn(BaseModel):
    status: str
