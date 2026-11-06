# BUK-33: Add a server health-check script and daily traffic report

| | |
|---|---|
| **Type** | Task |
| **Priority** | Medium |
| **Epic** | BUK-1 Platform foundations |
| **Month** | 1 |
| **Sprint** | 4 |
| **Reporter** | Kemi (Operations) |
| **Assignee** | You |
| **Due** | End of the week |

## Context

> Two things from ops this week:
>
> 1. Last Tuesday the disk on bukka-web-1 filled up with logs and the API
>    stopped taking orders. We only found out when restaurants called. I'd
>    like a script that checks the basics every few minutes and **shouts**
>    before customers notice.
> 2. Every evening I open the API logs and squint at them to see how lunch
>    went. Can we get a small report instead: how many requests, how many
>    errors, how slow we were at the worst moments, and what people used most?
>
> The API already writes one JSON line per request, so the data is there.
>
> — Kemi, Operations

## Acceptance criteria

### Health-check script: `scripts/ops/server-healthcheck.sh`

1. Bash, with `set -euo pipefail`, executable, and clean under `shellcheck`.
2. Checks, printing **one JSON line per check** to stdout, like
   `{"check": "disk", "status": "ok", "used_percent": 41}`:
   - **disk**: usage of `/`. `status` is `alert` when it's above
     `BUKKA_DISK_THRESHOLD` percent (default `85`)
   - **memory**: available memory in MB. `status` is `warn` below
     `BUKKA_MIN_FREE_MB` (default `100`). A warning never changes the exit code
   - **api**: an HTTP request to `BUKKA_HEALTH_URL` (default
     `http://127.0.0.1:8080/healthz`), with a timeout of 5 seconds or less.
     `status` is `alert` unless it returns HTTP 200
3. Exit codes: `0` when everything is fine, `1` when the API check fails,
   `2` when the disk check fails. If both fail, exit `2` (a full disk is
   the bigger emergency).

### Traffic report: `scripts/ops/traffic_report.py`

4. Python 3, standard library only. Usage:
   `python3 scripts/ops/traffic_report.py <api-log-file>`.
5. Reads the API's JSON log lines and counts only request records
   (`"msg": "request"`). Lines that aren't valid JSON, or aren't request
   records, are skipped, not fatal.
6. Prints one JSON object to stdout with exactly these fields:

   | Field | Meaning |
   |---|---|
   | `total_requests` | number of request records |
   | `errors_5xx` | requests with status 500 or above |
   | `error_rate_percent` | `errors_5xx / total_requests × 100`, rounded to 2 decimals (`0` when there are no requests) |
   | `p95_response_ms` | 95th percentile of `response_time_ms`, nearest-rank method |
   | `slow_requests` | requests that took more than 500 ms |
   | `top_paths` | the 3 most requested paths, as `[{"path": ..., "count": ...}]`, most first; ties sorted by path A to Z |
   | `status` | `"OK"` when `error_rate_percent` is below 5, otherwise `"CRITICAL"` |
   | `skipped_lines` | lines that were skipped |

### Schedule them: `deploy/cron/bukka-ops`

7. A cron file (the `/etc/cron.d` format, with a user column) that runs the
   health check **every 5 minutes** and the report **every day at 23:55**,
   each appending to its own file under `/var/log/bukka/`.

### Submit

8. Work on a branch called `buk-33-healthcheck-and-report`, from
   `upstream/apprentice/<your-github-username>`.
9. Run `bash scripts/verify/buk-33.sh`. It runs your scripts against
   generated logs and fake servers and compares the results. It writes
   `artifacts/buk-33-audit.txt`.
10. Commit `scripts/ops/`, `deploy/cron/` and the audit file, push, and open a
    pull request into `apprentice/<your-github-username>`, titled
    `feat: add health check and daily traffic report (BUK-33)`.

## Definition of done

- [ ] `verify` passes on your pull request. It runs the same tests again on GitHub's servers
- [ ] A teammate has reviewed and approved it
- [ ] Kemi could read the report without asking you what anything means

## Notes

- Try them on real logs: run the API (`make api-run`) and click around the web
  app, or use the logs from bukka-web-1 (`journalctl -u bukka-api -o cat`).
- **Nearest-rank percentile:** sort the values; the p95 is the value at
  position `ceil(0.95 × n)`, counting from 1.
- Useful: `df -P /`, `/proc/meminfo` (`MemAvailable`), `curl -s -o /dev/null
  -w '%{http_code}' -m 5`, Python's `json`, `math.ceil`, `collections.Counter`.
- Why exit codes matter: monitoring tools, cron wrappers and CI all decide
  "is this broken?" from the exit code, not from what you print.
