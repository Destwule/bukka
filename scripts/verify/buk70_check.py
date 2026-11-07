#!/usr/bin/env python3
"""BUK-70 checks: your Kubernetes manifests in k8s/ and what's running.

Run by scripts/verify/buk-70.sh (on your machine) and by the BUK-70 check on
your pull request (against a fresh kind cluster built from your manifests).
Run it from the repo root with kubectl pointing at your cluster. Prints one
line per check: "PASS  ..." or "FAIL  ... → what to do", plus "INFO" lines
for the audit. Exit code 1 if any check failed.

  --rollout     also run the zero-downtime test: customers keep ordering
                through the Ingress while web, menu-service and
                order-service are rolled out (kubectl rollout restart)
  --static      only check the files in k8s/ (no cluster needed, needs PyYAML)
  --ci          on the PR runner: the Secret comes from your example file,
                so don't look for its password in the repo
  --owner NAME  the images must be ghcr.io/NAME/...

Env: BUK70_NAMESPACE (default bukka), BUK70_URL (default http://bukka.localhost).
"""

import base64
import json
import os
import re
import secrets
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "loadtest"))
from lunch_rush import Rush, Target, kubectl_rollout  # noqa: E402

NS = os.environ.get("BUK70_NAMESPACE", "bukka")
URL = os.environ.get("BUK70_URL", "http://bukka.localhost")
K8S = Path("k8s")
EXAMPLE = K8S / "examples" / "secret.example.yaml"
CUSTOMER_FACING = ["web", "menu-service", "order-service"]
APPS = CUSTOMER_FACING + ["worker"]
API_IMAGE = {"web": "bukka-web", "menu-service": "bukka-api", "order-service": "bukka-api", "worker": "bukka-api"}
IMAGE_RE = re.compile(r"^ghcr\.io/([a-z0-9][a-z0-9-]*)/(bukka-web|bukka-api):sha-([0-9a-f]{7,40})$")
SECRETISH = re.compile(r"PASSWORD|SECRET|TOKEN|API_KEY|DATABASE_URL", re.I)
CRED_URL = re.compile(r"://[^:/@\s]+:([^@\s]+)@")

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


def info(key, value):
    print(f"INFO  {key}: {value}", flush=True)


def section(title):
    print(f"\n{title}", flush=True)


def sh(*args, timeout=120, input_=None):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, input=input_)
        return p.returncode, p.stdout, p.stderr
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        return 1, "", str(exc)


def kubectl(*args, timeout=60):
    return sh("kubectl", *args, timeout=timeout)


# --- Reading the manifests ----------------------------------------------------

def manifest_files():
    """The files `kubectl apply -f k8s/` reads (top level only)."""
    if not K8S.is_dir():
        return []
    return sorted(p for p in K8S.iterdir() if p.is_file() and p.suffix in (".yaml", ".yml", ".json"))


def uses_kustomize():
    return any((K8S / n).is_file() for n in ("kustomization.yaml", "kustomization.yml", "Kustomization"))


def manifest_text():
    if uses_kustomize():
        code, out, err = sh("kubectl", "kustomize", str(K8S))
        if code != 0:
            raise ValueError(f"kubectl kustomize k8s failed: {err.strip()[-200:]}")
        return out
    return "\n---\n".join(p.read_text(errors="replace") for p in manifest_files())


def parse_objects(text):
    """Every object in the manifests, as dicts (PyYAML if it's installed,
    otherwise kubectl turns the YAML into JSON)."""
    try:
        import yaml
        docs = list(yaml.safe_load_all(text))
    except ImportError:
        code, out, err = sh("kubectl", "create", "--dry-run=client", "-o", "json", "-f", "-", input_=text)
        if code != 0:
            raise ValueError(err.strip()[-300:])
        doc = json.loads(out) if out.strip() else {}
        docs = doc.get("items", []) if doc.get("kind") == "List" else [doc]
    objs = []
    for d in docs:
        if isinstance(d, dict) and d.get("kind") == "List":
            objs += d.get("items") or []
        elif isinstance(d, dict) and d.get("kind"):
            objs.append(d)
    return objs


def pod_spec(obj):
    spec = obj.get("spec") or {}
    if obj.get("kind") == "CronJob":
        spec = ((spec.get("jobTemplate") or {}).get("spec")) or {}
    return ((spec.get("template") or {}).get("spec")) or {}


def containers(spec, init=True):
    return list(spec.get("containers") or []) + (list(spec.get("initContainers") or []) if init else [])


def command_of(c):
    return " ".join(str(x) for x in (c.get("command") or []) + (c.get("args") or []))


def strings(node):
    if isinstance(node, dict):
        for v in node.values():
            yield from strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from strings(v)
    elif isinstance(node, str):
        yield node


def literal_leaks(objs):
    """Passwords written into the manifests: (where, what)."""
    leaks = []
    for o in objs:
        name = f"{o.get('kind')}/{(o.get('metadata') or {}).get('name')}"
        if o.get("kind") == "Secret" and (o.get("data") or o.get("stringData")):
            leaks.append((name, "a Secret with values in it"))
        if o.get("kind") == "ConfigMap":
            for k, v in (o.get("data") or {}).items():
                if re.search(r"PASSWORD|SECRET|TOKEN|API_KEY", k, re.I):
                    leaks.append((name, f"key {k}"))
        for c in containers(pod_spec(o)):
            for e in c.get("env") or []:
                v = e.get("value")
                if v is None or not SECRETISH.search(e.get("name", "")):
                    continue
                m = CRED_URL.search(str(v))
                if e["name"].upper().endswith("DATABASE_URL") or m:
                    if m and not m.group(1).startswith("$("):
                        leaks.append((name, f"env {e['name']} has the password in it"))
                elif str(v).strip():
                    leaks.append((name, f"env {e['name']} is set to a literal value"))
        for s in strings(o):
            m = CRED_URL.search(s)
            if m and not m.group(1).startswith("$(") and not any(name == l[0] for l in leaks):
                leaks.append((name, "a URL with a password in it"))
    return leaks


def check_manifests(owner=None):
    """The committed files. Returns the parsed objects (or [])."""
    section("Your manifests in k8s/")
    files = manifest_files()
    if not check(bool(files), "k8s/ has your manifests", "Put your YAML files in k8s/ (kubectl apply -f k8s/)."):
        return []
    info("manifests", " ".join(str(p) for p in files))
    try:
        objs = parse_objects(manifest_text())
    except Exception as exc:  # YAML error
        bad("The manifests are valid YAML", str(exc)[:300])
        return []
    ok(f"The manifests are valid YAML ({len(objs)} objects)")

    deploys = {(o.get("metadata") or {}).get("name"): o for o in objs if o.get("kind") == "Deployment"}
    missing = [a for a in APPS if a not in deploys]
    check(not missing, f"There are Deployments named {', '.join(APPS)}", f"Missing: {', '.join(missing)}")

    for app in APPS:
        d = deploys.get(app)
        if not d:
            continue
        imgs = [c.get("image", "") for c in containers(pod_spec(d), init=False)]
        main = imgs[0] if imgs else ""
        m = IMAGE_RE.match(main)
        want = API_IMAGE[app]
        if check(bool(m) and m.group(2) == want,
                 f"{app} uses your {want} image from GHCR, pinned to a commit (sha-...) tag ({main or 'no image'})",
                 f"Use ghcr.io/<you>/{want}:sha-<commit>, the tag your BUK-63 pipeline pushed. Never :latest."):
            if owner:
                check(m.group(1) == owner.lower(), f"{app}'s image is from your own GHCR (ghcr.io/{owner.lower()}/)",
                      f"It's from ghcr.io/{m.group(1)}/. Use the images your own pipeline built.")

    latest = sorted({c.get("image", "") for o in objs for c in containers(pod_spec(o))
                     if c.get("image") and (c["image"].endswith(":latest") or ":" not in c["image"].split("/")[-1])})
    check(not latest, "No image uses :latest or no tag at all", f"Pin these: {', '.join(latest)}")

    jobs = [o for o in objs if o.get("kind") in ("Job", "CronJob")
            and any("alembic upgrade head" in command_of(c) for c in containers(pod_spec(o)))]
    check(bool(jobs), "A Job runs the database migrations (alembic upgrade head)",
          "Add a Job that runs: sh -c \"alembic upgrade head && python -m bukka_api.seed\".")
    in_pods = sorted({n for n, d in deploys.items() for c in containers(pod_spec(d)) if "alembic" in command_of(c)})
    check(not in_pods, "No Deployment runs the migrations from every replica",
          f"{', '.join(in_pods)} run alembic: run it once, from the Job.")

    leaks = literal_leaks(objs)
    check(not leaks, "No passwords are written in the manifests k8s/ applies",
          "; ".join(f"{w}: {what}" for w, what in leaks[:5])
          + ". Create the real Secret with kubectl create secret, and keep only placeholders in "
            f"{EXAMPLE}.")
    check(EXAMPLE.is_file() and "kind: Secret" in EXAMPLE.read_text(errors="replace"),
          f"{EXAMPLE} shows the Secret with placeholder values",
          "Commit an example Secret (placeholders only) there. kubectl apply -f k8s/ doesn't read subfolders.")
    return objs


def check_rollout_log():
    section("Your rollout log")
    f = Path("artifacts/buk-70-rollout.txt")
    if not check(f.is_file(), f"{f} is committed", "Save your order loop's output there (step 17)."):
        return
    lines = f.read_text(errors="replace").splitlines()
    good = [l for l in lines if re.search(r"\b20[01]\b", l)]
    failed = [l for l in lines if re.search(r"\b(000|5\d\d)\b", l) and l not in good]
    check(len(good) >= 30, f"It shows at least 30 successful orders ({len(good)})",
          "Record one line per request with its status code, for the whole rollout.")
    check(not failed, "It shows no failed requests (no 000 or 5xx)", f"For example: {failed[0][:120]}" if failed else "")


# --- The running cluster -------------------------------------------------------

def get_all():
    kinds = "deployments,statefulsets,services,pods,persistentvolumeclaims,configmaps,ingresses,jobs"
    code, out, err = kubectl("get", kinds, "-n", NS, "-o", "json")
    if code != 0:
        return None, err.strip()[-300:]
    items = json.loads(out).get("items", [])
    by = {}
    for i in items:
        by.setdefault(i["kind"], {})[i["metadata"]["name"]] = i
    return by, ""


def selects(selector, labels):
    return bool(selector) and all(labels.get(k) == v for k, v in selector.items())


def pods_of(by, workload):
    sel = ((workload.get("spec") or {}).get("selector") or {}).get("matchLabels") or {}
    return [p for p in by.get("Pod", {}).values() if selects(sel, p["metadata"].get("labels") or {})
            and not p["metadata"].get("deletionTimestamp")]


def pod_ready(p):
    return p.get("status", {}).get("phase") == "Running" and all(
        cs.get("ready") for cs in p.get("status", {}).get("containerStatuses") or [{}])


def env_source(c, name, cms, seen=None):
    """Where container c gets env var `name`: secret, configmap, literal-ref,
    literal or missing."""
    for e in c.get("env") or []:
        if e.get("name") != name:
            continue
        vf = e.get("valueFrom") or {}
        if "secretKeyRef" in vf:
            return "secret"
        if "configMapKeyRef" in vf:
            return "configmap"
        v = str(e.get("value", ""))
        refs = re.findall(r"\$\(([A-Za-z0-9_]+)\)", v)
        if refs and all(env_source(c, r, cms) == "secret" for r in refs if SECRETISH.search(r)) \
                and any(SECRETISH.search(r) for r in refs):
            return "literal-ref"
        return "literal"
    for ef in c.get("envFrom") or []:
        if "secretRef" in ef:
            return "secret?"  # can't see inside from here; assume it's there
        cm = cms.get((ef.get("configMapRef") or {}).get("name"))
        if cm and name in (cm.get("data") or {}):
            return "configmap"
    return "missing"


def maxu_zero(v):
    return v in (0, "0", "0%")


def nonzero(v):
    return v not in (None, 0, "0", "0%")


def check_cluster(owner=None, ci=False):
    """What's running in the bukka namespace. Returns the objects (or None)."""
    section(f"The cluster (namespace {NS})")
    code, out, err = kubectl("config", "current-context")
    info("context", out.strip() or "?")
    code, _, err = kubectl("get", "namespace", NS)
    if not check(code == 0, f"The {NS} namespace exists",
                 (err.strip().splitlines() or ["Is your cluster running? kubectl get nodes"])[-1][:200]):
        return None
    by, err = get_all()
    if by is None:
        bad("kubectl can read the namespace", err)
        return None
    deps = by.get("Deployment", {})
    cms = by.get("ConfigMap", {})

    section("Deployments")
    for app in APPS:
        d = deps.get(app)
        if not check(d is not None, f"Deployment {app} is running", f"kubectl apply -f k8s/, then kubectl -n {NS} get deploy"):
            continue
        spec, st = d["spec"], d.get("status", {})
        want = 2 if app in CUSTOMER_FACING else 1
        ready = st.get("readyReplicas", 0) or 0
        check(spec.get("replicas", 1) >= want and ready >= want,
              f"{app} has at least {want} replica{'s' if want > 1 else ''}, all ready ({ready}/{spec.get('replicas', 1)} ready)",
              f"kubectl -n {NS} get pods; kubectl -n {NS} describe deploy {app}")
        if app in CUSTOMER_FACING:
            strat = spec.get("strategy") or {}
            ru = strat.get("rollingUpdate") or {}
            check(strat.get("type", "RollingUpdate") == "RollingUpdate" and maxu_zero(ru.get("maxUnavailable"))
                  and nonzero(ru.get("maxSurge")),
                  f"{app} rolls out with maxUnavailable: 0 and a surge (maxUnavailable {ru.get('maxUnavailable')}, maxSurge {ru.get('maxSurge')})",
                  "strategy: {type: RollingUpdate, rollingUpdate: {maxUnavailable: 0, maxSurge: 1}}")
        pspec = d["spec"]["template"]["spec"]
        main = (pspec.get("containers") or [{}])[0]
        live, ready_ = main.get("livenessProbe") or {}, main.get("readinessProbe") or {}
        if app in ("menu-service", "order-service"):
            check((live.get("httpGet") or {}).get("path") == "/healthz", f"{app}'s liveness probe is GET /healthz",
                  "livenessProbe: {httpGet: {path: /healthz, port: 8080}}")
            check((ready_.get("httpGet") or {}).get("path") == "/readyz", f"{app}'s readiness probe is GET /readyz",
                  "readinessProbe: {httpGet: {path: /readyz, port: 8080}}")
        elif app == "web":
            check(bool(ready_), "web has a readiness probe", "e.g. readinessProbe: {httpGet: {path: /healthz, port: 8080}}")
        else:
            hg = live.get("httpGet") or {}
            check(hg.get("path") == "/healthz" and str(hg.get("port")) in ("8081", "health"),
                  "worker's liveness probe is GET /healthz on its health port (8081)",
                  "livenessProbe: {httpGet: {path: /healthz, port: 8081}}")
        psc = pspec.get("securityContext") or {}
        cs_ = containers(pspec)
        nonroot = all(((c.get("securityContext") or {}).get("runAsNonRoot", psc.get("runAsNonRoot")) is True) for c in cs_)
        check(nonroot, f"{app} runs with runAsNonRoot: true", "securityContext: {runAsNonRoot: true} on the pod")

    section("Resources")
    for kind in ("Deployment", "StatefulSet"):
        for name, o in by.get(kind, {}).items():
            missing = []
            for c in containers(o["spec"]["template"]["spec"]):
                r = c.get("resources") or {}
                for part in ("requests", "limits"):
                    for res in ("cpu", "memory"):
                        if res not in (r.get(part) or {}):
                            missing.append(f"{c['name']}: {part}.{res}")
            check(not missing, f"{name} sets CPU and memory requests and limits",
                  f"Missing {', '.join(missing[:4])}")

    section("Images")
    for app in APPS:
        d = deps.get(app)
        if not d:
            continue
        for p in pods_of(by, d)[:1]:
            img = (p["spec"]["containers"] or [{}])[0].get("image", "")
            m = IMAGE_RE.match(img)
            info("image", f"{app} {img}")
            if check(bool(m) and m.group(2) == API_IMAGE[app], f"{app} runs a ghcr.io/<you>/{API_IMAGE[app]}:sha-... image ({img})",
                     "Use the image your BUK-63 pipeline pushed, tagged sha-<commit>."):
                if owner:
                    check(m.group(1) == owner.lower(), f"{app}'s image is from ghcr.io/{owner.lower()}/",
                          f"It's from ghcr.io/{m.group(1)}/.")

    section("Services and the Ingress")
    svcs = by.get("Service", {})
    for name in CUSTOMER_FACING:
        s = svcs.get(name)
        if not check(s is not None, f"Service {name} exists", f"The web container's Nginx looks for {name}:8080."):
            continue
        ports = [p.get("port") for p in s["spec"].get("ports") or []]
        if name != "web":
            check(8080 in ports, f"Service {name} listens on port 8080 ({ports})", "Nginx proxies to port 8080.")
        sel = s["spec"].get("selector") or {}
        ready = [p for p in by.get("Pod", {}).values() if selects(sel, p["metadata"].get("labels") or {}) and pod_ready(p)]
        check(len(ready) >= 2, f"Service {name} sends traffic to {len(ready)} ready pods (wants 2+)",
              "Check its selector matches the Deployment's pod labels.")
    routed = False
    for ing in by.get("Ingress", {}).values():
        for rule in ing["spec"].get("rules") or []:
            for p in ((rule.get("http") or {}).get("paths")) or []:
                svc = ((p.get("backend") or {}).get("service") or {}).get("name")
                if rule.get("host") == "bukka.localhost" and svc == "web":
                    routed = True
    check(routed, "An Ingress sends bukka.localhost to the web Service",
          "rules: [{host: bukka.localhost, http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: web, port: ...}}}]}}]")

    section("PostgreSQL and Redis")
    pods = by.get("Pod", {}).values()
    pgs = [p for p in pods if any("postgres" in c.get("image", "") for c in p["spec"]["containers"])]
    pvcs = by.get("PersistentVolumeClaim", {})
    if check(any(pod_ready(p) for p in pgs), "PostgreSQL is running and ready in the cluster",
             "A Deployment or StatefulSet with postgres:16 (and a readiness probe, e.g. pg_isready)."):
        claims = [v["persistentVolumeClaim"]["claimName"] for p in pgs for v in p["spec"].get("volumes") or []
                  if v.get("persistentVolumeClaim")]
        bound = [c for c in claims if (pvcs.get(c) or {}).get("status", {}).get("phase") == "Bound"]
        check(bool(bound), f"PostgreSQL keeps its data on a PersistentVolumeClaim ({', '.join(bound) or 'none'})",
              "Mount a PVC at /var/lib/postgresql/data (or use a StatefulSet volumeClaimTemplate).")
    check(any(pod_ready(p) for p in pods if any(c.get("image", "").split("/")[-1].startswith("redis")
                                                for c in p["spec"]["containers"])),
          "Redis is running and ready in the cluster", "A Deployment with redis:7 and a Service the API can reach.")

    section("Settings and secrets")
    mine = {n: c for n, c in cms.items() if n != "kube-root-ca.crt"}
    check(bool(mine), f"A ConfigMap holds the settings ({', '.join(mine) or 'none'})",
          "Put non-secret settings (LOG_LEVEL, REDIS_URL, ...) in a ConfigMap.")
    leaky = [n for n, c in mine.items() for k, v in (c.get("data") or {}).items()
             if re.search(r"PASSWORD|SECRET|TOKEN", k, re.I) or (CRED_URL.search(str(v)) and not CRED_URL.search(str(v)).group(1).startswith("$("))]
    check(not leaky, "No ConfigMap holds a password", f"Move it out of {', '.join(sorted(set(leaky)))} into a Secret.")
    for app in ("menu-service", "order-service", "worker"):
        d = deps.get(app)
        if not d:
            continue
        c = d["spec"]["template"]["spec"]["containers"][0]
        src = env_source(c, "DATABASE_URL", cms)
        check(src in ("secret", "secret?", "literal-ref"), f"{app} gets DATABASE_URL from a Secret ({src})",
              "env: [{name: DATABASE_URL, valueFrom: {secretKeyRef: {name: ..., key: DATABASE_URL}}}]")
    pw_ref = None
    for p in pgs[:1]:
        c = p["spec"]["containers"][0]
        src = env_source(c, "POSTGRES_PASSWORD", cms)
        if src == "missing" and env_source(c, "POSTGRES_PASSWORD_FILE", cms) != "missing":
            src = "secret?"
        check(src in ("secret", "secret?"), f"PostgreSQL gets POSTGRES_PASSWORD from a Secret ({src})",
              "valueFrom: {secretKeyRef: ...}")
        for e in c.get("env") or []:
            if e.get("name") == "POSTGRES_PASSWORD" and "secretKeyRef" in (e.get("valueFrom") or {}):
                pw_ref = e["valueFrom"]["secretKeyRef"]
        for ef in c.get("envFrom") or []:
            if not pw_ref and "secretRef" in ef:
                pw_ref = {"name": ef["secretRef"]["name"], "key": "POSTGRES_PASSWORD"}
    if pw_ref and not ci:
        code, out, _ = kubectl("get", "secret", pw_ref["name"], "-n", NS, "-o", "json")
        try:
            pw = base64.b64decode(json.loads(out)["data"][pw_ref["key"]]).decode()
        except Exception:
            pw = ""
        if pw:
            hit = sh("git", "grep", "-lF", "--", pw)[1].strip()
            hist = sh("git", "log", "--all", "-p", timeout=90)[1]
            check(len(pw) >= 12 and not hit and pw not in hist,
                  "The database password is long and isn't in any committed file",
                  "Use a long random password (openssl rand -hex 16) and never commit it." if len(pw) < 12
                  else f"It's in {hit.splitlines()[0] if hit else 'your git history'}: change it.")
    return by


def check_app(by):
    """Through the front door, like a customer."""
    section(f"End to end through {URL}")
    t = Target(URL)
    code, _, body = t.request("GET", "/")
    check(code == 200 and 'id="root"' in body, "The web app loads", f"GET / gave {code}. Is the Ingress controller running?")
    code, _, body = t.request("GET", "/api/restaurants")
    try:
        rs = json.loads(body) if code == 200 else []
    except ValueError:
        rs = []
    if not check(any(r.get("slug") == "mama-put-yaba" for r in rs), "/api/restaurants lists the demo restaurants",
                 f"Got {code}. Did the migration Job run? kubectl -n {NS} logs job/<name>"):
        return
    deps = by.get("Deployment", {})

    def logs_of(app, since="60s"):
        d = deps.get(app)
        if not d:
            return ""
        sel = ",".join(f"{k}={v}" for k, v in (d["spec"]["selector"].get("matchLabels") or {}).items())
        _, out, _ = kubectl("logs", "-n", NS, "-l", sel, "--since", since, "--tail", "-1",
                            "--max-log-requests", "10", "--prefix=false", timeout=60)
        return out

    marker = "verify-" + secrets.token_hex(4)
    t.request("GET", f"/api/restaurants/{marker}/menu")
    kitchen = "verify-" + secrets.token_hex(4)
    t.request("GET", f"/api/kitchen/{kitchen}")
    time.sleep(3)
    menu_logs, order_logs = logs_of("menu-service"), logs_of("order-service")
    check(marker in menu_logs and marker not in order_logs, "Nginx sends /api/restaurants* to menu-service",
          "Check web's nginx.conf and the menu-service Service.")
    check(kitchen in order_logs and kitchen not in menu_logs, "Nginx sends /api/kitchen* to order-service")

    probe = ("import sys,urllib.request,urllib.error\n"
             "try: print(urllib.request.urlopen('http://127.0.0.1:8080'+sys.argv[1],timeout=5).status)\n"
             "except urllib.error.HTTPError as e: print(e.code)\n"
             "except Exception: print(0)")
    for app, mine, other in [("menu-service", "/api/restaurants", "/api/kitchen/orders"),
                             ("order-service", "/api/kitchen/orders", "/api/restaurants")]:
        d = deps.get(app)
        pods = [p for p in pods_of(by, d) if pod_ready(p)] if d else []
        if not pods:
            continue
        name = pods[0]["metadata"]["name"]
        a = kubectl("exec", "-n", NS, name, "--", "python", "-c", probe, mine)[1].strip()
        b = kubectl("exec", "-n", NS, name, "--", "python", "-c", probe, other)[1].strip()
        check(a == "200" and b == "404", f"{app} serves {mine} but not {other}",
              f"Got {a or '?'} and {b or '?'}. Run python -m bukka_api.services.{'menu' if app == 'menu-service' else 'orders'}.")

    _, _, menu = t.request("GET", "/api/restaurants/mama-put-yaba/menu")
    try:
        dish = json.loads(menu)["dishes"][0]["id"]
    except (ValueError, KeyError, IndexError):
        dish = 1
    code, _, body = t.request("POST", "/api/orders", {"restaurant_slug": "mama-put-yaba", "customer_name": "BUK-70 verify",
                                                      "delivery_address": "1 Cluster Close, Yaba",
                                                      "items": [{"dish_id": dish, "quantity": 1}]})
    if not check(code == 201, "Placing an order through the Ingress works", f"POST /api/orders gave {code}: {body[:150]}"):
        return
    oid = json.loads(body)["id"]
    status = "placed"
    deadline = time.time() + 120
    while time.time() < deadline:
        c, _, b = t.request("GET", f"/api/orders/{oid}")
        try:
            status = json.loads(b)["status"]
        except (ValueError, KeyError):
            pass
        if status == "delivered":
            break
        time.sleep(3)
    check(status == "delivered", f"The worker moved order #{oid} along to '{status}' (wants 'delivered')",
          f"kubectl -n {NS} logs deploy/worker. Do worker and order-service both have REDIS_URL?")


def check_zero_downtime(by):
    section("Zero downtime: customers keep ordering while web, menu-service and order-service roll out")
    deps = by.get("Deployment", {})
    if not all(a in deps for a in CUSTOMER_FACING):
        bad("The rollout test can run", "web, menu-service and order-service must all exist.")
        return
    before = {p["metadata"]["name"] for a in CUSTOMER_FACING for p in pods_of(by, deps[a])}
    rush = Rush(Target(URL), rps=8)
    window = rush.run(rollout=lambda: kubectl_rollout(NS, CUSTOMER_FACING, timeout=300),
                      rollout_at=8, after_rollout=8, max_seconds=420)
    recs = rush.records
    failed = [r for r in recs if not r[4]]
    if not check(window.get("ok", False), "kubectl rollout restart + rollout status finished for all three",
                 (window.get("log") or "")[-300:]):
        return
    after, _ = get_all()
    now = {p["metadata"]["name"] for a in CUSTOMER_FACING for p in pods_of(after or {}, deps[a])}
    check(now and not (now & before), "Every web, menu-service and order-service pod was replaced",
          f"{len(now & before)} old pods are still running.")
    orders = sum(1 for r in recs if r[1] == "order" and r[4])
    info("rollout_test", f"{len(recs)} requests, {len(failed)} failed, {orders} orders, rollout took "
                         f"{window['end'] - window['start']:.0f}s")
    check(len(recs) >= 100 and orders >= 20, f"Customers kept coming during the rollout ({len(recs)} requests, {orders} orders)")
    check(not failed, f"No request failed during the rollout ({len(failed)} of {len(recs)} failed)",
          "First failures: " + "; ".join(f"{r[0]:.0f}s {r[5]}" for r in failed[:3])
          + ". Readiness probes, maxUnavailable: 0, and giving pods time to leave the Service before they stop.")


def main():
    args = sys.argv[1:]
    owner = None
    if "--owner" in args:
        owner = args[args.index("--owner") + 1] or None
    if not os.path.isfile("tickets/BUK-70.md"):
        print("Run this from the root of your bukka clone.")
        return 2
    check_manifests(owner)
    if "--static" in args:
        return 1 if FAILS else 0
    check_rollout_log()
    by = check_cluster(owner, ci="--ci" in args)
    if by is not None:
        check_app(by)
        if "--rollout" in args:
            check_zero_downtime(by)
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
