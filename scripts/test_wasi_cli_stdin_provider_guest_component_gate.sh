#!/usr/bin/env bash
# #1539: bounded arbitrary-core stdin-provider route. Generates two
# compiled-shaped guests (drain and early close), validates their nominal WIT
# and bridge structure, then runs them on pinned Wasmtime 47.0.2 when the
# ratified stdin provider is available.
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
cat >"$HARNESS" <<'EOF'
import @vibe/compiler/entry/source_compile/wasi_only {
  comp_emit_component_wasm_async_stdin_provider_fixture
}

fn main() -> Unit with Exception + Fs {
  Fs::write_bytes("_build/bench/wasi_cli_stdin_provider_guest/drain.component.wasm", comp_emit_component_wasm_async_stdin_provider_fixture(0))
  Fs::write_bytes("_build/bench/wasi_cli_stdin_provider_guest/early-close.component.wasm", comp_emit_component_wasm_async_stdin_provider_fixture(1))
}
EOF
rm -f "$HARNESS_WASM" "$HARNESS_WASM.diag" "$DRAIN" "$EARLY"
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" "$HARNESS" "$HARNESS_WASM" main >/dev/null
VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke main "$HARNESS_WASM" >/dev/null

for lane in drain early-close; do
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
echo "[wasi-cli-stdin-provider-guest] generated components validate/WIT/structure OK"

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
run_lane drain 42
run_lane early-close 43

echo "wasi cli stdin provider guest component gate OK (wasmtime 47.0.2)"
