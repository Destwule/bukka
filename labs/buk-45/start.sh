#!/usr/bin/env bash
# Start bukka-api-1 for BUK-45 (needs Docker).
# Run from the repo root:  bash labs/buk-45/start.sh
# Starts the API server fresh. Your database container, network and volume
# (if you've made them) are left alone.
set -euo pipefail
NAME=bukka-api-1
IMAGE=bukka-lab-buk45
[ -f labs/buk-45/Dockerfile ] || { echo "Run this from the root of your bukka clone."; exit 2; }
command -v docker >/dev/null || { echo "Docker isn't installed. See labs/buk-45/README.md."; exit 2; }

docker network inspect bukka-web-net >/dev/null 2>&1 || docker network create bukka-web-net >/dev/null
docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "Building the server image (first time takes a minute or two)..."
docker build -q -t "$IMAGE" -f labs/buk-45/Dockerfile . >/dev/null
docker run -d --name "$NAME" --hostname "$NAME" --network bukka-web-net -p 18082:8080 "$IMAGE" >/dev/null
sleep 3
cat <<MSG

bukka-api-1 is up on the bukka-web-net network. Customers reach it at
http://localhost:18082

Log in:  docker exec -it -u oncall $NAME bash
When you're done: bash scripts/verify/buk-45.sh
MSG
