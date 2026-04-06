#!/usr/bin/env bash
# Run each fixture in an isolated subprocess to detect abort/crash.
# Reports: pass, fail (error), crash (abort/signal), timeout, skip.
#
# Usage:
#   scripts/test_fixtures_isolation.sh                # all fixtures
#   scripts/test_fixtures_isolation.sh fixtures/foo.vibe  # specific files
#
# Env:
#   VIBE_FIXTURE_TIMEOUT  per-fixture timeout in seconds (default: 5)
#   VIBE_FIXTURE_JOBS     parallel workers (default: nproc)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/ensure_native_cli.sh"
CLI="$VIBE_CLI_BIN"
TIMEOUT="${VIBE_FIXTURE_TIMEOUT:-5}"
JOBS="${VIBE_FIXTURE_JOBS:-$(nproc 2>/dev/null || echo 2)}"
# Parser-only fixtures are covered by parser/typecheck suites; isolate runtime
# subprocess behavior here without the session worker in the middle.
export VIBE_USE_SESSION_HTTP="${VIBE_USE_SESSION_HTTP:-0}"
export VIBE_CLI_BIN CLI TIMEOUT

declare -a files
if [[ $# -gt 0 ]]; then
  files=("$@")
else
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$ROOT_DIR/fixtures" -maxdepth 1 -name '*.vibe' -type f | sort)
  # Also include runtime-style fixtures that need script execution
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$ROOT_DIR/fixtures/runtime" -maxdepth 1 -name '*.vibe' -type f 2>/dev/null | sort)
fi

total=${#files[@]}

# Helper: run a single fixture, output a result line to stdout
# Format: STATUS<TAB>basename[ (detail)]
run_one_fixture() {
  local f="$1"
  local basename
  basename="$(basename "$f")"

  if [[ "$basename" == err_parse_* ]]; then
    echo "skip	$basename"
    return
  fi

  # Each worker gets its own temp file (PID-based)
  local tmpf="/tmp/vibe_fixture_isolation_$$.vibe"
  trap 'rm -f "$tmpf"' RETURN

  # Extract script part (before __DATA__)
  sed -n '/^__DATA__$/q;p' "$f" > "$tmpf"

  if [[ ! -s "$tmpf" ]]; then
    echo "skip	$basename"
    return
  fi

  # Run in subprocess with timeout
  local rc=0
  timeout "$TIMEOUT" "$CLI" run "$tmpf" >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 124 ]]; then
    echo "timeout	$basename"
  elif [[ $rc -eq 134 || $rc -eq 139 || $rc -eq 137 || $rc -gt 128 ]]; then
    local sig=$((rc - 128))
    echo "crash	$basename (signal=$sig, rc=$rc)"
  elif [[ $rc -ne 0 ]]; then
    echo "fail	$basename"
  else
    echo "pass	$basename"
  fi
}
export -f run_one_fixture

# Run fixtures in parallel and collect results
results_file="/tmp/vibe_fixture_results_$$.txt"
trap 'rm -f "$results_file"' EXIT

printf '%s\n' "${files[@]}" | xargs -P "$JOBS" -I {} bash -c 'run_one_fixture "$@"' _ {} > "$results_file"

# Aggregate results
pass=0
fail=0
crash=0
skip=0
timeout_count=0
crashes=()
timeouts=()

while IFS=$'\t' read -r status detail; do
  case "$status" in
    pass) pass=$((pass + 1)) ;;
    fail) fail=$((fail + 1)) ;;
    crash)
      crash=$((crash + 1))
      crashes+=("$detail")
      ;;
    timeout)
      timeout_count=$((timeout_count + 1))
      timeouts+=("$detail")
      ;;
    skip) skip=$((skip + 1)) ;;
  esac
done < "$results_file"

echo ""
echo "=== fixture isolation report ==="
echo "total=$total pass=$pass fail=$fail crash=$crash timeout=$timeout_count skip=$skip"

if [[ ${#crashes[@]} -gt 0 ]]; then
  echo ""
  echo "[CRASH] abort/signal detected (these kill the test process):"
  for c in "${crashes[@]}"; do
    echo "  $c"
  done
fi

if [[ ${#timeouts[@]} -gt 0 ]]; then
  echo ""
  echo "[TIMEOUT] exceeded ${TIMEOUT}s (possible infinite loop):"
  for t in "${timeouts[@]}"; do
    echo "  $t"
  done
fi

if [[ ${#crashes[@]} -gt 0 || ${#timeouts[@]} -gt 0 ]]; then
  exit 1
fi
