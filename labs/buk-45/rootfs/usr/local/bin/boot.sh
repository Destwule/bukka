#!/usr/bin/env bash
# Container entrypoint: start the API, stay up.
/usr/local/bin/bukka-api start
exec sleep infinity
