#!/usr/bin/env python3
"""BUK-77 checks: the launch readiness review.

Run by scripts/verify/buk-77.sh (on your machine, with your cluster up) and
by the BUK-77 check on your pull request (--files: no cluster there).
Prints "PASS  ..." / "FAIL  ... → what to do" lines. Exit 1 if any failed.

  --files       only the committed files: manifests, docs, runbook, CI,
                and the evidence in artifacts/ (no cluster needed)
  --owner NAME  the images must be ghcr.io/NAME/...
"""

import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import buk70_check as k  # noqa: E402  (shares its PASS/FAIL counter)

DOC = Path("docs/launch-readiness.md")
RUNBOOK = Path("runbooks/orders-stopped.md")
CI = Path(".github/workflows/ci.yml")
RUSH = Path("artifacts/buk-77-lunch-rush.txt")
ROLLBACK = Path("artifacts/buk-77-rollback.txt")
PLAN = Path("artifacts/buk-77-terraform-plan.txt")

DOC_SECTIONS = ["## Architecture", "## Launch checklist", "## Lunch Rush results", "## Rollback rehearsal",
                "## Risks and next steps"]
RUNBOOK_SECTIONS = ["## How you know", "## Check first", "## Fix", "## Why it happens"]
# Every piece the architecture diagram must show (any one spelling counts).
PIECES = {
    "the Ingress": r"ingress",
    "web (Nginx)": r"\bweb\b|nginx",
    "the menu service": r"menu[- ]service",
    "the order service": r"order[- ]service",
    "the worker": r"\bworker\b",
    "Redis": r"redis",
    "PostgreSQL": r"postgres",
    "the registry (GHCR)": r"ghcr|registry",
    "the pipeline": r"pipeline|github actions|\bci\b",
}
MIN_DOC_WORDS = 400
MIN_RUNBOOK_WORDS = 200
MIN_TICKED = 7
# The Lunch Rush bar (same as scripts/loadtest/lunch_rush.py).
RUSH_MIN_SECONDS = 170
RUSH_MIN_RPS = 10
RUSH_MAX_ERROR = 1.0
RUSH_MAX_P95 = 1000


def words(text):
    return len(re.findall(r"\S+", text))


def sections(text):
    """{'## Heading': body} for every level-2 heading."""
    out, cur = {}, None
    for line in text.splitlines():
        if line.startswith("## "):
            cur = line.strip()
            out[cur] = ""
        elif cur:
            out[cur] += line + "\n"
    return out


def find_section(secs, heading):
    for h, body in secs.items():
        if h.lower().startswith(heading.lower()):
            return body
    return None


def check_doc():
    k.section(f"The readiness review ({DOC})")
    if not k.check(DOC.is_file(), f"{DOC} exists", "Write it: it's the main deliverable of this ticket."):
        return
    text = DOC.read_text(errors="replace")
    secs = sections(text)
    missing = [h for h in DOC_SECTIONS if find_section(secs, h) is None]
    k.check(not missing, f"It has the sections {', '.join(DOC_SECTIONS)}", f"Missing: {', '.join(missing)}")
    n = words(text)
    k.check(n >= MIN_DOC_WORDS, f"It's long enough to be useful ({n} words, wants {MIN_DOC_WORDS}+)",
            "Someone who wasn't here should be able to run the launch from it.")

    arch = find_section(secs, "## Architecture") or ""
    k.check("```" in arch or "![" in arch, "The Architecture section has a diagram (a text diagram or an image)",
            "A code block with boxes and arrows is fine, or ![diagram](docs/architecture.png).")
    if "![" in arch:
        for img in re.findall(r"!\[[^\]]*\]\(([^)\s]+)\)", arch):
            if not img.startswith("http"):
                p = (DOC.parent / img) if not Path(img).is_file() else Path(img)
                k.check(p.is_file(), f"The diagram image {img} is committed")
    absent = [name for name, rx in PIECES.items() if not re.search(rx, arch, re.I)]
    k.check(not absent, "The architecture shows every piece, from the Ingress to the pipeline",
            f"Not mentioned: {', '.join(absent)}")

    checklist = find_section(secs, "## Launch checklist") or ""
    ticked = [l for l in checklist.splitlines() if re.match(r"\s*[-*] \[[xX]\]", l)]
    open_ = [l for l in checklist.splitlines() if re.match(r"\s*[-*] \[ \]", l)]
    short = [l for l in ticked if words(re.sub(r"^\s*[-*] \[[xX]\]", "", l)) < 8]
    k.check(len(ticked) >= MIN_TICKED and not open_,
            f"The launch checklist has {len(ticked)} ticked items and none left open (wants {MIN_TICKED}+)",
            f"{len(open_)} unticked. Tick an item only once you've checked it." if open_ else "See the ticket for the list.")
    k.check(ticked and not short, "Every ticked item says how you checked it",
            f"Too short: {short[0].strip()[:80]}" if short else "")
    rush = find_section(secs, "## Lunch Rush results") or ""
    k.check(re.search(r"p95", rush, re.I) and re.search(r"\d", rush),
            "The Lunch Rush section gives your numbers (p95, error rate)")
    rb = find_section(secs, "## Rollback rehearsal") or ""
    k.check("rollout undo" in rb, "The Rollback section has the rollback command (kubectl rollout undo)")


def check_runbook():
    k.section(f"The runbook ({RUNBOOK})")
    if not k.check(RUNBOOK.is_file(), f"{RUNBOOK} exists", "Follow the template in runbooks/README.md."):
        return
    text = RUNBOOK.read_text(errors="replace")
    missing = [h for h in RUNBOOK_SECTIONS if not re.search(rf"^{re.escape(h)}", text, re.M)]
    k.check(not missing, "It has How you know, Check first, Fix and Why it happens", f"Missing: {', '.join(missing)}")
    k.check("kubectl" in text, "It names the kubectl commands to run first")
    k.check("rollout undo" in text, "It says how to roll back (kubectl rollout undo)")
    n = words(text)
    k.check(n >= MIN_RUNBOOK_WORDS, f"It's long enough to follow at 2am ({n} words, wants {MIN_RUNBOOK_WORDS}+)")


def fields(path):
    out = {}
    for line in path.read_text(errors="replace").splitlines():
        if not line.strip():
            break
        m = re.match(r"([a-z_0-9]+): (.*)$", line)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def num(d, key, default=-1.0):
    try:
        return float(d.get(key, default))
    except ValueError:
        return default


def check_evidence():
    k.section("Evidence in artifacts/")
    if k.check(RUSH.is_file() and RUSH.read_text(errors="replace").startswith("# BUK-77 Lunch Rush"),
               f"{RUSH} is the summary from scripts/loadtest/lunch_rush.py",
               "Run python3 scripts/loadtest/lunch_rush.py with your cluster up (it saves the file)."):
        f = fields(RUSH)
        k.check("bukka.localhost" in f.get("target", ""), f"It ran through the Ingress ({f.get('target')})",
                "Run it against http://bukka.localhost, the way customers come in.")
        dur, rps, ach = num(f, "duration_seconds"), num(f, "target_rps"), num(f, "achieved_rps")
        k.check(dur >= RUSH_MIN_SECONDS and rps >= RUSH_MIN_RPS and ach >= 0.9 * RUSH_MIN_RPS,
                f"It ran for 3 minutes at {RUSH_MIN_RPS}+ requests a second ({dur:.0f}s at {ach:g} rps)",
                "Use the defaults: python3 scripts/loadtest/lunch_rush.py")
        req = num(f, "requests")
        k.check(req >= 0.9 * dur * RUSH_MIN_RPS, f"The request count adds up ({req:.0f} requests)")
        err = num(f, "error_rate_percent", 100)
        k.check(0 <= err < RUSH_MAX_ERROR, f"Fewer than {RUSH_MAX_ERROR:g}% of requests failed ({err:g}%)")
        p95 = num(f, "p95_ms", 99999)
        k.check(0 < p95 < RUSH_MAX_P95, f"p95 was under {RUSH_MAX_P95} ms ({p95:.0f} ms)")
        k.check(f.get("rollout_during_load") == "yes" and num(f, "rollout_window_requests") >= 50,
                f"It rolled out web, menu-service and order-service during the rush "
                f"({f.get('rollout_window_requests', 0)} requests during the rollout)",
                "Don't use --no-rollout for the final run.")
        k.check(f.get("rollout_window_failed") == "0", f"No request failed during the rollout ({f.get('rollout_window_failed')})")
        k.check(f.get("result") == "PASS", f"The Lunch Rush passed ({f.get('result')})")

    if k.check(ROLLBACK.is_file(), f"{ROLLBACK} is committed", "Save the output of your rollback rehearsal there."):
        t = ROLLBACK.read_text(errors="replace")
        k.check("rolled back" in t and "successfully rolled out" in t,
                "It shows kubectl rollout undo and the rollout finishing",
                "It should include 'deployment.apps/web rolled back' and 'successfully rolled out'.")

    tf = sorted(Path("infra/terraform").glob("*.tf")) if Path("infra/terraform").is_dir() else []
    k.check(bool(tf), "Your BUK-51 Terraform is in infra/terraform/", "Build on your BUK-51 branch.")
    if k.check(PLAN.is_file(), f"{PLAN} is committed", "terraform plan -no-color | tee artifacts/buk-77-terraform-plan.txt"):
        t = PLAN.read_text(errors="replace")
        k.check("No changes." in t and not re.search(r"Plan: \d+ to add", t),
                "terraform plan after apply shows No changes",
                "Run terraform apply first, then plan again: it should have nothing to do.")


def check_ci():
    k.section(f"Manifests are checked in CI ({CI})")
    if not k.check(CI.is_file(), f"{CI} exists (from BUK-63)"):
        return
    t = CI.read_text(errors="replace")
    lines = [l for l in t.splitlines() if "kubeconform" in l and not l.strip().startswith("#")]
    k.check(bool(lines) and re.search(r"\bk8s\b", t) is not None, "A job validates k8s/ with kubeconform",
            "Add a job that runs kubeconform on k8s/ (see the Notes in the ticket).")


def check_images_in_git(by):
    k.section("The running images were built from your branch")
    shas = set()
    for app in k.APPS:
        d = (by.get("Deployment") or {}).get(app)
        for p in (k.pods_of(by, d) if d else [])[:1]:
            m = k.IMAGE_RE.match(p["spec"]["containers"][0].get("image", ""))
            if m:
                shas.add(m.group(3))
    if not k.check(bool(shas), "The images are tagged with commit SHAs"):
        return
    for s in sorted(shas):
        known = subprocess.run(["git", "merge-base", "--is-ancestor", s, "HEAD"], capture_output=True).returncode == 0
        k.check(known, f"sha-{s} is a commit on your branch", "Deploy the images your pipeline built from this branch.")


def main():
    args = sys.argv[1:]
    owner = args[args.index("--owner") + 1] if "--owner" in args else None
    if not os.path.isfile("tickets/BUK-77.md"):
        print("Run this from the root of your bukka clone.")
        return 2
    k.check_manifests(owner)
    check_doc()
    check_runbook()
    check_evidence()
    check_ci()
    if "--files" not in args:
        by = k.check_cluster(owner)
        if by is not None:
            k.check_app(by)
            check_images_in_git(by)
    return 1 if k.FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
