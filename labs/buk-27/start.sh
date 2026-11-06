#!/usr/bin/env bash
# Start the BUK-27 server, bukka-web-1 (needs Docker).
# Run from the repo root:  bash labs/buk-27/start.sh
set -euo pipefail
NAME=bukka-web-1
IMAGE=bukka-lab-buk27
[ -f labs/buk-27/Dockerfile ] || { echo "Run this from the root of your bukka clone."; exit 2; }
command -v docker >/dev/null || { echo "Docker isn't installed. See labs/buk-27/README.md."; exit 2; }

docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "Building the server image (first time takes a few minutes)..."
docker build -q -t "$IMAGE" -f labs/buk-27/Dockerfile . >/dev/null
# systemd needs a few extra privileges to run inside a container.
docker run -d --name "$NAME" --hostname "$NAME" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw -p 18081:80 "$IMAGE" >/dev/null
sleep 4
cat <<MSG

bukka-web-1 is up. Once you've set it up, customers reach it at http://localhost:18081

Log in:
  docker exec -it -u oncall $NAME bash -l

Your config files live in your repo (deploy/), then get copied onto the server.
When you're done: bash scripts/verify/buk-27.sh
To start over from scratch: bash labs/buk-27/start.sh
MSG
