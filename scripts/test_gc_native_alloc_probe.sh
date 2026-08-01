#!/usr/bin/env bash
# Verify the wasm-gc backend's private native-allocation probe end-to-end.
#
# The scalar fixture has no aggregate values: struct.new/array.new in its
# output can only come from the compiler probe. Both references are dropped
# before user code, so this is intentionally not an ABI or representation
# migration test.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CLI_WASM="${1:-${VIBE_GC_NATIVE_ALLOC_PROBE_CLI_WASM:-}}"
if [ -z "$CLI_WASM" ]; then
  CLI_WASM="$(ls -t "$ROOT_DIR"/_build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1 || true)"
fi
[ -n "$CLI_WASM" ] && [ -s "$CLI_WASM" ] || {
  echo "[gc-native-alloc-probe] FAIL: pass a fresh stage2.wasm or build a selfhost generation" >&2
  exit 1
}

RUNNER="$ROOT_DIR/runtime/viberun/target/release/viberun"
if [ ! -x "$RUNNER" ] || find runtime/viberun/src runtime/viberun/Cargo.toml runtime/viberun/Cargo.lock -newer "$RUNNER" -print -quit | grep -q .; then
  cargo build --release --manifest-path runtime/viberun/Cargo.toml >/dev/null
fi

WORK="$(mktemp -d "$ROOT_DIR/_build/gc_native_alloc_probe.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/probe.wasm"
OUT_REL="${OUT#"$ROOT_DIR"/}"

VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE=1 VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
  fixtures/gc_native_alloc_probe.vibe "$OUT_REL" main >/dev/null
[ -s "$OUT" ] || {
  echo "[gc-native-alloc-probe] FAIL: gc backend emitted no module" >&2
  exit 1
}

# Type 10 is the private one-field i64 struct; type 11 is the private immutable
# i64 array. The fixture has no user aggregates, so these exact instructions
# prove compiler emission rather than source-level aggregate lowering.
python3 - "$OUT" <<'PY'
import sys
wasm = open(sys.argv[1], "rb").read()
required = (
    (b"\xfb\x00\x0a", "struct.new type 10"),
    (b"\xfb\x06\x0b", "array.new type 11"),
)
for opcode, description in required:
    if opcode not in wasm:
        raise SystemExit(f"[gc-native-alloc-probe] FAIL: missing {description}")
PY

RESULT="$($RUNNER "$OUT" | tail -1)"
if [ "$RESULT" != "42" ]; then
  echo "[gc-native-alloc-probe] FAIL: viberun got '$RESULT' (want 42)" >&2
  exit 1
fi

echo "[gc-native-alloc-probe] ok: viberun executed private struct.new + array.new (42)"
