#!/usr/bin/env bash
# #1539: generated, production-unused stdin provider shadow component gate.
# Structural checks always cover the exact nominal import prefix, synchronous
# memory-bearing read-via-stream lower, private adapter/scenario surface, and
# component WIT. Wasmtime 47.0.2 additionally runs drain/early-close and the
# two expected-trap controls when its ratified stdin provider is available.
# The forced completion tag is a control of cleanup/fail-closed code, not a
# measurement of a provider-generated completion error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/wasi_cli_stdin_provider_shadow}"
mkdir -p "$OUT_DIR"

require_or_skip_runtime() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "wasi cli stdin provider shadow FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "[wasi-cli-stdin-provider-shadow] runtime SKIP: $what"
  echo "wasi cli stdin provider shadow structural gate OK"
  exit 0
}

command -v wasm-tools >/dev/null 2>&1 || {
  echo "wasi cli stdin provider shadow FAILED: wasm-tools is required for generated structural validation" >&2
  exit 1
}

COMPILER="${VIBE_STDIN_PROVIDER_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  COMPILER="$(ls -td "$PROJECT_ROOT"/_build/selfhost/generations/*/ 2>/dev/null | head -1 || true)stage2.wasm"
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
fi
HARNESS="$OUT_DIR/dump.vibex"
HARNESS_WASM="$OUT_DIR/dump.wasm"
COMPONENT="$OUT_DIR/generated.component.wasm"
PRINTED="$OUT_DIR/generated.wat"
WIT="$OUT_DIR/generated.wit"
cat >"$HARNESS" <<'EOF'
import @vibe/compiler/entry/source_compile/wasi_only {
  comp_emit_component_wasm_stdin_provider_shadow
}

fn main() -> Unit with Exception + Fs {
  Fs::write_bytes("_build/bench/wasi_cli_stdin_provider_shadow/generated.component.wasm", comp_emit_component_wasm_stdin_provider_shadow())
}
EOF
rm -f "$HARNESS_WASM" "$HARNESS_WASM.diag" "$COMPONENT"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" "$HARNESS" "$HARNESS_WASM" main >/dev/null
VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke main "$HARNESS_WASM" >/dev/null

wasm-tools validate --features all "$COMPONENT"
wasm-tools print "$COMPONENT" >"$PRINTED"
wasm-tools component wit "$COMPONENT" >"$WIT"

# #1620's independently-derived 208-byte golden, now a shared exact prefix.
PREFIX_SHA="$(dd if="$COMPONENT" bs=1 count=208 2>/dev/null | shasum -a 256 | awk '{print $1}')"
[ "$PREFIX_SHA" = "9e0ecf27d3a3e5515f503f3fc0867e0ae5e02164adc32f279f9e6b1efd921c5e" ] || {
  echo "wasi cli stdin provider shadow FAILED: exact nominal import prefix drifted ($PREFIX_SHA)" >&2
  exit 1
}
grep -Fq 'import wasi:cli/types@0.3.0;' "$WIT"
grep -Fq 'import wasi:cli/stdin@0.3.0;' "$WIT"
grep -Fq 'read-via-stream: func() -> tuple<stream<u8>, future<result<_, error-code>>>;' "$WIT"
grep -Fq '(core func (;0;) (canon lower (func 0) (memory 0)))' "$PRINTED"
grep -Fq 'canon stream.read 3 async (memory 0)' "$PRINTED"
grep -Fq 'canon future.read 5 async (memory 0)' "$PRINTED"
grep -Fq 'stdin-provider-shadow-acquire' "$PRINTED"
grep -Fq 'stdin-provider-shadow-settle' "$PRINTED"
grep -Fq 'forced-completion-tag-control' "$PRINTED"
grep -Fq 'foreign-provider-control' "$PRINTED"
if grep -Fq 'host_stream_get$stdin' "$PRINTED" || grep -Fq 'host_stream_close' "$PRINTED"; then
  echo "wasi cli stdin provider shadow FAILED: generic HostStream machinery leaked into shadow" >&2
  exit 1
fi
# Both BLOCKED branches encode join(handle,set), wait, join(handle,0), set.drop.
[ "$(grep -c 'call 6' "$PRINTED")" -ge 4 ]
[ "$(grep -c 'call 8' "$PRINTED")" -eq 2 ]
echo "[wasi-cli-stdin-provider-shadow] generated component validate/WIT/prefix/structure OK"

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
run_success() {
  local lane="$1" expected="$2"
  local log="$OUT_DIR/run.$lane.log"
  if ! timeout 60 "$WASMTIME_BIN" run "${FLAGS[@]}" --invoke "$lane()" "$COMPONENT" <"$INPUT" >"$log" 2>&1; then
    if grep -Eq 'component imports instance .wasi:cli/stdin@0\.3\.0., but a matching implementation was not found in (the )?linker' "$log"; then
      require_or_skip_runtime "wasmtime has no matching wasi:cli/stdin@0.3.0 implementation"
    fi
    cat "$log" >&2
    echo "wasi cli stdin provider shadow FAILED: $lane did not exit 0" >&2
    exit 1
  fi
  [ "$(cat "$log")" = "$expected" ] || {
    echo "wasi cli stdin provider shadow FAILED: $lane expected $expected, got $(cat "$log")" >&2
    exit 1
  }
  echo "[wasi-cli-stdin-provider-shadow] $lane: $expected"
}
run_trap() {
  local lane="$1"
  local log="$OUT_DIR/run.$lane.log"
  if timeout 60 "$WASMTIME_BIN" run "${FLAGS[@]}" --invoke "$lane()" "$COMPONENT" <"$INPUT" >"$log" 2>&1; then
    echo "wasi cli stdin provider shadow FAILED: $lane unexpectedly succeeded" >&2
    exit 1
  fi
  grep -Eqi 'unreachable|wasm trap' "$log" || {
    echo "wasi cli stdin provider shadow FAILED: $lane failed without the expected trap" >&2
    cat "$log" >&2
    exit 1
  }
  echo "[wasi-cli-stdin-provider-shadow] $lane: expected trap"
}

run_success drain 42
run_success early-close 43
run_trap forced-completion-tag-control
run_trap foreign-provider-control

echo "wasi cli stdin provider shadow component gate OK (wasmtime 47.0.2)"
