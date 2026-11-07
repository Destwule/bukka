#!/usr/bin/env python3
"""The Lunch Rush: hungry customers hitting Bukka through the front door.

Each simulated customer does what a hungry person does at lunch:

  1. GET  /api/restaurants              (look around)
  2. GET  /api/restaurants/<slug>/menu  (open a menu)
  3. POST /api/orders                   (order something)
  4. GET  /api/orders/<id>              (check on it)

Customers arrive at a steady rate so the whole run makes about --rps requests
a second. Part way through, it rolls out web, menu-service and order-service
(`kubectl rollout restart`) while the customers keep coming, because on
launch day you will ship a fix in the middle of the rush.

Run it from the root of your bukka clone, with your cluster up (BUK-77):

    python3 scripts/loadtest/lunch_rush.py                # 3 minutes at 10 rps
    python3 scripts/loadtest/lunch_rush.py --minutes 1 --no-rollout   # a quick try

It prints a summary and saves it to artifacts/buk-77-lunch-rush.txt. The
run passes when fewer than 1% of requests fail, p95 is under 1000 ms and no
request fails during the rollout. Only the Python standard library is used.
"""

import argparse
import http.client
import json
import os
import random
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlsplit

DEFAULT_URL = os.environ.get("BUKKA_URL", "http://bukka.localhost")
ROLLOUT = ["web", "menu-service", "order-service"]
STEPS = ["restaurants", "menu", "order", "status"]
# The bar for the BUK-77 Lunch Rush.
MAX_ERROR_PERCENT = 1.0
MAX_P95_MS = 1000


class Target:
    """Sends requests to a URL like http://bukka.localhost.

    *.localhost names don't resolve everywhere (Python on macOS, some Linux
    setups), so if the name doesn't resolve we connect to 127.0.0.1 and send
    the name in the Host header, which is all the Ingress looks at.
    """

    def __init__(self, url):
        parts = urlsplit(url.rstrip("/"))
        self.url = url.rstrip("/")
        self.https = parts.scheme == "https"
        self.host_header = parts.netloc
        self.port = parts.port or (443 if self.https else 80)
        self.addr = parts.hostname
        try:
            socket.getaddrinfo(self.addr, self.port)
        except socket.gaierror:
            if self.addr.endswith(".localhost") or self.addr == "localhost":
                self.addr = "127.0.0.1"

    def request(self, method, path, body=None, timeout=10):
        """Returns (status, milliseconds, text). status 0 = no HTTP answer."""
        cls = http.client.HTTPSConnection if self.https else http.client.HTTPConnection
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Host": self.host_header, "Connection": "close", "User-Agent": "bukka-lunch-rush"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        start = time.monotonic()
        conn = cls(self.addr, self.port, timeout=timeout)
        try:
            conn.request(method, path, body=data, headers=headers)
            resp = conn.getresponse()
            text = resp.read().decode(errors="replace")
            return resp.status, (time.monotonic() - start) * 1000, text
        except Exception as exc:  # refused, reset, timed out
            return 0, (time.monotonic() - start) * 1000, f"{type(exc).__name__}: {exc}"
        finally:
            conn.close()


class Rush:
    """Customers arriving at a steady rate; every request is recorded."""

    def __init__(self, target, rps, workers=64):
        self.target = target
        self.rps = rps
        self.records = []  # (t_since_start, step, status, ms, ok, detail)
        self.lock = threading.Lock()
        self.pool = ThreadPoolExecutor(max_workers=workers)
        self.t0 = None
        self.n = 0

    def _record(self, step, status, ms, ok, detail=""):
        with self.lock:
            self.records.append((time.monotonic() - self.t0, step, status, ms, ok, detail[:160]))

    def _call(self, step, method, path, body=None, want=(200,)):
        status, ms, text = self.target.request(method, path, body)
        ok = status in want
        self._record(step, status, ms, ok, "" if ok else f"{method} {path} -> {status or text}")
        return ok, text

    def customer(self):
        self.n += 1
        n = self.n
        ok, text = self._call("restaurants", "GET", "/api/restaurants")
        if not ok:
            return
        try:
            slug = random.choice([r["slug"] for r in json.loads(text)])
        except (ValueError, KeyError, TypeError, IndexError):
            slug = "mama-put-yaba"
        ok, text = self._call("menu", "GET", f"/api/restaurants/{slug}/menu")
        if not ok:
            return
        try:
            dish = random.choice(json.loads(text)["dishes"])["id"]
        except (ValueError, KeyError, TypeError, IndexError):
            return
        ok, text = self._call("order", "POST", "/api/orders", {
            "restaurant_slug": slug, "customer_name": f"Lunch Rush {n}",
            "delivery_address": "12 Rush Hour Road, Yaba", "items": [{"dish_id": dish, "quantity": 1}],
        }, want=(201,))
        if not ok:
            return
        try:
            order_id = json.loads(text)["id"]
        except (ValueError, KeyError, TypeError):
            return
        self._call("status", "GET", f"/api/orders/{order_id}")

    def run(self, seconds=None, rollout=None, rollout_at=10.0, after_rollout=10.0, max_seconds=600):
        """Run for `seconds`. With `rollout` (a callable), start it at
        `rollout_at` seconds; without `seconds`, stop `after_rollout` seconds
        after the rollout finishes. Returns the rollout window (start, end)."""
        self.t0 = time.monotonic()
        interval = len(STEPS) / self.rps  # one customer makes 4 requests
        window = {}

        def do_rollout():
            window["start"] = time.monotonic() - self.t0
            window["ok"], window["log"] = rollout()
            window["end"] = time.monotonic() - self.t0

        roller = None
        k = 0
        while True:
            now = time.monotonic() - self.t0
            if rollout and roller is None and now >= rollout_at:
                roller = threading.Thread(target=do_rollout, daemon=True)
                roller.start()
            if seconds is not None and now >= seconds:
                break
            if seconds is None and "end" in window and now >= window["end"] + after_rollout:
                break
            if now >= max_seconds:
                break
            self.pool.submit(self.customer)
            k += 1
            time.sleep(max(0.0, k * interval - (time.monotonic() - self.t0)))
        self.pool.shutdown(wait=True)
        if roller is not None:
            roller.join(timeout=420)
        self.elapsed = time.monotonic() - self.t0
        return window


def kubectl_rollout(namespace, deployments, timeout=300):
    """`kubectl rollout restart` the deployments and wait for each to finish.
    Returns (all finished, log text)."""
    log = []
    ok = True

    def run(*args):
        nonlocal ok
        cmd = ["kubectl", "-n", namespace, *args]
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 30)
            out, code = (p.stdout + p.stderr).strip(), p.returncode
        except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
            out, code = str(exc), 1
        log.append(f"$ {' '.join(cmd)}\n{out}")
        ok = ok and code == 0

    run("rollout", "restart", *[f"deployment/{d}" for d in deployments])
    for d in deployments:
        run("rollout", "status", f"deployment/{d}", f"--timeout={timeout}s")
    return ok, "\n".join(log)


def percentile(values, p):
    if not values:
        return 0
    values = sorted(values)
    i = min(len(values) - 1, max(0, int(round(p / 100 * len(values) + 0.5)) - 1))
    return values[i]


def summarise(rush, window):
    rec = rush.records
    failed = [r for r in rec if not r[4]]
    ms = [r[3] for r in rec]
    s = {
        "requests": len(rec),
        "failed": len(failed),
        "error_rate_percent": round(100 * len(failed) / len(rec), 2) if rec else 100.0,
        "achieved_rps": round(len(rec) / rush.elapsed, 2) if rush.elapsed else 0,
        "p50_ms": round(percentile(ms, 50)),
        "p95_ms": round(percentile(ms, 95)),
        "max_ms": round(max(ms)) if ms else 0,
        "orders_placed": sum(1 for r in rec if r[1] == "order" and r[4]),
    }
    if window:
        inside = [r for r in rec if window["start"] <= r[0] <= window.get("end", rush.elapsed) + 5]
        s.update({
            "rollout_during_load": "yes" if window.get("ok") else "failed",
            "rollout_started_at_second": round(window["start"]),
            "rollout_seconds": round(window.get("end", rush.elapsed) - window["start"]),
            "rollout_window_requests": len(inside),
            "rollout_window_failed": sum(1 for r in inside if not r[4]),
        })
    else:
        s["rollout_during_load"] = "no"
    s["by_step"] = {st: (sum(1 for r in rec if r[1] == st), sum(1 for r in rec if r[1] == st and not r[4]),
                         round(percentile([r[3] for r in rec if r[1] == st], 95)))
                    for st in STEPS}
    s["failures"] = [f"{r[0]:7.1f}s  {r[1]:<11} {r[5]}" for r in failed[:20]]
    return s


def main():
    ap = argparse.ArgumentParser(description="BUK-77 Lunch Rush load test")
    ap.add_argument("--url", default=DEFAULT_URL, help=f"front door (default {DEFAULT_URL})")
    ap.add_argument("--rps", type=float, default=10, help="requests per second (default 10)")
    ap.add_argument("--minutes", type=float, default=3, help="how long to run (default 3)")
    ap.add_argument("--ramp", type=float, default=15, help="seconds at half speed first (default 15)")
    ap.add_argument("--namespace", default=os.environ.get("BUKKA_NAMESPACE", "bukka"))
    ap.add_argument("--no-rollout", action="store_true", help="don't roll anything out during the run")
    ap.add_argument("--out", default="artifacts/buk-77-lunch-rush.txt")
    a = ap.parse_args()

    target = Target(a.url)
    status, _, _ = target.request("GET", "/api/restaurants")
    if status != 200:
        print(f"GET {a.url}/api/restaurants gave {status or 'no answer'}. Is your cluster up and the Ingress working?")
        return 2

    seconds = a.minutes * 60
    rollout_at = max(a.ramp + 15, seconds / 3)
    print(f"Lunch Rush: {a.url}, {a.rps:g} requests/s for {a.minutes:g} min"
          + ("" if a.no_rollout else f", rolling out {', '.join(ROLLOUT)} at {rollout_at:.0f}s") + ".")
    if a.ramp > 0:
        Rush(target, a.rps / 2).run(seconds=a.ramp)  # warm-up, not counted
    rush = Rush(target, a.rps)
    rollout = None if a.no_rollout else (lambda: kubectl_rollout(a.namespace, ROLLOUT))
    stop = threading.Event()

    def progress():
        while not stop.wait(15):
            with rush.lock:
                n, bad_n = len(rush.records), sum(1 for r in rush.records if not r[4])
            print(f"  {time.monotonic() - rush.t0:5.0f}s  {n} requests, {bad_n} failed", flush=True)

    threading.Thread(target=progress, daemon=True).start()
    window = rush.run(seconds=seconds, rollout=rollout, rollout_at=rollout_at)
    stop.set()
    s = summarise(rush, window)

    passed = (s["error_rate_percent"] < MAX_ERROR_PERCENT and s["p95_ms"] < MAX_P95_MS
              and (a.no_rollout or (s["rollout_during_load"] == "yes" and s["rollout_window_failed"] == 0)))
    lines = [
        "# BUK-77 Lunch Rush (scripts/loadtest/lunch_rush.py)",
        f"generated_at: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}",
        f"target: {a.url}",
        f"duration_seconds: {round(rush.elapsed)}",
        f"target_rps: {a.rps:g}",
    ] + [f"{k}: {v}" for k, v in s.items() if k not in ("by_step", "failures")] + [
        f"result: {'PASS' if passed else 'FAIL'}",
        "",
        f"bar: fewer than {MAX_ERROR_PERCENT:g}% failed, p95 under {MAX_P95_MS} ms, no failures during the rollout",
        "",
        "step         requests  failed  p95_ms",
    ] + [f"{st:<12} {n:>8}  {f:>6}  {p:>6}" for st, (n, f, p) in s["by_step"].items()]
    if s["failures"]:
        lines += ["", "first failures:"] + s["failures"]
    if window.get("log"):
        lines += ["", "rollout:", window["log"]]
    text = "\n".join(lines) + "\n"
    print()
    print(text)
    if a.out:
        os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
        with open(a.out, "w") as f:
            f.write(text)
        print(f"Saved to {a.out}.")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
