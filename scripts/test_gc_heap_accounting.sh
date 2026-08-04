#!/usr/bin/env bash
# Verify non-escaping Wasm-GC local array literals do not churn the guest
# linear bump heap. This intentionally does not claim tracing-GC liveness;
# it only proves the private typed local never touches exported __heap_ptr.
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

# Churn, the if branch, the match branch, and (since #1332) the nested lambda
# body and a lambda created inside a module initializer each have one eligible
# literal -- five in total. Alias/push/return, an array a DEEPER lambda
# captures, and an array bound directly in an initializer's own `_start` frame
# still use the linear fallback. This guards typed-ref/i64 sibling-control-flow
# regressions, the lambda/capture boundary, and the frame-vs-module halves of
# the eligibility split, all at Wasm emission.
python3 - "$OUT" <<'PY'
import sys
wasm = open(sys.argv[1], "rb").read()
count = wasm.count(b"\xfb\x07\x0c")
if count != 5:
    raise SystemExit(
        "[gc-heap-accounting] FAIL: expected five eligible native "
        f"array.new_default type 12 instructions, found {count}"
    )
PY

# The fixture must also pass independent Wasm-GC validation: since #1332 lambda
# records DO describe typed native-array locals, so this is the check that the
# lambda code section declares (ref null $array) for exactly those slots.
wasm-tools validate --features all "$OUT" >/dev/null

REPORT="$(VIBE_MEM=1 "$RUNNER" "$OUT" 2>&1 >/dev/null)" || {
  printf '%s\n' "$REPORT" >&2
  echo "[gc-heap-accounting] FAIL: churn fixture trapped" >&2
  exit 1
}
printf '%s\n' "$REPORT"

# SIMD lane parity (#1331 調査の派生). `simd_*` は linear 専用として登録されて
# おり、`Bytes::blit`/`fill` は gc にあるのに SIMD だけ無い、という不整合だった。
# `Bytes` は両レーンとも linear memory 上にあり SIMD はまさにそこで成立する
# (`v128.load` はメモリアドレスを取る命令で、wasm-gc の配列はアドレス可能では
# ないため GC 側へ移す道は無い) ので、gc で動かない理由が無かった。
#
# ここに置くのは #125 の教訓 — CI に無い検証は腐る。登録を落とすと gc での
# コンパイルが失敗し、このステップで落ちる。
SIMD_OUT="$ROOT_DIR/_build/_gc_gate_simd.wasm"
SIMD_OUT_REL="${SIMD_OUT#"$ROOT_DIR"/}"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
  fixtures/simd_skip_ws_test.vibe "$SIMD_OUT_REL" __no_entry__ >/dev/null || {
  echo "[gc-heap-accounting] FAIL: simd fixture did not compile on the gc lane" >&2
  exit 1
}
wasm-tools validate --features all "$SIMD_OUT" >/dev/null
"$RUNNER" "$SIMD_OUT" >/dev/null || {
  echo "[gc-heap-accounting] FAIL: simd fixture trapped on the gc lane" >&2
  exit 1
}
echo "[gc-heap-accounting] ok: simd_skip_ws fixture passes on the gc lane"

ALLOCATED="$(printf '%s\n' "$REPORT" | sed -n 's/.*allocated=\([0-9][0-9]*\).*/\1/p' | head -1)"
case "$ALLOCATED" in
  ''|*[!0-9]*)
    echo "[gc-heap-accounting] FAIL: missing numeric vibe::mem allocated field" >&2
    exit 1
    ;;
esac

# The fixture's 8192 churn literals are native GC arrays. The current fixture
# also deliberately executes several linear fallback examples (alias, push,
# return, a module-level initializer, and since #1332 an array a DEEPER lambda
# captures), so its observed fixed baseline is 396 B -- it has moved 228 -> 304
# -> 380 -> 396 as those fallback cases were added.
# Do not assert that exact value: startup/layout and fallback
# fixture changes may move it. The old linear churn lowering was hundreds of
# KiB, therefore this bounded allowance remains the regression property.
if [ "$ALLOCATED" -gt 8192 ]; then
  echo "[gc-heap-accounting] FAIL: allocated=$ALLOCATED, expected <=8192 bytes (native local arrays must not bump __heap_ptr per iteration)" >&2
  exit 1
fi

echo "[gc-heap-accounting] ok: native local array churn kept guest bump allocation at $ALLOCATED bytes"
