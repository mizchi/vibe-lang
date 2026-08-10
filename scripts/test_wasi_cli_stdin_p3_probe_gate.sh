#!/usr/bin/env bash
# #1539: executable, fail-closed stdin lifecycle measurement for
# wasi:cli/stdin@0.3.0 on the pinned wasmtime 47.0.2 provider.
#
# The WAT retains the ratified nominal wasi:cli/types@0.3.0 error-code and a
# preview-2 command export. Its two explicitly invoked async lanes measure:
#   drain: bytes 10,15,17 -> EOF -> completion future success -> 42
#   drop:  drop readable stream -> completion future success -> 43
# Unexpected statuses/events/bytes/EOF/result variants return diagnostic codes
# from the guest and therefore fail this gate rather than being accepted.
#
# Env:
#   WASMTIME_BIN                 wasmtime binary under test (default: PATH)
#   VIBE_P3_GATE_REQUIRE_TOOLS=1 missing/wrong-version tools = FAIL, not skip
set -euo pipefail

PINNED_WASMTIME_VERSION="wasmtime 47.0.2"

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
WASMTIME_VERSION="$("$WASMTIME_BIN" --version 2>/dev/null || true)"
case "$WASMTIME_VERSION" in
  "$PINNED_WASMTIME_VERSION"\ *) ;;
  *) require_or_skip "requires $PINNED_WASMTIME_VERSION, got ${WASMTIME_VERSION:-unavailable}" ;;
esac

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
grep -Fq 'canon stream.read' "$PRINTED"
grep -Fq 'canon future.read' "$PRINTED"
grep -Fq 'canon waitable-set.wait' "$PRINTED"
grep -Fq 'canon task.return' "$PRINTED"

# Binary input avoids platform/text-mode ambiguity: the drain lane requires
# exactly these three u8 values followed by EOF.
INPUT="$OUT_DIR/stdin-10-15-17.bin"
printf '\012\017\021' >"$INPUT"
run_lane() {
  local lane="$1" expected="$2" log got
  log="$OUT_DIR/$lane.log"
  if ! timeout 60 "$WASMTIME_BIN" run -Sp3 \
      -W component-model-async=y -W component-model-async-stackful=y \
      -W component-model-more-async-builtins=y \
      --invoke "$lane()" "$COMPONENT" <"$INPUT" >"$log" 2>&1; then
    # Keep the old availability boundary fail-closed: only this exact missing
    # stdin-provider diagnostic may skip locally. An ABI/type/command error is
    # evidence against the probe and must always remain a failure.
    if is_expected_unavailability "$log"; then
      echo "[wasi-cli-stdin-p3-probe] validated exact ratified @0.3.0 imports; wasmtime has no matching stdin implementation"
      require_or_skip "wasmtime has no matching wasi:cli/stdin@0.3.0 implementation"
    fi
    echo "wasi cli stdin p3 probe FAILED: $lane lane did not exit 0" >&2
    cat "$log" >&2
    exit 1
  fi
  got="$(cat "$log")"
  if [ "$got" != "$expected" ]; then
    echo "wasi cli stdin p3 probe FAILED: $lane expected $expected, got: $got" >&2
    exit 1
  fi
  echo "[wasi-cli-stdin-p3-probe] $lane: $got"
}

run_lane drain 42
run_lane drop 43

echo "wasi cli stdin p3 probe gate OK ($PINNED_WASMTIME_VERSION; drain EOF/completion=42, early-drop/completion=43)"
