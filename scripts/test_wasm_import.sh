#!/usr/bin/env bash
# Typed core-wasm imports (`import ./x.wasm { .. }`): the binding the compiler
# synthesizes from the binary, linked and run on BOTH runners.
#
#   bash scripts/test_wasm_import.sh <stage2.wasm>
#
# The compiler is an argument because the committed seed predates the
# feature; the early compiler gate passes this checkout's stage2.
#
# What is asserted, per runner (viberun and the node runner):
#   1. fixtures/wasm_import/counter_main.vibex prints `count=42` -- i32 and
#      i64 values cross both ways and a void export mutates foreign state.
#   2. an Int that fits no reading of 32 bits, passed as an i32, TRAPS
#      (trap_i32_param.vibex) -- it must not reach the foreign function as a
#      truncated value, so `r=` is never printed;
#   3. an i64 result that needs the 64th bit TRAPS (trap_i64_result.vibex).
# And once:
#   4. counter.wasm is the assembly of counter.wat (when wat2wasm exists);
#   5. importing an export whose signature has no binding is refused by
#      `vibe check` (err_not_offered.vibe), and so is a component binary.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CLI="${1:-}"
[ -n "$CLI" ] && [ -s "$CLI" ] || { echo "usage: test_wasm_import.sh <stage2.wasm>" >&2; exit 2; }
FX=fixtures/wasm_import

WORK="$ROOT_DIR/_build/test_wasm_import"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "[wasm-import] FAIL $*" >&2; exit 1; }

VIBERUN="${VIBE_WASM_IMPORT_VIBERUN:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
if [ "$VIBERUN" = "$ROOT_DIR/runtime/viberun/target/release/viberun" ]; then
  bash "$ROOT_DIR/scripts/ensure_viberun.sh" >/dev/null 2>&1 || fail "could not build runtime/viberun"
fi
[ -x "$VIBERUN" ] || fail "viberun not available: $VIBERUN"
NODE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh"

vibe() { # <runner> <vibe args...>
  local runner="$1"; shift
  VIBE_RUNNER="$runner" VIBE_CLI_WASM="$CLI" VIBE_PREOPEN_DIR="$ROOT_DIR" \
    VIBE_BUILD_DIR="$WORK/build" "$ROOT_DIR/runtime/vibe" "$@"
}

# 4. The committed binary is the committed text.
if command -v wat2wasm >/dev/null 2>&1; then
  wat2wasm "$FX/counter.wat" -o "$WORK/counter.wasm"
  cmp -s "$WORK/counter.wasm" "$FX/counter.wasm" || fail "$FX/counter.wasm is stale: rebuild it with wat2wasm $FX/counter.wat -o $FX/counter.wasm"
else
  echo "[wasm-import] note: wat2wasm not installed; not re-assembling $FX/counter.wat"
fi

for runner in "$VIBERUN" "$NODE_RUNNER"; do
  label="$(basename "$runner")"
  # 1.
  status=0
  out="$(vibe "$runner" run "$FX/counter_main.vibex" 2>"$WORK/err")" || status=$?
  [ "$status" = 0 ] || { cat "$WORK/err" >&2; fail "[$label] counter_main exited $status"; }
  [ "$out" = "count=42" ] || fail "[$label] counter_main printed $(printf '%q' "$out"), want count=42"
  # 2. and 3.
  for t in trap_i32_param trap_i64_result; do
    status=0
    out="$(vibe "$runner" run "$FX/$t.vibex" 2>"$WORK/err")" || status=$?
    [ "$status" != 0 ] || fail "[$label] $t exited 0 (printed $(printf '%q' "$out")); the binding must trap"
    [ "$out" = "before" ] || fail "[$label] $t printed $(printf '%q' "$out"); want only 'before' (the call must not answer)"
    grep -q 'wasm_raw_' "$WORK/err" || { cat "$WORK/err" >&2; fail "[$label] $t did not trap inside the binding"; }
  done
done

# 5. Refusals are compile-time and name the import.
status=0
vibe "$NODE_RUNNER" check "$FX/err_not_offered.vibe" >"$WORK/out" 2>&1 || status=$?
[ "$status" != 0 ] || fail "importing an export with no binding (half: f64) was accepted"
grep -q "'half' is not exported by './counter.wasm'" "$WORK/out" || { cat "$WORK/out" >&2; fail "refusal does not name 'half'"; }

printf '\0asm\r\0\1\0' > "$WORK/comp.wasm"
cat > "$WORK/use_comp.vibe" <<'EOF'
import ./comp.wasm {
  f
}

let x: Int = 1
EOF
status=0
vibe "$NODE_RUNNER" check "$WORK/use_comp.vibe" >"$WORK/out" 2>&1 || status=$?
[ "$status" != 0 ] || fail "a component binary was accepted as a core-wasm import"
grep -q "is a wasm COMPONENT" "$WORK/out" || { cat "$WORK/out" >&2; fail "component refusal does not say why"; }

echo "[wasm-import] ok (viberun + node: run, i32/i64 range traps; check: refusals)"
