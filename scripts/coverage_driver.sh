#!/usr/bin/env bash
# Compatibility entry for the historical singular coverage driver (#1633).
# The driver is registered in the production exact-path suite; keep this
# command as a filtered invocation instead of maintaining a second raw-concat
# compile/merge implementation.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export VIBE_COV_DRIVER_FILTER=driver
exec bash scripts/coverage_drivers.sh
