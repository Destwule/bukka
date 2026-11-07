#!/usr/bin/env python3
"""BUK-58 checks: your Dockerfiles, compose.yaml and the running stack.

Run by scripts/verify/buk-58.sh (on your machine) and by the BUK-58 check on
your pull request. Run it from the repo root with the stack up. Prints one
line per check: "PASS  ..." or "FAIL  ... → what to do". Exit code 1 if any
check failed.

  --restart   also run `docker compose down` + `docker compose up -d` and
              check the order is still there (the verify script does this)
"""

import json
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

WEB = os.environ.get("BUK58_WEB_URL", "http://localhost:8000")
SERVICES = ["web", "menu-service", "order-service", "worker", "redis", "db"]
OUR_SERVICES = ["web", "menu-service", "order-service", "worker"]  # images you build
MB = 1_000_000
SIZE_LIMIT = {"web": 60 * MB}  # everything else: 250 MB
DEFAULT_LIMIT = 250 * MB
SKIP_DIRS = {".git", "node_modules", ".venv", "labs", "dist", "artifacts"}

FAILS = 0


def ok(msg):
    print(f"PASS  {msg}", flush=True)


def bad(msg, hint=""):
    global FAILS
    FAILS += 1
    print(f"FAIL  {msg}" + (f" → {hint}" if hint else ""), flush=True)


def check(cond, msg, hint=""):
    ok(msg) if cond else bad(msg, hint)
    return cond


def sh(*args, timeout=120, input_=None):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, input=input_)
        return p.returncode, p.stdout, p.stderr
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        return 1, "", str(exc)


def http(method, path, body=None, timeout=10):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(WEB + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:  # connection refused, timeout
        return 0, str(e)


# --- Files --------------------------------------------------------------------

def dockerfiles():
    found = []
    for root, dirs, files in os.walk("."):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        found += [Path(root, f) for f in files if f == "Dockerfile" or f.startswith("Dockerfile.")
                  or f.endswith(".Dockerfile")]
    return sorted(found)


def final_stage(text):
    """(number of FROM lines, final FROM line, USER lines in the final stage)."""
    lines = [l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("#")]
    froms = [i for i, l in enumerate(lines) if l.upper().startswith("FROM ")]
    if not froms:
        return 0, "", []
    last = froms[-1]
    users = [l.split(None, 1)[1].strip() if len(l.split()) > 1 else "" for l in lines[last:]
             if l.upper().startswith("USER ")]
    return len(froms), lines[last], users


def root_user(u):
    u = u.strip().strip('"').split(":")[0]
    return u in ("", "root", "0")


def check_files():
    print("Your Dockerfiles", flush=True)
    files = dockerfiles()
    rel = [str(f)[2:] if str(f).startswith("./") else str(f) for f in files]
    check(os.path.isfile("web/Dockerfile"), "web/Dockerfile exists")
    check(os.path.isfile("api/Dockerfile"), "api/Dockerfile exists")
    for f, name in zip(files, rel):
        text = f.read_text(errors="replace")
        n, last, users = final_stage(text)
        check(n >= 2, f"{name} is a multi-stage build ({n} stages)",
              "Add a build stage (FROM ... AS build) and copy only the result into the final stage.")
        check(bool(users) and not root_user(users[-1]),
              f"{name}: the final stage runs as a non-root USER ({users[-1] if users else 'none'})",
              "Add USER <non-root user or uid> to the final stage.")
        check(bool(re.search(r"^\s*HEALTHCHECK\s", text, re.M | re.I)),
              f"{name} has a HEALTHCHECK", "Add a HEALTHCHECK instruction to the final stage.")
        if name.startswith("web/"):
            check("nginx" in last.lower() and "node" not in last.lower(),
                  f"{name}: the final stage is Nginx, not Node ({last})")
        leaked = [l for l in text.splitlines() if re.match(r"\s*(ENV|ARG)\s.*(PASSWORD|SECRET|TOKEN)\s*[= ]\s*\S", l, re.I)
                  or re.search(r"://[^:/@\s]+:[^@\s$]+@", l)]
        check(not leaked, f"{name} has no passwords baked in",
              "Pass passwords at run time (compose environment / .env), never in the Dockerfile.")
        ignore = f.parent / ".dockerignore"
        if check(ignore.is_file(), f"{ignore.as_posix()} exists next to {name}",
                 "Add one listing .git, node_modules, .venv and *.db."):
            entries = {l.strip().strip("/").lstrip("*/") for l in ignore.read_text().splitlines()}
            want = {".git"} | ({"node_modules"} if name.startswith("web/") else {".venv"})
            missing = sorted(w for w in want if not any(e.startswith(w) for e in entries))
            check(not missing, f"{ignore.as_posix()} leaves out {', '.join(sorted(want))}",
                  f"Add: {', '.join(missing)}")

    print("\nSecrets", flush=True)
    check(os.path.isfile(".env.example"), ".env.example is committed with placeholder values")
    ignored = sh("git", "check-ignore", "-q", ".env")[0] == 0
    check(ignored, ".env is in .gitignore", "Add a line '.env' to .gitignore.")
    tracked = sh("git", "ls-files", "--error-unmatch", ".env")[0] == 0
    history = sh("git", "log", "--all", "--format=%h", "--", ".env")[1].strip()
    check(not tracked and not history, ".env has never been committed",
          "Remove it (git rm --cached .env), and change every password in it: they're leaked.")
    raw = Path("compose.yaml").read_text(errors="replace") if os.path.isfile("compose.yaml") else ""
    leaks = []
    for i, line in enumerate(raw.splitlines(), 1):
        if line.strip().startswith("#"):
            continue
        # KEY: value, KEY=value or - KEY=value, where KEY mentions a password/secret/token
        m = re.match(r"\s*-?\s*['\"]?([A-Z0-9_]*(PASSWORD|SECRET|TOKEN|API_KEY)[A-Z0-9_]*)['\"]?\s*[:=]\s*['\"]?([^'\"\s#]*)",
                     line, re.I)
        if m and m.group(3) and not m.group(3).startswith("$") and not m.group(1).upper().endswith("_FILE"):
            leaks.append(i)
        m = re.search(r"://[^:/@\s]+:([^@\s]+)@", line)
        if m and not m.group(1).startswith("$"):
            leaks.append(i)
    check(not leaks, "compose.yaml has no passwords written in it",
          f"Line(s) {sorted(set(leaks))}: read them from .env, e.g. POSTGRES_PASSWORD: ${{POSTGRES_PASSWORD}}")
    ips = [ip for ip in re.findall(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", raw) if ip not in ("127.0.0.1", "0.0.0.0")]
    check(not ips, "compose.yaml uses service names, not IP addresses", f"Found {sorted(set(ips))}.")


# --- compose.yaml -------------------------------------------------------------

def check_compose():
    print("\ncompose.yaml", flush=True)
    if not check(os.path.isfile("compose.yaml"), "compose.yaml exists at the repo root"):
        return None
    code, out, err = sh("docker", "compose", "config", "--format", "json")
    if not check(code == 0, "docker compose config is valid", (err.strip().splitlines() or ["?"])[-1][:200]):
        return None
    cfg = json.loads(out)
    svcs = cfg.get("services", {})
    missing = [s for s in SERVICES if s not in svcs]
    check(not missing, f"It has the services {', '.join(SERVICES)}", f"Missing: {', '.join(missing)}")
    img = lambda s: (svcs.get(s, {}).get("image") or "")
    check(re.match(r"(docker\.io/)?(library/)?postgres:16", img("db")) is not None,
          f"db runs PostgreSQL 16 ({img('db') or 'no image'})")
    check(re.match(r"(docker\.io/)?(library/)?redis:7", img("redis")) is not None,
          f"redis runs Redis 7 ({img('redis') or 'no image'})")
    off = [s for s in SERVICES if s in svcs and "bukka-net" not in (svcs[s].get("networks") or {})]
    check(not off, "Every service is on the bukka-net network", f"Not on bukka-net: {', '.join(off)}")

    published = {s: [str(p.get("published", "")) for p in v.get("ports", []) if p.get("published")]
                 for s, v in svcs.items()}
    others = {s: p for s, p in published.items() if p and s != "web"}
    check(not others, "Only web publishes a port", f"Also published: {others}")
    check("8000" in published.get("web", []), "web is published on port 8000",
          f"web publishes {published.get('web') or 'nothing'}.")

    def healthy_dep(svc, dep):
        d = (svcs.get(svc, {}).get("depends_on") or {}).get(dep) or {}
        return d.get("condition") == "service_healthy"

    for svc, deps in {"menu-service": ["db"], "order-service": ["db", "redis"], "worker": ["db", "redis"],
                      "web": ["menu-service", "order-service"]}.items():
        miss = [d for d in deps if not healthy_dep(svc, d)]
        check(not miss, f"{svc} waits for {' and '.join(deps)} to be healthy",
              f"depends_on: {{{miss[0]}: {{condition: service_healthy}}}}" if miss else "")

    vols = svcs.get("db", {}).get("volumes") or []
    named = [v for v in vols if v.get("type") == "volume" and v.get("target") == "/var/lib/postgresql/data"
             and v.get("source")]
    check(bool(named), "PostgreSQL data is in a named volume",
          "Mount a named volume at /var/lib/postgresql/data (top-level volumes:).")
    return cfg


# --- The running stack --------------------------------------------------------

def ps():
    code, out, _ = sh("docker", "compose", "ps", "-a", "--format", "json")
    if code != 0 or not out.strip():
        return []
    out = out.strip()
    if out.startswith("["):
        return json.loads(out)
    return [json.loads(l) for l in out.splitlines() if l.strip()]


def wait_healthy(seconds):
    deadline = time.time() + seconds
    while True:
        rows = {r["Service"]: r for r in ps()}
        if all(rows.get(s, {}).get("Health") == "healthy" for s in SERVICES):
            return rows
        if time.time() > deadline:
            return rows
        time.sleep(3)


def container(rows, svc):
    return rows.get(svc, {}).get("Name") or rows.get(svc, {}).get("ID")


def logs(name, since):
    _, out, err = sh("docker", "logs", "--since", since, name, timeout=30)
    return out + err


def check_running(rows):
    print("\nThe running stack", flush=True)
    for s in SERVICES:
        r = rows.get(s)
        if not r:
            bad(f"{s} is running", "docker compose up -d --build")
            continue
        check(r.get("State") == "running" and r.get("Health") == "healthy",
              f"{s} is running and healthy",
              f"It's {r.get('State')}/{r.get('Health') or 'no healthcheck'}. docker compose logs {s}")
    for svc, r in {k: v for k, v in rows.items() if k not in SERVICES}.items():
        fine = r.get("Health") == "healthy" or (r.get("State") == "exited" and r.get("ExitCode") == 0) \
            or (r.get("State") == "running" and not r.get("Health"))
        check(fine, f"{svc} is healthy or finished cleanly ({r.get('State')}, exit {r.get('ExitCode')})")

    print("\nImages and users", flush=True)
    seen = {}
    for s in OUR_SERVICES:
        name = container(rows, s)
        if not name:
            continue
        code, out, _ = sh("docker", "exec", name, "id", "-u")
        if code == 0:
            check(out.strip() != "0", f"{s} runs as a non-root user (uid {out.strip()})",
                  "Set USER in the final stage of its Dockerfile, and don't override user: in compose.")
        else:
            user = sh("docker", "inspect", "-f", "{{.Config.User}}", name)[1].strip()
            check(not root_user(user), f"{s} runs as a non-root user ({user or 'root'})")
        image_id = sh("docker", "inspect", "-f", "{{.Image}}", name)[1].strip()
        if image_id in seen:
            ok(f"{s} reuses the {seen[image_id]} image")
            continue
        seen[image_id] = s
        size = int(sh("docker", "image", "inspect", "-f", "{{.Size}}", image_id)[1].strip() or 0)
        limit = SIZE_LIMIT.get(s, DEFAULT_LIMIT)
        check(0 < size < limit, f"{s}'s image is under {limit // MB} MB ({size / MB:.0f} MB)",
              "Use a slim/alpine base and copy only what's needed into the final stage.")
        env = json.loads(sh("docker", "image", "inspect", "-f", "{{json .Config.Env}}", image_id)[1] or "[]") or []
        baked = [e.split("=")[0] for e in env if re.search(r"PASSWORD|SECRET|TOKEN", e.split("=")[0], re.I)
                 or re.search(r"://[^:/@]+:[^@]+@", e)]
        check(not baked, f"{s}'s image has no passwords baked in", f"Found {baked} in the image's ENV.")
    web = container(rows, "web")
    if web:
        code, _, _ = sh("docker", "exec", web, "sh", "-c", "command -v node || command -v npm")
        check(code != 0, "The web image has no Node in it", "Build with Node in one stage, serve dist/ from Nginx.")

    print("\nThe services are split", flush=True)
    probe = ("import sys,urllib.request,urllib.error\n"
             "try: print(urllib.request.urlopen('http://127.0.0.1:8080'+sys.argv[1],timeout=5).status)\n"
             "except urllib.error.HTTPError as e: print(e.code)\n"
             "except Exception as e: print(0)")
    for svc, path, other in [("menu-service", "/api/kitchen/orders", "orders"),
                             ("order-service", "/api/restaurants", "restaurants")]:
        name = container(rows, svc)
        if not name:
            continue
        mine = "/api/restaurants" if svc == "menu-service" else "/api/kitchen/orders"
        got_mine = sh("docker", "exec", name, "python", "-c", probe, mine)[1].strip()
        got_other = sh("docker", "exec", name, "python", "-c", probe, path)[1].strip()
        check(got_mine == "200" and got_other == "404",
              f"{svc} serves {mine} but not {path} (port 8080 inside the container)",
              f"Got {got_mine or '?'} and {got_other or '?'}. Run python -m bukka_api.services."
              f"{'menu' if svc == 'menu-service' else 'orders'}, not the monolith.")


def check_end_to_end(rows, restart):
    print(f"\nEnd to end through {WEB}", flush=True)
    code, body = http("GET", "/")
    check(code == 200 and 'id="root"' in body, "The web app loads", f"GET / gave {code}.")
    code, body = http("GET", "/api/restaurants")
    try:
        restaurants = json.loads(body) if code == 200 else []
    except ValueError:
        restaurants = []
    if not check(any(r.get("slug") == "mama-put-yaba" for r in restaurants),
                 "/api/restaurants lists the demo restaurants",
                 f"Got {code}. Did the migrations and seed run? docker compose logs"):
        return None

    since = str(int(time.time()) - 1)
    marker = "verify-" + secrets.token_hex(4)
    http("GET", f"/api/restaurants/{marker}/menu")
    kitchen = "verify-" + secrets.token_hex(4)
    http("GET", f"/api/kitchen/{kitchen}")  # a 404 from whichever service gets it, logged with its path
    time.sleep(2)
    menu_logs = logs(container(rows, "menu-service") or "x", since)
    order_logs = logs(container(rows, "order-service") or "x", since)
    check(marker in menu_logs and marker not in order_logs, "Nginx sends /api/restaurants* to menu-service",
          "location /api/restaurants { proxy_pass http://menu-service:8080; }")
    check(kitchen in order_logs and kitchen not in menu_logs, "Nginx sends /api/kitchen* to order-service",
          "location /api/kitchen { proxy_pass http://order-service:8080; }")

    slug = "mama-put-yaba"
    _, menu = http("GET", f"/api/restaurants/{slug}/menu")
    try:
        dish = json.loads(menu)["dishes"][0]["id"]
    except (ValueError, KeyError, IndexError):
        dish = 1
    since = str(int(time.time()) - 1)
    code, body = http("POST", "/api/orders", {"restaurant_slug": slug, "customer_name": "BUK-58 verify",
                                              "delivery_address": "1 Container Close, Yaba",
                                              "items": [{"dish_id": dish, "quantity": 1}]})
    order = json.loads(body) if code == 201 else {}
    if not check(code == 201, "Placing an order through the web port works", f"POST /api/orders gave {code}: {body[:150]}"):
        return None
    oid = order["id"]
    time.sleep(1)
    check(f'"order_id": {oid}' in logs(container(rows, "order-service") or "x", since),
          "Nginx sends /api/orders to order-service")

    worker = container(rows, "worker")
    status, ticket = "placed", False
    deadline = time.time() + 90
    while time.time() < deadline:
        wl = logs(worker or "x", since)
        ticket = any('"kitchen_ticket_printed"' in l and f'"order_id": {oid}' in l for l in wl.splitlines())
        _, b = http("GET", f"/api/orders/{oid}")
        try:
            status = json.loads(b)["status"]
        except (ValueError, KeyError):
            pass
        if ticket and status == "delivered":
            break
        time.sleep(3)
    check(ticket, f"The worker logged the kitchen ticket for order #{oid}",
          "docker compose logs worker. Does it have REDIS_URL, and does order-service?")
    check(status == "delivered", f"The worker moved order #{oid} along to '{status}' (wants 'delivered')",
          "docker compose logs worker order-service")

    db = container(rows, "db")
    q = f"select status from orders where id = {int(oid)}"
    got = sh("docker", "exec", db or "x", "sh", "-c",
             f'psql -U "$POSTGRES_USER" -d "${{POSTGRES_DB:-$POSTGRES_USER}}" -Atc "{q}"')[1].strip()
    check(got != "", f"Order #{oid} is in PostgreSQL ({got or 'not found'})",
          "The services must use DATABASE_URL=postgresql+psycopg://...@db:5432/...")

    pw = sh("docker", "exec", db or "x", "printenv", "POSTGRES_PASSWORD")[1].strip()
    if pw:
        hit = sh("git", "grep", "-lF", "--", pw, "--", ".", ":!.env.example")[1].strip()
        hist = sh("git", "log", "--all", "-p", "--", ".", ":!.env.example", timeout=60)[1]
        check(not hit and pw not in hist, "The database password isn't in any committed file (except .env.example)",
              "Move it to .env, and change it: it's leaked.")

    if restart:
        print("\nThe data survives a restart (docker compose down, then up)", flush=True)
        code, _, err = sh("docker", "compose", "down", timeout=180)
        check(code == 0, "docker compose down", err.strip()[-200:])
        code, _, err = sh("docker", "compose", "up", "-d", timeout=300)
        check(code == 0, "docker compose up -d", err.strip()[-200:])
        rows = wait_healthy(180)
        still = all(rows.get(s, {}).get("Health") == "healthy" for s in SERVICES)
        check(still, "Every service is healthy again after the restart",
              ", ".join(f"{s}={rows.get(s, {}).get('Health')}" for s in SERVICES))
        code = 0
        deadline = time.time() + 30
        while time.time() < deadline:
            code, body = http("GET", f"/api/orders/{oid}")
            if code == 200:
                break
            time.sleep(2)
        check(code == 200, f"Order #{oid} is still there after docker compose down and up",
              "Keep PostgreSQL's data in a named volume, and don't use down -v.")
    return oid


def main():
    restart = "--restart" in sys.argv
    if not os.path.isfile("tickets/BUK-58.md"):
        print("Run this from the root of your bukka clone.")
        return 2
    check_files()
    cfg = check_compose()
    if cfg is not None:
        rows = {r["Service"]: r for r in ps()}
        if not rows:
            bad("The stack is running", "cp .env.example .env && docker compose up -d --build")
        else:
            rows = wait_healthy(120)
            check_running(rows)
            check_end_to_end(rows, restart)
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
