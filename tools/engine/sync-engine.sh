#!/bin/bash
# Rewrites Ray's engine/ from an Ardia checkout: the rename map (rename-ardia.py), then Ray's own changes from
# engine-ray/ (apply-ray.py). Never edit engine/ by hand; change engine-ray/ or the rename map and run this again.
#   tools/engine/sync-engine.sh [ardia checkout]   (default: third_party/ardia, at engine.lock's ardia_tag)
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
ardia="${1:-$root/third_party/ardia}"
python3 "$root/tools/engine/rename-ardia.py" "$ardia" "$root/engine"
python3 "$root/tools/engine/apply-ray.py" "$root/engine" "$root/engine-ray"
