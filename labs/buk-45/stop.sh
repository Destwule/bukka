#!/usr/bin/env bash
# Remove the BUK-45 lab: the API server, and (with --all) your database too.
docker rm -f bukka-api-1 >/dev/null 2>&1 && echo "bukka-api-1 removed" || true
if [ "${1:-}" = "--all" ]; then
  docker rm -f bukka-orders-db >/dev/null 2>&1 && echo "bukka-orders-db removed" || true
  docker volume rm bukka-orders-data >/dev/null 2>&1 && echo "volume bukka-orders-data removed (the data is gone)" || true
  docker network rm bukka-db-net bukka-web-net >/dev/null 2>&1 || true
fi
