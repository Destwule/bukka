#!/usr/bin/env bash
# Start the BUK-21 "production server" (needs Docker).
# Run from the repo root:  bash labs/buk-21/start.sh
set -euo pipefail
NAME=bukka-prod-1
IMAGE=bukka-lab-buk21
[ -f labs/buk-21/Dockerfile ] || { echo "Run this from the root of your bukka clone."; exit 2; }
command -v docker >/dev/null || { echo "Docker isn't installed. See labs/buk-21/README.md."; exit 2; }

docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "Building the server image (first time takes a minute or two)..."
docker build -q -t "$IMAGE" -f labs/buk-21/Dockerfile . >/dev/null
docker run -d --name "$NAME" --hostname "$NAME" --cap-add NET_ADMIN -p 18080:8080 "$IMAGE" >/dev/null
sleep 3
cat <<MSG

bukka-prod-1 is up. Customers reach it at http://localhost:18080

Log in as the on-call engineer:
  docker exec -it -u oncall $NAME bash

Useful on the server: bukka-api status|restart|logs, ss, curl, dig, sudo iptables -L -n -v
When you're done: bash scripts/verify/buk-21.sh
To start over from scratch: bash labs/buk-21/start.sh
MSG
