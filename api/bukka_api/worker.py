"""Bukka worker: takes jobs off the Redis queue and moves orders along.

When an order is placed, the order service pushes an `order_placed` job.
The worker prints the kitchen ticket (a log line), then moves the order
placed -> preparing -> out_for_delivery -> delivered, one step every
WORKER_STEP_SECONDS, so the kitchen screen updates without anyone clicking.
If someone in the kitchen already moved the order on by hand, the worker
leaves it alone (it only moves an order from the status it expects).

Run:    python -m bukka_api.worker
Needs:  DATABASE_URL, REDIS_URL
Optional:
  WORKER_STEP_SECONDS   seconds between status changes (default 5)
  WORKER_HEALTH_PORT    port for GET /healthz and /readyz (default 8081, 0 = off)
Health: GET /healthz -> 200 while the job loop is running (503 if it has
        stalled for 30s); GET /readyz -> 200 when Redis and the database answer.
        It also sets bukka:worker:heartbeat:<hostname> in Redis (expires in 30s).
"""

import os
import signal
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from sqlalchemy import update

from bukka_api import __version__
from bukka_api.access_log import log_event
from bukka_api.config import get_settings
from bukka_api.db import make_engine, make_session_factory, ping
from bukka_api.jobs import HEARTBEAT_PREFIX, JobQueue
from bukka_api.models import ORDER_STATUSES, Order

STALL_SECONDS = 30


class Worker:
    def __init__(self, queue: JobQueue, sessions, step_seconds: float = 5.0, name: str | None = None):
        self.queue = queue
        self.sessions = sessions
        self.step_seconds = step_seconds
        self.name = name or socket.gethostname()
        self.last_loop = time.monotonic()
        self.stopping = threading.Event()
        self.processed = 0

    # --- Jobs -------------------------------------------------------------

    def handle(self, job: dict) -> None:
        kind = job.get("type")
        if kind == "order_placed":
            self.order_placed(int(job["order_id"]))
        elif kind == "advance_order":
            self.advance(int(job["order_id"]), job["from_status"])
        else:
            log_event("warning", "unknown_job", worker=self.name, job=kind)
        self.processed += 1

    def order_placed(self, order_id: int) -> None:
        with self.sessions() as session:
            order = session.get(Order, order_id)
            if order is None:
                log_event("warning", "order_missing", worker=self.name, order_id=order_id)
                return
            dishes = [f"{i.quantity} x {i.dish_name}" for i in order.items]
            customer = order.customer_name
        log_event("info", "kitchen_ticket_printed", worker=self.name, order_id=order_id,
                  customer=customer, dishes=dishes)
        self.queue.record({"event": "kitchen_ticket_printed", "order_id": order_id, "ts": time.time()})
        self.advance(order_id, "placed")

    def advance(self, order_id: int, from_status: str) -> None:
        """Move the order one step on, only if it's still in from_status."""
        i = ORDER_STATUSES.index(from_status)
        if i + 1 >= len(ORDER_STATUSES):
            return
        to_status = ORDER_STATUSES[i + 1]
        with self.sessions() as session:
            # Compare-and-set: a no-op if the kitchen already moved it by hand
            # or another worker got there first.
            result = session.execute(
                update(Order).where(Order.id == order_id, Order.status == from_status).values(status=to_status)
            )
            session.commit()
        if result.rowcount != 1:
            log_event("info", "order_skipped", worker=self.name, order_id=order_id, expected=from_status)
            return
        log_event("info", "order_status", worker=self.name, order_id=order_id, status=to_status)
        if to_status == "delivered":
            log_event("info", "notification_sent", worker=self.name, order_id=order_id,
                      text="Your order has been delivered. Enjoy!")
            self.queue.record({"event": "notification_sent", "order_id": order_id, "ts": time.time()})
        else:
            self.queue.enqueue_later(self.step_seconds, "advance_order", order_id=order_id, from_status=to_status)

    # --- Loop -------------------------------------------------------------

    def run_once(self, timeout: int = 1) -> bool:
        """One pass: heartbeat, promote due jobs, handle at most one job."""
        self.last_loop = time.monotonic()
        self.queue.client.set(HEARTBEAT_PREFIX + self.name, str(time.time()), ex=STALL_SECONDS)
        self.queue.promote_due()
        job = self.queue.pop(timeout=timeout)
        if job is None:
            return False
        try:
            self.handle(job)
        except Exception as exc:
            log_event("error", "job_failed", worker=self.name, job=job.get("type"),
                      order_id=job.get("order_id"), error=type(exc).__name__, detail=str(exc)[:200])
        return True

    def run(self) -> None:
        log_event("info", "worker_started", worker=self.name, version=__version__, step_seconds=self.step_seconds)
        while not self.stopping.is_set():
            try:
                self.run_once()
            except Exception as exc:  # Redis restarting, network blip: wait and retry
                self.last_loop = time.monotonic()
                log_event("error", "worker_loop_error", worker=self.name, error=type(exc).__name__)
                self.stopping.wait(2)
        log_event("info", "worker_stopped", worker=self.name, processed=self.processed)

    def healthy(self) -> bool:
        return time.monotonic() - self.last_loop < STALL_SECONDS


def start_health_server(worker: Worker, engine, port: int) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/healthz":
                ok = worker.healthy()
                self.reply(200 if ok else 503, b'{"status": "ok"}' if ok else b'{"status": "stalled"}')
            elif self.path == "/readyz":
                ok = worker.queue.ping() and ping(engine)
                self.reply(200 if ok else 503, b'{"status": "ready"}' if ok else b'{"status": "unavailable"}')
            else:
                self.reply(404, b'{"detail": "Not Found"}')

        def reply(self, code: int, body: bytes):
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):  # keep probe noise out of the logs
            pass

    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main() -> None:
    settings = get_settings()
    if not settings.redis_url:
        log_event("error", "worker_not_configured", detail="Set REDIS_URL, e.g. redis://redis:6379/0")
        raise SystemExit(2)
    engine = make_engine(settings.database_url)
    worker = Worker(
        JobQueue.from_url(settings.redis_url),
        make_session_factory(engine),
        step_seconds=float(os.getenv("WORKER_STEP_SECONDS", "5")),
    )
    port = int(os.getenv("WORKER_HEALTH_PORT", "8081"))
    if port:
        start_health_server(worker, engine, port)

    def stop(signum, frame):
        log_event("info", "worker_stopping", worker=worker.name, signal=signum)
        worker.stopping.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    worker.run()
    engine.dispose()


if __name__ == "__main__":
    main()
