# BUK-21 lab: bukka-prod-1

A small Debian server running the Bukka API, in a Docker container, broken
the way production was after last night's change. You don't need to know
Docker for this ticket: the scripts handle it.

```bash
bash labs/buk-21/start.sh                    # create the server (starts fresh every time)
docker exec -it -u oncall bukka-prod-1 bash  # log in as the on-call engineer
bash labs/buk-21/stop.sh                     # remove it
```

Customers reach the server at `http://localhost:18080`.

**Needs Docker:** Docker Desktop on macOS or Windows (with WSL), Docker Engine
on Linux, or a GitHub Codespace (Docker is already there).

Please don't read the files in this folder to find the problems. That's like
reading the answer key: the point of the ticket is the method you use to find
them.
