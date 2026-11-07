# BUK-70: Deploy to Kubernetes with zero-downtime rollouts

| | |
|---|---|
| **Type** | Task |
| **Priority** | High |
| **Epic** | BUK-3 Containers and continuous delivery |
| **Month** | 3 |
| **Sprint** | 11 |
| **Reporter** | Hussein Alamutu (Product Manager & Lead DevOps Engineer) |
| **Assignee** | You |
| **Due** | End of Sprint 11 |

## Context

### Why this matters

Yesterday at 12:40 we pushed a one-line fix to the menu page. Compose stopped
the old containers before starting the new ones, and for about four minutes
the kitchen screen showed "Something went wrong". Mama Titi's in Yaba missed
six orders. Restaurants change prices and sell out of dishes in the middle of
the day, so we have to be able to ship at any time, even during the 12 to
2pm rush, without anyone noticing.

### What I need from you

- Move Bukka to Kubernetes, starting on a local cluster (kind or k3d) with
  the same manifests we'd use in production.
- At least two copies of everything customers touch; traffic only goes to a
  copy once it's ready, and copies are replaced one at a time.
- Use the images CI publishes from BUK-63.

— Hussein Alamutu, Product Manager & Lead DevOps Engineer

## Acceptance criteria

### The manifests

1. Put your manifests in `k8s/`, one file per kind of resource or per
   service, whichever you find easier to read. Everything goes in a
   namespace called `bukka`.
2. **Deployments** for `web`, `menu-service`, `order-service` and
   `worker`, using your images from GHCR (`bukka-web` and `bukka-api`),
   tagged with a commit SHA (never `latest`).
3. **`web`, `menu-service` and `order-service` run at least 2 replicas.**
   The worker can run 1.
4. **Rolling updates never take a copy away before the new one is ready:**
   `strategy.rollingUpdate.maxUnavailable: 0` (with `maxSurge: 1`) on
   `web`, `menu-service` and `order-service`.
5. **Probes on the two API services:**
   - liveness probe on `GET /healthz`
   - readiness probe on `GET /readyz`

   Give `web` a probe that checks Nginx answers, and the worker a liveness
   probe on its own `/healthz` port.
6. **Resource requests and limits** (CPU and memory) on every container.
7. **No container runs as root:** `securityContext.runAsNonRoot: true` on
   the `web`, `menu-service`, `order-service` and `worker` pods, and the
   pods actually start with it. (Doing the same for PostgreSQL and Redis is
   a good stretch: their images have their own non-root users.)
8. **Services** for `web`, `menu-service` and `order-service`, so pods find
   each other by name. The web container's Nginx forwards
   `/api/restaurants*` to `menu-service` and `/api/orders*` and
   `/api/kitchen*` to `order-service`, as in BUK-58.
9. A **ConfigMap** for settings that aren't secret, and a **Secret** for the
   database password and `DATABASE_URL`. This repo is public: create the
   real Secret with `kubectl create secret`, and commit
   `k8s/examples/secret.example.yaml` showing its shape with placeholder
   values. Keep it in that subfolder: `kubectl apply -f k8s/` doesn't read
   subfolders, so it never overwrites your real Secret. The placeholders
   must work together (the same password in both values): the check on your
   pull request uses this file to deploy your app to a throwaway cluster.
   Never commit a real password.
10. An **Ingress** that sends `http://bukka.localhost` to the `web` Service.
11. PostgreSQL and Redis can run in the cluster as single-replica
    Deployments (or StatefulSets), with a PersistentVolumeClaim for the
    database. They don't need the zero-downtime treatment. Say why in your
    design note.
12. Database migrations run once, before the new API version takes traffic
    (for example, a Kubernetes Job), not from every replica.

### It runs

13. `kubectl apply -f k8s/` on a fresh cluster brings every pod to `Running`
    and `Ready`. Open `http://bukka.localhost`, place an order and watch the
    worker move it along on the kitchen screen.

### Ship a change during "lunch"

14. Make a **small, visible change to the menu page**, for example a
    "Free delivery before 12pm" banner. Let CI build it into a new image
    with a new SHA tag.
15. Start a loop that places an order every second against
    `http://bukka.localhost` and prints one line per request with its HTTP
    status code (`curl -w '%{http_code}'` is your friend).
16. While the loop runs, roll out the new image (`kubectl set image` or
    update the tag and `kubectl apply`). Watch it with
    `kubectl rollout status`.
17. **Every order in the loop succeeds** during the rollout. Save the loop's
    output to `artifacts/buk-70-rollout.txt`.
18. **Roll it back** with `kubectl rollout undo` and confirm the banner is
    gone, again without failed requests. Then roll forward to the new
    version.

### Submit

19. Work on a branch called `buk-70-kubernetes-rollouts`, created from
    `upstream/apprentice/<your-github-username>`.
20. With your cluster running the new version, run
    `bash scripts/verify/buk-70.sh`. It checks your manifests and the
    cluster, places an order through `http://bukka.localhost` and waits for
    the worker to deliver it, then runs its own lunch-time test: customers
    keep ordering while it rolls out `web`, `menu-service` and
    `order-service` (`kubectl rollout restart`). **Not one request may
    fail.** It writes `artifacts/buk-70-kubernetes.txt`.
21. Commit your manifests, the menu change, the loop script, both artifact
    files, push, and open a pull request into
    `apprentice/<your-github-username>`, titled
    `feat: deploy Bukka to Kubernetes with rolling updates (BUK-70)`.
22. In the pull request description, add a short **design note**:
    - **why liveness checks `/healthz` but readiness checks `/readyz`**, and
      what would happen to every API pod during a database blip if
      liveness checked `/readyz` instead
    - why `maxUnavailable: 0` matters when you only have 2 replicas
    - how you chose your resource requests and limits
    - why PostgreSQL and Redis don't get the same rolling update setup

## Definition of done

- [ ] A fresh `kubectl apply -f k8s/` brings everything up without manual fixes
- [ ] Your rollout log shows no failed orders during the update and the rollback
- [ ] `verify` passes on your pull request (it builds your images and
      deploys `k8s/` to a fresh kind cluster, so allow it 15 minutes)
- [ ] A teammate has reviewed and approved your pull request

## Notes

- **Liveness and readiness answer different questions.** Liveness asks "is
  this process stuck, should Kubernetes restart it?". Readiness asks "should
  this pod get traffic right now?". If the database is down, restarting the
  API won't fix it, but sending it traffic won't help either.
- **Why at least 2 replicas?** With one copy, any restart, rollout or crash
  is an outage. With two, one can be replaced while the other serves.
- **Why requests and limits?** Requests tell the scheduler how much room a
  pod needs. Limits stop one greedy pod from starving everything else on
  the node, including the kitchen screen.
- **Local cluster:** `kind` or `k3d` both work. With kind you'll need to
  install the ingress-nginx controller and map ports 80 and 443 when you
  create the cluster (the kind docs have a ready-made config). k3d ships with
  Traefik as its ingress controller.
- `*.localhost` names resolve to your own machine in most browsers and in
  `curl`. If yours doesn't, add `127.0.0.1 bukka.localhost` to `/etc/hosts`.
- If your images aren't public yet (BUK-63, step 14), the pods will sit in
  `ImagePullBackOff`. `kubectl describe pod` tells you why.
- **If a few requests fail during every rollout,** your probes are probably
  fine and the problem is the moment a pod is told to stop: it can stop
  before the Service and the Ingress have stopped sending it traffic. Look
  up "Kubernetes graceful shutdown preStop" and think about what a pod
  should do in those few seconds.
- **A Job can't be changed once it exists.** To run migrations for a new
  image, delete the old Job first (`kubectl -n bukka delete job <name>`),
  then apply.
- Useful commands: `kubectl get pods -w`, `kubectl describe pod <name>`,
  `kubectl logs <pod>`, `kubectl rollout status deployment/menu-service`,
  `kubectl rollout history deployment/web`, `kubectl rollout undo
  deployment/web`, `kubectl get events --sort-by=.lastTimestamp`.
