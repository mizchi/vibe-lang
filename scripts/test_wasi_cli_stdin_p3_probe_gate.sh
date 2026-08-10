#!/usr/bin/env bash
# #1539: fail-closed availability check for wasi:cli/stdin@0.3.0.
#
# The probe declares the ratified WIT import, including the nominal
# wasi:cli/types@0.3.0 error-code used in the completion result. It checks
# linkage only. A successful link passes; the exact missing-implementation
# diagnostic skips locally and fails in required mode. Neither is a completed
# behavioral test.
#
# Env:
#   WASMTIME_BIN                 wasmtime binary under test (default: PATH)
#   VIBE_P3_GATE_REQUIRE_TOOLS=1 missing tools = FAIL instead of skip
set -euo pipefail

is_expected_unavailability() {
  local log="$1"
  # Do not accept a generic type error: it could describe an ABI defect in the
  # probe itself. The selected host must specifically say that the ratified
  # stdin instance has no linker implementation.
  grep -Eq 'component imports instance .wasi:cli/stdin@0\.3\.0., but a matching implementation was not found in (the )?linker' "$log"
}

run_diagnostic_self_test() {
  local dir expected wrong_type missing_function missing_command_export
  dir="$(mktemp -d)"
  expected="$dir/expected.log"
  wrong_type="$dir/wrong-type.log"
  missing_function="$dir/missing-function.log"
  missing_command_export="$dir/missing-command-export.log"

  cat >"$expected" <<'EOF'
component imports instance `wasi:cli/stdin@0.3.0`, but a matching implementation was not found in the linker
EOF
  cat >"$wrong_type" <<'EOF'
component imports instance wasi:cli/stdin@0.3.0, but instance export read-via-stream has the wrong type
EOF
  cat >"$missing_function" <<'EOF'
component imports instance wasi:cli/stdin@0.3.0, but function implementation is missing
EOF
  cat >"$missing_command_export" <<'EOF'
no exported instance named `wasi:cli/run@0.2.12`
EOF

  if ! is_expected_unavailability "$expected"; then
    rm -rf "$dir"
    echo "wasi cli stdin p3 probe diagnostic self-test FAILED: missing expected unavailability" >&2
    return 1
  fi
  if is_expected_unavailability "$wrong_type" || is_expected_unavailability "$missing_function" || is_expected_unavailability "$missing_command_export"; then
    rm -rf "$dir"
    echo "wasi cli stdin p3 probe diagnostic self-test FAILED: accepted ABI/type or missing-command diagnostic" >&2
    return 1
  fi
  rm -rf "$dir"
  echo "wasi cli stdin p3 probe diagnostic self-test OK"
}

if [ "${1:-}" = "--self-test-diagnostics" ]; then
  run_diagnostic_self_test
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/wasi_cli_stdin_p3_probe}"
mkdir -p "$OUT_DIR"

require_or_skip() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "wasi cli stdin p3 probe FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "wasi cli stdin p3 probe skipped: $what"
  exit 0
}

command -v wasm-tools >/dev/null 2>&1 || require_or_skip "wasm-tools not installed"
WASMTIME_BIN="${WASMTIME_BIN:-$(command -v wasmtime || true)}"
[ -n "$WASMTIME_BIN" ] || require_or_skip "wasmtime not installed"

WAT="$PROJECT_ROOT/tools/wasip3_component_probe/stdin_read_via_stream/component.wat"
COMPONENT="$OUT_DIR/stdin_read_via_stream.wasm"
wasm-tools parse "$WAT" -o "$COMPONENT"
wasm-tools validate --features all "$COMPONENT"
PRINTED="$OUT_DIR/stdin_read_via_stream.print.wat"
wasm-tools print "$COMPONENT" >"$PRINTED"
grep -Fq 'wasi:cli/types@0.3.0' "$PRINTED"
grep -Fq 'wasi:cli/stdin@0.3.0' "$PRINTED"
grep -Fq 'wasi:cli/run@0.2.12' "$PRINTED"
grep -Fq '(enum "io" "illegal-byte-sequence" "pipe")' "$PRINTED"
grep -Fq 'read-via-stream' "$PRINTED"

LOG="$OUT_DIR/wasmtime.log"
if "$WASMTIME_BIN" run -Sp3 -Wcomponent-model-async=y "$COMPONENT" >"$LOG" 2>&1; then
  echo "[wasi-cli-stdin-p3-probe] validated exact ratified @0.3.0 imports; wasmtime linked stdin"
  echo "wasi cli stdin p3 probe gate OK (availability only; lifecycle remains unmeasured)"
  exit 0
fi

# A generic `wrong type`, `function implementation is missing`, or missing
# command export is not evidence of stdin availability. Preserve the exact log
# for review.
if ! is_expected_unavailability "$LOG"; then
  echo "wasi cli stdin p3 probe FAILED: unexpected wasmtime rejection" >&2
  cat "$LOG" >&2
  exit 1
fi

echo "[wasi-cli-stdin-p3-probe] validated exact ratified @0.3.0 imports; wasmtime has no matching stdin implementation"
require_or_skip "wasmtime has no matching wasi:cli/stdin@0.3.0 implementation"
