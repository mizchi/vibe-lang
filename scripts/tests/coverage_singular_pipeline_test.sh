#!/usr/bin/env bash
# Executable isolated capped corpus -> singular filtered driver -> checked merge.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/_build/coverage/singular-pipeline-attestation"
rm -rf "$OUT"
VIBE_COV_DIR="$OUT" VIBE_COV_MAX=1 bash scripts/coverage_corpus.sh fixtures/hello.vibe
before="$(VIBE_COVERAGE_DRIVERS_LIB_ONLY=1 source scripts/coverage_drivers.sh; COMPILER_COV="$OUT/compiler_cov.wasm"; coverage_driver_stat "$OUT/acc.json")"
VIBE_COV_DIR="$OUT" bash scripts/coverage_driver.sh
after="$(VIBE_COVERAGE_DRIVERS_LIB_ONLY=1 source scripts/coverage_drivers.sh; COMPILER_COV="$OUT/compiler_cov.wasm"; coverage_driver_stat "$OUT/acc.json")"
read -r before_hit before_total <<<"$before"
read -r after_hit after_total <<<"$after"
[ "$before_total" -gt 0 ]
[ "$after_total" -eq "$before_total" ]
[ "$after_hit" -ge "$before_hit" ]
[ -s _build/coverage/drivers/driver/src.vibe ]
[ -s _build/coverage/drivers/driver/m.wasm ]
[ -s _build/coverage/drivers/driver/cov.json ]
echo "coverage_singular_pipeline_test: ok ($before_hit -> $after_hit/$after_total)"
