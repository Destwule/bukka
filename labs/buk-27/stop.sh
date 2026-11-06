#!/usr/bin/env bash
docker rm -f bukka-web-1 >/dev/null 2>&1 && echo "bukka-web-1 removed" || echo "bukka-web-1 wasn't running"
