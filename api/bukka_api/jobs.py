"""The job queue between the order service and the worker.

The API pushes small JSON jobs onto a Redis list; the worker pops them off.
With no REDIS_URL the queue is disabled and enqueue() does nothing, so the
API runs on its own exactly as before.

Keys:
  bukka:jobs                 list of ready jobs (LPUSH by producers, BRPOP by the worker)
  bukka:jobs:delayed         sorted set of jobs to run later (score = unix time due)
  bukka:events               the last 100 things the worker did (capped list)
  bukka:worker:heartbeat:*   one key per worker, expires if the worker stops
"""

import json
import time

from bukka_api.access_log import log_event

QUEUE_KEY = "bukka:jobs"
DELAYED_KEY = "bukka:jobs:delayed"
EVENTS_KEY = "bukka:events"
HEARTBEAT_PREFIX = "bukka:worker:heartbeat:"


def connect(redis_url: str):
    """A Redis client, or None when no REDIS_URL is configured."""
    if not redis_url:
        return None
    import redis  # imported lazily: only needed when a queue is configured

    return redis.Redis.from_url(redis_url, socket_connect_timeout=2, socket_timeout=5, decode_responses=True)


class JobQueue:
    def __init__(self, client):
        self.client = client

    @classmethod
    def from_url(cls, redis_url: str) -> "JobQueue":
        return cls(connect(redis_url))

    @property
    def enabled(self) -> bool:
        return self.client is not None

    def enqueue(self, job_type: str, **payload) -> bool:
        """Push a job. Never raises: a queue outage must not lose an order."""
        if self.client is None:
            return False
        job = {"type": job_type, "enqueued_at": time.time(), **payload}
        try:
            self.client.lpush(QUEUE_KEY, json.dumps(job))
            return True
        except Exception as exc:  # redis down, timeout, DNS...
            log_event("error", "enqueue_failed", job=job_type, error=type(exc).__name__, **payload)
            return False

    def enqueue_later(self, delay_seconds: float, job_type: str, **payload) -> None:
        job = {"type": job_type, "enqueued_at": time.time(), **payload}
        self.client.zadd(DELAYED_KEY, {json.dumps(job): time.time() + delay_seconds})

    def promote_due(self) -> int:
        """Move delayed jobs whose time has come onto the main queue."""
        now = time.time()
        moved = 0
        for raw in self.client.zrangebyscore(DELAYED_KEY, 0, now, start=0, num=100):
            # zrem returns 1 for only one worker, so a job is promoted once.
            if self.client.zrem(DELAYED_KEY, raw):
                self.client.lpush(QUEUE_KEY, raw)
                moved += 1
        return moved

    def pop(self, timeout: int = 1) -> dict | None:
        """Take the oldest job, waiting up to `timeout` seconds (0 = don't wait)."""
        if timeout > 0:
            item = self.client.brpop([QUEUE_KEY], timeout=timeout)
            raw = item[1] if item else None
        else:
            raw = self.client.rpop(QUEUE_KEY)
        if raw is None:
            return None
        try:
            return json.loads(raw)
        except ValueError:
            log_event("error", "bad_job", raw=raw[:200])
            return None

    def record(self, event: dict) -> None:
        self.client.lpush(EVENTS_KEY, json.dumps(event))
        self.client.ltrim(EVENTS_KEY, 0, 99)

    def ping(self) -> bool:
        if self.client is None:
            return False
        try:
            return bool(self.client.ping())
        except Exception:
            return False
