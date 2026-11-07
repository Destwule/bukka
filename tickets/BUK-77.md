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
   changes.
2. **Images:** every image running in your cluster was built by your
   BUK-63 pipeline and is tagged with a commit SHA that exists on your
   branch.
3. **Kubernetes:** your BUK-70 manifests deploy the whole app to a fresh
   kind or k3d cluster with one command (for example `make deploy`), and
   every pod becomes `Ready`.
4. **Deploy check in CI:** add a job to your pipeline that, after the
   images are built, creates a throwaway kind cluster on the runner,
   deploys your manifests with the new images, and fails if
   `GET /api/restaurants` doesn't return the restaurants. A change that
   breaks the deploy should go red before it reaches your cluster.

### The launch checklist

5. Add `docs/launch-checklist.md`. For each item, tick it and write one line
   on how you checked it. Include at least:
   - every pod runs as a non-root user and has requests and limits
   - `web` and `api` run at least 2 replicas with readiness probes
   - no real passwords or keys are committed anywhere in the repo
   - the database is on a persistent volume and survives a pod restart
   - you can roll back a bad release in under a minute (and the command)
   - you know where to look first if orders stop: which logs, which
     `kubectl` commands
   - the Lunch Rush test below passes

### The Lunch Rush

6. Write a load test in `loadtest/` using **k6** or **Locust**. Each
   simulated customer should do what a hungry person does at lunch: list
   restaurants, open a menu, place an order, then check its status.
7. Run it against your cluster through the Ingress
   (`http://bukka.localhost`) at a steady **20 requests per second for 5
   minutes**, after a short ramp-up.
8. **It must pass:**
   - **p95 response time under 500 ms**
   - **fewer than 1% of requests fail**

   Put these targets in the test itself (k6 `thresholds`, or a check at the
   end of the Locust run) so the test fails on its own if they're missed.
9. Save the summary to `artifacts/buk-77-lunch-rush.txt`. If your first
   run misses the target, that's normal: find out why, fix it, and say what
   you changed in your design note.

### The 1-on-1 walkthrough

10. Book a 30-minute session with the engineering lead. Bring your cluster
    running. You'll:
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

11. Work on a branch called `buk-77-launch-readiness`, created from
    `upstream/apprentice/<your-github-username>`.
12. With your cluster running, run `bash scripts/verify/buk-77.sh`. It
    writes `artifacts/buk-77-launch.txt`.
13. Commit the checklist, the load test, the CI change, both artifact files
    and anything you fixed along the way, push, and open a pull request into
    `apprentice/<your-github-username>`, titled
    `feat: launch readiness review and Lunch Rush test (BUK-77)`.
14. In the pull request description, add a short **design note**:
    - an **architecture diagram** (a picture or a text diagram is fine)
      showing web, api, worker, Redis, PostgreSQL, the Ingress, the
      registry and the pipeline, and how a change gets from a commit to a
      running pod
    - your Lunch Rush results, and anything you changed to hit the target
    - the one thing you'd improve next if Bukka gave you another sprint

## Definition of done

- [ ] Your Lunch Rush test passes against your own deployment
- [ ] Your launch checklist is complete, with how you checked each item
- [ ] The deploy check in CI is green
- [ ] `verify` passes on your pull request
- [ ] A teammate has reviewed and approved your pull request
- [ ] You've had your 1-on-1 walkthrough with the engineering lead

## Notes

- **Why a launch checklist?** On launch day you're tired and excited, and
  that's when things get missed. Teams write the list down beforehand so
  nobody has to remember it under pressure.
- **Why p95 and not the average?** An average hides the slow requests. p95
  means 95 out of 100 customers got their answer within that time. The
  other 5 are the people who leave one-star reviews, so we watch them too.
- **Why test through the Ingress?** That's the path real customers take.
  Testing the API directly would skip Nginx and the Ingress, which are part
  of what can slow down.
- **If the Lunch Rush is slow,** look before you change anything:
  `kubectl top pods` (needs metrics-server), the API's `response_time_ms`
  in its logs, whether a pod is hitting its CPU limit, and whether pods
  restarted during the test. More replicas only help if the bottleneck is
  the API.
- Your laptop is running the whole of Bukka, the cluster and the load test
  at once. If it struggles, close other apps first, and mention your
  machine in your results.
- The 1-on-1 is the only session like this in the programme. It's a
  conversation with a teammate, not an exam board. If you've done BUK-58 to
  BUK-70 yourself, you already know the answers.
