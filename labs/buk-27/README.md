# BUK-27 lab: bukka-web-1

A fresh Debian server with systemd, in a Docker container. The Bukka code is
already deployed to `/opt/bukka`, but nothing runs it and no web server is
installed. You don't need to know Docker for this ticket: the scripts handle it.

```bash
bash labs/buk-27/start.sh                       # create the server (fresh every time)
docker exec -it -u oncall bukka-web-1 bash -l   # log in
bash labs/buk-27/stop.sh                        # remove it
```

Copy files from your repo onto the server with:

```bash
docker cp deploy/systemd/bukka-api.service bukka-web-1:/tmp/
```

then move them into place with `sudo` on the server.

Customers reach the server at `http://localhost:18081` (its port 80).

**Needs Docker:** Docker Desktop on macOS or Windows (with WSL), Docker Engine
on Linux, or a GitHub Codespace on your fork.
