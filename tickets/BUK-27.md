# BUK-27: Run the API as a systemd service behind Nginx

| | |
|---|---|
| **Type** | Task |
| **Priority** | High |
| **Epic** | BUK-1 Platform foundations |
| **Month** | 1 |
| **Sprint** | 3 |
| **Reporter** | Hussein Alamutu (Product Manager & Lead DevOps Engineer) |
| **Assignee** | You |
| **Due** | End of the week |

## Context

### Why this matters

On Sunday, Bukka went down for 40 minutes because the API was "running" in
someone's terminal and that terminal closed. Nobody noticed until a
restaurant called. Partners judge us on whether we're open at lunchtime, and
that outage should never be possible again.

### What I need from you

Set bukka-web-1 up the way we'll run every server from now on:

- The API runs as a **service**: it starts on boot, restarts itself if it
  crashes, and doesn't run as root.
- **Nginx** sits in front: it serves the web app and passes `/api` to the
  API, which only listens on localhost.
- If the API is down, customers get a clear "kitchen is closed" message, not
  a scary error page.
- The config lives **in our repo**, so we can rebuild this server any time.

— Hussein Alamutu, Product Manager & Lead DevOps Engineer

## Acceptance criteria

### Get on the server

1. Start the server with `bash labs/buk-27/start.sh` and log in with
   `docker exec -it -u oncall bukka-web-1 bash -l`. Read the welcome message:
   it says where everything is.

### Run the API as a service

2. Write a systemd unit, `deploy/systemd/bukka-api.service`, in your repo,
   and install it on the server as `/etc/systemd/system/bukka-api.service`.
   It must:
   - run `/opt/bukka/venv/bin/python -m bukka_api.main` as the `bukka`
     service account, never root
   - load its settings from `/etc/bukka/api.env`
   - restart automatically on failure, within 10 seconds
   - start on boot (enabled), after the network is up
3. If the API process is killed (`sudo kill -9 <pid>`), it comes back by itself.
4. After a full server restart (`docker restart bukka-web-1`), the site works
   without anyone logging in.

### Put Nginx in front

5. Install Nginx on the server and write `deploy/nginx/bukka.conf` in your
   repo, installed on the server so Nginx uses it. It must:
   - listen on port 80
   - serve the web app from `/opt/bukka/web/dist`
   - pass every request under `/api/` to the API on `127.0.0.1:8080`
   - forward the customer's real address: set the `X-Real-IP`,
     `X-Forwarded-For` and `X-Forwarded-Proto` headers
6. The API is **not** reachable directly from outside: it keeps listening on
   `127.0.0.1` only.
7. When the API is stopped, `/api/...` returns HTTP **502** with a JSON body
   `{"error": "kitchen_closed", "message": "..."}` (a friendly message of
   your choice) instead of Nginx's default error page.

### Submit

8. Work on a branch called `buk-27-systemd-nginx`, created from
   `upstream/apprentice/<your-github-username>`.
9. With the server still running, run `bash scripts/verify/buk-27.sh`. It
   checks the server, and that the files in your repo match what's
   installed. It writes `artifacts/buk-27-audit.txt`.
10. Commit `deploy/` and the audit file, push, and open a pull request into
    `apprentice/<your-github-username>`, titled
    `feat: run the API under systemd behind nginx (BUK-27)`.
11. In the pull request description, answer in a few sentences: why does the
    API listen only on `127.0.0.1` now that Nginx is in front?

## Definition of done

- [ ] `verify` passes on your pull request
- [ ] A teammate has reviewed and approved it
- [ ] Someone could rebuild this server from your `deploy/` folder alone

## Notes

- Useful commands: `sudo systemctl daemon-reload`, `systemctl status bukka-api`,
  `journalctl -u bukka-api -f`, `sudo nginx -t`, `sudo systemctl reload nginx`,
  `ss -ltnp`, `curl -i http://localhost/api/restaurants`.
- `journalctl -u bukka-api` shows the API's JSON logs. Once Nginx forwards
  the headers, the `client` field shows the customer's address instead of
  `127.0.0.1`.
- Look up `Restart=`, `RestartSec=`, `User=`, `EnvironmentFile=` and
  `WantedBy=` in `man systemd.service` / `man systemd.exec`.
- For the 502 page, look up Nginx's `error_page` directive and a named
  `location`.
- Copy files from your repo into the server with
  `docker cp <file> bukka-web-1:/tmp/`, then `sudo mv` them into place.
- Windows: run everything from WSL. If Docker won't run, use a GitHub
  Codespace on your fork.
