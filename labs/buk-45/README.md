# BUK-45 lab: bukka-api-1

The Bukka API server, in a Docker container on the `bukka-web-net` network.
Its data still lives in a SQLite file on its own disk. Your job (see
`tickets/BUK-45.md`) is to give it a private PostgreSQL database.

```bash
bash labs/buk-45/start.sh                   # create the API server (fresh each time)
docker exec -it -u oncall bukka-api-1 bash  # log in
bash labs/buk-45/stop.sh                    # remove the API server
bash labs/buk-45/stop.sh --all              # also remove your database, its data and the networks
```

Customers reach the API at `http://localhost:18082`.

## How this maps to AWS

| Here | In AWS |
|---|---|
| `bukka-web-net` Docker network | the public web subnets |
| `bukka-db-net`, created with `--internal` | the private database subnets (no route to the internet) |
| `bukka-orders-db` PostgreSQL container, no published ports | an RDS instance with `PubliclyAccessible: false` |
| the `bukka-orders-data` volume | RDS storage |
| `bukka-api-1` attached to both networks | the API server, allowed in by `bukka-db-sg` |

**Needs Docker:** Docker Desktop on macOS or Windows (with WSL), Docker Engine
on Linux, or a GitHub Codespace (Docker is already there).
