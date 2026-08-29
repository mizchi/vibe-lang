#!/usr/bin/env bash
set -uo pipefail

# WASM-GC selfbuild frontier report (#538).
#
# The end goal is compiling the WHOLE compiler (the flat module-source bundle)
# with the wasm-gc backend (VIBE_BACKEND=gc) to get a small distribution
# artifact (#59/#538; a concrete size target will be set after the first
# release). This script measures how far the gc lane gets today, in two parts:
#
#   1. FEATURE PROBES — small programs, one language feature each. Every probe
#      is compiled AND (when it compiles) run on wasmtime with gc flags, and
#      its result compared against the linear backend's. This is the live
#      reclassification of the old "P4 260/263" tally (which was measured on
#      the retired MoonBit-host gc backend and no longer maps to the selfhost
#      port).
#   2. BUNDLE FRONTIER — attempt the full flat-bundle gc compile and report
#      the first blocking diagnostic (the current frontier).
#
# Not a CI gate (the frontier is expected to move): run it manually or from
# `pkf run test-gc-selfbuild`. The gc gate that IS enforced is
# compiler_gate.sh step 40h (the supported-subset smoke fixture).
#
# Usage: bash scripts/test_gc_selfbuild.sh [stage2.wasm]
#   stage2.wasm defaults to the newest generation build.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

# The compiler is a deeply-recursive program, and node's DEFAULT stack is not
# enough to type-check the flat bundle -- on it BOTH lanes die with
# "expression too deeply nested (stack overflow while type-checking)" long
# before codegen runs. scripts/generations.sh (the real build) therefore uses
# --stack-size=131072, and this script must use the same one.
#
# Without it this script does not merely fail: it MISREPORTS THE FRONTIER,
# which is its entire job. It reports a host stack limit as if it were the gc
# lane's limit, and it does so PESSIMISTICALLY -- "not even type-checking
# works" reads as far-behind when the lane in fact reaches the self-compile
# fixpoint. Anyone acting on that goes hunting for problems that are already
# solved (#1262: it happened).
: "${VIBE_NODE_WASM_FLAGS:=--experimental-wasm-exnref --stack-size=${VIBE_GC_SELFBUILD_NODE_STACK_SIZE:-131072}}"
export VIBE_NODE_WASM_FLAGS

CLI_WASM="${1:-${VIBE_GC_SELFBUILD_CLI_WASM:-}}"
if [ -z "$CLI_WASM" ]; then
  CLI_WASM="$(ls -t "$ROOT_DIR"/_build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1 || true)"
fi
if [ -z "$CLI_WASM" ] || [ ! -s "$CLI_WASM" ]; then
  echo "[gc-selfbuild] SKIP: no selfhost compiler wasm (run scripts/generations.sh build, or pass one)"
  exit 0
fi
echo "[gc-selfbuild] compiler: $CLI_WASM"

OUT_DIR="$ROOT_DIR/_build/gc_selfbuild"
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR/probes"

WASMTIME_BIN="$(bash scripts/wasmtime_bin.sh 2>/dev/null || command -v wasmtime || true)"

# --- 1. feature probes -------------------------------------------------------

write_probe() { # name, source (stdin)
  cat >"$OUT_DIR/probes/$1.vibe"
}

write_probe enum_ctor_match <<'EOF'
enum Shape {
  Dot;
  Circle(Int);
  Rect(Int, Int)
}
let area: (Shape) -> Int = (s) -> {
  match s {
    Dot => 1,
    Circle(r) => 3 * r * r,
    Rect(w, h) => w * h
  }
}
export let main = () -> Int { area(Dot) + area(Circle(3)) + area(Rect(4, 5)) }
EOF

write_probe option_builtin <<'EOF'
let unwrap_or: (Option[Int], Int) -> Int = (o, d) -> {
  match o {
    Some(v) => v,
    None => d
  }
}
export let main = () -> Int { unwrap_or(Some(40), 0) + unwrap_or(None, 2) }
EOF

write_probe nested_ctor_pattern <<'EOF'
enum Tree {
  Leaf(Int);
  Node(Tree, Tree)
}
let rec sum: (Tree) -> Int = (t) -> {
  match t {
    Leaf(v) => v,
    Node(Leaf(a), r) => a + sum(r),
    Node(l, r) => sum(l) + sum(r)
  }
}
export let main = () -> Int { sum(Node(Leaf(1), Node(Leaf(2), Leaf(3)))) }
EOF

write_probe mut_capture_closure <<'EOF'
export let main = () -> Int {
  let mut acc = 0
  let add = (n: Int) -> Unit {
    acc = acc + n
  }
  add(5)
  add(7)
  acc
}
EOF

write_probe struct_literal_field <<'EOF'
struct Point {
  x: Int;
  y: Int
}
let mk: (Int, Int) -> Point = (a, b) -> {
  Point::{ x: a, y: b }
}
export let main = () -> Int {
  let p = mk(11, 31)
  p.x + p.y
}
EOF

write_probe string_ops_builtin <<'EOF'
export let main = () -> Int {
  let s = "hello,world"
  if String::contains(s, "world") {
    String::index_of(s, ",")
  } else {
    0 - 1
  }
}
EOF

write_probe string_builder <<'EOF'
export let main = () -> Int {
  let sb = StringBuilder::new()
  StringBuilder::push(sb, "ab")
  StringBuilder::push(sb, "cde")
  String::length(StringBuilder::freeze(sb))
}
EOF

write_probe map_builtin <<'EOF'
export let main = () -> Int {
  let mb = MapBuilder::new()
  MapBuilder::set(mb, "a", 40)
  MapBuilder::set(mb, "b", 2)
  let m = MapBuilder::freeze(mb)
  Map::get(m, "a") + Map::get(m, "b")
}
EOF

write_probe effect_throw_handle <<'EOF'
let risky: (Int) -> Int with Exception = (x) -> {
  if x == 0 {
    throw("zero")
  }
  100 / x
}
export let main = () -> Int {
  handle {
    risky(0)
  } with Exception {
    Throw(_) => 42
  }
}
EOF

write_probe bytes_ops <<'EOF'
export let main = () -> Int {
  let b = Bytes::from_array([
    1,
    2,
    3
  ])
  Bytes::get(b, 0) + Bytes::get(b, 2) + Bytes::length(b)
}
EOF

pass=0; fail=0; declare -a failures=()
for probe in "$OUT_DIR"/probes/*.vibe; do
  name="$(basename "$probe" .vibe)"
  gc_wasm="$OUT_DIR/probes/$name.gc.wasm"
  lin_wasm="$OUT_DIR/probes/$name.lin.wasm"
  rm -f "$gc_wasm" "$gc_wasm.diag" "$lin_wasm" "$lin_wasm.diag"
  env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
    "${probe#"$ROOT_DIR"/}" "${gc_wasm#"$ROOT_DIR"/}" main >/dev/null 2>&1 || true
  if [ ! -s "$gc_wasm" ]; then
    fail=$((fail+1)); failures+=("$name: COMPILE: $(cat "$gc_wasm.diag" 2>/dev/null || echo '(no diag)')")
    continue
  fi
  if [ -z "$WASMTIME_BIN" ]; then
    pass=$((pass+1)); echo "[gc-selfbuild] probe $name: compiled (no wasmtime; run skipped)"
    continue
  fi
  gc_out="$("$WASMTIME_BIN" run -W gc=y,function-references=y,exceptions=y "$gc_wasm" 2>/dev/null | tail -1)"
  env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
    "${probe#"$ROOT_DIR"/}" "${lin_wasm#"$ROOT_DIR"/}" main >/dev/null 2>&1
  lin_out="$(env VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$lin_wasm" 2>/dev/null | tail -1)"
  if [ -n "$gc_out" ] && [ "$gc_out" = "$lin_out" ]; then
    pass=$((pass+1)); echo "[gc-selfbuild] probe $name: OK ($gc_out)"
  else
    fail=$((fail+1)); failures+=("$name: RUN: gc='$gc_out' linear='$lin_out'")
  fi
done

echo
echo "[gc-selfbuild] probes: $pass pass, $fail fail"
for f in "${failures[@]:-}"; do
  [ -n "$f" ] && echo "[gc-selfbuild]   FAIL $f"
done

# --- 2. bundle frontier ------------------------------------------------------

echo
echo "[gc-selfbuild] full-bundle gc compile (the selfbuild end goal):"
BUNDLE_SRC="lib/@vibe/compiler/_cli_adapter_module_source.vibe"
BUNDLE_OUT="$OUT_DIR/bundle_gc.wasm"
rm -f "$BUNDLE_OUT" "$BUNDLE_OUT.diag"
env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  VIBE_INTERNAL_TRUSTED_SOURCE=1 bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
  "$BUNDLE_SRC" "${BUNDLE_OUT#"$ROOT_DIR"/}" cli_main >/dev/null 2>&1
if [ -s "$BUNDLE_OUT" ]; then
  if command -v wasm-tools >/dev/null 2>&1; then
    if wasm-tools validate --features all "$BUNDLE_OUT" >/dev/null 2>&1; then
      echo "[gc-selfbuild] BUNDLE COMPILED + VALID: $(wc -c <"$BUNDLE_OUT") bytes (linear stage2 ~2.57MB; P4 compile E2E done)"
    else
      echo "[gc-selfbuild] BUNDLE EMITTED BUT INVALID: $(wasm-tools validate --features all "$BUNDLE_OUT" 2>&1 | head -2 | tail -1)"
    fi
  else
    echo "[gc-selfbuild] BUNDLE COMPILED: $(wc -c <"$BUNDLE_OUT") bytes (wasm-tools unavailable; validity unchecked)"
  fi
else
  echo "[gc-selfbuild] frontier: $(cat "$BUNDLE_OUT.diag" 2>/dev/null || echo '(no diag)')"
fi

# --- 3. run E2E (P4.5) --------------------------------------------------------
# Run the gc-compiled compiler itself (its _start reads argv via the "vibe"
# host imports) on a small program and require its output wasm to be
# byte-identical to what the SAME source compiler (linear lane, same VIBE_RC=0
# flags) produces. This is the P4.5 milestone: the gc-lane artifact is a
# working compiler, not just a valid module.
if [ -s "$BUNDLE_OUT" ]; then
  echo
  echo "[gc-selfbuild] run E2E (gc-compiled compiler compiles a program):"
  RUN_SRC="$OUT_DIR/run_e2e.vibe"
  printf 'export let main = () -> Int { 40 + 2 }\n' >"$RUN_SRC"
  RUN_OUT="$OUT_DIR/run_e2e.out.wasm"
  RUN_REF="$OUT_DIR/run_e2e.ref.wasm"
  rm -f "$RUN_OUT" "$RUN_OUT.diag" "$RUN_REF" "$RUN_REF.diag"
  env VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$BUNDLE_OUT" \
    "${RUN_SRC#"$ROOT_DIR"/}" "${RUN_OUT#"$ROOT_DIR"/}" main >/dev/null 2>&1
  env VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
    "${RUN_SRC#"$ROOT_DIR"/}" "${RUN_REF#"$ROOT_DIR"/}" main >/dev/null 2>&1
  if [ -s "$RUN_OUT" ] && cmp -s "$RUN_OUT" "$RUN_REF"; then
    echo "[gc-selfbuild] RUN E2E OK: gc-compiled compiler output is byte-identical to the linear compiler's (P4.5 done)"
  else
    echo "[gc-selfbuild] RUN E2E frontier: $(cat "$RUN_OUT.diag" 2>/dev/null || echo 'no output or mismatch vs linear reference')"
  fi
fi

# --- 4. self-compile fixpoint -------------------------------------------------
# The full circle: the gc-compiled compiler compiles the WHOLE compiler bundle
# (linear backend, VIBE_RC=0) and must reproduce byte-for-byte what the linear
# compiler produces from the same source. Compare against a reference built by
# CLI_WASM with the same flags.
if [ -s "$BUNDLE_OUT" ]; then
  echo
  echo "[gc-selfbuild] self-compile fixpoint (gc-compiled compiler compiles the compiler):"
  SELF_OUT="$OUT_DIR/selfcompile.wasm"
  SELF_REF="$OUT_DIR/selfcompile.ref.wasm"
  rm -f "$SELF_OUT" "$SELF_OUT.diag" "$SELF_REF" "$SELF_REF.diag"
  env VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$BUNDLE_OUT" \
    "$BUNDLE_SRC" "${SELF_OUT#"$ROOT_DIR"/}" cli_main >/dev/null 2>&1
  env VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
    "$BUNDLE_SRC" "${SELF_REF#"$ROOT_DIR"/}" cli_main >/dev/null 2>&1
  if [ -s "$SELF_OUT" ] && cmp -s "$SELF_OUT" "$SELF_REF"; then
    echo "[gc-selfbuild] SELF-COMPILE FIXPOINT OK: byte-identical to the linear compiler's output ($(wc -c <"$SELF_OUT") bytes)"
    echo "[gc-selfbuild] remaining: P5 size reduction (DCE + wasm-opt; target set after first release)"
  else
    echo "[gc-selfbuild] self-compile frontier: $(cat "$SELF_OUT.diag" 2>/dev/null || echo 'no output or mismatch vs linear reference')"
  fi
fi

# --- 5. gc runtime test fixtures (#683) ---------------------------------------
# Compile *_test.vibe fixtures on the wasm-gc backend (test-block lowering in
# compile_source_gc_only) and run them under wasmtime — the runtime
# verification harness #683 asked for. Structural ==/!= coverage lives in
# fixtures/eq_structural_aggregates_test.vibe.
echo
echo "[gc-selfbuild] gc runtime test fixtures (#683):"
gcfx_log="$OUT_DIR/gc_fixtures.log"
if VIBE_TEST_CLI_WASM="$CLI_WASM" VIBE_TEST_BACKEND=gc \
    bash "$ROOT_DIR/scripts/vibe_test.sh" \
    fixtures/eq_structural_aggregates_test.vibe \
    fixtures/map_builder_growth_test.vibe \
    fixtures/struct_field_collision_test.vibe \
    fixtures/float_return_to_string_gc_test.vibe \
    fixtures/float_call_offset_gc_lane.vibe \
    fixtures/float_return_review_gc.vibe \
    fixtures/int_bit_primitives_test.vibe \
    fixtures/bytes_alloc_backend_parity_test.vibe \
    fixtures/gc_handle_aggregate_test.vibe \
    fixtures/trait_namespace_operation_test.vibe \
    fixtures/trait_namespace_import_test.vibe \
    fixtures/trait_namespace_inherited_import_test.vibe \
    fixtures/gc_import_resolution_test.vibe \
    fixtures/gc_import_builtin_shadow_test.vibe \
    fixtures/constructor_indexed_map_gc_test.vibe \
    fixtures/constructor_indexed_async_iter_gc_test.vibe \
    fixtures/bytes_index_of_bytes_test.vibe \
    fixtures/bytes_index_of_byte_test.vibe \
    fixtures/bytes_count_last_index_of_test.vibe \
    fixtures/bytes_compare_test.vibe \
    fixtures/string_split_empty_separator_test.vibe \
    fixtures/iterator_map_direct_key_gc_test.vibe > "$gcfx_log" 2>&1; then
  sed 's/^/[gc-selfbuild]   /' "$gcfx_log"
  echo "[gc-selfbuild] gc runtime fixtures ok"
else
  sed 's/^/[gc-selfbuild]   /' "$gcfx_log"
  echo "[gc-selfbuild] gc runtime fixtures FAILED"
  fail=$((fail+1))
fi

if bash "$ROOT_DIR/scripts/test_gc_direct_import_diag.sh" "$CLI_WASM"; then
  echo "[gc-selfbuild] direct single-file import diagnostic ok"
else
  echo "[gc-selfbuild] direct single-file import diagnostic FAILED"
  fail=$((fail+1))
fi

echo
echo "[gc-selfbuild] done ($pass/$((pass+fail)) probes)"
# Informational tool: report, don't gate.
exit 0
