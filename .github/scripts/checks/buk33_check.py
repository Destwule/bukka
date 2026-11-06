"""BUK-33 behaviour tests for the apprentice's health check and traffic report.

Used by scripts/verify/buk-33.sh (locally) and .github/scripts/checks/buk-33.sh
(in CI). Prints one 'PASS  ...' or 'FAIL  ...' line per check; exit 1 if any fail.
"""

import http.server
import json
import math
import os
import random
import re
import subprocess
import sys
import tempfile
import threading
from collections import Counter
from pathlib import Path

HC = Path("scripts/ops/server-healthcheck.sh")
REPORT = Path("scripts/ops/traffic_report.py")
CRON = Path("deploy/cron/bukka-ops")
RESULTS: list[str] = []


def check(name: str, ok: bool, hint: str = "") -> None:
    RESULTS.append(("PASS  " if ok else "FAIL  ") + name + ("" if ok or not hint else f" ({hint})"))


# --- Expected report, computed independently -------------------------------

def expected_report(lines: list[str]) -> dict:
    times, paths, errors, skipped = [], Counter(), 0, 0
    for line in lines:
        try:
            rec = json.loads(line)
        except ValueError:
            skipped += 1
            continue
        if not isinstance(rec, dict) or rec.get("msg") != "request":
            skipped += 1
            continue
        times.append(rec["response_time_ms"])
        paths[rec["path"]] += 1
        errors += rec["status"] >= 500
    n = len(times)
    rate = round(errors / n * 100, 2) if n else 0
    p95 = sorted(times)[math.ceil(0.95 * n) - 1] if n else 0
    top = sorted(paths.items(), key=lambda kv: (-kv[1], kv[0]))[:3]
    return {
        "total_requests": n,
        "errors_5xx": errors,
        "error_rate_percent": rate,
        "p95_response_ms": p95,
        "slow_requests": sum(t > 500 for t in times),
        "top_paths": [{"path": p, "count": c} for p, c in top],
        "status": "OK" if rate < 5 else "CRITICAL",
        "skipped_lines": skipped,
    }


def make_log(seed: int, n: int, error_share: float) -> list[str]:
    rng = random.Random(seed)
    paths = ["/api/restaurants", "/api/restaurants/mama-put-yaba/menu", "/api/orders",
             "/api/kitchen/orders", "/healthz", "/api/orders/42"]
    lines = []
    for i in range(n):
        status = 500 if rng.random() < error_share else rng.choice([200, 200, 200, 201, 404, 422])
        lines.append(json.dumps({
            "ts": f"2026-11-0{rng.randint(1, 9)}T12:{i % 60:02d}:00.000+00:00", "level": "info",
            "msg": "request", "method": "GET", "path": rng.choice(paths), "status": status,
            "response_time_ms": int(rng.expovariate(1 / 120)), "client": "10.0.0.5",
        }))
        if rng.random() < 0.05:
            lines.append(json.dumps({"ts": "x", "level": "info", "msg": "order_placed", "order_id": i}))
        if rng.random() < 0.02:
            lines.append("this is not json {")
    return lines


def run_report(lines: list[str]) -> tuple[dict | None, str]:
    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as f:
        f.write("\n".join(lines) + "\n")
        path = f.name
    try:
        out = subprocess.run([sys.executable, str(REPORT), path], capture_output=True, text=True, timeout=30)
    finally:
        os.unlink(path)
    if out.returncode != 0:
        return None, out.stderr.strip()[-200:]
    try:
        return json.loads(out.stdout), ""
    except ValueError:
        return None, "output is not a single JSON object"


# --- Fake health endpoint ---------------------------------------------------

class Health(http.server.BaseHTTPRequestHandler):
    code = 200

    def do_GET(self):  # noqa: N802
        self.send_response(Health.code)
        self.end_headers()
        self.wfile.write(b'{"status": "ok"}')

    def log_message(self, *a):
        pass


def run_hc(env: dict) -> tuple[int, list[dict]]:
    out = subprocess.run(["bash", str(HC)], capture_output=True, text=True, timeout=30,
                         env={**os.environ, **env})
    records = []
    for line in out.stdout.splitlines():
        try:
            records.append(json.loads(line))
        except ValueError:
            pass
    return out.returncode, records


def main() -> int:
    # Traffic report
    if not REPORT.exists():
        check("traffic_report.py exists", False, f"create {REPORT}")
    else:
        check("traffic_report.py exists", True)
        # Distinct response times 10..200 ms in shuffled order, so an
        # off-by-one percentile gives a different answer.
        crafted = [json.dumps({"msg": "request", "path": f"/api/p{i % 4}", "status": 500 if i % 10 == 0 else 200,
                               "response_time_ms": t}) for i, t in enumerate(random.Random(5).sample(range(10, 201, 10), 20))]
        cases = [("crafted", crafted), ("normal day", make_log(7, 400, 0.02)), ("bad lunch rush", make_log(11, 250, 0.12)),
                 ("one request", make_log(3, 1, 0.0)), ("empty log", [])]
        for label, lines in cases:
            got, err = run_report(lines)
            want = expected_report(lines)
            if got is None:
                check(f"Report is correct: {label}", False, err or "crashed")
                continue
            wrong = [k for k in want if got.get(k) != want[k]]
            extra = sorted(set(got) - set(want))
            check(f"Report is correct: {label}", not wrong and not extra,
                  f"wrong: {', '.join(wrong)}" if wrong else f"unexpected fields: {', '.join(extra)}")

    # Health check
    if not HC.exists():
        check("server-healthcheck.sh exists", False, f"create {HC}")
    else:
        text = HC.read_text()
        check("server-healthcheck.sh uses set -euo pipefail", "set -euo pipefail" in text)
        check("server-healthcheck.sh is executable", os.access(HC, os.X_OK), f"chmod +x {HC}")
        sc = subprocess.run(["shellcheck", str(HC)], capture_output=True, text=True) if \
            subprocess.run(["which", "shellcheck"], capture_output=True).returncode == 0 else None
        if sc is not None:
            check("server-healthcheck.sh is clean under shellcheck", sc.returncode == 0,
                  sc.stdout.strip().splitlines()[0] if sc.stdout.strip() else "")

        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Health)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{srv.server_address[1]}/healthz"
        try:
            Health.code = 200
            code, recs = run_hc({"BUKKA_HEALTH_URL": url, "BUKKA_DISK_THRESHOLD": "100", "BUKKA_MIN_FREE_MB": "1"})
            checks = {r.get("check"): r for r in recs}
            check("Healthy server: exits 0", code == 0, f"exited {code}")
            check("Prints disk, memory and api checks as JSON lines",
                  {"disk", "memory", "api"} <= set(checks), f"got {sorted(checks)}")
            check("Disk check reports used_percent",
                  isinstance(checks.get("disk", {}).get("used_percent"), (int, float)))

            Health.code = 503
            code, _ = run_hc({"BUKKA_HEALTH_URL": url, "BUKKA_DISK_THRESHOLD": "100"})
            check("API unhealthy (HTTP 503): exits 1", code == 1, f"exited {code}")

            code, _ = run_hc({"BUKKA_HEALTH_URL": "http://127.0.0.1:9/healthz", "BUKKA_DISK_THRESHOLD": "100"})
            check("API unreachable: exits 1", code == 1, f"exited {code}")

            Health.code = 200
            code, recs = run_hc({"BUKKA_HEALTH_URL": url, "BUKKA_DISK_THRESHOLD": "0"})
            disk = next((r for r in recs if r.get("check") == "disk"), {})
            check("Disk over threshold: exits 2 and status alert", code == 2 and disk.get("status") == "alert",
                  f"exited {code}, disk status {disk.get('status')}")

            Health.code = 503
            code, _ = run_hc({"BUKKA_HEALTH_URL": url, "BUKKA_DISK_THRESHOLD": "0"})
            check("Disk and API both failing: exits 2", code == 2, f"exited {code}")

            Health.code = 200
            code, recs = run_hc({"BUKKA_HEALTH_URL": url, "BUKKA_DISK_THRESHOLD": "100",
                                 "BUKKA_MIN_FREE_MB": "99999999"})
            mem = next((r for r in recs if r.get("check") == "memory"), {})
            check("Low memory warns but still exits 0", code == 0 and mem.get("status") == "warn",
                  f"exited {code}, memory status {mem.get('status')}")
        finally:
            srv.shutdown()

    # Cron
    if not CRON.exists():
        check("Cron file deploy/cron/bukka-ops exists", False)
    else:
        jobs = [l.split() for l in CRON.read_text().splitlines() if l.strip() and not l.lstrip().startswith("#")
                and not re.match(r"^\s*\w+=", l)]
        hc = [j for j in jobs if any("server-healthcheck.sh" in w for w in j)]
        rp = [j for j in jobs if any("traffic_report.py" in w for w in j)]
        check("Cron runs the health check every 5 minutes with a user column",
              any(j[:5] == ["*/5", "*", "*", "*", "*"] and len(j) > 6 for j in hc))
        check("Cron runs the report daily at 23:55",
              any(j[:2] == ["55", "23"] and j[2:5] == ["*", "*", "*"] for j in rp))
        check("Cron output goes to /var/log/bukka/", all(any("/var/log/bukka/" in w for w in j) for j in hc + rp)
              and bool(hc and rp))

    print("\n".join(RESULTS))
    return 1 if any(r.startswith("FAIL") for r in RESULTS) else 0


if __name__ == "__main__":
    sys.exit(main())
