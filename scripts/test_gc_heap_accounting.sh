#!/usr/bin/env bash
# Characterize the current wasm-gc lane's guest-linear bump allocation.
#
# This is intentionally NOT a Wasmtime tracing-GC leak test: current gc-lane
# aggregate/closure lowering advances exported `__heap_ptr` in linear memory.
# It proves that the churn fixture runs and allocates enough discarded objects
# to exercise that path; a future struct.new/array.new backend needs a separate
# embedding-level live-heap test.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CLI_WASM="${1:-${VIBE_GC_HEAP_ACCOUNTING_CLI_WASM:-}}"
if [ -z "$CLI_WASM" ]; then
  CLI_WASM="$(ls -t "$ROOT_DIR"/_build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1 || true)"
fi
[ -n "$CLI_WASM" ] && [ -s "$CLI_WASM" ] || {
  echo "[gc-heap-accounting] FAIL: pass a stage2.wasm or build a selfhost generation" >&2
  exit 1
}

RUNNER="$ROOT_DIR/runtime/viberun/target/release/viberun"
if [ ! -x "$RUNNER" ] || find runtime/viberun/src runtime/viberun/Cargo.toml runtime/viberun/Cargo.lock -newer "$RUNNER" -print -quit | grep -q .; then
  cargo build --release --manifest-path runtime/viberun/Cargo.toml >/dev/null
fi

WORK="$(mktemp -d "$ROOT_DIR/_build/gc_heap_accounting.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/churn.wasm"
OUT_REL="${OUT#"$ROOT_DIR"/}"

VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
  fixtures/gc_heap_churn_test.vibe "$OUT_REL" __no_entry__ >/dev/null
[ -s "$OUT" ] || {
  echo "[gc-heap-accounting] FAIL: gc backend emitted no test module" >&2
  exit 1
}

REPORT="$(VIBE_MEM=1 "$RUNNER" "$OUT" 2>&1 >/dev/null)" || {
  printf '%s\n' "$REPORT" >&2
  echo "[gc-heap-accounting] FAIL: churn fixture trapped" >&2
  exit 1
}
printf '%s\n' "$REPORT"

ALLOCATED="$(printf '%s\n' "$REPORT" | sed -n 's/.*allocated=\([0-9][0-9]*\).*/\1/p' | head -1)"
case "$ALLOCATED" in
  ''|*[!0-9]*)
    echo "[gc-heap-accounting] FAIL: missing numeric vibe::mem allocated field" >&2
    exit 1
    ;;
esac

# 8192 discarded four-element arrays currently allocate ~600 KiB. Keep the
# threshold deliberately low so harmless layout/capacity changes do not make
# the characterization brittle, while still proving multiple page crossings.
if [ "$ALLOCATED" -lt 65536 ]; then
  echo "[gc-heap-accounting] FAIL: allocated=$ALLOCATED, expected >=65536 bytes" >&2
  exit 1
fi

echo "[gc-heap-accounting] ok: guest bump high-water increased by $ALLOCATED bytes"
