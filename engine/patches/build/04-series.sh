#!/usr/bin/env bash
# Step 4: our series on the tree 03-helium.py left (Helium, its domain and name substitution, the branding):
# apply-chromium-patches.sh (series.py capture-base, the patches, the layers, the offline game).
# Usage: 04-series.sh --apply | --help (under scripts/agent/locked chromium)
set -euo pipefail
source "$(dirname "$0")/step-guard.sh" "$@"
source "$(dirname "$0")/env.sh"
"$(dirname "$0")/apply-chromium-patches.sh" --apply
