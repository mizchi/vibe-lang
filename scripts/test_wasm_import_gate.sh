#!/usr/bin/env bash
# Typed wasm imports (`import ./x.wasm { .. }`): the binding the compiler
# synthesizes from a core module or a component, linked and run.
#
#   bash scripts/test_wasm_import_gate.sh <stage2.wasm>
#
# The compiler is an argument because the committed seed predates the
# feature; the early compiler gate passes this checkout's stage2.
#
# What is asserted, per runner (viberun and the node runner):
#   1. fixtures/wasm_import/counter_main.vibex prints `count=42` -- i32 and
#      i64 values cross both ways and a void export mutates foreign state --
#      and its artifact imports only the three functions it calls;
#   2. an i32 is offered as `UInt32` (#3730), so an argument that fits no
#      32-bit reading is refused at compile time, naming the range
#      (err_core_i32_range.vibe; asserted once, below step 5);
#   3. an i64 result that needs the 64th bit TRAPS (trap_i64_result.vibex);
#  12. the memory accessors work over an exported SHARED memory
#      (shared_memory_main.vibex; wasmtime hands it over as a different
#      object, `SharedMemory`);
#  13. a reactor's `_initialize: () -> ()` runs before the first call, and an
#      export merely NAMED `_initialize` with another signature is not
#      called at link time (init_main.vibex).
# And once:
#   4. the fixture binaries are built from their committed text (when
#      wat2wasm and wasm-tools exist);
#   5. importing an export whose signature has no binding is refused by
#      `vibe check` (err_not_offered.vibe);
#   6.-8. a wasm COMPONENT import (greeter.component.wasm): runs on viberun
#      with strings and Ints, an Int outside its WIT width is refused, and the
#      node runner, which cannot instantiate components, refuses it;
#   9. `vibe run` from a package's subdirectory links the binary it compiled
#      against (the compile runs in the project root, the program does not);
#  10. `vibe bench` links the foreign module into each block's fresh store;
#  11. a component whose WIT signature changed after the build is refused at
#      link time rather than converted by its new types;
#  14. a component's WIT `u8` / `s16` are offered as `UInt32` / `Int32`
#      (#3826): an in-range call answers exactly (narrow_import_test.vibe,
#      whose `inspect` rows `vibe test` checks on viberun), and an
#      argument outside the narrow range is refused at the call, naming the
#      range, rather than truncated (trap_component_u8_range.vibex).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CLI="${1:-}"
[ -n "$CLI" ] && [ -s "$CLI" ] || { echo "usage: test_wasm_import_gate.sh <stage2.wasm>" >&2; exit 2; }
# Later probes change directory. Resolve the selected compiler once, while
# relative arguments still refer to the repository root.
case "$CLI" in /*) ;; *) CLI="$ROOT_DIR/$CLI" ;; esac
# The fixture directory, relative to the repository root (the imports record
# paths as the compiler resolves them, so it must be inside the tree). Only
# scripts/test_wasm_import_gate_test.sh overrides it, with a mutated copy.
FX="${WASM_IMPORT_GATE_FIXTURES:-fixtures/wasm_import}"
case "$FX" in
  /*|*..*) echo "test_wasm_import_gate.sh: WASM_IMPORT_GATE_FIXTURES must be a path inside the tree, got $FX" >&2; exit 2 ;;
esac

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

# The allocator lane is set per call, never inherited: the RC lane tags an
# Int (`n << 1`) and the bump lane does not, so the binding's conversions
# differ between them, and a gate that ran whichever lane its caller had
# exported checked one of them at random (tests/gates/lib.sh exports
# VIBE_RC=0; a shell usually has none).
LANE_RC="${LANE_RC:-1}"
vibe() { # <runner> <vibe args...>
  local runner="$1"; shift
  # RUST_BACKTRACE / VIBE_RUNNER_BACKTRACE change how viberun prints a trap,
  # and a dev shell often sets one: unset, so the refusal messages asserted
  # below are the ones CI sees (#2252).
  env -u RUST_BACKTRACE -u VIBE_RUNNER_BACKTRACE \
    VIBE_RC="$LANE_RC" VIBE_RUNNER="$runner" VIBE_CLI_WASM="$CLI" VIBE_PREOPEN_DIR="$ROOT_DIR" \
    VIBE_BUILD_DIR="$WORK/build" "$ROOT_DIR/runtime/vibe" "$@"
}

# 4. The committed binaries are the committed text.
if [ "$FX" != fixtures/wasm_import ]; then
  echo "[wasm-import] note: fixtures overridden ($FX); the committed binaries are checked on the default run"
elif command -v wat2wasm >/dev/null 2>&1 && command -v wasm-tools >/dev/null 2>&1; then
  bash "$ROOT_DIR/scripts/build_wasm_import_fixtures.sh" --check || fail "fixture binaries are stale"
else
  echo "[wasm-import] note: wat2wasm / wasm-tools not installed; not rebuilding the fixture binaries"
fi

# The foreign functions an artifact imports from <module>, sorted, one line.
foreign_imports() { # <artifact.wasm> <module>
  node -e '
    const m = new WebAssembly.Module(require("node:fs").readFileSync(process.argv[1]));
    const names = WebAssembly.Module.imports(m).filter((i) => i.module === process.argv[2]).map((i) => i.name).sort();
    console.log(names.join(" "));
  ' "$1" "$2"
}

for lane_and_runner in "1 $VIBERUN" "0 $VIBERUN" "1 $NODE_RUNNER" "0 $NODE_RUNNER"; do
  LANE_RC="${lane_and_runner%% *}"
  runner="${lane_and_runner#* }"
  label="$(basename "$runner") VIBE_RC=$LANE_RC"
  # 1.
  status=0
  out="$(vibe "$runner" run "$FX/counter_main.vibex" 2>"$WORK/err")" || status=$?
  [ "$status" = 0 ] || { cat "$WORK/err" >&2; fail "[$label] counter_main exited $status"; }
  [ "$out" = "count=42" ] || fail "[$label] counter_main printed $(printf '%q' "$out"), want count=42"
  # Tree-shaken: the artifact imports the three functions it calls, not
  # every export the binding offers (the late DCE knows the release
  # artifact's exports are stripped).
  got="$(foreign_imports "$WORK/build/run/counter_main.wasm" "vibe:wasm:$FX/counter.wasm")"
  [ "$got" = "Add_I32 bump count" ] || fail "[$label] counter_main imports '$got' from counter.wasm, want 'Add_I32 bump count'"
  # 3.
  for t in trap_i64_result; do
    status=0
    out="$(vibe "$runner" run "$FX/$t.vibex" 2>"$WORK/err")" || status=$?
    [ "$status" != 0 ] || fail "[$label] $t exited 0 (printed $(printf '%q' "$out")); the binding must trap"
    [ "$out" = "before" ] || fail "[$label] $t printed $(printf '%q' "$out"); want only 'before' (the call must not answer)"
    grep -q 'wasm_raw_' "$WORK/err" || { cat "$WORK/err" >&2; fail "[$label] $t did not trap inside the binding"; }
  done
  # 12.
  status=0
  out="$(vibe "$runner" run "$FX/shared_memory_main.vibex" 2>"$WORK/err")" || status=$?
  [ "$status" = 0 ] || { cat "$WORK/err" >&2; fail "[$label] shared_memory_main exited $status"; }
  [ "$out" = "load=42 peek=7 size=65536" ] || fail "[$label] shared_memory_main printed $(printf '%q' "$out"), want load=42 peek=7 size=65536"
  # 13.
  status=0
  out="$(vibe "$runner" run "$FX/init_main.vibex" 2>"$WORK/err")" || status=$?
  [ "$status" = 0 ] || { cat "$WORK/err" >&2; fail "[$label] init_main exited $status"; }
  [ "$out" = "value=7 foo=42 init=2" ] || fail "[$label] init_main printed $(printf '%q' "$out"), want value=7 foo=42 init=2"
done

# 2. An i32 is a `UInt32`: an argument outside it is a compile-time error.
status=0
vibe "$NODE_RUNNER" check "$FX/err_core_i32_range.vibe" >"$WORK/out" 2>&1 || status=$?
[ "$status" != 0 ] || fail "an i32 argument outside UInt32 was accepted"
grep -q 'integer literal 4294967296 does not fit `UInt32` (0 .. 4294967295)' "$WORK/out" || { cat "$WORK/out" >&2; fail "the i32 refusal does not name the UInt32 range"; }

# 5. Refusals are compile-time and name the import.
status=0
vibe "$NODE_RUNNER" check "$FX/err_not_offered.vibe" >"$WORK/out" 2>&1 || status=$?
[ "$status" != 0 ] || fail "importing an export with no binding (half: f64) was accepted"
grep -q "'half' is not exported by './counter.wasm'" "$WORK/out" || { cat "$WORK/out" >&2; fail "refusal does not name 'half'"; }

# 6. A COMPONENT import (greeter.component.wasm, typed by greeter.wit) runs on
#    viberun, on both lanes: a string crosses both ways, Ints cross and state
#    persists.
want="$(printf 'hi, vibe\nadd=42\ncounter=2')"
for LANE_RC in 1 0; do
  status=0
  out="$(vibe "$VIBERUN" run "$FX/greeter_main.vibex" 2>"$WORK/err")" || status=$?
  [ "$status" = 0 ] || { cat "$WORK/err" >&2; fail "[viberun VIBE_RC=$LANE_RC] greeter_main exited $status"; }
  [ "$out" = "$want" ] || fail "[viberun VIBE_RC=$LANE_RC] greeter_main printed $(printf '%q' "$out"), want $(printf '%q' "$want")"
done
LANE_RC=1
# 7. A WIT `s32` is offered as `Int32` (#3730), so a value outside its
#    width is refused at compile time, naming the range, instead of reaching
#    the runner's lowering.
status=0
vibe "$NODE_RUNNER" check "$FX/err_component_s32_range.vibe" >"$WORK/out" 2>&1 || status=$?
[ "$status" != 0 ] || fail "an s32 argument outside Int32 was accepted"
grep -q 'integer literal 2147483648 does not fit `Int32` (-2147483648 .. 2147483647)' "$WORK/out" || { cat "$WORK/out" >&2; fail "the s32 refusal does not name the Int32 range"; }
# 8. The node runner cannot instantiate a component, and says so instead of
#    answering every call with its fallback stub.
status=0
out="$(vibe "$NODE_RUNNER" run "$FX/greeter_main.vibex" 2>"$WORK/err")" || status=$?
[ "$status" != 0 ] || fail "[node] a component import ran on the node runner (printed $(printf '%q' "$out"))"
grep -q "importing a wasm component runs on viberun" "$WORK/err" || { cat "$WORK/err" >&2; fail "[node] the component refusal does not say why"; }

# 9. Paths are rooted where the compile ran. A program under a package's
#    subdirectory is compiled in the PROJECT root but runs in the directory it
#    was invoked from; the import still links the binary it was typed against.
PROJ="$WORK/proj"
mkdir -p "$PROJ/sub"
printf 'name = @scratch/wasm-import-gate\nversion = 0.0.1\ndeps = {}\n' > "$PROJ/index.vpkg"
cp "$FX/counter.wasm" "$PROJ/sub/counter.wasm"
cat > "$PROJ/sub/main.vibex" <<'EOF2'
import ./counter.wasm {
  add_i32
}

fn main() -> Unit allows Console {
  println("r=\{add_i32(40, 2)}")
}
EOF2
status=0
out="$(cd "$PROJ/sub" && env -u VIBE_WASM_LINK_DIR VIBE_RC=1 VIBE_RUNNER="$VIBERUN" VIBE_CLI_WASM="$CLI" \
  "$ROOT_DIR/runtime/vibe" run main.vibex 2>"$WORK/err")" || status=$?
[ "$status" = 0 ] || { cat "$WORK/err" >&2; fail "[subdirectory] run exited $status"; }
[ "$out" = "r=42" ] || fail "[subdirectory] printed $(printf '%q' "$out"), want r=42"

# 10. `vibe bench` gives each block a fresh instance; the foreign module has
#     to be linked into that store too, or the artifact cannot instantiate.
status=0
vibe "$VIBERUN" bench "$FX/counter_bench.vibe" >"$WORK/out" 2>"$WORK/err" || status=$?
[ "$status" = 0 ] || { cat "$WORK/err" >&2; fail "[viberun] counter_bench exited $status"; }
grep -q "^bench counter_bench.vibe::foreign add_i32: " "$WORK/out" "$WORK/err" || { cat "$WORK/out" "$WORK/err" >&2; fail "[viberun] counter_bench reported no measurement"; }

# 11. A component rebuilt after the program with a different WIT signature
#     is refused at link time, not converted by its new types: build against
#     greeter.component.wasm, then link against greeter_drift.component.wasm
#     (`counter` retyped u64 -> s64) at the same path.
vibe "$VIBERUN" build "$FX/greeter_main.vibex" -o "$WORK/greeter_main.wasm" >"$WORK/out" 2>&1 || { cat "$WORK/out" >&2; fail "[viberun] could not build greeter_main"; }
DRIFT="$WORK/drift"
mkdir -p "$DRIFT/$FX"
cp "$FX/greeter_drift.component.wasm" "$DRIFT/$FX/greeter.component.wasm"
status=0
(cd "$DRIFT" && env -u RUST_BACKTRACE -u VIBE_RUNNER_BACKTRACE VIBE_WASM_LINK_DIR="$DRIFT" \
  "$VIBERUN" "$WORK/greeter_main.wasm") >"$WORK/out" 2>"$WORK/err" || status=$?
[ "$status" != 0 ] || fail "[viberun] a component whose WIT signature drifted was linked (printed $(printf '%q' "$(cat "$WORK/out")"))"
grep -q "'counter' is now (->s64) but the program was compiled against (->u64); rebuild the program" "$WORK/err" \
  || { cat "$WORK/err" >&2; fail "[viberun] the signature-drift refusal does not say why"; }

# 14. Narrow WIT widths (#3826): offered as `UInt32` / `Int32`, exact in
#     range on both lanes, and an argument outside the narrow range refused at
#     the call by the runner, which names the range.
# The expectations are the test file's own `inspect` rows; the unit runner
# runs on node, which cannot instantiate a component, so it is run here.
# `vibe test` records a pass under $VIBE_HOME/cache/test, which defaults to
# the checkout when the launcher is run from it: point it at the scratch
# directory, so the gate leaves the tree as it found it (#2899) and a cached
# pass from an earlier run can never stand in for this one.
for LANE_RC in 1 0; do
  status=0
  VIBE_HOME="$WORK/home" vibe "$VIBERUN" test "$FX/narrow_import_test.vibe" >"$WORK/out" 2>&1 || status=$?
  [ "$status" = 0 ] || { cat "$WORK/out" >&2; fail "[viberun VIBE_RC=$LANE_RC] narrow_import_test failed"; }
done
LANE_RC=1
status=0
out="$(vibe "$VIBERUN" run "$FX/trap_component_u8_range.vibex" 2>"$WORK/err")" || status=$?
[ "$status" != 0 ] || fail "[viberun] a u8 argument outside 0 .. 255 was accepted (printed $(printf '%q' "$out"))"
grep -q '300 does not fit the component.s `u8` parameter (0 .. 255)' "$WORK/err" || { cat "$WORK/err" >&2; fail "[viberun] the u8 refusal does not name the range"; }

echo "[wasm-import] ok (core: viberun + node, range traps, shared memory, _initialize, refusals; component: viberun, WIT range refusal, narrow widths, node refusal)"
