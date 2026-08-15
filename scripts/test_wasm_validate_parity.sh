#!/usr/bin/env bash
# `@vibex/wasm_parser::validate_structure` against `wasm-tools validate` (#1133).
#
# The contract under test is ONE-SIDED, and the two halves are gated
# differently on purpose:
#
#   HARD   never reject a module wasm-tools accepts. A false rejection means
#          the validator would refuse a legitimate module, so any occurrence
#          fails this script.
#   FLOOR  reject as many as possible of the ones wasm-tools rejects. Structural
#          validation cannot see a type error, so 100% is not the target and
#          never will be at this layer -- the floor exists to notice a
#          REGRESSION in what is already caught.
#
# The oracle is wasm-tools, never this implementation. Mutants wasm-tools
# accepts are dropped rather than assumed invalid: truncating a module to its
# 8-byte header, for instance, produces a perfectly valid empty module.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CLI_WASM="${1:-${VIBE_VALIDATE_PARITY_CLI_WASM:-}}"
if [ -z "$CLI_WASM" ]; then
  CLI_WASM="$(ls -t "$ROOT_DIR"/_build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1 || true)"
fi
[ -n "$CLI_WASM" ] && [ -s "$CLI_WASM" ] || {
  echo "[validate-parity] FAIL: pass a stage2.wasm or build a selfhost generation" >&2
  exit 1
}
command -v wasm-tools >/dev/null 2>&1 || {
  echo "[validate-parity] SKIP: wasm-tools not on PATH (it is the oracle)" >&2
  exit 0
}

WORK="$ROOT_DIR/_build/validate_parity"
rm -rf "$WORK"; mkdir -p "$WORK/pos" "$WORK/neg"

# 1. Positive corpus: this compiler's own output, both backends. These are the
#    modules a false rejection would break, so they are the ones worth using.
FIXTURES=(
  fixtures/gc_direct_array_abi_test.vibe
  fixtures/gc_heap_churn_test.vibe
  fixtures/gc_native_struct_local_test.vibe
)
for f in "${FIXTURES[@]}"; do
  [ -f "$f" ] || continue
  b="$(basename "$f" .vibe)"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
    "$f" "_build/validate_parity/pos/$b.lin.wasm" __no_entry__ >/dev/null 2>&1 || true
  VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
    "$f" "_build/validate_parity/pos/$b.gc.wasm" __no_entry__ >/dev/null 2>&1 || true
done
for w in "$WORK"/pos/*.wasm; do
  [ -e "$w" ] || continue
  wasm-tools validate --features all "$w" >/dev/null 2>&1 || {
    echo "[validate-parity] FAIL: the oracle rejects our own output: $w" >&2
    exit 1
  }
done

# 2. Negative corpus: structural corruptions, then labelled BY THE ORACLE.
python3 - "$WORK" <<'PY'
import os, sys, glob
work = sys.argv[1]
for f in sorted(glob.glob(work + '/pos/*.wasm')):
    b = bytearray(open(f, 'rb').read())
    base = os.path.basename(f)[:-5]
    def emit(tag, data):
        open(f'{work}/neg/{base}.{tag}.wasm', 'wb').write(bytes(data))
    emit('trunc', b[:int(len(b) * 0.6)])
    m = bytearray(b); m[1] = 0x41; emit('magic', m)
    v = bytearray(b); v[4] = 0x09; emit('version', v)
    s = bytearray(b); s[9] = 0x7F; emit('sectsize', s)
    u = bytearray(b) + bytes([0x7A, 0x02, 0x00, 0x00]); emit('unknownsect', u)
PY
for w in "$WORK"/neg/*.wasm; do
  [ -e "$w" ] || continue
  if wasm-tools validate --features all "$w" >/dev/null 2>&1; then rm -f "$w"; fi
done

# 3. Our verdict, reached the way a caller would reach it.
probe="$WORK/probe.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
  scripts/wasm_validate/probe.vibex "_build/validate_parity/probe.wasm" main >/dev/null 2>&1
[ -s "$probe" ] || { echo "[validate-parity] FAIL: probe did not compile" >&2; exit 1; }

verdict() {
  cp "$1" "$ROOT_DIR/_build/val_target.wasm"
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke main "_build/validate_parity/probe.wasm" 2>&1 | head -1
}

false_rejections=0
pos_total=0
for w in "$WORK"/pos/*.wasm; do
  [ -e "$w" ] || continue
  pos_total=$((pos_total + 1))
  case "$(verdict "$w")" in
    ACCEPT*) ;;
    *) false_rejections=$((false_rejections + 1)); echo "[validate-parity] false rejection: $w" >&2 ;;
  esac
done
caught=0
neg_total=0
for w in "$WORK"/neg/*.wasm; do
  [ -e "$w" ] || continue
  neg_total=$((neg_total + 1))
  case "$(verdict "$w")" in REJECT*) caught=$((caught + 1)) ;; esac
done
rm -f "$ROOT_DIR/_build/val_target.wasm"

if [ "$pos_total" -eq 0 ] || [ "$neg_total" -eq 0 ]; then
  echo "[validate-parity] FAIL: empty corpus (pos=$pos_total neg=$neg_total)" >&2
  exit 1
fi
if [ "$false_rejections" -ne 0 ]; then
  echo "[validate-parity] FAIL: $false_rejections/$pos_total modules the oracle accepts were rejected" >&2
  exit 1
fi
if [ "$caught" -ne "$neg_total" ]; then
  echo "[validate-parity] FAIL: caught $caught/$neg_total structural corruptions (was $neg_total/$neg_total)" >&2
  exit 1
fi
echo "[validate-parity] ok: $pos_total/$pos_total accepted, $caught/$neg_total structural corruptions rejected"
echo "[validate-parity] note: type-level invalidity is NOT covered by this layer -- measured 0/14 on"
echo "[validate-parity]       bad-opcode and out-of-range-type-index mutants, which is expected until"
echo "[validate-parity]       the operand-stack layer exists (#1745 (5))."
