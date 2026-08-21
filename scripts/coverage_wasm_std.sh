#!/usr/bin/env bash
# Measure @vibe/builtin tests through the maintained selfhost coverage path.
#
# The retired wasm-source wrapper compiled with MoonBit-host-only CLI flags and
# disappeared with the host in #594. Keep this task as a narrow selector over
# scripts/vibe_test.sh --coverage instead of maintaining a second compiler and
# report pipeline.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
FILTER="${VIBE_WASM_STD_COVERAGE_FILTER:-}"
EXCLUDE="${VIBE_WASM_STD_COVERAGE_EXCLUDE:-}"

# These variables belonged to the removed wasm-source compiler/report format.
# Reject them rather than accepting knobs that no longer affect the result.
legacy_vars=(
  VIBE_WASM_SOURCE_COVERAGE_ALLOW_TRAP
  VIBE_WASM_SOURCE_COVERAGE_DIR
  VIBE_WASM_SOURCE_COVERAGE_MODE
  VIBE_WASM_SOURCE_COVERAGE_NO_DCE
  VIBE_WASM_SOURCE_COVERAGE_REPORT_SUMMARY_ONLY
  VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS
  VIBE_WASM_STD_COVERAGE_ALLOW_TRAP
  VIBE_WASM_STD_COVERAGE_DIR
  VIBE_WASM_STD_COVERAGE_MATRIX
  VIBE_WASM_STD_COVERAGE_MIN_LINE_RATE
  VIBE_WASM_STD_COVERAGE_MIN_MEASURED_RATE
  VIBE_WASM_STD_COVERAGE_MODE
  VIBE_WASM_STD_COVERAGE_MODES
  VIBE_WASM_STD_COVERAGE_NO_DCE
  VIBE_WASM_STD_COVERAGE_STRICT
)
for name in "${legacy_vars[@]}"; do
  if [ -n "${!name:-}" ]; then
    echo "[wasm std coverage] $name belongs to the retired wasm-source lane." >&2
    echo "  Use scripts/vibe_test.sh --coverage options and VIBE_TEST_CLI_WASM instead." >&2
    exit 2
  fi
done

cd "$PROJECT_ROOT"
mapfile -t tests < <(find lib/@vibe/builtin -name '*_test.vibe' | sort)
if [ -n "$FILTER" ]; then
  mapfile -t tests < <(printf '%s\n' "${tests[@]}" | rg "$FILTER" || true)
fi
if [ -n "$EXCLUDE" ]; then
  mapfile -t tests < <(printf '%s\n' "${tests[@]}" | rg -v "$EXCLUDE" || true)
fi
if [ "${#tests[@]}" -eq 0 ]; then
  echo "[wasm std coverage] no test files selected under lib/@vibe/builtin" >&2
  exit 1
fi

echo "[wasm std coverage] measuring ${#tests[@]} file(s) with vibe_test.sh --coverage"
exec bash "$SCRIPT_DIR/vibe_test.sh" --coverage "${tests[@]}"
