#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
VIBE_COVERAGE_DRIVERS_LIB_ONLY=1 source scripts/coverage_drivers.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DRIVER_DIR="$TMP/driver"
mkdir -p "$DRIVER_DIR"
: > "$DRIVER_DIR/src.vibe"

# Routing: both migrated labels use exact exposure. A filtered run for either
# label can therefore skip the legacy merged-source generator; legacy labels
# still require it.
coverage_driver_uses_exact_exposure units
coverage_driver_uses_exact_exposure traitenv
if coverage_driver_uses_exact_exposure units2; then
  echo "coverage_drivers_test: units2 unexpectedly routed to exact exposure" >&2
  exit 1
fi

# A sidecar diagnostic is deterministic: one attempt and a nonzero status.
deterministic_attempts=0
coverage_driver_compile_once() {
  deterministic_attempts=$((deterministic_attempts + 1))
  printf 'unknown name: db_new\n' > "$1/m.wasm.diag"
  return 1
}
status=0
coverage_driver_compile_with_retries "$DRIVER_DIR" main || status=$?
[ "$status" = 2 ]
[ "$deterministic_attempts" = 1 ]
[ "$COVERAGE_DRIVER_COMPILE_ATTEMPTS" = 1 ]

# A diagnostic-free transient failure remains retryable and may succeed on the
# sixth and final attempt.
transient_attempts=0
coverage_driver_compile_once() {
  transient_attempts=$((transient_attempts + 1))
  if [ "$transient_attempts" = 6 ]; then
    printf 'wasm' > "$1/m.wasm"
    return 0
  fi
  return 1
}
coverage_driver_compile_with_retries "$DRIVER_DIR" main
[ "$transient_attempts" = 6 ]
[ "$COVERAGE_DRIVER_COMPILE_ATTEMPTS" = 6 ]

# A persistent diagnostic-free host failure stops after exactly six attempts.
host_attempts=0
coverage_driver_compile_once() {
  host_attempts=$((host_attempts + 1))
  return 1
}
status=0
coverage_driver_compile_with_retries "$DRIVER_DIR" main || status=$?
[ "$status" = 1 ]
[ "$host_attempts" = 6 ]
[ "$COVERAGE_DRIVER_COMPILE_ATTEMPTS" = 6 ]

echo 'coverage_drivers_test: ok'
