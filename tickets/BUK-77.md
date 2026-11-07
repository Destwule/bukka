# BUK-77: Production launch readiness review

| | |
|---|---|
| **Type** | Task |
| **Priority** | Highest |
| **Epic** | BUK-3 Containers and continuous delivery |
| **Month** | 3 |
| **Sprint** | 12 |
| **Reporter** | Hussein Alamutu (Product Manager & Lead DevOps Engineer) |
| **Assignee** | You |
| **Due** | End of Sprint 12 |

## Context

### Why this matters 🎉

We've signed 40 new restaurant partners across Lekki, Yaba and Ikeja, and
marketing is running a "Lunch on Bukka" campaign on launch day: our biggest
lunch rush ever, all at once, between 12 and 2pm. Before I tell the
partners we're ready, I need to know the platform holds up.

### What I need from you

- Bring together everything you've built over three months: the cloud
  network in Terraform, the images, the pipeline and the Kubernetes setup.
- Show me it holds up under a lunch rush, and walk me through how it fits
  together.

This isn't a test of whether you know everything. It's the conversation every
team has before a launch: what we built, how we know it works, and what we'd
do if something went wrong. You've done the hard part already.

— Hussein Alamutu, Product Manager & Lead DevOps Engineer

## Acceptance criteria

### Bring it all together

1. **Infrastructure:** your Terraform from BUK-51 still applies cleanly to
   LocalStack, and running `terraform plan` straight afterwards shows no
   changes. Save that second plan:
   `terraform plan -no-color | tee artifacts/buk-77-terraform-plan.txt`.
2. **Images:** every image running in your cluster was built by your
   BUK-63 pipeline and is tagged with a commit SHA that exists on your
   branch.
3. **Kubernetes:** your BUK-70 manifests deploy the whole app to a fresh
   kind or k3d cluster, every pod becomes `Ready`, and the BUK-70 checks
   still pass.
4. **Manifests are checked in CI:** add a job to `.github/workflows/ci.yml`
   that validates `k8s/` with [kubeconform](https://github.com/yannh/kubeconform),
   so a typo in a manifest goes red before it reaches a cluster (see the
   Notes).

### The readiness review

This is the main deliverable: the document you'd hand a teammate the night
before launch.

5. Add `docs/launch-readiness.md` with these sections (400+ words in all):
   - `## Architecture`: a **diagram** (a text diagram in a code block, or an
     image you commit) from the browser to the database: the Ingress, web,
     menu-service, order-service, the worker, Redis and PostgreSQL, plus the
     registry (GHCR) and the pipeline, and how a change gets from a commit
     to a running pod. Add a line on why each piece is there.
   - `## Launch checklist`: tick each item and write one line on how you
     checked it. At least:
     - every pod runs as a non-root user and has requests and limits
     - `web`, `menu-service` and `order-service` run at least 2 replicas
       with readiness probes
     - no real passwords or keys are committed anywhere in the repo
     - the database is on a persistent volume and survives a pod restart
     - you can roll back a bad release in under a minute (and the command)
     - you know where to look first if orders stop (your runbook below)
     - the Lunch Rush passes
   - `## Lunch Rush results`: your numbers (requests, error rate, p95), and
     anything you changed to get there.
   - `## Rollback rehearsal`: what you rolled back, the command, and how
     long it took.
   - `## Risks and next steps`: the biggest risk you see on launch day, and
     the one thing you'd improve next if Bukka gave you another sprint.
6. Add a runbook, `runbooks/orders-stopped.md`, for "orders stop moving or
   customers can't order", using the template in `runbooks/README.md`
   (`## How you know`, `## Check first`, `## Fix`, `## Why it happens`).
   Name the `kubectl` commands you'd run first, in order, and how to roll
   back (200+ words).

### Rollback rehearsal

7. Roll out a change to `web` (a small change to the menu page, or just
   `kubectl -n bukka rollout restart deployment/web`), then roll it back
   with `kubectl rollout undo` and time it. Save the output to
   `artifacts/buk-77-rollback.txt` (the Notes show one way). It should show
   the `rolled back` and `successfully rolled out` lines.

### The Lunch Rush (guided)

8. Run the provided load test against your cluster through the Ingress:
   ```bash
   python3 scripts/loadtest/lunch_rush.py
   ```
   Each simulated customer lists restaurants, opens a menu, places an order
   and checks its status. After a short warm-up it runs at **10 requests a
   second for 3 minutes**, and a third of the way in it rolls out `web`,
   `menu-service` and `order-service` while customers keep coming. Read the
   script first: it's short, and it's the kind of thing you'll write
   yourself one day.
9. **The bar:**
   - fewer than **1%** of requests fail
   - **p95** response time under **1000 ms**
   - **no request fails during the rollout**

   The script saves its summary to `artifacts/buk-77-lunch-rush.txt` and
   says `result: PASS` or `FAIL`. If your first run misses, that's normal:
   find out why (see the Notes), fix it, run it again, and say what you
   changed in your readiness review.
10. *Stretch, not required:* write your own load test in `loadtest/` with
    k6 or Locust, with the targets in the test itself (k6 `thresholds`),
    and try a higher rate. Or add a CI job that deploys your manifests to a
    throwaway kind cluster on the runner.

### The 1-on-1 walkthrough

11. Book a 30-minute session with the engineering lead. Bring your cluster
    running and your readiness review open. You'll:
    - **walk through your architecture diagram** from the browser to the
      database, and say why each piece is there
    - **make a small change live**: commit it, show the pipeline build and
      publish the image, then roll it out to your cluster
    - **talk through three "what would you check first" situations**. We'll
      pick from these, so you can prepare: a pod stuck in
      `CrashLoopBackOff`, an image that won't pull, the API not `Ready`
      because the database is down, or the Lunch Rush getting slow.

    Thinking out loud and saying "I'd check X, then Y" is exactly what we
    want. Looking things up during the session is fine.

### Submit

12. Work on a branch called `buk-77-launch-readiness`, created from
    `upstream/apprentice/<your-github-username>`.
13. With your cluster running, run `bash scripts/verify/buk-77.sh`. It
    checks your readiness review, runbook, CI job and evidence files,
    re-runs the BUK-70 cluster checks, and writes
    `artifacts/buk-77-launch.txt`.
14. Commit the readiness review, the runbook, the CI change, the artifact
    files and anything you fixed along the way, push, and open a pull
    request into `apprentice/<your-github-username>`, titled
    `feat: launch readiness review and Lunch Rush test (BUK-77)`.
15. In the pull request description, link your readiness review and paste
    the top of your Lunch Rush summary.

## Definition of done

- [ ] Your readiness review and runbook are complete, with how you checked
      each checklist item
- [ ] Your Lunch Rush passes against your own deployment, rollout included
- [ ] You've rehearsed a rollback and saved the output
- [ ] The kubeconform job in your pipeline is green
- [ ] `verify` passes on your pull request
- [ ] A teammate has reviewed and approved your pull request
- [ ] You've had your 1-on-1 walkthrough with the engineering lead

## Notes

- **Why a readiness review?** On launch day you're tired and excited, and
  that's when things get missed. Teams write it down beforehand so nobody
  has to remember it under pressure, and so someone else can pick it up.
- **Why p95 and not the average?** An average hides the slow requests. p95
  means 95 out of 100 customers got their answer within that time. The
  other 5 are the people who leave one-star reviews, so we watch them too.
- **Why test through the Ingress?** That's the path real customers take.
  Testing the API directly would skip Nginx and the Ingress, which are part
  of what can slow down.
- **Why such a modest bar?** Your laptop runs the cluster, the whole app and
  the load test at once, so absolute numbers don't mean much. What matters
  is that nothing fails, even mid-rollout, and that you can explain the
  numbers you got. Mention your machine in your results.
- **If the Lunch Rush fails or is slow,** look before you change anything:
  the `first failures` lines in the summary, `kubectl -n bukka get pods`
  (did anything restart?), `kubectl top pods` (needs metrics-server), the
  API's `response_time_ms` in its logs, and whether a pod is hitting its CPU
  limit. Failures only during the rollout point back at BUK-70: probes,
  `maxUnavailable: 0` and how pods shut down. More replicas only help if the
  bottleneck is the API.
- **Trying it quickly:** `python3 scripts/loadtest/lunch_rush.py --minutes 1
  --no-rollout` is a one-minute smoke test. The final run must use the
  defaults.
- **kubeconform** checks your YAML against the Kubernetes schemas without a
  cluster. On the runner:
  ```bash
  curl -fsSL https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz | tar -xz kubeconform
  ./kubeconform -strict -ignore-missing-schemas -summary k8s/*.yaml
  ```
- **Recording the rollback rehearsal:**
  ```bash
  { kubectl -n bukka rollout history deployment/web
    time kubectl -n bukka rollout undo deployment/web
    kubectl -n bukka rollout status deployment/web; } 2>&1 | tee artifacts/buk-77-rollback.txt
  ```
- The 1-on-1 is the only session like this in the programme. It's a
  conversation with a teammate, not an exam board. If you've done BUK-58 to
  BUK-70 yourself, you already know the answers.
