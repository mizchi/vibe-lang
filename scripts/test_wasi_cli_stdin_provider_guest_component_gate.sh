#!/usr/bin/env bash
# #1539: bounded arbitrary-core stdin-provider route. Generates compiled-shaped
# drain/early-close guests plus odd/out-of-u32/high-bit tagged-wire trap
# controls, validates their nominal WIT and bridge structure, then runs them on
# pinned Wasmtime 47.0.2 when the ratified stdin provider is available.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="$PROJECT_ROOT/_build/bench/wasi_cli_stdin_provider_guest"
mkdir -p "$OUT_DIR"

require_or_skip_runtime() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "wasi cli stdin provider guest FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "[wasi-cli-stdin-provider-guest] runtime SKIP: $what"
  echo "wasi cli stdin provider guest structural gate OK"
  exit 0
}

command -v wasm-tools >/dev/null 2>&1 || {
  echo "wasi cli stdin provider guest FAILED: wasm-tools is required" >&2
  exit 1
}

COMPILER="${VIBE_STDIN_PROVIDER_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  shopt -s nullglob
  for candidate in "$PROJECT_ROOT"/_build/selfhost/generations/*/stage2.wasm; do
    if [ -z "$COMPILER" ] || [ "$candidate" -nt "$COMPILER" ]; then
      COMPILER="$candidate"
    fi
  done
  shopt -u nullglob
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
fi
HARNESS="$OUT_DIR/dump.vibex"
HARNESS_WASM="$OUT_DIR/dump.wasm"
DRAIN="$OUT_DIR/drain.component.wasm"
EARLY="$OUT_DIR/early-close.component.wasm"
ODD_WIRE="$OUT_DIR/odd-wire.component.wasm"
OUT_OF_U32_WIRE="$OUT_DIR/out-of-u32-wire.component.wasm"
HIGH_BIT_WIRE="$OUT_DIR/high-bit-wire.component.wasm"
cat >"$HARNESS" <<'EOF'
import @vibe/compiler/entry/source_compile/wasi_only {
  comp_emit_component_wasm_async_stdin_provider_fixture
}

fn main() -> Unit with Exception + Fs {
  Fs::write_bytes("_build/bench/wasi_cli_stdin_provider_guest/drain.component.wasm", comp_emit_component_wasm_async_stdin_provider_fixture(0))
  Fs::write_bytes("_build/bench/wasi_cli_stdin_provider_guest/early-close.component.wasm", comp_emit_component_wasm_async_stdin_provider_fixture(1))
  Fs::write_bytes("_build/bench/wasi_cli_stdin_provider_guest/odd-wire.component.wasm", comp_emit_component_wasm_async_stdin_provider_fixture(2))
  Fs::write_bytes("_build/bench/wasi_cli_stdin_provider_guest/out-of-u32-wire.component.wasm", comp_emit_component_wasm_async_stdin_provider_fixture(3))
  Fs::write_bytes("_build/bench/wasi_cli_stdin_provider_guest/high-bit-wire.component.wasm", comp_emit_component_wasm_async_stdin_provider_fixture(4))
}
EOF
rm -f "$HARNESS_WASM" "$HARNESS_WASM.diag" "$DRAIN" "$EARLY" "$ODD_WIRE" "$OUT_OF_U32_WIRE" "$HIGH_BIT_WIRE"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" "$HARNESS" "$HARNESS_WASM" main >/dev/null
VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke main "$HARNESS_WASM" >/dev/null

for lane in drain early-close odd-wire out-of-u32-wire high-bit-wire; do
  component="$OUT_DIR/$lane.component.wasm"
  printed="$OUT_DIR/$lane.wat"
  wit="$OUT_DIR/$lane.wit"
  wasm-tools validate --features all "$component"
  wasm-tools print "$component" >"$printed"
  wasm-tools component wit "$component" >"$wit"
  prefix_sha="$(dd if="$component" bs=1 count=208 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  [ "$prefix_sha" = "9e0ecf27d3a3e5515f503f3fc0867e0ae5e02164adc32f279f9e6b1efd921c5e" ] || {
    echo "wasi cli stdin provider guest FAILED: nominal prefix drifted ($prefix_sha)" >&2
    exit 1
  }
  grep -Fq 'import wasi:cli/types@0.3.0;' "$wit"
  grep -Fq 'import wasi:cli/stdin@0.3.0;' "$wit"
  grep -Fq 'read-via-stream: func() -> tuple<stream<u8>, future<result<_, error-code>>>;' "$wit"
  grep -Fq 'stdin_provider_acquire' "$printed"
  grep -Fq 'stdin_provider_read' "$printed"
  grep -Fq 'stdin_provider_close' "$printed"
  grep -Fq '(core func (;0;) (canon lower (func 0) (memory 0)))' "$printed"
  grep -Fq 'canon stream.read 3 async (memory 0)' "$printed"
  grep -Fq 'canon future.read 5 async (memory 0)' "$printed"
  # The full shadow instance and its scenario exports are not guest imports.
  if grep -Fq 'host_stream_read' "$printed" || grep -Fq 'host_stream_close' "$printed"; then
    echo "wasi cli stdin provider guest FAILED: generic HostStream leaked" >&2
    exit 1
  fi
  # shellcheck disable=SC2016
  if grep -Fq 'host_stream_get$stdin' "$printed"; then
    echo "wasi cli stdin provider guest FAILED: named stdin HostStream leaked" >&2
    exit 1
  fi
done

check_malformed_control_guest() {
  local lane="$1" wire="$2"
  local body="$OUT_DIR/$lane-control.wat"
  sed -n '/  (core module (;0;)/,/^  )/p' "$OUT_DIR/$lane.wat" \
    | sed -n '/    (func (;4;)/,/^    )/p' >"$body"
  grep -Fq "i64.const $wire" "$body"
  # The control directly invokes bridge read (import 2): it neither acquires
  # provider state nor closes it before exercising malformed-wire validation.
  [ "$(grep -c '^      call 2$' "$body")" -eq 1 ]
  if grep -Eq '^      call (1|3)$' "$body"; then
    echo "wasi cli stdin provider guest FAILED: $lane touches provider lifecycle before validation" >&2
    exit 1
  fi
}
check_malformed_control_guest odd-wire 1
check_malformed_control_guest out-of-u32-wire 4294967296
check_malformed_control_guest high-bit-wire -2

# The bridge is core module 2 in this bounded composer. It owns no memory, and
# decode (func 3) must complete both wire checks before narrowing. Read/close
# must call decode before the first lifecycle-shadow call, proving malformed
# wires cannot reach provider state or any canonical stream/future operation.
BRIDGE_WAT="$OUT_DIR/bridge.wat"
sed -n '/  (core module (;2;)/,/^  )/p' "$OUT_DIR/drain.wat" >"$BRIDGE_WAT"
grep -Fq 'i64.and' "$BRIDGE_WAT"
grep -Fq 'i64.gt_u' "$BRIDGE_WAT"
grep -Fq 'i32.wrap_i64' "$BRIDGE_WAT"
if grep -Eq 'i32\.(load|store)|memory\.' "$BRIDGE_WAT"; then
  echo "wasi cli stdin provider guest FAILED: tagged bridge accesses state directly" >&2
  exit 1
fi
check_bridge_call_order() {
  local func_idx="$1" provider_call="$2"
  local body="$OUT_DIR/bridge-func-$func_idx.wat"
  sed -n "/    (func (;$func_idx;)/,/^    )/p" "$BRIDGE_WAT" >"$body"
  awk -v provider_call="$provider_call" '
    /^      call [0-9]+$/ {
      calls += 1
      if (calls == 1 && $2 != 3) bad = 1
      if (calls == 2 && $2 != provider_call) bad = 1
    }
    END { exit !(calls == 2 && bad != 1) }
  ' "$body"
}
# func 5 read: decode (3), then shadow read (1); func 6 close: decode, shadow close (2).
check_bridge_call_order 5 1
check_bridge_call_order 6 2
# Decode itself is pure validation/narrowing: no state access and no imports.
DECODE_WAT="$OUT_DIR/bridge-func-3.wat"
sed -n '/    (func (;3;)/,/^    )/p' "$BRIDGE_WAT" >"$DECODE_WAT"
if grep -Eq '^      call ' "$DECODE_WAT"; then
  echo "wasi cli stdin provider guest FAILED: decode calls provider before validation" >&2
  exit 1
fi
[ "$(grep -c '^        unreachable$' "$DECODE_WAT")" -eq 2 ]
awk '
  /i64\.and/ { odd_check = NR }
  /i64\.gt_u/ { range_check = NR }
  /i32\.wrap_i64/ { narrow = NR }
  END { exit !(odd_check < range_check && range_check < narrow) }
' "$DECODE_WAT"
echo "[wasi-cli-stdin-provider-guest] generated components validate/WIT/bridge ordering OK"

WASMTIME_BIN="${WASMTIME_BIN:-$(command -v wasmtime || true)}"
[ -n "$WASMTIME_BIN" ] || require_or_skip_runtime "wasmtime not installed"
WASMTIME_VERSION="$("$WASMTIME_BIN" --version 2>/dev/null || true)"
case "$WASMTIME_VERSION" in
  "wasmtime 47.0.2"\ *) ;;
  *) require_or_skip_runtime "requires wasmtime 47.0.2, got ${WASMTIME_VERSION:-unavailable}" ;;
esac

INPUT="$OUT_DIR/stdin-10-15-17.bin"
printf '\012\017\021' >"$INPUT"
FLAGS=(-Sp3 -W component-model-async=y -W component-model-async-stackful=y -W component-model-more-async-builtins=y)
run_lane() {
  local lane="$1" expected="$2"
  local log="$OUT_DIR/run.$lane.log"
  if ! timeout 60 "$WASMTIME_BIN" run "${FLAGS[@]}" --invoke 'run()' "$OUT_DIR/$lane.component.wasm" <"$INPUT" >"$log" 2>&1; then
    if grep -Eq 'component imports instance .wasi:cli/stdin@0\.3\.0., but a matching implementation was not found in (the )?linker' "$log"; then
      require_or_skip_runtime "wasmtime has no matching wasi:cli/stdin@0.3.0 implementation"
    fi
    cat "$log" >&2
    echo "wasi cli stdin provider guest FAILED: $lane did not exit 0" >&2
    exit 1
  fi
  [ "$(cat "$log")" = "$expected" ] || {
    echo "wasi cli stdin provider guest FAILED: $lane expected $expected, got $(cat "$log")" >&2
    exit 1
  }
  echo "[wasi-cli-stdin-provider-guest] $lane: $expected"
}
run_trap() {
  local lane="$1"
  local log="$OUT_DIR/run.$lane.log"
  if timeout 60 "$WASMTIME_BIN" run "${FLAGS[@]}" --invoke 'run()' "$OUT_DIR/$lane.component.wasm" <"$INPUT" >"$log" 2>&1; then
    echo "wasi cli stdin provider guest FAILED: $lane unexpectedly succeeded" >&2
    exit 1
  fi
  grep -Eqi 'unreachable|wasm trap' "$log" || {
    echo "wasi cli stdin provider guest FAILED: $lane failed without the expected trap" >&2
    cat "$log" >&2
    exit 1
  }
  echo "[wasi-cli-stdin-provider-guest] $lane: expected trap"
}
run_lane drain 42
run_lane early-close 43
run_trap odd-wire
run_trap out-of-u32-wire
run_trap high-bit-wire

echo "wasi cli stdin provider guest component gate OK (wasmtime 47.0.2)"
