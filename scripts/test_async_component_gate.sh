#!/usr/bin/env bash
# Async-component regression gate (#821 Step 0 restoration).
#
# Verifies the WASI p3 async vertical documented in docs/spec/wasi-p3-async.md:
# a `.vibe` entry `run : () -> Int with Async` compiled by the selfhost
# compiler (single-source path, entry name "run") is wrapped into a Component
# Model async component and returns 42 under wasmtime with the p3 RC flags.
# Also asserts the wrap does NOT leak into ordinary builds (a non-async entry
# stays a plain core module).
#
# Entries covered (spec milestone table M1b-3b / M-conc-1 / M2a / M2b / M2c):
#   await      await(Future::ready(42))
#   body       ByteStream consume: String::to_bytes fold
#   roundtrip  ByteStream::to_string(String::to_bytes(...))
#   control    non-async entry stays a core module (magic layer 0x01)
#
# forawait: the `for x in stream` entry regressed while this gate was
# missing (#822 — the pull-classification called the Stream value as a
# closure); fixed by classifying builtin Streams to the eager array loop, and
# promoted into the always-on set.
#
# Env:
#   VIBE_ASYNC_GATE_COMPILER        compiler wasm override (default: newest
#                                   _build generation stage2, else seed)
#   VIBE_ASYNC_GATE_WASMTIME_FLAGS  wasmtime flags override (default: wasmtime
#                                   45 RC flag set; clear/adjust for the
#                                   wasmtime 46 re-probe, #821)
#   VIBE_P3_GATE_REQUIRE_TOOLS=1    missing wasmtime = FAIL instead of skip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_async_component}"
mkdir -p "$OUT_DIR"

WASMTIME_BIN="$("$SCRIPT_DIR/wasmtime_bin.sh" 2>/dev/null || command -v wasmtime || true)"
if [ -z "${WASMTIME_BIN:-}" ] || ! "$WASMTIME_BIN" --version >/dev/null 2>&1; then
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "selfhost async component gate FAILED: wasmtime not installed (required mode)" >&2
    exit 1
  fi
  echo "selfhost async component gate skipped: wasmtime not installed"
  exit 0
fi
echo "[async-component-gate] wasmtime: $("$WASMTIME_BIN" --version)"

COMPILER="${VIBE_ASYNC_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  # `|| true`: no generations dir => ls exits nonzero => pipefail would abort
  # before the seed fallback below could run.
  COMPILER="$(ls -td "$PROJECT_ROOT"/_build/selfhost/generations/*/ 2>/dev/null | head -1 || true)stage2.wasm"
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
fi
echo "[async-component-gate] compiler: $COMPILER"

# wasmtime 45 RC flag set (docs/spec/wasi-p3-async.md §3.5). On wasmtime 46+
# component-model-async is default; override via VIBE_ASYNC_GATE_WASMTIME_FLAGS.
WT_FLAGS="${VIBE_ASYNC_GATE_WASMTIME_FLAGS:--W exceptions=y -W concurrency-support=y -W component-model-async=y -W component-model-async-stackful=y}"

write_fixtures() {
  cat >"$OUT_DIR/await.vibe" <<'EOF'
let run: () -> Int with Async = () -> {
  await(Future::ready(42))
}
EOF
  cat >"$OUT_DIR/body.vibe" <<'EOF'
let run: () -> Int with Async = () -> {
  let mut acc = 0
  for b in String::to_bytes("\n ") {
    acc = acc + b
  }
  acc
}
EOF
  cat >"$OUT_DIR/roundtrip.vibe" <<'EOF'
let run: () -> Int with Async = () -> {
  let s = ByteStream::to_string(String::to_bytes("42"))
  if s == "42" { 42 } else { 0 }
}
EOF
  cat >"$OUT_DIR/forawait.vibe" <<'EOF'
let run: () -> Int with Async = () -> {
  let s = String::to_bytes("*")
  let mut sum = 0
  for x in s {
    sum = sum + x
  }
  sum
}
EOF
  cat >"$OUT_DIR/control.vibe" <<'EOF'
let run: () -> Int = () -> { 40 + 2 }
EOF
}

# magic_layer <file> -> "01" (core module) or "0d" (component)
magic_layer() {
  od -A n -t x1 -N 8 "$1" | awk '{print $5}'
}

compile_one() {
  local src="$1" out="$2"
  rm -f "$out" "$out.diag"
  # Single-source path (NO VIBE_FS_COMPILE): compile_source_wasi_only detects
  # the async `run` entry and wraps it into an async component.
  VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw \
    bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
    "$COMPILER" "$src" "$out" run >/dev/null
}

run_component_42() {
  local name="$1"
  local comp="$OUT_DIR/$name.component.wasm"
  if ! compile_one "$OUT_DIR/$name.vibe" "$comp"; then
    echo "selfhost async component gate FAILED: $name did not compile: $(cat "$comp.diag" 2>/dev/null)" >&2
    exit 1
  fi
  if [ "$(magic_layer "$comp")" != "0d" ]; then
    echo "selfhost async component gate FAILED: $name output is not a component (async wrap missing)" >&2
    exit 1
  fi
  if command -v wasm-tools >/dev/null 2>&1; then
    wasm-tools validate --features all "$comp" >/dev/null
  fi
  local result
  result="$("$WASMTIME_BIN" $WT_FLAGS --invoke 'run()' "$comp" 2>"$OUT_DIR/$name.err" | tail -n 1 || true)"
  if [ "$result" != "42" ]; then
    echo "selfhost async component gate FAILED: $name returned '$result' (expected 42)" >&2
    sed -n '1,6p' "$OUT_DIR/$name.err" >&2 || true
    exit 1
  fi
  echo "[async-component-gate] $name: 42 ok"
}

write_fixtures

ENTRIES="await body roundtrip forawait"
for name in $ENTRIES; do
  run_component_42 "$name"
done

# Non-async control must stay a plain core module — the async wrap must not
# leak into ordinary builds.
CONTROL_OUT="$OUT_DIR/control.wasm"
if ! compile_one "$OUT_DIR/control.vibe" "$CONTROL_OUT"; then
  echo "selfhost async component gate FAILED: control did not compile: $(cat "$CONTROL_OUT.diag" 2>/dev/null)" >&2
  exit 1
fi
if [ "$(magic_layer "$CONTROL_OUT")" != "01" ]; then
  echo "selfhost async component gate FAILED: non-async control is not a plain core module" >&2
  exit 1
fi
echo "[async-component-gate] control: core module ok"

echo "selfhost async component gate passed"
