"""Alembic environment: reads DATABASE_URL like the app does."""

from alembic import context

from bukka_api.config import get_settings
from bukka_api.db import Base, make_engine
from bukka_api import models  # noqa: F401  (registers the tables)

target_metadata = Base.metadata


def run_migrations() -> None:
    engine = make_engine(get_settings().database_url)
    with engine.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata, render_as_batch=True)
        with context.begin_transaction():
            context.run_migrations()


run_migrations()
