#!/usr/bin/env bash
# Container entrypoint: apply the incident's faults, start the API, stay up.
/usr/local/bin/start-faults.sh && rm -f /usr/local/bin/start-faults.sh
/usr/local/bin/bukka-api start
exec sleep infinity
