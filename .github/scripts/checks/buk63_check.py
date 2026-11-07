#!/usr/bin/env python3
"""BUK-63 checks: your CI workflow, and the proof that it ran on your fork.

  buk63_check.py static [.github/workflows/ci.yml]
      Reads the workflow (needs PyYAML) and checks its shape: triggers,
      permissions, quality gates, the image job, GHCR with GITHUB_TOKEN, no
      publishing from pull requests, SHA tags.

  buk63_check.py remote --repo <owner>/bukka [--green <run id>] [--red <run id>]
                        [--workflow-sha256 <sha256 of ci.yml>]
      Asks GitHub (with the `gh` CLI) for the runs of ci.yml on your fork:
      a green push run, a red one, and the images for the green run's commit
      on GHCR (fetched anonymously, which also proves they're public).
      Without --green/--red it picks them; with them it re-checks those runs.
      Prints "INFO key: value" lines the verify script saves in the audit.

Each check prints "PASS  ..." or "FAIL  ... → what to do". Exit 1 on any FAIL.
Env: BUK63_REGISTRY (default https://ghcr.io), BUK63_IMAGES (default "bukka-web bukka-api").
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

FAILS = 0
WORKFLOW_PATH = ".github/workflows/ci.yml"
REGISTRY = os.environ.get("BUK63_REGISTRY", "https://ghcr.io").rstrip("/")
IMAGES = os.environ.get("BUK63_IMAGES", "bukka-web bukka-api").split()


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


# --- static ---------------------------------------------------------------------

def glob_match(pattern, name):
    """GitHub branch filter globs: ** matches anything, * anything but /."""
    rx = ""
    i = 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            rx, i = rx + ".*", i + 2
        elif pattern[i] == "*":
            rx, i = rx + "[^/]*", i + 1
        elif pattern[i] == "?":
            rx, i = rx + ".", i + 1
        else:
            rx, i = rx + re.escape(pattern[i]), i + 1
    return re.fullmatch(rx, name) is not None


def branch_runs(trigger, name):
    if trigger is None:
        return True  # `push:` with no filters runs on every branch
    if not isinstance(trigger, dict):
        return True
    inc = trigger.get("branches")
    exc = trigger.get("branches-ignore")
    if inc is not None:
        inc = [inc] if isinstance(inc, str) else inc
        result = False
        for p in inc:  # later "!pattern" entries exclude again
            if p.startswith("!"):
                result = result and not glob_match(p[1:], name)
            elif glob_match(p, name):
                result = True
        return result
    if exc is not None:
        exc = [exc] if isinstance(exc, str) else exc
        return not any(glob_match(p, name) for p in exc)
    return True


def text(obj):
    return json.dumps(obj, default=str)


def step_texts(step):
    return " ".join(str(step.get(k, "")) for k in ("run", "uses")) + " " + text(step.get("with", {}))


def static(path):
    print(f"Your workflow ({path})", flush=True)
    try:
        import yaml
    except ImportError:
        bad("PyYAML is installed", "python3 -m pip install pyyaml (or run 'make api-install' first)")
        return
    if not check(os.path.isfile(path), f"{path} exists", "Add your pipeline at .github/workflows/ci.yml."):
        return
    try:
        wf = yaml.safe_load(open(path))
    except yaml.YAMLError as exc:
        bad(f"{path} is valid YAML", str(exc).splitlines()[0])
        return
    if not check(isinstance(wf, dict) and isinstance(wf.get("jobs"), dict), f"{path} is valid YAML with jobs"):
        return
    raw = open(path).read()
    on = wf.get("on", wf.get(True))  # YAML 1.1 reads a bare `on` as True
    if isinstance(on, str):
        on = {on: None}
    elif isinstance(on, list):
        on = {k: None for k in on}
    on = on or {}

    check("pull_request" in on, "Runs on every pull request", "on: pull_request")
    check("pull_request_target" not in on, "Doesn't use pull_request_target",
          "pull_request_target runs fork code with a write token. Use pull_request.")
    push = on.get("push", False) if "push" in on else False
    check("push" in on and branch_runs(push, "main") and branch_runs(push, "buk-63-ci-pipeline"),
          "Runs on pushes to main and to buk-* branches", "on: push: branches: [main, 'buk-*']")

    perms = wf.get("permissions")
    top_ok = isinstance(perms, dict) and perms.get("contents") == "read" and \
        all(v in ("read", "none") for v in perms.values())
    check(top_ok, "Top-level permissions are read-only (contents: read)",
          f"permissions: {{contents: read}} at the top (found {perms!r}).")

    jobs = wf["jobs"]
    steps = {name: (j.get("steps") or []) for name, j in jobs.items() if isinstance(j, dict)}

    def jobs_with(pred):
        return [n for n, ss in steps.items() if any(pred(step_texts(s)) for s in ss if isinstance(s, dict))]

    gates = {
        "API tests (pytest)": jobs_with(lambda t: re.search(r"\bpytest\b", t)),
        "web build (npm ci + npm run build)": [n for n in jobs_with(lambda t: "npm ci" in t)
                                              if n in jobs_with(lambda t: re.search(r"npm run build|vite build", t))],
        "shellcheck": jobs_with(lambda t: "shellcheck" in t.lower()),
        "hadolint": jobs_with(lambda t: "hadolint" in t.lower()),
    }
    for gate, where in gates.items():
        check(bool(where), f"A job runs the {gate}" + (f" ({', '.join(where)})" if where else ""))

    is_build = lambda t: re.search(r"docker/build-push-action|docker (buildx )?build\b|docker push\b", t)
    image_jobs = jobs_with(is_build)
    if not check(bool(image_jobs), f"A job builds the images ({', '.join(image_jobs) or 'none'})",
                 "Use docker/build-push-action (or docker build) in an images job."):
        return

    def needs(name, seen=None):
        seen = seen or set()
        n = jobs[name].get("needs") or []
        for dep in [n] if isinstance(n, str) else n:
            if dep in jobs and dep not in seen:
                seen.add(dep)
                needs(dep, seen)
        return seen

    for ij in image_jobs:
        upstream = needs(ij)
        missing = [g for g, where in gates.items() if where and not (set(where) & upstream)]
        check(not missing, f"'{ij}' only starts after every check passes (needs:)",
              f"Add needs: for the jobs that run: {', '.join(missing)}")

    job_text = " ".join(text(jobs[ij]) for ij in image_jobs)
    built = " ".join(step_texts(s) for ij in image_jobs for s in steps[ij] if isinstance(s, dict) and is_build(step_texts(s)))
    built += " " + text([jobs[ij].get("strategy", {}) for ij in image_jobs])
    for d in ("web", "api"):
        check(re.search(rf"(^|[\s\"'/=.:]){d}(/|\b)", built) is not None, f"It builds the {d} image (context ./{d})")
    check("ghcr.io" in job_text, "It publishes to ghcr.io")
    check(re.search(r"secrets\.GITHUB_TOKEN|github\.token", job_text) is not None,
          "It logs in to GHCR with the built-in GITHUB_TOKEN", "password: ${{ secrets.GITHUB_TOKEN }}")
    other_secrets = sorted(set(re.findall(r"secrets\.([A-Za-z0-9_]+)", raw)) - {"GITHUB_TOKEN"})
    check(not other_secrets, "No other secrets or personal access tokens",
          f"Found secrets.{', secrets.'.join(other_secrets)}. Use GITHUB_TOKEN only.")
    check(re.search(r"type=sha|github\.sha|GITHUB_SHA", job_text) is not None,
          "Images are tagged with the commit SHA", "docker/metadata-action with tags: type=sha")

    writers = {n: (j.get("permissions") or {}) for n, j in jobs.items() if isinstance(j, dict)}
    pkg = [n for n, p in writers.items() if isinstance(p, dict) and p.get("packages") == "write"]
    check(bool(pkg) and set(pkg) <= set(image_jobs), "Only the image job gets packages: write",
          f"permissions: {{contents: read, packages: write}} on the images job only (found on {pkg or 'none'}).")
    other_writes = [n for n, p in writers.items() if n not in image_jobs and
                    (p == "write-all" or (isinstance(p, dict) and "write" in p.values()))]
    check(not other_writes, "No other job can write", f"Remove write permissions from {other_writes}.")

    # Every push to the registry must be switched off for pull requests.
    ungated = []
    gate_rx = re.compile(r"github\.event_name|github\.ref\b|github\.ref_name|startsWith\(github\.ref")
    for ij in image_jobs:
        job_if = str(jobs[ij].get("if", ""))
        for s in steps[ij]:
            if not isinstance(s, dict):
                continue
            uses, run = str(s.get("uses", "")), str(s.get("run", ""))
            pushes = ("build-push-action" in uses and str((s.get("with") or {}).get("push", "false")).lower() != "false") \
                or re.search(r"docker (image )?push\b|--push\b", run)
            if not pushes:
                continue
            guard = job_if + str(s.get("if", "")) + str((s.get("with") or {}).get("push", ""))
            if not gate_rx.search(guard):
                ungated.append(s.get("name") or uses or run[:40])
    check(not ungated, "Images are only pushed on a push, never from a pull request",
          f"Gate these with github.event_name: {ungated}. e.g. push: ${{{{ github.event_name == 'push' }}}}")


# --- remote ---------------------------------------------------------------------

def gh_api(path):
    p = subprocess.run(["gh", "api", path], capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout).strip().splitlines()[-1] if (p.stderr or p.stdout).strip() else "gh api failed")
    return json.loads(p.stdout)


def image_public(owner, image, tag):
    repo = f"{owner.lower()}/{image}"
    try:
        with urllib.request.urlopen(f"{REGISTRY}/token?scope=repository:{repo}:pull", timeout=20) as r:
            token = json.loads(r.read())["token"]
        req = urllib.request.Request(f"{REGISTRY}/v2/{repo}/manifests/{tag}", method="HEAD", headers={
            "Authorization": f"Bearer {token}",
            "Accept": ", ".join([
                "application/vnd.oci.image.index.v1+json", "application/vnd.oci.image.manifest.v1+json",
                "application/vnd.docker.distribution.manifest.list.v2+json",
                "application/vnd.docker.distribution.manifest.v2+json"]),
        })
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status == 200, ""
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}"
    except Exception as e:
        return False, type(e).__name__


def workflow_at(repo, sha):
    import base64
    import hashlib
    data = gh_api(f"repos/{repo}/contents/{WORKFLOW_PATH}?ref={sha}")
    return hashlib.sha256(base64.b64decode(data["content"])).hexdigest()


def remote(repo, green_id=None, red_id=None, workflow_sha256=None):
    print(f"\nThe pipeline on {repo}", flush=True)
    owner = repo.split("/")[0]
    try:
        if green_id or red_id:
            runs = [gh_api(f"repos/{repo}/actions/runs/{i}") for i in (green_id, red_id) if i]
        else:
            runs = gh_api(f"repos/{repo}/actions/workflows/ci.yml/runs?per_page=100").get("workflow_runs", [])
    except Exception as exc:
        bad(f"GitHub lists the runs of ci.yml on {repo}", f"{exc}. Run 'gh auth login', and push your branch.")
        return
    ok(f"GitHub lists the runs of ci.yml on {repo}")

    def mine(r):
        return (r.get("path", "").split("@")[0] == WORKFLOW_PATH
                and (r.get("head_repository") or r.get("repository") or {}).get("full_name", "").lower() == repo.lower())

    green = [r for r in runs if mine(r) and r.get("event") == "push" and r.get("conclusion") == "success"
             and (green_id is None or str(r.get("id")) == str(green_id))]
    if green_id is None:
        green = [r for r in green if str(r.get("head_branch", "")).startswith("buk-63-")]
    red = [r for r in runs if mine(r) and r.get("conclusion") == "failure"
           and (red_id is None or str(r.get("id")) == str(red_id))]

    if check(bool(green), "A green push run of ci.yml on a buk-63 branch",
             "Push your branch to your fork and wait for the pipeline to pass (Actions must be enabled on your fork)."):
        g = green[0]
        info("green_run", g.get("html_url"))
        info("green_run_id", g.get("id"))
        info("green_sha", g.get("head_sha"))
        if workflow_sha256:
            try:
                ran = workflow_at(repo, g.get("head_sha"))
            except Exception as exc:
                ran = f"unknown ({exc})"
            check(ran == workflow_sha256, "The green run used the ci.yml in this pull request",
                  "You changed ci.yml after the green run. Push, wait for a green run, and run verify again.")
        tag = "sha-" + str(g.get("head_sha", ""))[:7]
        for image in IMAGES:
            found, why = image_public(owner, image, tag)
            ref = f"ghcr.io/{owner.lower()}/{image}:{tag}"
            if check(found, f"{ref} is published and public",
                     f"{why or 'not found'}. Did the images job push it, and is the package public "
                     "(Package settings → Change visibility)?"):
                info("image", ref)
    if check(bool(red), "A red run of ci.yml (the broken test from step 15)",
             "Push a commit that breaks an API test, let the pipeline fail, then revert it."):
        info("red_run", red[0].get("html_url"))
        info("red_run_id", red[0].get("id"))


def main(argv):
    if not argv or argv[0] not in ("static", "remote"):
        print(__doc__)
        return 2
    if argv[0] == "static":
        static(argv[1] if len(argv) > 1 else WORKFLOW_PATH)
    else:
        args = dict(zip(argv[1::2], argv[2::2]))
        if "--repo" not in args:
            print("remote needs --repo <owner>/<repo>")
            return 2
        remote(args["--repo"], args.get("--green"), args.get("--red"), args.get("--workflow-sha256"))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
