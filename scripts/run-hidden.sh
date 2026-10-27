#!/bin/bash
# Launches build/LumenTests.app hidden on a throwaway data dir with DevTools on a port, and waits until a page loads.
#   scripts/run-hidden.sh <data dir> [port] [url]
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
data=${1:?usage: run-hidden.sh <data dir> [port] [url]}
port=${2:-9341}
url=${3:-https://example.com}
mkdir -p "$data"
open -g -n --stdout "$data/stdout.log" --stderr "$data/stderr.log" \
  --env LUMEN_BACKGROUND=1 --env LUMEN_LOG_STATE=1 --env LUMEN_DATA_DIR="$data" --env LUMEN_REMOTE_DEBUGGING_PORT="$port" \
  --env LUMEN_START_URL="$url" "$root/build/LumenTests.app"
for _ in $(seq 1 60); do
  if curl -s --max-time 1 "http://127.0.0.1:$port/json/list" | grep -q '"type": "page"'; then
    curl -s "http://127.0.0.1:$port/json/list"
    exit 0
  fi
  sleep 0.5
done
echo "error: no page on port $port after 30 s; see $data/stderr.log" >&2
exit 1
