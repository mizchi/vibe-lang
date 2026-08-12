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

# Every driver goes through exact-path exposure (#1633), so every driver must
# name the compiler values it uses with `import <exact file> { .. }`. A driver
# with no imports only ever worked under the deleted raw-concatenation lane,
# where it inherited whatever names the concatenation happened to expose; on the
# exposure lane it compiles against nothing and dies with `unknown name`.
driver_rows="$(grep -E '^run_driver ' scripts/coverage_drivers.sh | awk '{ print $2, $3, $4 }')"
[ -n "$driver_rows" ] || { echo "coverage_drivers_test: no run_driver rows found" >&2; exit 1; }
while read -r entry file label; do
  [ -f "$file" ] || { echo "coverage_drivers_test: $label driver missing: $file" >&2; exit 1; }
  grep -qE '^import [^ ]+\.vibe \{' "$file" || {
    echo "coverage_drivers_test: $label ($file) has no exact-file import" >&2
    exit 1
  }
  grep -qE "^export let $entry:" "$file" || {
    echo "coverage_drivers_test: $label ($file) does not export its entry $entry" >&2
    exit 1
  }
done <<< "$driver_rows"

# The raw-concatenation lane and its truncated walk are gone; nothing may bring
# a `merged_nodce` base back without also revisiting this test.
if grep -q 'merged_nodce' scripts/coverage_drivers.sh; then
  echo "coverage_drivers_test: legacy merged_nodce base reintroduced" >&2
  exit 1
fi
if grep -Eq 'VIBE_COV_FLAT|cat .*FLAT' scripts/coverage_driver.sh scripts/coverage_unittests.sh; then
  echo "coverage_drivers_test: legacy raw flat concatenation remains" >&2
  exit 1
fi
grep -q 'VIBE_COV_DRIVER_FILTER=driver' scripts/coverage_driver.sh || {
  echo "coverage_drivers_test: singular compatibility wrapper does not select driver" >&2
  exit 1
}

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
