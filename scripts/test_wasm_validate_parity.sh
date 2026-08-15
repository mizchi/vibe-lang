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

    # Harder class: corruption that leaves the section framing intact, so only
    # a walk INSIDE a section can see it. Kept in the same corpus rather than a
    # separate one -- a floor that silently excluded the hard cases would read
    # as full parity.
    def sections(buf):
        p = 8
        while p < len(buf):
            sid = buf[p]; p += 1
            n = 0; sh = 0
            while True:
                x = buf[p]; p += 1; n |= (x & 0x7f) << sh; sh += 7
                if not x & 0x80: break
            yield sid, p, p + n
            p += n
    for sid, st, en in sections(b):
        if sid == 10:
            m = bytearray(b); m[st + (en - st) // 2] = 0x06
            emit('badopcode', m)
        if sid == 3:
            m = bytearray(b); m[st + 1] = 0x7E
            emit('badtypeidx', m)
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

# 4. Coverage, which the catch ratio does NOT measure. A stepper that bails on
#    the first opcode it does not know still catches mutants -- the corruption
#    is usually before the bail -- while reading almost nothing. Requiring the
#    walk to reach the end of every body in our own output is the check that
#    actually noticed 0xFD, and a one-byte valtype assumption that started three
#    bodies inside their own local declarations.
walk="$WORK/walk.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
  scripts/wasm_validate/walk_probe.vibex "_build/validate_parity/walk.wasm" main >/dev/null 2>&1
[ -s "$walk" ] || { echo "[validate-parity] FAIL: walk probe did not compile" >&2; exit 1; }
walk_bodies=0
walk_stopped=0
for w in "$WORK"/pos/*.wasm; do
  [ -e "$w" ] || continue
  cp "$w" "$ROOT_DIR/_build/val_target.wasm"
  read -r b s <<<"$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke main "_build/validate_parity/walk.wasm" 2>/dev/null | head -1)"
  walk_bodies=$((walk_bodies + ${b:-0}))
  walk_stopped=$((walk_stopped + ${s:-0}))
done
rm -f "$ROOT_DIR/_build/val_target.wasm"
if [ "$walk_bodies" -eq 0 ]; then
  echo "[validate-parity] FAIL: walk probe reported no function bodies" >&2
  exit 1
fi
if [ "$walk_stopped" -ne 0 ]; then
  echo "[validate-parity] FAIL: the stepper gave up inside $walk_stopped/$walk_bodies of our own" >&2
  echo "[validate-parity]       function bodies, so validation does not reach past that point" >&2
  exit 1
fi

if [ "$pos_total" -eq 0 ] || [ "$neg_total" -eq 0 ]; then
  echo "[validate-parity] FAIL: empty corpus (pos=$pos_total neg=$neg_total)" >&2
  exit 1
fi
if [ "$false_rejections" -ne 0 ]; then
  echo "[validate-parity] FAIL: $false_rejections/$pos_total modules the oracle accepts were rejected" >&2
  exit 1
fi
# The floor is a RATIO, not a total: the corpus size moves with the fixtures.
# It exists to catch a regression in what is already caught, not to assert
# parity -- reaching it is not the same as validating.
floor_num=$((neg_total * 90 / 100))
if [ "$caught" -lt "$floor_num" ]; then
  echo "[validate-parity] FAIL: caught $caught/$neg_total, below the $floor_num floor" >&2
  exit 1
fi
echo "[validate-parity] ok: $pos_total/$pos_total accepted (zero false rejections), $caught/$neg_total rejected"
echo "[validate-parity]     instruction walk reached the end of $walk_bodies/$walk_bodies function bodies"
echo "[validate-parity] note: what remains uncaught needs operand-stack typing, which this layer does"
echo "[validate-parity]       not do (#1745 (5)). A module that is well-formed but ill-TYPED still"
echo "[validate-parity]       passes here."
