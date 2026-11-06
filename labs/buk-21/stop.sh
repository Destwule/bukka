#!/usr/bin/env bash
# Remove the BUK-21 lab server.
docker rm -f bukka-prod-1 >/dev/null 2>&1 && echo "bukka-prod-1 removed" || echo "bukka-prod-1 wasn't running"
