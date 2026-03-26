#!/usr/bin/env bash
# Run E2E parity tests for vibe language features.
#
# Usage:
#   scripts/test_e2e_parity.sh                    # run all tests/e2e/*.vibe
#   scripts/test_e2e_parity.sh file1.vibe ...     # specific files
#   VIBE_CLI_BIN=/path/to/vibe scripts/test_e2e_parity.sh  # custom binary
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${VIBE_CLI_BIN:-}" ]]; then
  source "$ROOT_DIR/scripts/ensure_native_cli.sh"
fi
CLI="$VIBE_CLI_BIN"
TIMEOUT="${VIBE_E2E_TIMEOUT:-30}"
E2E_DIR="$ROOT_DIR/tests/e2e"

pass=0
fail=0
failures=()

run_timeout() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    "$@"
  fi
}

run_test() {
  local src="$1"
  local name
  name="$(basename "$src")"

  local out=""
  local rc=0
  out="$(run_timeout "$TIMEOUT" "$CLI" test "$src" 2>&1)" || rc=$?

  if [[ $rc -eq 0 ]]; then
    pass=$((pass + 1))
    echo "  PASS  $name"
  else
    fail=$((fail + 1))
    failures+=("$name")
    echo "  FAIL  $name"
    echo "$out" | sed 's/^/        /'
  fi
}

# Collect test files
if [[ $# -gt 0 ]]; then
  files=("$@")
else
  files=()
  for f in "$E2E_DIR"/*_test.vibe; do
    [[ -f "$f" ]] && files+=("$f")
  done
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No test files found in $E2E_DIR"
  exit 1
fi

echo "=== E2E Parity Test Suite ==="
echo "CLI: $CLI"
echo "Files: ${#files[@]}"
echo ""

for f in "${files[@]}"; do
  run_test "$f"
done

echo ""
echo "=== Summary ==="
echo "  Pass: $pass"
echo "  Fail: $fail"
echo "  Total: $((pass + fail))"

if [[ $fail -gt 0 ]]; then
  echo ""
  echo "Failed tests:"
  for name in "${failures[@]}"; do
    echo "  - $name"
  done
  exit 1
fi

echo ""
echo "All tests passed."
