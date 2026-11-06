"""One JSON line per request on stdout.

Structured logs are what log tools (CloudWatch, Loki, a Python script) can
actually parse: every request becomes
{"ts": ..., "level": "info", "method": "GET", "path": "/api/restaurants",
 "status": 200, "response_time_ms": 4, "client": "10.0.0.5"}
"""

import json
import sys
import time
from datetime import datetime, timezone

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request


def log_event(level: str, message: str, **fields) -> None:
    record = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "level": level,
        "msg": message,
        **fields,
    }
    sys.stdout.write(json.dumps(record) + "\n")
    sys.stdout.flush()


class AccessLogMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        start = time.perf_counter()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            return response
        finally:
            elapsed_ms = round((time.perf_counter() - start) * 1000)
            forwarded = request.headers.get("x-forwarded-for", "")
            client = forwarded.split(",")[0].strip() if forwarded else (request.client.host if request.client else "")
            log_event(
                "error" if status >= 500 else "info",
                "request",
                method=request.method,
                path=request.url.path,
                status=status,
                response_time_ms=elapsed_ms,
                client=client,
            )
