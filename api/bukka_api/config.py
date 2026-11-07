"""All configuration comes from environment variables. Nothing is hard-coded
per environment: the same build runs on a laptop, a VM or Kubernetes."""

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    # SQLite for local development; PostgreSQL in production, e.g.
    # postgresql+psycopg://bukka:<password>@db.internal:5432/bukka
    database_url: str
    # Where the API listens. 0.0.0.0 means every network interface;
    # 127.0.0.1 means only this machine can reach it.
    host: str
    port: int
    log_level: str
    environment: str
    # The job queue, e.g. redis://redis:6379/0. Empty means no queue: the API
    # works exactly the same, nothing is sent to the worker, and orders are
    # moved along by hand on the kitchen screen.
    redis_url: str = ""


def get_settings() -> Settings:
    return Settings(
        database_url=os.getenv("DATABASE_URL", "sqlite:///./bukka.db"),
        host=os.getenv("BUKKA_HOST", "0.0.0.0"),
        port=int(os.getenv("BUKKA_PORT", "8080")),
        log_level=os.getenv("LOG_LEVEL", "info"),
        environment=os.getenv("BUKKA_ENV", "development"),
        redis_url=os.getenv("REDIS_URL", ""),
    )
