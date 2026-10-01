#!/usr/bin/env bash
# Sourced by this lane's run.sh; shares its resolved compiler and gate state.

# ADR-0068 (#2248): `@vibe/concurrent/experimental` needs `VIBE_UNSTABLE=1` to compile at
# all, and a dozen fixtures in this lane exercise that surface deliberately
# (region generativity, spawnable capture, the async boundary, the TaskGroup
# sugar). Granted lane-wide rather than per call site: the boundary exists for
# a USER's build, these are the repository's own fixtures, and the boundary
# itself is pinned by section 108 -- which clears the variable with
# `env -u VIBE_UNSTABLE` on every no-opt-in case precisely so it stays honest
# under an ambient grant.
export VIBE_UNSTABLE=1


# 40. The retired V128 intrinsics stay retired (#2342). The 12 `v128_*` names
#     were removed after measurement: the same algorithm through them cost 22x a
#     hand-written inline-wasm kernel and heap-boxed 2 unreclaimable bytes per
#     byte scanned (bench/bench_simd_bytes_find.vibe,
#     docs/internal/design/simd-data-structures.md 3.1). A retired surface that quietly comes
#     back is worse than one that never left -- especially this one, which
#     type-checked and looked like the supported way to write SIMD -- so assert
#     the name does NOT resolve, and fails the way the CLI promises.
echo "[compiler-gate] 40/40 retired V128 intrinsics stay retired"
vdir="_build/_gate_v128"
rm -rf "$vdir"; mkdir -p "$vdir"
cat > "$vdir/retired_v128.vibe" <<'RETIREDEOF'
fn probe(b: Bytes) -> Int {
  let _ = v128_load(b, 0)
  0
}
RETIREDEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$vdir/retired_v128.vibe" "$vdir/v128.wasm" __no_entry__ >"$vdir/out.txt" 2>&1 || true
if [ -s "$vdir/v128.wasm" ]; then
  echo "[compiler-gate] FAIL: v128_load still compiles -- the retired intrinsic surface came back (#2342)" >&2
  exit 1
fi
if ! cat "$vdir/out.txt" "$vdir/v128.wasm.diag" 2>/dev/null | grep -q "unknown name: v128_load"; then
  echo "[compiler-gate] FAIL: v128_load was rejected, but not with 'unknown name' -- the diagnostic must say what is wrong" >&2
  cat "$vdir/out.txt" "$vdir/v128.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$vdir"
echo "[compiler-gate] retired V128 intrinsics stay retired ok"

# 40b. Fused SIMD whitespace skip (#536 Phase 3): simd_skip_ws(Bytes,Int,Int)
#      runs a single inline v128 scan loop (16 bytes/iteration, v128 kept on the
#      operand stack with NO per-op heap boxing) plus a scalar tail. The fixture
#      asserts the result equals the scalar first-non-whitespace index across the
#      tail-only, single-chunk bitmask/ctz, multi-chunk, and non-zero-start paths.
echo "[compiler-gate] 40b/40 fused SIMD whitespace skip (simd_skip_ws)"
swdir="_build/_gate_simd_skip_ws"
rm -rf "$swdir"; mkdir -p "$swdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/simd_skip_ws_test.vibe" "$swdir/sw.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$swdir/sw.wasm" ]; then
  echo "[compiler-gate] FAIL: simd_skip_ws test did not compile" >&2
  cat "$swdir/sw.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$swdir/sw.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: simd_skip_ws test trapped (assert failed)" >&2; exit 1
fi
rm -rf "$swdir"
echo "[compiler-gate] fused SIMD whitespace skip ok"

# 40b2. String-native fused SIMD scan (#1868 Phase 1). Keep the scalar oracle
# in the fixture so quote/backslash/control detection, byte offsets, UTF-8,
# chunk boundaries, and the scalar tail stay identical.
echo "[compiler-gate] 40b2/40 fused SIMD string-special scan"
sssdir="_build/_gate_simd_string_special"
rm -rf "$sssdir"; mkdir -p "$sssdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/simd_scan_string_special_test.vibe" "$sssdir/sss.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$sssdir/sss.wasm" ]; then
  echo "[compiler-gate] FAIL: SIMD string-special test did not compile" >&2
  cat "$sssdir/sss.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$sssdir/sss.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: SIMD string-special test trapped" >&2; exit 1
fi
rm -rf "$sssdir"
echo "[compiler-gate] fused SIMD string-special scan ok"

# 40b3. String-native fused LF scan (#1902 Phase 1). The scalar oracle pins
# short tails, exact chunk boundaries, UTF-8 byte offsets, non-zero starts,
# LF, and EOF before the lexer adopts the builtin.
echo "[compiler-gate] 40b3/40 fused SIMD line-end scan"
sledir="_build/_gate_simd_line_end"
rm -rf "$sledir"; mkdir -p "$sledir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/simd_scan_line_end_test.vibe" "$sledir/sle.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$sledir/sle.wasm" ]; then
  echo "[compiler-gate] FAIL: SIMD line-end test did not compile" >&2
  cat "$sledir/sle.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$sledir/sle.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: SIMD line-end test trapped" >&2; exit 1
fi
rm -rf "$sledir"
echo "[compiler-gate] fused SIMD line-end scan ok"

# 40c. Region capture (#629 step 2): a `let mut` captured by a closure inside a
#      struct/record literal, projection, handler, loop, labeled arg, map literal
#      or spread must still be heap-boxed (by-reference capture), not snapshotted.
#      The fixture asserts the read closure sees the writer's mutations and the
#      outer cell is updated; it traps under the pre-fix by-value snapshot bug.
echo "[compiler-gate] 40c/40 region capture (mut captured inside struct literal etc.)"
rcdir="_build/_gate_region_capture"
rm -rf "$rcdir"; mkdir -p "$rcdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/region_capture_test.vibe" "$rcdir/rc.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$rcdir/rc.wasm" ]; then
  echo "[compiler-gate] FAIL: region_capture test did not compile" >&2
  cat "$rcdir/rc.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$rcdir/rc.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: region_capture test trapped (assert failed)" >&2; exit 1
fi
rm -rf "$rcdir"
echo "[compiler-gate] region capture ok"

# 40d. RC reclamation leak guard (#699/#700/#701/#702/#706): a hot loop
#      allocating a tuple + a captured `let mut` cell + the closure that
#      captures it + a recursive enum tree consumed by a recursive fn + a heap
#      param consumed by a normal call INSIDE a while loop (#706's
#      parse_module_sections shape), every iteration, must be fully reclaimed
#      under VIBE_RC. Compile via the FS-compile path WITH VIBE_RC=1 (the
#      `vibe run` path — also exercises #701, which wired RC into FS mode) and
#      measure __heap_ptr: reclamation keeps heap_used a small constant (~424 B
#      at N=20000), whereas a regression in tuple RC reclaim (#700),
#      captured-mut cell/closure reclaim (#699), VIBE_RC silently ignored in FS
#      mode (#701), the recursive-enum match double-free that trapped at scale
#      (#702 Blocker B), or the loop-consumed heap param's own reference never
#      being dropped (#706 — leaked ~84 B per call before its fix) makes it
#      scale with N (or trap). #700 slipped precisely because no gate asserted
#      a bounded heap.
# #1540: the memhost-with-realloc module the async string shape needs must be a
# VALID core module, not merely well-shaped bytes. The first cut emitted two
# separate export sections (`emit_export_memory` and `emit_export_section` each
# emit their own section 7, and a core module may carry only one), which every
# byte-inspection test happily accepted and `wasm-tools validate` rejected with
# "section out of order". Emitting and validating is the only assertion that
# catches that class.
if command -v wasm-tools >/dev/null 2>&1; then
  echo "[compiler-gate] 40c3/40 memhost-with-realloc is a valid core module (#1540)"
  mhdir="_build/_gate_memhost_realloc"
  rm -rf "$mhdir"; mkdir -p "$mhdir"
  cat > "$mhdir/emit.vibe" <<'MHEOF'
import @vibe/compiler/entry/source_compile/wasi_only {
  comp_emit_memhost_realloc_fixture
}

fn main() -> Int allows Fs {
  let m = comp_emit_memhost_realloc_fixture()
  Fs::write_bytes("_build/_gate_memhost_realloc/memhost.wasm", m)
  Bytes::length(m)
}
MHEOF
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$mhdir/emit.vibe" "$mhdir/emit.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$mhdir/emit.wasm" ]; then
    echo "[compiler-gate] FAIL: the memhost-realloc emitter program did not compile" >&2
    cat "$mhdir/emit.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke main "$mhdir/emit.wasm" >/dev/null 2>&1 || true
  if [ ! -s "$mhdir/memhost.wasm" ]; then
    echo "[compiler-gate] FAIL: the memhost-realloc emitter wrote no module" >&2
    exit 1
  fi
  if ! wasm-tools validate "$mhdir/memhost.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: the emitted memhost-realloc module does not validate (#1540)" >&2
    wasm-tools validate "$mhdir/memhost.wasm" >&2 || true
    exit 1
  fi
  echo "[compiler-gate] memhost-with-realloc validates ok (#1540)"
else
  echo "[compiler-gate] note: wasm-tools absent, skipping the memhost-realloc validation (#1540)"
fi
# #1540: the whole async string component, assembled from the widened emitters
# alone, must LOAD AND RUN -- not merely carry the right bytes.
#
# The unit test in component_codegen_test.vibe pins the canon byte sequences and
# the core-func indices around them, and that is as far as byte inspection can
# go: a component whose lift points at the wrong core func, whose data segment
# never reaches the imported memory, or whose instantiation order is unsound
# still contains every sequence the test looks for. Running it is the only
# assertion that separates "emits the documented bytes" from "is the component
# the probe is".
#
# The bar is the hand-written probe's: greet("bob") -> "hi", meaning the string
# really round-trips out through task.return.
gate_wasmtime_bin="$(bash scripts/wasmtime_bin.sh 2>/dev/null || command -v wasmtime || true)"
if command -v wasm-tools >/dev/null 2>&1 && [ -n "$gate_wasmtime_bin" ] \
   && "$gate_wasmtime_bin" --version >/dev/null 2>&1; then
  echo "[compiler-gate] 40c4/40 emitted async string component runs (#1540)"
  asdir="_build/_gate_async_string_component"
  rm -rf "$asdir"; mkdir -p "$asdir"
  cat > "$asdir/emit.vibe" <<'ASEOF'
import @vibe/compiler/entry/source_compile/wasi_only {
  comp_emit_async_string_component
}

fn repeat(piece: String, count: Int) -> String {
  let out = StringBuilder::new()
  let mut i = 0
  while i < count {
    StringBuilder::push(out, piece)
    i = i + 1
  }
  StringBuilder::freeze(out)
}

fn main() -> Int allows Fs {
  let m = comp_emit_async_string_component("greet", "name", "hi")
  Fs::write_bytes("_build/_gate_async_string_component/component.wasm", m)
  let large = comp_emit_async_string_component("greet", "name", repeat("x", 1100))
  Fs::write_bytes("_build/_gate_async_string_component/component-large.wasm", large)
  Bytes::length(m)
}
ASEOF
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$asdir/emit.vibe" "$asdir/emit.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$asdir/emit.wasm" ]; then
    echo "[compiler-gate] FAIL: the async-string component emitter program did not compile" >&2
    cat "$asdir/emit.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke main "$asdir/emit.wasm" >/dev/null 2>&1 || true
  if [ ! -s "$asdir/component.wasm" ]; then
    echo "[compiler-gate] FAIL: the async-string component emitter wrote no component" >&2
    exit 1
  fi
  if ! wasm-tools validate --features all "$asdir/component.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: the emitted async string component does not validate (#1540)" >&2
    wasm-tools validate --features all "$asdir/component.wasm" >&2 || true
    exit 1
  fi
  if ! wasm-tools validate --features all "$asdir/component-large.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: the emitted large-reply component does not validate (#1540)" >&2
    wasm-tools validate --features all "$asdir/component-large.wasm" >&2 || true
    exit 1
  fi
  as_out="$("$gate_wasmtime_bin" run -W exceptions=y -W concurrency-support=y \
    -W component-model-async=y -W component-model-async-stackful=y \
    --invoke 'greet("bob")' "$asdir/component.wasm" 2>&1 || true)"
  case "$as_out" in
    *'"hi"'*) ;;
    *)
      echo "[compiler-gate] FAIL: emitted greet(\"bob\") returned '$as_out' (want \"hi\") (#1540)" >&2
      exit 1
      ;;
  esac
  as_large_out="$("$gate_wasmtime_bin" run -W exceptions=y -W concurrency-support=y \
    -W component-model-async=y -W component-model-async-stackful=y \
    --invoke 'greet("bob")' "$asdir/component-large.wasm" 2>&1 || true)"
  as_large_payload="$(printf '%s' "$as_large_out" | tr -d '"(),[:space:]')"
  as_large_non_x="$(printf '%s' "$as_large_payload" | tr -d 'x')"
  if [ "${#as_large_payload}" -ne 1100 ] || [ -n "$as_large_non_x" ]; then
    echo "[compiler-gate] FAIL: large reply was corrupted or truncated (got ${#as_large_payload} bytes) (#1540)" >&2
    exit 1
  fi
  echo "[compiler-gate] emitted async string component: greet(\"bob\") -> \"hi\" (#1540)"
else
  echo "[compiler-gate] note: wasm-tools/wasmtime absent, skipping the async string component run (#1540)"
fi
# #1540 scope 3: a HostStream PARAMETER on the component surface.
#
# Two things had to change together for this to compile, and this lane pins
# both because each is silently undone by the other's absence.
#
#   1. The Async boundary is wrapped around `entry_name`, and the component
#      lanes compile with the `__no_entry__` sentinel -- so nothing ever
#      matched and no boundary was built. It now falls back to the exported
#      Async function, and ONLY when there is exactly one.
#   2. A host stream reaches vibe code as the cell `[3, handle]`, which
#      `host_stream_named` builds. A PARAMETER arrives as the bare handle, so
#      the reads would have pulled state and handle out of an integer. The
#      parameter is now shadowed by the cell at the top of the body.
#
# The import list is the assertion that says the stream came from the
# PARAMETER: `vibe.host_stream_read` present, and NO `host_stream_get$<name>`,
# which is the named-import lane #1540 ruled out as a composition cycle.
echo "[compiler-gate] 40c5/40 HostStream parameter on the component surface (#1540)"
hsdir="_build/_gate_hoststream_param"
rm -rf "$hsdir"; mkdir -p "$hsdir"
cat > "$hsdir/handler.vibe" <<'HSEOF'
export let handler = (method: String, url: String, headers: String, body: HostStream) -> String with Async {
  let mut total = 0
  let mut go = true
  while go {
    let b = host_stream_next(body)
    if b < 0 { go = false } else { total = total + b }
  }
  "200\n\nsum:\{total}"
}
HSEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hsdir/handler.vibe" "$hsdir/handler.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$hsdir/handler.wasm" ]; then
  echo "[compiler-gate] FAIL: a HostStream-parameter handler did not compile (#1540)" >&2
  cat "$hsdir/handler.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if command -v wasm-tools >/dev/null 2>&1; then
  hs_imports="$(wasm-tools print "$hsdir/handler.wasm" 2>/dev/null | grep -c 'vibe" "host_stream_read"' || true)"
  [ -n "$hs_imports" ] || hs_imports=0
  if [ "$hs_imports" = "0" ]; then
    echo "[compiler-gate] FAIL: the handler does not import vibe.host_stream_read (#1540)" >&2
    exit 1
  fi
  hs_named="$(wasm-tools print "$hsdir/handler.wasm" 2>/dev/null | grep -c 'host_stream_get' || true)"
  [ -n "$hs_named" ] || hs_named=0
  if [ "$hs_named" != "0" ]; then
    echo "[compiler-gate] FAIL: the stream came from a NAMED import, not the parameter (#1540)" >&2
    exit 1
  fi
  echo "[compiler-gate] HostStream parameter: reads via host_stream_read, no named get (#1540)"
fi
# The other half: with TWO exported Async functions there is no single
# boundary, and picking one would wrap the wrong function's suspends. That case
# must keep failing loudly rather than guess.
cat > "$hsdir/two.vibe" <<'HSEOF'
export let handler = (body: HostStream) -> Int with Async {
  host_stream_next(body)
}

export let other = (body: HostStream) -> Int with Async {
  host_stream_next(body)
}
HSEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hsdir/two.vibe" "$hsdir/two.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$hsdir/two.wasm" ]; then
  echo "[compiler-gate] FAIL: two exported Async functions silently picked a boundary (#1540)" >&2
  exit 1
fi
echo "[compiler-gate] two exported Async functions still refuse to guess a boundary (#1540)"
# #1746 (RC lane): the raw-ABI shim dispatched on the callee NAME alone, so a
# program defining its own top-level `fn sleep` had the shim applied to ITS
# call -- emitting a module that failed validation, with no diagnostic. Only
# VIBE_RC=1 was affected, so the VIBE_RC=0 baseline every other lane uses could
# not see it. `wasm-tools validate` is the assertion that matters here: a
# `.wasm` existing is NOT the same as a `.wasm` loading, which is exactly how
# this stayed invisible.
echo "[compiler-gate] 40c2/40 RC user-shadowed builtin name (#1746)"
shdir="_build/_gate_rc_shadow_sleep"
rm -rf "$shdir"; mkdir -p "$shdir"
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/rc_user_shadowed_sleep_test.vibe" "$shdir/sh.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$shdir/sh.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_user_shadowed_sleep fixture did not compile under VIBE_RC" >&2
  cat "$shdir/sh.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if command -v wasm-tools >/dev/null 2>&1; then
  if ! wasm-tools validate --features all "$shdir/sh.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: rc_user_shadowed_sleep emitted an INVALID module under VIBE_RC (#1746)" >&2
    wasm-tools validate --features all "$shdir/sh.wasm" >&2 || true
    exit 1
  fi
else
  echo "[compiler-gate] note: wasm-tools absent, skipping the validate half of #1746"
fi
sh_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$shdir/sh.wasm" 2>&1 | tail -1)"
if [ "$sh_out" != "42" ]; then
  echo "[compiler-gate] FAIL: rc_user_shadowed_sleep got '$sh_out' (want 42 -- the USER's sleep must be called)" >&2
  exit 1
fi
echo "[compiler-gate] RC user-shadowed builtin name ok (#1746)"
echo "[compiler-gate] 40d/40 RC reclamation leak guard (tuple+cell+closure+enum+loop-consume+builder-return)"
lkdir="_build/_gate_rc_leak"
rm -rf "$lkdir"; mkdir -p "$lkdir"
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/rc_reclaim_leak_test.vibe" "$lkdir/rc.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$lkdir/rc.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_reclaim_leak fixture did not compile under VIBE_RC" >&2
  cat "$lkdir/rc.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
lk_json="$(node scripts/measure_heap.mjs "$lkdir/rc.wasm" main 2>/dev/null)"
lk_used="$(printf '%s' "$lk_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
lk_result="$(printf '%s' "$lk_json" | sed -n 's/.*"result":\([0-9]*\).*/\1/p')"
if [ -z "$lk_used" ]; then
  echo "[compiler-gate] FAIL: could not measure rc_reclaim_leak heap ($lk_json)" >&2; exit 1
fi
if [ "$lk_result" != "9801510000" ]; then
  echo "[compiler-gate] FAIL: rc_reclaim_leak wrong result $lk_result (want 9801510000)" >&2; exit 1
fi
# #2683: the bound is 4000 B. The fixture's steady state is a CONSTANT --
# one parked block per size bin at loop exit, 3,204 B measured with the
# MapBuilder / Map shapes (indexed maps, grown builder storage) -- while a
# leak scales with N: the 16 B per iteration of a single unreleased empty
# map is 320,000 B at N=20000, a full leak ~36,000,000 B.
if [ "$lk_used" -ge 4000 ]; then
  echo "[compiler-gate] FAIL: rc_reclaim_leak heap_used=$lk_used >= 4000 (RC reclamation regressed; a per-iteration leak is >= 320000 at N=20000, ~36000000 == full leak)" >&2; exit 1
fi
rm -rf "$lkdir"
echo "[compiler-gate] RC reclamation leak guard ok (heap_used=$lk_used B at N=20000)"

# 40e. #2760: a mutable slot whose initializer's spine ends in a PROJECTION.
# Its own file rather than a shape inside 40d's fixture, because that file's
# house idioms mask this leak -- see the fixture header for both details and
# the numbers that show it.
#
# This bounds a HALF-APPLIED fix, not a state main was ever in. Attributed on
# 6507c60 by building each variant: unpatched 268 B, #2760's assignment arm
# WITHOUT the projection arm 1,600,348 B (3,200,348 B at N=40000, so it
# SCALES), both arms 348 B (constant in N). The bound below separates the
# middle row from the other two by three orders of magnitude.
echo "[compiler-gate] 40e/40 RC mutable-initializer projection leak guard (#2760)"
pjdir="_build/_gate_rc_proj_leak"
rm -rf "$pjdir"; mkdir -p "$pjdir"
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/rc_mut_init_proj_leak_test.vibe" "$pjdir/rc.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$pjdir/rc.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_mut_init_proj_leak fixture did not compile under VIBE_RC" >&2
  cat "$pjdir/rc.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
pj_json="$(node scripts/measure_heap.mjs "$pjdir/rc.wasm" main 2>/dev/null)"
pj_used="$(printf '%s' "$pj_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
pj_result="$(printf '%s' "$pj_json" | sed -n 's/.*"result":\([0-9]*\).*/\1/p')"
if [ -z "$pj_used" ]; then
  echo "[compiler-gate] FAIL: could not measure rc_mut_init_proj_leak heap ($pj_json)" >&2; exit 1
fi
if [ "$pj_result" != "0" ]; then
  echo "[compiler-gate] FAIL: rc_mut_init_proj_leak wrong result $pj_result (want 0)" >&2; exit 1
fi
if [ "$pj_used" -ge 2000 ]; then
  echo "[compiler-gate] FAIL: rc_mut_init_proj_leak heap_used=$pj_used >= 2000 (#2760 regressed; the assignment arm without the projection arm measured 1600348 at N=20000, and a retain emitted TWICE for a bare projection leaks at the same rate)" >&2; exit 1
fi
rm -rf "$pjdir"
echo "[compiler-gate] RC mutable-initializer projection leak guard ok (heap_used=$pj_used B at N=20000)"

# 40e2. #2760: the retain must NOT fire when the wrapper binds the borrow's own
# source -- the inner ELet lowering already promoted it, and a second retain
# leaks the element on every assignment. Found in review on #2783, not by a
# gate: the ANSWER stays correct, so only a heap bound sees it. Measured on
# 6507c60 at N=20000: 164 B unpatched, 1,600,084 B classifying from the leaf
# callee alone, 164 B with the source test. 80 B per iteration, so it scales.
#
# #2796 added the PROJECTION leaf (once_proj) to the same fixture, because
# spine_leaf_unowned answers the two leaf kinds in separate arms and a bound
# holding only one of them is a bound the other arm walks past. Both halves are
# proven able to fail: with the EDot arm's guard deleted the same fixture
# measures 1,600,108 B against this row's 2000.
#
# #2786 added a THIRD direction, once_owning_self: a self-mentioning wrapper,
# which #2799 read as another shape that must not be retained and which the plan
# says is short a reference like any other. It bounds the RELEASE half of that
# fix -- a slot that acquires its replacement has to let go of what it held --
# and is proven able to fail the same way: a compiler carrying the acquire half
# alone measures 1,600,164 B here against this row's 2000, on a fixture whose
# ANSWER is 0 either way.
# #2803 adds consuming reads after the store, including replacements promoted
# by a wrapper's local owner. On 17874c5d8 the extended fixture returns the
# correct value but uses 8,000,328 B at N=20000; the fixed compiler uses 408 B
# at both N=20000 and N=40000.
echo "[compiler-gate] 40e2/40 RC wrapper-assign double-retain guard (#2760/#2786/#2803)"
drdir="_build/_gate_rc_double_retain"
rm -rf "$drdir"; mkdir -p "$drdir"
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/rc_wrapper_assign_double_retain_test.vibe" "$drdir/rc.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$drdir/rc.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_wrapper_assign_double_retain fixture did not compile under VIBE_RC" >&2
  cat "$drdir/rc.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
dr_json="$(node scripts/measure_heap.mjs "$drdir/rc.wasm" main 2>/dev/null)"
dr_used="$(printf '%s' "$dr_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
dr_result="$(printf '%s' "$dr_json" | sed -n 's/.*"result":\([0-9]*\).*/\1/p')"
if [ -z "$dr_used" ]; then
  echo "[compiler-gate] FAIL: could not measure rc_wrapper_assign_double_retain heap ($dr_json)" >&2; exit 1
fi
if [ "$dr_result" != "0" ]; then
  echo "[compiler-gate] FAIL: rc_wrapper_assign_double_retain wrong result $dr_result (want 0)" >&2; exit 1
fi
if [ "$dr_used" -ge 2000 ]; then
  echo "[compiler-gate] FAIL: rc_wrapper_assign_double_retain heap_used=$dr_used >= 2000 (#2760/#2786/#2803 regressed; an unspent reference leaks at least 80 B per iteration at N=20000)" >&2; exit 1
fi
rm -rf "$drdir"
echo "[compiler-gate] RC wrapper-assign double-retain guard ok (heap_used=$dr_used B at N=20000)"

# 40e3. #3043 / ADR-0116: a `for` whose value is discarded allocates no result
# array. Compiled on the BUMP lane (VIBE_RC=0) on purpose: nothing is ever
# reclaimed there, so a loop that materialised its array and dropped it would
# still show in heap_used -- under RC the drop hides it. Measured on main at
# 0f0ba364e: 252 B (the `xs` literal alone), constant in the iteration count;
# the same loop written `let ys = for x in xs { x }` measured 504,252 B at 2000
# iterations. Five discard positions run per iteration (see the fixture).
echo "[compiler-gate] 40e3/40 discarded for-in allocates no result array (#3043)"
fddir="_build/_gate_for_discard"
rm -rf "$fddir"; mkdir -p "$fddir"
VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/for_discard_no_alloc_test.vibe" "$fddir/bump.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$fddir/bump.wasm" ]; then
  echo "[compiler-gate] FAIL: for_discard_no_alloc fixture did not compile on the bump lane" >&2
  cat "$fddir/bump.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
fd_json="$(node scripts/measure_heap.mjs "$fddir/bump.wasm" main 2>/dev/null)"
fd_used="$(printf '%s' "$fd_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
fd_result="$(printf '%s' "$fd_json" | sed -n 's/.*"result":\([0-9]*\).*/\1/p')"
if [ -z "$fd_used" ]; then
  echo "[compiler-gate] FAIL: could not measure for_discard_no_alloc heap ($fd_json)" >&2; exit 1
fi
if [ "$fd_result" != "1632000" ]; then
  echo "[compiler-gate] FAIL: for_discard_no_alloc wrong result $fd_result (want 1632000)" >&2; exit 1
fi
if [ "$fd_used" -ge 2000 ]; then
  echo "[compiler-gate] FAIL: for_discard_no_alloc heap_used=$fd_used >= 2000 (a discarded for-in materialised its result array; one such loop is ~250 B per iteration, ~500 KB over the fixture's 2000)" >&2; exit 1
fi
# The same promise under a `handle` (Codex on #3061): forin_discard_pass had no
# EHandle arm, so the loop inside collected -- 504,252 B measured before the
# fix, 252 B (the `xs` literal) after.
VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/for_discard_handle_no_alloc_test.vibe" "$fddir/handle.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$fddir/handle.wasm" ]; then
  echo "[compiler-gate] FAIL: for_discard_handle_no_alloc fixture did not compile on the bump lane" >&2
  cat "$fddir/handle.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
fh_json="$(node scripts/measure_heap.mjs "$fddir/handle.wasm" main 2>/dev/null)"
fh_used="$(printf '%s' "$fh_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
fh_result="$(printf '%s' "$fh_json" | sed -n 's/.*"result":\([0-9]*\).*/\1/p')"
if [ -z "$fh_used" ] || [ "$fh_result" != "2000" ]; then
  echo "[compiler-gate] FAIL: for_discard_handle_no_alloc bad measurement ($fh_json)" >&2; exit 1
fi
if [ "$fh_used" -ge 2000 ]; then
  echo "[compiler-gate] FAIL: for_discard_handle_no_alloc heap_used=$fh_used >= 2000 (a for-in discarded under a handle materialised its result array)" >&2; exit 1
fi
rm -rf "$fddir"
echo "[compiler-gate] discarded for-in no-allocation guard ok (heap_used=$fd_used B, under a handle $fh_used B, at 2000 iterations)"

# 40f. RC shadow-liveness regression guard (#715 recurrence prevention).
#      Compiles the #715 shape corpus (every minimal shape that once produced
#      a use-after-free / double-free in the Perceus RC backend) with
#      VIBE_RC=shadow -- codegen that marks freed blocks in a shadow byte
#      table and executes `unreachable` on the FIRST dup-of-freed or
#      drop-of-freed -- and runs it. A regression in the RC dup/drop
#      accounting traps HERE, deterministically, at the faulting operation,
#      instead of corrupting the free list and crashing later at an
#      unrelated, binary-layout-dependent location ("moving target").
#      This is the shape corpus only. Branch-heavy checker paths (the first
#      cut of #1964) need the 40f2 checked-artifact smoke.
echo "[compiler-gate] 40f/40 RC shadow-liveness regression guard (#715 shapes)"
shdir="_build/_gate_rc_shadow"
rm -rf "$shdir"; mkdir -p "$shdir"
VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/rc_shadow_regression_test.vibe" "$shdir/shadow.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$shdir/shadow.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_shadow_regression fixture did not compile under VIBE_RC=shadow" >&2
  cat "$shdir/shadow.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
sh_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$shdir/shadow.wasm" 2>&1 | tail -1)"
if [ "$sh_out" != "25377489" ]; then
  echo "[compiler-gate] FAIL: rc_shadow_regression got '$sh_out' (want 25377489). A trap here means an RC dup/drop accounting regression touched a freed block -- see fixtures/rc_shadow_regression_test.vibe for which shapes are covered and issue #715 for the debugging methodology." >&2
  exit 1
fi
rm -rf "$shdir"
echo "[compiler-gate] RC shadow-liveness regression guard ok (25377489)"

# 40f-b. #3103: a `let` bound to an if/match whose branch tail calls a
#        borrow-returning function (`Array::get`) holds a view of an element
#        its container still owns. The plan gives the binding a scope-end
#        drop, so the lowering must retain that tail -- in a loop and in
#        straight-line code alike. Before the fix the shadow build aborted
#        with `drop of freed value`, and the plain RC build answered 134444
#        without a trap: the freed element was reused and read as garbage.
#        Six shapes at distinct decimal places (see the fixture header).
echo "[compiler-gate] 40f-b/40 branch-tail borrow let retain (#3103)"
bbdir="_build/_gate_rc_branch_borrow_let"
rm -rf "$bbdir"; mkdir -p "$bbdir"
for bb_lane in rc shadow; do
  rm -f "$bbdir/bb.wasm" "$bbdir/bb.wasm.diag"
  case "$bb_lane" in
    rc) env VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_branch_borrow_let_test.vibe" "$bbdir/bb.wasm" main >/dev/null 2>&1 || true ;;
    shadow) env VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_branch_borrow_let_test.vibe" "$bbdir/bb.wasm" main >/dev/null 2>&1 || true ;;
  esac
  if [ ! -s "$bbdir/bb.wasm" ]; then
    echo "[compiler-gate] FAIL: rc_branch_borrow_let fixture did not compile on the $bb_lane lane (#3103)" >&2
    cat "$bbdir/bb.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  bb_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$bbdir/bb.wasm" 2>&1 | tail -1)"
  if [ "$bb_out" != "334444" ]; then
    echo "[compiler-gate] FAIL: rc_branch_borrow_let got '$bb_out' on the $bb_lane lane (want 334444). The digit that moved names the shape (see fixtures/rc_branch_borrow_let_test.vibe); a shadow abort means an if/match branch tail's borrowed element was dropped without a retain (#3103)." >&2
    exit 1
  fi
done

rm -rf "$bbdir"
echo "[compiler-gate] branch-tail borrow let retain ok (334444 on rc/shadow)"
# 40f-b2. #3108 review: the follow-ups of the same retain on the shadow
#         lane, where an unbalanced drop traps on its first occurrence. The
#         plain RC lane can answer these right by luck (a freed block not yet
#         reused), which is why the unit runner's default lane is not enough:
#         a branch that reaches its borrow-returning tail through a `let rec`
#         block or a `handle` body / arm.
echo "[compiler-gate] 40f-b2/40 let-rec / handle branch-tail borrow retain on shadow (#3108)"
if ! VIBE_RC=shadow VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash scripts/vibe_test.sh fixtures/rc_branch_borrow_letrec_test.vibe \
    >"$ROOT_DIR/_build/_gate_rc_branch_letrec.log" 2>&1; then
  echo "[compiler-gate] FAIL: a borrowed branch tail behind a let rec or a handle was dropped without a retain under VIBE_RC=shadow (#3108):" >&2
  tail -20 "$ROOT_DIR/_build/_gate_rc_branch_letrec.log" >&2
  exit 1
fi
rm -f "$ROOT_DIR/_build/_gate_rc_branch_letrec.log"
echo "[compiler-gate] let-rec / handle branch-tail borrow retain ok on shadow"
# #3110: the let-rec self capture is weak, so the binder's reference must be
# released at scope end. A returned closure must keep a reference of its own.
echo "[compiler-gate] 131/131 local let-rec closure release (#3110)"
for rec_lane in 1 shadow; do
  if ! VIBE_RC="$rec_lane" VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/rc_letrec_self_cycle_bounded_test.vibe \
      fixtures/rc_letrec_mut_alias_test.vibe \
      >"$ROOT_DIR/_build/_gate_rc_letrec_self_cycle.log" 2>&1; then
    echo "[compiler-gate] FAIL: local let rec leak or escaped closure on VIBE_RC=$rec_lane (#3110):" >&2
    tail -20 "$ROOT_DIR/_build/_gate_rc_letrec_self_cycle.log" >&2
    exit 1
  fi
done
rm -f "$ROOT_DIR/_build/_gate_rc_letrec_self_cycle.log"
echo "[compiler-gate] local let-rec closure bounded and returned closure alive on rc/shadow ok (#3110)"
# 40f-b3. #3113: a captured `let mut` cell owns its payload. The cell's drop
#         releases what it holds, so every store into it must be an owned
#         reference and every read that leaves for an owning place a
#         retained one. The fixture covers both sides: borrowed initializers
#         (direct, if/match, block, borrow-bound name, projection, if-arm
#         projection, pattern binder), a borrowed assignment, the scope's
#         tail, and a read handed to an owning parameter from the closure
#         and from the defining scope. Two of its shapes pass on the plain RC
#         lane even when broken and only show under VIBE_RC=shadow, so it
#         runs on both.
echo "[compiler-gate] 40f-b3/40 captured let mut cell owns its payload (#3113)"
for cm_lane in 1 shadow; do
  if ! VIBE_RC="$cm_lane" VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/rc_captured_mut_borrow_test.vibe \
      >"$ROOT_DIR/_build/_gate_rc_captured_mut.log" 2>&1; then
    echo "[compiler-gate] FAIL: fixtures/rc_captured_mut_borrow_test.vibe failed with VIBE_RC=$cm_lane (#3113). A trap means a captured let mut's RC cell released a payload it did not own -- a borrowed value stored without a retain, or a read of the cell handed to an owning place without one:" >&2
    tail -20 "$ROOT_DIR/_build/_gate_rc_captured_mut.log" >&2
    exit 1
  fi
done
rm -f "$ROOT_DIR/_build/_gate_rc_captured_mut.log"
echo "[compiler-gate] captured let mut cell ownership ok (rc + shadow)"

# 40f-b4. #3128: a program's own top-level definition of a borrowing
#         builtin's name (`Array::truncate`, `String::join`, `Bytes::compare`,
#         `Map::size`) owns its parameters, so the call site must hand over a
#         reference instead of the builtin's borrow. On the shadow lane the
#         premature release traps on its first occurrence; the plain RC lane
#         can answer right by luck when the freed block is not reused yet.
echo "[compiler-gate] 40f-b4/40 shadowed borrowing builtin receives owned arguments on shadow (#3128)"
if ! VIBE_RC=shadow VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash scripts/vibe_test.sh fixtures/rc_shadowed_builtin_ownership_test.vibe \
    >"$ROOT_DIR/_build/_gate_rc_shadowed_builtin.log" 2>&1; then
  echo "[compiler-gate] FAIL: a source definition of a borrowing builtin's name was called with a borrowed argument it then released, under VIBE_RC=shadow (#3128):" >&2
  tail -20 "$ROOT_DIR/_build/_gate_rc_shadowed_builtin.log" >&2
  exit 1
fi
rm -f "$ROOT_DIR/_build/_gate_rc_shadowed_builtin.log"
echo "[compiler-gate] shadowed borrowing builtin ownership ok on shadow"

# 40f-b5. #3129: `MutList::*` / `MutBytes::*` lower to the builtin
#         `Array::*` / `ArrayBuilder::push` / `Bytes::*`. A program that
#         defines its own function under the target spelling must not capture
#         the call: the plain RC lane answers the program's sentinel instead of
#         the list's length, and the shadow lane traps on the program function
#         releasing a list it was only lent.
echo "[compiler-gate] 40f-b5/40 MutList / MutBytes and internal builtin calls reach the builtin under a same-named program function (#3129, #3132)"
if ! VIBE_RC=shadow VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash scripts/vibe_test.sh fixtures/mut_alias_shadowed_builtin_test.vibe \
    >"$ROOT_DIR/_build/_gate_mut_alias_shadowed.log" 2>&1; then
  echo "[compiler-gate] FAIL: a MutList / MutBytes operation was captured by the program's own function of the builtin's spelling under VIBE_RC=shadow (#3129):" >&2
  tail -20 "$ROOT_DIR/_build/_gate_mut_alias_shadowed.log" >&2
  exit 1
fi
rm -f "$ROOT_DIR/_build/_gate_mut_alias_shadowed.log"
echo "[compiler-gate] MutList / MutBytes builtin aliases ok on shadow"
# #3132: the compiler's OWN calls by a builtin's name -- for-in, the HOF and
# Map loops, interpolation, structural `==` -- must reach the builtin when the
# program defines `Array::length` / `get` / `push`, on the shadow lane and on
# wasm-gc (whose native-array shortcuts used to answer a program's own direct
# `Array::length` call with the builtin). #3146: the CHECKER types those
# synthesized calls from the builtin's signature and row too, so a program
# whose own `String::concat` / `Array::get` differs from the builtin still
# compiles its interpolation and index sugar.
if ! VIBE_RC=shadow VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash scripts/vibe_test.sh fixtures/builtin_shadow_internal_lowering_test.vibe fixtures/builtin_shadow_parser_sugar_test.vibe \
      fixtures/builtin_shadow_synthesized_typing_test.vibe fixtures/builtin_shadow_synthesized_row_test.vibe \
    >"$ROOT_DIR/_build/_gate_builtin_shadow_lowering.log" 2>&1; then
  echo "[compiler-gate] FAIL: a compiler-internal call by a builtin's name reached the program's same-named function under VIBE_RC=shadow (#3132):" >&2
  tail -20 "$ROOT_DIR/_build/_gate_builtin_shadow_lowering.log" >&2
  exit 1
fi
if ! VIBE_TEST_BACKEND=gc VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash scripts/vibe_test.sh fixtures/mut_alias_shadowed_builtin_test.vibe fixtures/builtin_shadow_internal_lowering_test.vibe fixtures/builtin_shadow_parser_sugar_test.vibe \
      fixtures/builtin_shadow_synthesized_typing_test.vibe fixtures/builtin_shadow_synthesized_row_test.vibe \
    >"$ROOT_DIR/_build/_gate_builtin_shadow_lowering.log" 2>&1; then
  echo "[compiler-gate] FAIL: on wasm-gc a builtin and a same-named program function were confused (#3129 / #3132):" >&2
  tail -20 "$ROOT_DIR/_build/_gate_builtin_shadow_lowering.log" >&2
  exit 1
fi
rm -f "$ROOT_DIR/_build/_gate_builtin_shadow_lowering.log"
echo "[compiler-gate] builtin-named internal calls ok on shadow and wasm-gc"
# #3179: the other direction. A direct call the program wrote to its OWN
# function of a spelling the checker arms by name (`Array::get`, `Map::get`,
# `MutList::get`, `Future::ready`, `__index`, ...) is typed from that
# function's declaration and answers its value. The checker used to type it
# as the builtin while codegen called the program's function, so a String
# result was added to as an Int. The unit runner covers the default lane.
for dc_lane in shadow gc; do
  case "$dc_lane" in
    shadow) dc_env="VIBE_RC=shadow" ;;
    gc) dc_env="VIBE_TEST_BACKEND=gc" ;;
  esac
  if ! env "$dc_env" VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/builtin_shadow_direct_call_typing_test.vibe \
      >"$ROOT_DIR/_build/_gate_builtin_shadow_direct_call.log" 2>&1; then
    echo "[compiler-gate] FAIL: a direct call to the program's own function of a builtin-armed spelling was typed, or run, as the builtin on the $dc_lane lane (#3179):" >&2
    tail -20 "$ROOT_DIR/_build/_gate_builtin_shadow_direct_call.log" >&2
    exit 1
  fi
done
rm -f "$ROOT_DIR/_build/_gate_builtin_shadow_direct_call.log"
echo "[compiler-gate] program-declared builtin spellings ok: direct calls answer the program's own functions (shadow + gc)"
# #3185 / #3186: the spellings a LOWERING intercepts ahead of the function
# table -- the frozen-array / MutList / MutBytes conversions, the higher-order
# Array family, Map::set / delete, FixedArray::make / unsafe_set / blit, the
# parser sugar's __slice / __len / __set_field / __region_run, the conversions
# (Int::to_double, Char::to_int, ...) and the capability builtins (Fs::exists,
# Env::args_len, ...). A program's own function of one of them used to be
# ignored for its direct calls (the checker typed the declaration, the builtin
# ran), and `fn __set_field` took every field write. One fixture per family,
# each answering values its builtin never does, with the compiler's own calls
# by those names checked beside them -- and a dependency's calls, which cannot
# see the program's private definition (entry_scope). The unit runner covers
# the default lane.
for bf_lane in shadow gc; do
  case "$bf_lane" in
    shadow) bf_env="VIBE_RC=shadow" ;;
    gc) bf_env="VIBE_TEST_BACKEND=gc" ;;
  esac
  if ! env "$bf_env" VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/builtin_shadow_region_collections_test.vibe fixtures/builtin_shadow_array_hof_test.vibe \
        fixtures/builtin_shadow_map_fixed_array_test.vibe fixtures/builtin_shadow_sugar_callee_test.vibe \
        fixtures/builtin_shadow_conversion_test.vibe fixtures/builtin_shadow_capability_test.vibe \
        fixtures/builtin_shadow_entry_scope_test.vibe \
        fixtures/resolved_mutlist_runtime_test.vibe fixtures/resolved_mutlist_import_test.vibe \
        fixtures/resolved_mutbytes_runtime_test.vibe fixtures/resolved_mutbytes_import_test.vibe \
      >"$ROOT_DIR/_build/_gate_builtin_shadow_intercept.log" 2>&1; then
    echo "[compiler-gate] FAIL: a program's own function of a builtin spelling a lowering intercepts was ignored for its direct call, or took the compiler's own call, on the $bf_lane lane (#3185 / #3186):" >&2
    tail -20 "$ROOT_DIR/_build/_gate_builtin_shadow_intercept.log" >&2
    exit 1
  fi
done
# `Iterator::map` over an array is devirtualized to the builtin `Array::map`
# behind the program's own one. Shadow only: importing @vibe/builtin's
# Iterator does not compile on wasm-gc (its async half reaches Future::ready).
if ! VIBE_RC=shadow VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash scripts/vibe_test.sh fixtures/builtin_shadow_iterator_devirt_test.vibe fixtures/builtin_shadow_export_unit_test.vibe \
    >"$ROOT_DIR/_build/_gate_builtin_shadow_intercept.log" 2>&1; then
  echo "[compiler-gate] FAIL: a builtin operation reached a private function from another source unit under VIBE_RC=shadow (#3185 / #3211):" >&2
  tail -20 "$ROOT_DIR/_build/_gate_builtin_shadow_intercept.log" >&2
  exit 1
fi
rm -f "$ROOT_DIR/_build/_gate_builtin_shadow_intercept.log"
echo "[compiler-gate] intercepted builtin spellings ok: the program's own functions answer its calls (shadow + gc)"
# #3186: the authority half, read off the artifact. A program whose own PURE
# `Fs::exists` / `Env::args_len` / `Stdin::read_char` answers for the builtin is
# exempt from the capability row (#2107), so its linear module must not reach
# the host: it must load, and it must import no capability. Before the fix the
# linear lane took the call into the host-import shim, which here emitted a
# module that did not validate.
capdir="_build/_gate_builtin_shadow_capability"
rm -rf "$capdir"; mkdir -p "$capdir"
cat > "$capdir/own_fs.vibe" <<'CAPEOF'
fn Fs::exists(path: String) -> Bool {
  String::length(path) == 3
}

fn Env::args_len() -> Int {
  77
}

fn Stdin::read_char() -> Int {
  0 - 5
}

export fn probe() -> Int {
  if Fs::exists("abc") {
    Env::args_len() + Stdin::read_char()
  } else {
    0
  }
}
CAPEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$capdir/own_fs.vibe" "$capdir/own_fs.wasm" __no_entry__ >"$capdir/build.log" 2>&1 || true
if [ ! -s "$capdir/own_fs.wasm" ]; then
  echo "[compiler-gate] FAIL: a program with its own pure Fs::exists did not build on linear (#3186):" >&2
  cat "$capdir/own_fs.wasm.diag" >&2 2>/dev/null || tail -20 "$capdir/build.log" >&2
  exit 1
fi
# The linear lane may emit exnref, which this node may still gate behind a flag
# (the host runner probes it the same way).
cap_node_flags=()
if node --experimental-wasm-exnref -e "" >/dev/null 2>&1; then
  cap_node_flags=(--experimental-wasm-exnref)
fi
if ! cap_imports="$(node ${cap_node_flags[@]+"${cap_node_flags[@]}"} -e '
const bytes = require("fs").readFileSync(process.argv[1]);
const mod = new WebAssembly.Module(bytes);
for (const i of WebAssembly.Module.imports(mod)) console.log(i.module + "." + i.name);
' "$capdir/own_fs.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: the linear module of a program with its own pure Fs::exists does not load (#3186):" >&2
  printf '%s\n' "$cap_imports" | tail -5 >&2
  exit 1
fi
if printf '%s\n' "$cap_imports" | grep -Eq '^vibe\.(fs_|env_|stdin_)'; then
  echo "[compiler-gate] FAIL: a program's own pure Fs::exists / Env::args_len / Stdin::read_char reached a host capability on linear (#3186):" >&2
  printf '%s\n' "$cap_imports" >&2
  exit 1
fi
rm -rf "$capdir"
echo "[compiler-gate] own pure capability-named functions ok: the linear module loads and imports no capability (#3186)"
# #3158: the 63-bit wrap contract (#1877) holds the SAME values on every
# backend, so its test runs on wasm-gc too (the unit runner covers linear).
# It could not compile there: the erased-generic `[T: Add]` / `[T: Ord]`
# dispatch (#973) reached gc codegen as an unresolved `__generic_add`.
if ! VIBE_TEST_BACKEND=gc VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash scripts/vibe_test.sh lib/@vibe/compiler/tests/int_overflow_wrap_test.vibe fixtures/generic_marker_dispatch_test.vibe \
    >"$ROOT_DIR/_build/_gate_gc_int_wrap.log" 2>&1; then
  echo "[compiler-gate] FAIL: the Int wrap / erased-generic dispatch tests fail on wasm-gc (#3158):" >&2
  tail -20 "$ROOT_DIR/_build/_gate_gc_int_wrap.log" >&2
  exit 1
fi
rm -f "$ROOT_DIR/_build/_gate_gc_int_wrap.log"
echo "[compiler-gate] Int wrap and erased-generic + / < ok on wasm-gc"
# #3132 review: `--entry` naming the program's own function spelled like a
# builtin (renamed aside to `StringBuilder::new$user`) still resolves, and the
# module exports it under the name the program wrote -- on linear and wasm-gc.
bedir="_build/_gate_builtin_shadow_entry"
rm -rf "$bedir"; mkdir -p "$bedir"
for be_lane in linear gc; do
  rm -f "$bedir/e.wasm" "$bedir/e.wasm.diag"
  case "$be_lane" in
    linear) env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" "fixtures/builtin_shadow_entry.vibe" "$bedir/e.wasm" 'StringBuilder::new' >/dev/null 2>&1 || true ;;
    gc) env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" "fixtures/builtin_shadow_entry.vibe" "$bedir/e.wasm" 'StringBuilder::new' >/dev/null 2>&1 || true ;;
  esac
  if [ ! -s "$bedir/e.wasm" ]; then
    echo "[compiler-gate] FAIL: --entry StringBuilder::new naming the program's own function did not build on the $be_lane lane (#3132 review):" >&2
    cat "$bedir/e.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  if ! node -e 'const m=new WebAssembly.Module(require("fs").readFileSync(process.argv[1]));process.exit(WebAssembly.Module.exports(m).some(e=>e.name===process.argv[2])?0:1)' "$bedir/e.wasm" 'StringBuilder::new'; then
    echo "[compiler-gate] FAIL: the $be_lane module does not export the entry as StringBuilder::new (#3132 review)" >&2
    exit 1
  fi
done
rm -rf "$bedir"
echo "[compiler-gate] builtin-named --entry ok: resolves and exports its source name (linear + gc)"
# #3144 round 4: tables keyed by a definition's NAME must agree with the
# rename. A trait impl method binds `<Type>::<method>` (`impl Measured for
# String { length(..) }` defines `String::length`), and the witness / dot-call
# lookups that compute that name missed the moved definition: the witness
# answered the builtin's 3 and `s.length()` trapped. On all three lanes.
if ! VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash scripts/vibe_test.sh fixtures/builtin_shadow_trait_impl_test.vibe \
    >"$ROOT_DIR/_build/_gate_builtin_shadow_trait_impl.log" 2>&1 \
  || ! VIBE_RC=shadow VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash scripts/vibe_test.sh fixtures/builtin_shadow_trait_impl_test.vibe \
    >>"$ROOT_DIR/_build/_gate_builtin_shadow_trait_impl.log" 2>&1 \
  || ! VIBE_TEST_BACKEND=gc VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash scripts/vibe_test.sh fixtures/builtin_shadow_trait_impl_test.vibe \
    >>"$ROOT_DIR/_build/_gate_builtin_shadow_trait_impl.log" 2>&1; then
  echo "[compiler-gate] FAIL: a trait impl method bound at a builtin's name was not reached through its witness or a dot-call (#3144):" >&2
  tail -20 "$ROOT_DIR/_build/_gate_builtin_shadow_trait_impl.log" >&2
  exit 1
fi
rm -f "$ROOT_DIR/_build/_gate_builtin_shadow_trait_impl.log"
echo "[compiler-gate] builtin-named trait impl method dispatch ok (linear + shadow + gc)"
# wasm-gc's native Array-reference ABI reads two name tables against the
# renamed declarations: the pre-erasure GENERIC names (a generic signature is
# excluded) and the `export { .. }` block (a public one is excluded). Either
# one in the source spelling admitted a program's own `Array::length` --
# measured as one native `array.new_default` literal where the same program
# under any other name emits none. Count them: 0.
gadir="_build/_gate_builtin_shadow_gc_abi"
rm -rf "$gadir"; mkdir -p "$gadir"
for ga_fx in fixtures/builtin_shadow_gc_direct_abi_generic_test.vibe fixtures/builtin_shadow_gc_direct_abi_export_test.vibe; do
  ga_out="$gadir/$(basename "$ga_fx" .vibe).wasm"
  env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" "$ga_fx" "$ga_out" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$ga_out" ]; then
    echo "[compiler-gate] FAIL: $ga_fx did not build on wasm-gc (#3144):" >&2
    cat "$ga_out.diag" >&2 2>/dev/null || true
    exit 1
  fi
  ga_native=$(node -e 'const b=require("fs").readFileSync(process.argv[1]);let n=0;for(let i=0;i+2<b.length;i++){if(b[i]===0xfb&&b[i+1]===0x07&&b[i+2]===0x0c)n++}console.log(n)' "$ga_out")
  if [ "$ga_native" != "0" ]; then
    echo "[compiler-gate] FAIL: $ga_fx put a program's own Array::length on the gc native Array-reference ABI ($ga_native native literal(s), expected 0) (#3144)" >&2
    exit 1
  fi
done
rm -rf "$gadir"
echo "[compiler-gate] builtin-named gc direct-ABI tables ok (generic + export block)"

# 40f0. #2837: `Array::truncate` changes the array's LENGTH, not the lifetime
#       of an element someone already took out of it. That is the ownership
#       rule stable-surface.md §2.2a freezes and the one #2837 asks to define
#       before removed elements may be reclaimed -- and it is why the eager
#       drop-on-truncate experiment during #2554 had to be reverted.
#
#       Four shapes at distinct decimal places (plain / aliased through a
#       helper / reserved capacity / nested one level down), on all four
#       lanes, because the issue asks for bump-RC-GC value parity AND the
#       shadow pin. Under VIBE_RC=shadow a drop-of-freed traps on the FIRST
#       occurrence, so a future reclamation change fails loudly here instead
#       of handing back a freed block at an unrelated location.
echo "[compiler-gate] 40f0/40 truncate does not invalidate a saved element view (#2837)"
svdir="_build/_gate_truncate_saved_view"
rm -rf "$svdir"; mkdir -p "$svdir"
for sv_lane in bump rc shadow gc; do
  rm -f "$svdir/sv.wasm" "$svdir/sv.wasm.diag"
  case "$sv_lane" in
    bump) env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_truncate_saved_view_test.vibe" "$svdir/sv.wasm" main >/dev/null 2>&1 || true ;;
    rc) env VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_truncate_saved_view_test.vibe" "$svdir/sv.wasm" main >/dev/null 2>&1 || true ;;
    shadow) env VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_truncate_saved_view_test.vibe" "$svdir/sv.wasm" main >/dev/null 2>&1 || true ;;
    gc) env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_truncate_saved_view_test.vibe" "$svdir/sv.wasm" main >/dev/null 2>&1 || true ;;
  esac
  if [ ! -s "$svdir/sv.wasm" ]; then
    echo "[compiler-gate] FAIL: rc_truncate_saved_view fixture did not compile on the $sv_lane lane (#2837)" >&2
    cat "$svdir/sv.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  sv_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$svdir/sv.wasm" 2>&1 | tail -1)"
  if [ "$sv_out" != "2122312" ]; then
    echo "[compiler-gate] FAIL: rc_truncate_saved_view got '$sv_out' on the $sv_lane lane (want 2122312). Each shape sits at its own decimal place -- 1s plain, 100s aliased, 10000s reserved, 1000000s nested -- so the digit that moved names the one that broke. A trap means a saved element view was freed by a truncation (#2837)." >&2
    exit 1
  fi
done
rm -rf "$svdir"
echo "[compiler-gate] truncate saved-view guard ok (2122312 on bump/rc/shadow/gc)"

# 40f0b. #2837: what a truncate removes is RELEASED on the RC lane, so a
#        fill / truncate / refill loop of owned elements keeps the heap
#        frontier bounded -- and a view read out of the array before the
#        truncate and read after it survives, because the plan pins it.
#        Before the release, the same fixture grew __heap_ptr by 17,777,044 B
#        over its 2000 rounds (8,888 B per round of 100 owned pushes, linear:
#        4,445,044 B at 500 rounds, 35,553,044 B at 4000); with it, 9,844 B at
#        500, 2000 and 4000 rounds alike. The answer (2000 rounds whose saved view still
#        read its own element) is checked on bump, rc, shadow and gc, and the
#        shadow lane traps on the first drop of a freed block.
echo "[compiler-gate] 40f0b/40 truncate releases removed owned elements (#2837)"
trdir="_build/_gate_truncate_reclaim"
rm -rf "$trdir"; mkdir -p "$trdir"
for tr_lane in bump rc shadow gc; do
  rm -f "$trdir/tr.wasm" "$trdir/tr.wasm.diag"
  case "$tr_lane" in
    bump) env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_truncate_reclaim_bounded_test.vibe" "$trdir/tr.wasm" main >/dev/null 2>&1 || true ;;
    rc) env VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_truncate_reclaim_bounded_test.vibe" "$trdir/tr.wasm" main >/dev/null 2>&1 || true ;;
    shadow) env VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_truncate_reclaim_bounded_test.vibe" "$trdir/tr.wasm" main >/dev/null 2>&1 || true ;;
    gc) env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_truncate_reclaim_bounded_test.vibe" "$trdir/tr.wasm" main >/dev/null 2>&1 || true ;;
  esac
  if [ ! -s "$trdir/tr.wasm" ]; then
    echo "[compiler-gate] FAIL: rc_truncate_reclaim_bounded fixture did not compile on the $tr_lane lane (#2837)" >&2
    cat "$trdir/tr.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  tr_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$trdir/tr.wasm" 2>&1 | tail -1)"
  if [ "$tr_out" != "2000" ]; then
    echo "[compiler-gate] FAIL: rc_truncate_reclaim_bounded got '$tr_out' on the $tr_lane lane (want 2000). A smaller count means a saved view read a freed, reused block; a trap means a truncate released an element something still held (#2837)." >&2
    exit 1
  fi
  if [ "$tr_lane" = rc ]; then
    tr_json="$(node scripts/measure_heap.mjs "$trdir/tr.wasm" main 2>/dev/null)"
    tr_used="$(printf '%s' "$tr_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
    if [ -z "$tr_used" ]; then
      echo "[compiler-gate] FAIL: could not measure rc_truncate_reclaim_bounded heap ($tr_json)" >&2; exit 1
    fi
    if [ "$tr_used" -ge 200000 ]; then
      echo "[compiler-gate] FAIL: rc_truncate_reclaim_bounded heap_used=$tr_used >= 200000 (#2837 regressed: a truncate no longer releases the owned elements it removes; unreleased, this fixture measured 17,777,044 B)" >&2; exit 1
    fi
  fi
done
rm -rf "$trdir"
echo "[compiler-gate] truncate reclamation guard ok (2000 on bump/rc/shadow/gc, rc heap_used=$tr_used B)"
# A program's own top-level `Array::truncate` replaces the builtin, so the
# release must not run before it (#3115 review). Under shadow a release
# would trap on the drop of the freed suffix.
if ! VIBE_RC=shadow VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh fixtures/rc_truncate_user_shadow_test.vibe >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: rc_truncate_user_shadow_test failed under VIBE_RC=shadow -- a truncate released elements before calling a user-defined Array::truncate (#3115)" >&2
  exit 1
fi
echo "[compiler-gate] user-defined Array::truncate guard ok on shadow"
if ! VIBE_RC=shadow VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh fixtures/rc_truncate_user_capacity_test.vibe >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: rc_truncate_user_capacity_test failed under VIBE_RC=shadow -- a truncate released elements of an array a user-defined Array::with_capacity returned (#3115)" >&2
  exit 1
fi
echo "[compiler-gate] user-defined Array::with_capacity guard ok on shadow"
# #3114 x #2837: an alias of a pinned view across a released truncate.
if ! VIBE_RC=shadow VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh fixtures/rc_truncate_alias_pin_test.vibe >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: rc_truncate_alias_pin_test failed under VIBE_RC=shadow -- an alias of a pinned view did not survive a released truncate (#3114/#2837)" >&2
  exit 1
fi
echo "[compiler-gate] alias of a pinned view across a released truncate ok on shadow"
# 40f0c. #3114: `let w = v`, where `v` is a borrowed `Array::get` view, got a
#        planned scope-end drop (or a last-use transfer into a consuming call,
#        a push, a return) for a reference it never took, so the element the
#        array still owned was released twice. The shadow lane traps at the
#        second release; the plain RC lane corrupted the free list and died in
#        a later allocation. Nine alias shapes at distinct decimal places, on
#        all four lanes -- gc and bump are the value oracle, shadow is the pin.
#        Above them, nine shapes whose source hands the view back through a
#        block, a `let` chain, or an `if` / `match` / `handle` (#3114 review).
echo "[compiler-gate] 40f0c/40 alias of a borrowed view is not released twice (#3114)"
vadir="_build/_gate_rc_view_alias"
rm -rf "$vadir"; mkdir -p "$vadir"
for va_lane in bump rc shadow gc; do
  rm -f "$vadir/va.wasm" "$vadir/va.wasm.diag"
  case "$va_lane" in
    bump) env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_view_alias_drop_test.vibe" "$vadir/va.wasm" main >/dev/null 2>&1 || true ;;
    rc) env VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_view_alias_drop_test.vibe" "$vadir/va.wasm" main >/dev/null 2>&1 || true ;;
    shadow) env VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_view_alias_drop_test.vibe" "$vadir/va.wasm" main >/dev/null 2>&1 || true ;;
    gc) env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_view_alias_drop_test.vibe" "$vadir/va.wasm" main >/dev/null 2>&1 || true ;;
  esac
  if [ ! -s "$vadir/va.wasm" ]; then
    echo "[compiler-gate] FAIL: rc_view_alias_drop fixture did not compile on the $va_lane lane (#3114)" >&2
    cat "$vadir/va.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  va_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$vadir/va.wasm" 2>&1 | tail -1)"
  if [ "$va_out" != "126354332566498532" ]; then
    echo "[compiler-gate] FAIL: rc_view_alias_drop got '$va_out' on the $va_lane lane (want 126354332566498532). Each alias shape sits at its own decimal place -- see the fixture header for which digit is which. A trap means an alias of a borrowed view released a reference it never took (#3114)." >&2
    exit 1
  fi
done
rm -rf "$vadir"
echo "[compiler-gate] borrowed-view alias guard ok (126354332566498532 on bump/rc/shadow/gc)"

# 40f0d. #3134: `let w = p` inside a loop body, with `p` bound outside the
#        loop, transferred `p`'s one reference into `w` on every iteration,
#        so the first iteration's consumer freed `p` and the next read freed
#        memory (RC answered 529 for 18; shadow trapped). Nine loop shapes at
#        distinct decimal places (while / for / nested / `loop` with continue
#        and break, parameter and outer-let sources, chain, push, consumed
#        twice), on all four lanes; the release side is the unit-lane
#        rc_loop_carried_alias_release_test.vibe.
echo "[compiler-gate] 40f0d/40 alias of a loop-carried binding is retained per iteration (#3134)"
lcdir="_build/_gate_rc_loop_carried_alias"
rm -rf "$lcdir"; mkdir -p "$lcdir"
for lc_lane in bump rc shadow gc; do
  rm -f "$lcdir/lc.wasm" "$lcdir/lc.wasm.diag"
  case "$lc_lane" in
    bump) env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_loop_carried_alias_test.vibe" "$lcdir/lc.wasm" main >/dev/null 2>&1 || true ;;
    rc) env VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_loop_carried_alias_test.vibe" "$lcdir/lc.wasm" main >/dev/null 2>&1 || true ;;
    shadow) env VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_loop_carried_alias_test.vibe" "$lcdir/lc.wasm" main >/dev/null 2>&1 || true ;;
    gc) env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_loop_carried_alias_test.vibe" "$lcdir/lc.wasm" main >/dev/null 2>&1 || true ;;
  esac
  if [ ! -s "$lcdir/lc.wasm" ]; then
    echo "[compiler-gate] FAIL: rc_loop_carried_alias fixture did not compile on the $lc_lane lane (#3134)" >&2
    cat "$lcdir/lc.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  lc_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$lcdir/lc.wasm" 2>&1 | tail -1)"
  if [ "$lc_out" != "362412181109361818" ]; then
    echo "[compiler-gate] FAIL: rc_loop_carried_alias got '$lc_out' on the $lc_lane lane (want 362412181109361818). Each loop shape owns a two-digit block -- see all_shapes in the fixture. A trap means an alias inside a loop body spent a reference of a binding declared outside it (#3134)." >&2
    exit 1
  fi
done
rm -rf "$lcdir"
echo "[compiler-gate] loop-carried alias guard ok (362412181109361818 on bump/rc/shadow/gc)"

# 40f0e. #3135 / #3134 review: the plan called a `Double` literal scalar while
#        codegen boxes it, so an alias of one inside a loop body took no
#        reference of its own and freed the source's box on the first
#        iteration (RC: memory access out of bounds; shadow: trap).
#        Four shapes at distinct decimal places, on all four lanes.
echo "[compiler-gate] 40f0e/40 alias of a Double literal inside a loop keeps the box alive (#3135)"
dldir="_build/_gate_rc_double_literal_alias"
rm -rf "$dldir"; mkdir -p "$dldir"
for dl_lane in bump rc shadow gc; do
  rm -f "$dldir/dl.wasm" "$dldir/dl.wasm.diag"
  case "$dl_lane" in
    bump) env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_double_literal_alias_test.vibe" "$dldir/dl.wasm" main >/dev/null 2>&1 || true ;;
    rc) env VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_double_literal_alias_test.vibe" "$dldir/dl.wasm" main >/dev/null 2>&1 || true ;;
    shadow) env VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_double_literal_alias_test.vibe" "$dldir/dl.wasm" main >/dev/null 2>&1 || true ;;
    gc) env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_double_literal_alias_test.vibe" "$dldir/dl.wasm" main >/dev/null 2>&1 || true ;;
  esac
  if [ ! -s "$dldir/dl.wasm" ]; then
    echo "[compiler-gate] FAIL: rc_double_literal_alias fixture did not compile on the $dl_lane lane (#3135)" >&2
    cat "$dldir/dl.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  dl_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$dldir/dl.wasm" 2>&1 | tail -1)"
  if [ "$dl_out" != "6333" ]; then
    echo "[compiler-gate] FAIL: rc_double_literal_alias got '$dl_out' on the $dl_lane lane (want 6333). Each shape sits at its own decimal place -- see the fixture header. A trap means an alias of a Double inside a loop released the source's box (#3135)." >&2
    exit 1
  fi
done
rm -rf "$dldir"
echo "[compiler-gate] Double-literal alias guard ok (6333 on bump/rc/shadow/gc)"

# 40f0f. #3137: a `for` at the head of a sequence drops each body value
#        without releasing it, but the plan counted a bare name on the body's
#        result spine as an owning use, so `let d = A(..); for x in ns { d }`
#        leaked `d` whole on every call (and so did a bare `d` statement).
#        Unfixed, the bounded fixture grew __heap_ptr by 448,084 B over its
#        2000 calls (224,084 B at 1000); fixed, 196 B. The answer is checked on
#        bump, rc, shadow and gc; the shadow lane traps on the drop of a freed
#        block. rc_forin_discard_body_test.vibe then checks, on rc and shadow,
#        that every value the plan stopped consuming is still alive after the
#        loop.
#        #3162: the same leak held for a `handle` at the head of a sequence
#        (its handled body and each handler arm) and for a `while` body. With
#        those three shapes added the fixture grew __heap_ptr by 672,172 B on
#        the pre-#3162 compiler; fixed, it stays under the same bound.
echo "[compiler-gate] 40f0f/40 discarded for, handle and while bodies release their heap binding (#3137, #3162)"
fddir="_build/_gate_rc_forin_discard"
rm -rf "$fddir"; mkdir -p "$fddir"
for fd_lane in bump rc shadow gc; do
  rm -f "$fddir/fd.wasm" "$fddir/fd.wasm.diag"
  case "$fd_lane" in
    bump) env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_forin_discard_bounded_test.vibe" "$fddir/fd.wasm" main >/dev/null 2>&1 || true ;;
    rc) env VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_forin_discard_bounded_test.vibe" "$fddir/fd.wasm" main >/dev/null 2>&1 || true ;;
    shadow) env VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_forin_discard_bounded_test.vibe" "$fddir/fd.wasm" main >/dev/null 2>&1 || true ;;
    gc) env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_forin_discard_bounded_test.vibe" "$fddir/fd.wasm" main >/dev/null 2>&1 || true ;;
  esac
  if [ ! -s "$fddir/fd.wasm" ]; then
    echo "[compiler-gate] FAIL: rc_forin_discard_bounded fixture did not compile on the $fd_lane lane (#3137)" >&2
    cat "$fddir/fd.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  fd_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$fddir/fd.wasm" 2>&1 | tail -1)"
  if [ "$fd_out" != "2007000" ]; then
    echo "[compiler-gate] FAIL: rc_forin_discard_bounded got '$fd_out' on the $fd_lane lane (want 2007000). A trap means a discarded for, handle or while body released a binding it never owned (#3137, #3162)." >&2
    exit 1
  fi
  if [ "$fd_lane" = rc ]; then
    fd_json="$(node scripts/measure_heap.mjs "$fddir/fd.wasm" main 2>/dev/null)"
    fd_used="$(printf '%s' "$fd_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
    if [ -z "$fd_used" ]; then
      echo "[compiler-gate] FAIL: could not measure rc_forin_discard_bounded heap ($fd_json)" >&2; exit 1
    fi
    if [ "$fd_used" -ge 20000 ]; then
      echo "[compiler-gate] FAIL: rc_forin_discard_bounded heap_used=$fd_used >= 20000 (#3137 / #3162 regressed: a name a discarded for, handle or while body reads is counted as consumed again, so its binding loses its drop; unfixed, this fixture measured 672,172 B)" >&2; exit 1
    fi
  fi
done
rm -rf "$fddir"
for fd_lane in 1 shadow; do
  if ! VIBE_RC="$fd_lane" VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/rc_forin_discard_body_test.vibe \
      >"$ROOT_DIR/_build/_gate_rc_forin_discard_body.log" 2>&1; then
    echo "[compiler-gate] FAIL: fixtures/rc_forin_discard_body_test.vibe failed with VIBE_RC=$fd_lane (#3137). A trap or a churn string means a value a discarded for body reads was released while still in use:" >&2
    tail -20 "$ROOT_DIR/_build/_gate_rc_forin_discard_body.log" >&2
    exit 1
  fi
done
rm -f "$ROOT_DIR/_build/_gate_rc_forin_discard_body.log"
echo "[compiler-gate] discarded for, handle and while body guard ok (2007000 on bump/rc/shadow/gc, rc heap_used=$fd_used B; body shapes ok on rc + shadow)"

# 40f0g. #3140: `x.f = v` leaked the struct (the plan counted the receiver as
#        an owning use and planned a reference nothing released) and never
#        released the value it overwrote. The receiver is borrowed now, and the
#        store releases the old value where the plan proves no view of it is
#        still read (`plan_setfield_release`). Unfixed, the bounded fixture
#        grew __heap_ptr by 2,383,996 B over its 2000 rounds (1,191,996 B at
#        1000); fixed, 308 B. The answer is checked on bump, rc, shadow and gc;
#        the shadow lane traps on the drop of a freed block.
#        rc_set_field_release_test.vibe then checks, on rc and shadow, both the
#        stores that release and the ones that must not: a view of the old
#        value read before the store, one the caller holds, an iteration over
#        the field, a match on it, a captured or aliased struct.
echo "[compiler-gate] 40f0g/40 a field assignment releases the value it overwrites (#3140)"
sfdir="_build/_gate_rc_set_field"
rm -rf "$sfdir"; mkdir -p "$sfdir"
for sf_lane in bump rc shadow gc; do
  rm -f "$sfdir/sf.wasm" "$sfdir/sf.wasm.diag"
  case "$sf_lane" in
    bump) env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_set_field_bounded_test.vibe" "$sfdir/sf.wasm" main >/dev/null 2>&1 || true ;;
    rc) env VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_set_field_bounded_test.vibe" "$sfdir/sf.wasm" main >/dev/null 2>&1 || true ;;
    shadow) env VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_set_field_bounded_test.vibe" "$sfdir/sf.wasm" main >/dev/null 2>&1 || true ;;
    gc) env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_set_field_bounded_test.vibe" "$sfdir/sf.wasm" main >/dev/null 2>&1 || true ;;
  esac
  if [ ! -s "$sfdir/sf.wasm" ]; then
    echo "[compiler-gate] FAIL: rc_set_field_bounded fixture did not compile on the $sf_lane lane (#3140)" >&2
    cat "$sfdir/sf.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  sf_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$sfdir/sf.wasm" 2>&1 | tail -1)"
  if [ "$sf_out" != "2019000" ]; then
    echo "[compiler-gate] FAIL: rc_set_field_bounded got '$sf_out' on the $sf_lane lane (want 2019000). A trap means a field assignment released a value something still held (#3140)." >&2
    exit 1
  fi
  if [ "$sf_lane" = rc ]; then
    sf_json="$(node scripts/measure_heap.mjs "$sfdir/sf.wasm" main 2>/dev/null)"
    sf_used="$(printf '%s' "$sf_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
    if [ -z "$sf_used" ]; then
      echo "[compiler-gate] FAIL: could not measure rc_set_field_bounded heap ($sf_json)" >&2; exit 1
    fi
    if [ "$sf_used" -ge 20000 ]; then
      echo "[compiler-gate] FAIL: rc_set_field_bounded heap_used=$sf_used >= 20000 (#3140 regressed: a field assignment consumes its receiver again, or no longer releases the value it overwrites; unfixed, this fixture measured 2,383,996 B)" >&2; exit 1
    fi
  fi
done
rm -rf "$sfdir"
for sf_lane in 1 shadow; do
  if ! VIBE_RC="$sf_lane" VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/rc_set_field_release_test.vibe \
      >"$ROOT_DIR/_build/_gate_rc_set_field_release.log" 2>&1; then
    echo "[compiler-gate] FAIL: fixtures/rc_set_field_release_test.vibe failed with VIBE_RC=$sf_lane (#3140). A trap or a churn string means a field assignment released a value a view still reads:" >&2
    tail -20 "$ROOT_DIR/_build/_gate_rc_set_field_release.log" >&2
    exit 1
  fi
done
rm -f "$ROOT_DIR/_build/_gate_rc_set_field_release.log"
echo "[compiler-gate] field assignment release guard ok (2019000 on bump/rc/shadow/gc, rc heap_used=$sf_used B; release/decline shapes ok on rc + shadow)"

# 40f0h. #3141: an early `return` / `break` / `continue` / `throw` jumped
#        past the scope-end drops of every scope it left, so each binding in
#        them leaked on every call that took the exit -- a binding the early
#        path never consumed, the references kept for its later uses, a loop
#        body's binding, a function's bindings on a throw, nested scopes, and
#        a captured cell with its closure. The exit now releases them
#        (rc_exit_release, from the plan's PaExitDrop rows), a `let mut` no
#        closure captures included, stored before the exit or after it or in
#        the loop it leaves (#3181 review). Unfixed, the bounded fixture grew
#        __heap_ptr by 3,888,084 B over its 2000 rounds, and 1,344,212 B with
#        every exit releasing except a `let mut`; fixed, 440 B. The answer is
#        checked on bump, rc, shadow and gc; the shadow lane traps on the
#        drop of a freed block.
#        rc_early_exit_release_test.vibe then checks, on rc and shadow, that
#        what each exit hands out, and every binding it does not leave, is
#        still alive afterwards -- including a `break v` / `continue(a)` of a
#        parameterized loop, which store a value in a slot that outlives the
#        exit (it trapped under shadow when the exit released what that value
#        was a view of).
#        #3168 / #3175: a parameterized loop's result slot was classified
#        from its `0` placeholder, so a discarded loop leaked what `break v`
#        stored and a borrowed `break Array::get(xs, i)` handed out an element
#        its array still owned; a `continue` (or any exit) after a branch that
#        consumed a binding on one path only left it unreleased; and a
#        reassigned `let mut` with a dup budget got no exit row. With those
#        rounds added (loop_discard, loop_brk_body, loop_borrow) the fixture
#        traps on the default, rc and shadow lanes of a stage2 from main at
#        a81ffcb2e (loop_borrow's element is released twice); without
#        loop_borrow it grows __heap_ptr by 1,120,244 B there. Fixed, 472 B.
echo "[compiler-gate] 40f0h/40 an early exit releases the scopes it leaves (#3141, #3168, #3175)"
exdir="_build/_gate_rc_early_exit"
rm -rf "$exdir"; mkdir -p "$exdir"
for ex_lane in bump rc shadow gc; do
  rm -f "$exdir/ex.wasm" "$exdir/ex.wasm.diag"
  case "$ex_lane" in
    bump) env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_early_exit_bounded_test.vibe" "$exdir/ex.wasm" main >/dev/null 2>&1 || true ;;
    rc) env VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_early_exit_bounded_test.vibe" "$exdir/ex.wasm" main >/dev/null 2>&1 || true ;;
    shadow) env VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_early_exit_bounded_test.vibe" "$exdir/ex.wasm" main >/dev/null 2>&1 || true ;;
    gc) env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_early_exit_bounded_test.vibe" "$exdir/ex.wasm" main >/dev/null 2>&1 || true ;;
  esac
  if [ ! -s "$exdir/ex.wasm" ]; then
    echo "[compiler-gate] FAIL: rc_early_exit_bounded fixture did not compile on the $ex_lane lane (#3141)" >&2
    cat "$exdir/ex.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  ex_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$exdir/ex.wasm" 2>&1 | tail -1)"
  if [ "$ex_out" != "2049000" ]; then
    echo "[compiler-gate] FAIL: rc_early_exit_bounded got '$ex_out' on the $ex_lane lane (want 2049000). A trap means an early exit, or a loop's result slot, released a binding it did not own or one still in use (#3141, #3168)." >&2
    exit 1
  fi
  if [ "$ex_lane" = rc ]; then
    ex_json="$(node scripts/measure_heap.mjs "$exdir/ex.wasm" main 2>/dev/null)"
    ex_used="$(printf '%s' "$ex_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
    if [ -z "$ex_used" ]; then
      echo "[compiler-gate] FAIL: could not measure rc_early_exit_bounded heap ($ex_json)" >&2; exit 1
    fi
    if [ "$ex_used" -ge 20000 ]; then
      echo "[compiler-gate] FAIL: rc_early_exit_bounded heap_used=$ex_used >= 20000 (#3141 regressed: an early exit skips the scope-end drops of the scopes it leaves again; unfixed, this fixture measured 3,888,084 B)" >&2; exit 1
    fi
  fi
done
rm -rf "$exdir"
for ex_lane in 1 shadow; do
  if ! VIBE_RC="$ex_lane" VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/rc_early_exit_release_test.vibe \
      >"$ROOT_DIR/_build/_gate_rc_early_exit_release.log" 2>&1; then
    echo "[compiler-gate] FAIL: fixtures/rc_early_exit_release_test.vibe failed with VIBE_RC=$ex_lane (#3141). A trap or a churn string means an early exit released a value still in use:" >&2
    tail -20 "$ROOT_DIR/_build/_gate_rc_early_exit_release.log" >&2
    exit 1
  fi
done
rm -f "$ROOT_DIR/_build/_gate_rc_early_exit_release.log"
echo "[compiler-gate] early exit release guard ok (2049000 on bump/rc/shadow/gc, rc heap_used=$ex_used B; handed-out and outer values alive on rc + shadow)"

# 40f0i. #3184: a `let mut` slot owns what it holds, but a store of a VIEW
#        (`let v = Array::get(xs, 0); cur = v`, a `for` element, an alias or
#        a block ending in one, a conditional handing one back) took no
#        reference of its own, so the view's owner released the value the slot
#        still held; and `cur = p` of an owned binding declared outside the
#        loop the store runs in transferred `p`'s one reference on every
#        iteration, freeing it on the second. A `let mut` initializer had both
#        holes too. Unfixed (a stage2 from the #3181 branch, 9159d7a76) the
#        bounded fixture traps under shadow and answers with reused blocks
#        under rc. #3190: so did a `let` / `let mut` in a loop initialized
#        from a conditional, a match or a block handing back an owned
#        binding from outside the loop, on a stage2 from the #3184 branch
#        (40d32fe86). #3215 adds two more view-store shapes. The answer
#        (88000) is checked on bump, rc, shadow and gc,
#        and the rc lane's heap growth is bounded, so the retains the fix adds
#        are each released again; rc_mut_store_view_test.vibe then checks, on
#        rc and shadow, that what each slot holds is alive where it is read.
echo "[compiler-gate] 40f0i/40 a let mut owns the view or loop-carried binding it stores (#3184)"
msdir="_build/_gate_rc_mut_store_view"
rm -rf "$msdir"; mkdir -p "$msdir"
for ms_lane in bump rc shadow gc; do
  rm -f "$msdir/ms.wasm" "$msdir/ms.wasm.diag"
  case "$ms_lane" in
    bump) env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_mut_store_view_bounded_test.vibe" "$msdir/ms.wasm" main >/dev/null 2>&1 || true ;;
    rc) env VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_mut_store_view_bounded_test.vibe" "$msdir/ms.wasm" main >/dev/null 2>&1 || true ;;
    shadow) env VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_mut_store_view_bounded_test.vibe" "$msdir/ms.wasm" main >/dev/null 2>&1 || true ;;
    gc) env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_mut_store_view_bounded_test.vibe" "$msdir/ms.wasm" main >/dev/null 2>&1 || true ;;
  esac
  if [ ! -s "$msdir/ms.wasm" ]; then
    echo "[compiler-gate] FAIL: rc_mut_store_view_bounded fixture did not compile on the $ms_lane lane (#3184)" >&2
    cat "$msdir/ms.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  ms_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$msdir/ms.wasm" 2>&1 | tail -1)"
  if [ "$ms_out" != "88000" ]; then
    echo "[compiler-gate] FAIL: rc_mut_store_view_bounded got '$ms_out' on the $ms_lane lane (want 88000). A trap, or fewer than 44 per round, means a let or let mut held a value some other binding released (#3184, #3190, #3215)." >&2
    exit 1
  fi
  if [ "$ms_lane" = rc ]; then
    ms_json="$(node scripts/measure_heap.mjs "$msdir/ms.wasm" main 2>/dev/null)"
    ms_used="$(printf '%s' "$ms_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
    if [ -z "$ms_used" ]; then
      echo "[compiler-gate] FAIL: could not measure rc_mut_store_view_bounded heap ($ms_json)" >&2; exit 1
    fi
    if [ "$ms_used" -ge 20000 ]; then
      echo "[compiler-gate] FAIL: rc_mut_store_view_bounded heap_used=$ms_used >= 20000 (#3184: a reference a store took is not released again -- a view retained twice, or a loop-carried binding both retained at the store and still transferred)" >&2; exit 1
    fi
  fi
done
rm -rf "$msdir"
for ms_lane in 1 shadow; do
  if ! VIBE_RC="$ms_lane" VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/rc_mut_store_view_test.vibe \
      >"$ROOT_DIR/_build/_gate_rc_mut_store_view.log" 2>&1; then
    echo "[compiler-gate] FAIL: fixtures/rc_mut_store_view_test.vibe failed with VIBE_RC=$ms_lane (#3184). A trap or a zz string means a let mut slot held a value some other binding released:" >&2
    tail -20 "$ROOT_DIR/_build/_gate_rc_mut_store_view.log" >&2
    exit 1
  fi
done
rm -f "$ROOT_DIR/_build/_gate_rc_mut_store_view.log"
echo "[compiler-gate] let mut store ownership guard ok (88000 on bump/rc/shadow/gc, rc heap_used=$ms_used B; stored values alive on rc + shadow)"

# 40f0i/41. #3191: each of these loop forms previously kept one reference
# per round. Check both the answer and the RC heap so a compensating retain
# cannot conceal a leak behind a correct result.
echo "[compiler-gate] 40f0i/41 loop reference reclamation (#3191)"
lrdir="_build/_gate_rc_loop_reclaim"
rm -rf "$lrdir"; mkdir -p "$lrdir"
for lr_case in for_named_array loop_owning_call match_binder_nested_loop; do
  case "$lr_case" in
    for_named_array) lr_want=12000 ;;
    loop_owning_call) lr_want=88000 ;;
    match_binder_nested_loop) lr_want=4002000 ;;
  esac
  for lr_lane in bump rc shadow gc; do
    rm -f "$lrdir/lr.wasm" "$lrdir/lr.wasm.diag"
    case "$lr_lane" in
      bump) lr_env="" ;;
      rc) lr_env=1 ;;
      shadow) lr_env=shadow ;;
      gc) lr_env=gc ;;
    esac
    if [ "$lr_lane" = gc ]; then
      env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
        bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
        "fixtures/rc_${lr_case}_bounded_test.vibe" "$lrdir/lr.wasm" main >/dev/null 2>&1 || true
    else
      env VIBE_RC="$lr_env" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
        bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
        "fixtures/rc_${lr_case}_bounded_test.vibe" "$lrdir/lr.wasm" main >/dev/null 2>&1 || true
    fi
    if [ ! -s "$lrdir/lr.wasm" ]; then
      echo "[compiler-gate] FAIL: rc_${lr_case}_bounded did not compile on $lr_lane" >&2
      cat "$lrdir/lr.wasm.diag" >&2 2>/dev/null || true
      exit 1
    fi
    lr_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$lrdir/lr.wasm" 2>&1 | tail -1)"
    if [ "$lr_out" != "$lr_want" ]; then
      echo "[compiler-gate] FAIL: rc_${lr_case}_bounded got '$lr_out' on $lr_lane (want $lr_want)" >&2
      exit 1
    fi
    if [ "$lr_lane" = rc ]; then
      lr_json="$(node scripts/measure_heap.mjs "$lrdir/lr.wasm" main 2>/dev/null)"
      lr_used="$(printf '%s' "$lr_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
      if [ -z "$lr_used" ] || [ "$lr_used" -ge 20000 ]; then
        echo "[compiler-gate] FAIL: rc_${lr_case}_bounded heap_used=$lr_used >= 20000 (#3191)" >&2
        exit 1
      fi
      echo "[compiler-gate] rc_${lr_case}_bounded heap_used=$lr_used B"
    fi
  done
done
rm -rf "$lrdir"

# 40f0i/42. #3219: a mutable slot's planned dups belong to the actual
# owning uses, and a collected `for` owns the values stored in its result.
echo "[compiler-gate] 40f0i/42 remaining loop reference reclamation (#3219)"
rl_dir="_build/_gate_rc_remaining_loops"
rm -rf "$rl_dir"; mkdir -p "$rl_dir"
for rl_case in mut_restore_loop mut_shadowed_use for_collect_named_array; do
  case "$rl_case" in
    mut_restore_loop) rl_want=8002000 ;;
    mut_shadowed_use) rl_want=6001000 ;;
    for_collect_named_array) rl_want=4000000 ;;
  esac
  for rl_lane in bump rc shadow gc; do
    rm -f "$rl_dir/rl.wasm" "$rl_dir/rl.wasm.diag"
    case "$rl_lane" in
      bump) rl_env="" ;;
      rc) rl_env=1 ;;
      shadow) rl_env=shadow ;;
      gc) rl_env=gc ;;
    esac
    if [ "$rl_lane" = gc ]; then
      env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
        bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
        "fixtures/rc_${rl_case}_bounded_test.vibe" "$rl_dir/rl.wasm" main >/dev/null 2>&1 || true
    else
      env VIBE_RC="$rl_env" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
        bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
        "fixtures/rc_${rl_case}_bounded_test.vibe" "$rl_dir/rl.wasm" main >/dev/null 2>&1 || true
    fi
    if [ ! -s "$rl_dir/rl.wasm" ]; then
      echo "[compiler-gate] FAIL: rc_${rl_case}_bounded did not compile on $rl_lane" >&2
      cat "$rl_dir/rl.wasm.diag" >&2 2>/dev/null || true
      exit 1
    fi
    rl_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$rl_dir/rl.wasm" 2>&1 | tail -1)"
    if [ "$rl_out" != "$rl_want" ]; then
      echo "[compiler-gate] FAIL: rc_${rl_case}_bounded got '$rl_out' on $rl_lane (want $rl_want)" >&2
      exit 1
    fi
    if [ "$rl_lane" = rc ]; then
      rl_json="$(node scripts/measure_heap.mjs "$rl_dir/rl.wasm" main 2>/dev/null)"
      rl_used="$(printf '%s' "$rl_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
      if [ -z "$rl_used" ] || [ "$rl_used" -ge 20000 ]; then
        echo "[compiler-gate] FAIL: rc_${rl_case}_bounded heap_used=$rl_used >= 20000 (#3219)" >&2
        exit 1
      fi
      echo "[compiler-gate] rc_${rl_case}_bounded heap_used=$rl_used B"
    fi
  done
done
rm -rf "$rl_dir"

# 40f0j. #3135: a `Double` is a heap box on the RC lane, but the plan counted
#        a bare name as an OWNING use when it was an operand of a comparison
#        or of arithmetic, and a `Double` parameter as scalar -- so an
#        operand's last use handed its box to an f64 op that only reads, an
#        earlier use took a dup nobody released, a callee never dropped the
#        box a caller handed its `Double` parameter, and the box of a literal
#        operand, of an intermediate result and of a call's result read by an
#        operator was never freed. An operator's name operand is a borrow now,
#        a `Double` parameter is owned, operands are computed on their bits
#        (emit_float_operand_bits) and a self-reassignment through an operator
#        (`acc = acc + x`) releases the box it replaces. A `while` condition
#        comparing a `Double` no longer takes the integer fast path, which
#        compared box addresses. Unfixed, the bounded fixture grew
#        __heap_ptr by 1,344,120 B over its 2000 rounds without its
#        `while_cmp` shape, and trapped in the allocator with it. The
#        answer is checked on bump, rc, shadow and gc; the shadow lane traps
#        on the drop of a freed block. rc_double_release_test.vibe then
#        checks, on rc and shadow, that every box an operator, a builtin or a
#        callee reads is still alive afterwards.
echo "[compiler-gate] 40f0j/40 a Double an operator or a parameter reads is released (#3135)"
dbdir="_build/_gate_rc_double_release"
rm -rf "$dbdir"; mkdir -p "$dbdir"
for db_lane in bump rc shadow gc; do
  rm -f "$dbdir/db.wasm" "$dbdir/db.wasm.diag"
  case "$db_lane" in
    bump) env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_double_release_bounded_test.vibe" "$dbdir/db.wasm" main >/dev/null 2>&1 || true ;;
    rc) env VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_double_release_bounded_test.vibe" "$dbdir/db.wasm" main >/dev/null 2>&1 || true ;;
    shadow) env VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_double_release_bounded_test.vibe" "$dbdir/db.wasm" main >/dev/null 2>&1 || true ;;
    gc) env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_double_release_bounded_test.vibe" "$dbdir/db.wasm" main >/dev/null 2>&1 || true ;;
  esac
  if [ ! -s "$dbdir/db.wasm" ]; then
    echo "[compiler-gate] FAIL: rc_double_release_bounded fixture did not compile on the $db_lane lane (#3135)" >&2
    cat "$dbdir/db.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  db_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$dbdir/db.wasm" 2>&1 | tail -1)"
  if [ "$db_out" != "29007002" ]; then
    echo "[compiler-gate] FAIL: rc_double_release_bounded got '$db_out' on the $db_lane lane (want 29007002). A trap means a Double box was released while an operator, a builtin or a callee still read it (#3135)." >&2
    exit 1
  fi
  if [ "$db_lane" = rc ]; then
    db_json="$(node scripts/measure_heap.mjs "$dbdir/db.wasm" main 2>/dev/null)"
    db_used="$(printf '%s' "$db_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
    if [ -z "$db_used" ]; then
      echo "[compiler-gate] FAIL: could not measure rc_double_release_bounded heap ($db_json)" >&2; exit 1
    fi
    if [ "$db_used" -ge 20000 ]; then
      echo "[compiler-gate] FAIL: rc_double_release_bounded heap_used=$db_used >= 20000 (#3135 regressed: a Double read by an operator, an inline Double builtin or a Double parameter is leaked again; unfixed, this fixture measured 1,344,120 B)" >&2; exit 1
    fi
  fi
done
rm -rf "$dbdir"
for db_lane in 1 shadow; do
  if ! VIBE_RC="$db_lane" VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/rc_double_release_test.vibe \
      >"$ROOT_DIR/_build/_gate_rc_double_release.log" 2>&1; then
    echo "[compiler-gate] FAIL: fixtures/rc_double_release_test.vibe failed with VIBE_RC=$db_lane (#3135). A trap or a churn value means a Double box was released while still in use:" >&2
    tail -20 "$ROOT_DIR/_build/_gate_rc_double_release.log" >&2
    exit 1
  fi
done
rm -f "$ROOT_DIR/_build/_gate_rc_double_release.log"
echo "[compiler-gate] Double release guard ok (29007002 on bump/rc/shadow/gc, rc heap_used=$db_used B; borrowed and owned boxes alive on rc + shadow)"

# 40f0k. #3169: a handle whose body reaches its `perform` through a call is
#        lowered by evidence passing: the handle passes a FRESH dictionary
#        record of arm closures to each call, and the callee takes it as a
#        parameter typed `__EvDict_<E>`. The plan read that name's first
#        letter, `_`, as "not a type that is heap", so the callee never
#        dropped the dictionary and every handled call leaked it. Unfixed, the
#        bounded fixture grew __heap_ptr by 704,112 B over its 2000 rounds.
#        The answer is checked on bump, rc, shadow and gc; the shadow lane
#        traps on the drop of a freed block. rc_user_effect_handle_test.vibe
#        then checks, on rc and shadow, that a callee performing from a loop,
#        a forwarded dictionary and an arm's captured locals stay alive.
echo "[compiler-gate] 40f0k/40 a user-effect handle releases its evidence dictionary (#3169)"
ehdir="_build/_gate_rc_user_effect_handle"
rm -rf "$ehdir"; mkdir -p "$ehdir"
for eh_lane in bump rc shadow gc; do
  rm -f "$ehdir/eh.wasm" "$ehdir/eh.wasm.diag"
  case "$eh_lane" in
    bump) env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_user_effect_handle_bounded_test.vibe" "$ehdir/eh.wasm" main >/dev/null 2>&1 || true ;;
    rc) env VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_user_effect_handle_bounded_test.vibe" "$ehdir/eh.wasm" main >/dev/null 2>&1 || true ;;
    shadow) env VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_user_effect_handle_bounded_test.vibe" "$ehdir/eh.wasm" main >/dev/null 2>&1 || true ;;
    gc) env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw       bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"       "fixtures/rc_user_effect_handle_bounded_test.vibe" "$ehdir/eh.wasm" main >/dev/null 2>&1 || true ;;
  esac
  if [ ! -s "$ehdir/eh.wasm" ]; then
    echo "[compiler-gate] FAIL: rc_user_effect_handle_bounded fixture did not compile on the $eh_lane lane (#3169)" >&2
    cat "$ehdir/eh.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  eh_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$ehdir/eh.wasm" 2>&1 | tail -1)"
  if [ "$eh_out" != "10005000" ]; then
    echo "[compiler-gate] FAIL: rc_user_effect_handle_bounded got '$eh_out' on the $eh_lane lane (want 10005000). A trap means a callee released an evidence dictionary it did not own, or one still in use (#3169)." >&2
    exit 1
  fi
  if [ "$eh_lane" = rc ]; then
    eh_json="$(node scripts/measure_heap.mjs "$ehdir/eh.wasm" main 2>/dev/null)"
    eh_used="$(printf '%s' "$eh_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
    if [ -z "$eh_used" ]; then
      echo "[compiler-gate] FAIL: could not measure rc_user_effect_handle_bounded heap ($eh_json)" >&2; exit 1
    fi
    if [ "$eh_used" -ge 20000 ]; then
      echo "[compiler-gate] FAIL: rc_user_effect_handle_bounded heap_used=$eh_used >= 20000 (#3169 regressed: a callee's __EvDict_ parameter is scalar to the plan again, so every handled call leaks its dictionary; unfixed, this fixture measured 704,112 B)" >&2; exit 1
    fi
  fi
done
rm -rf "$ehdir"
for eh_lane in 1 shadow; do
  if ! VIBE_RC="$eh_lane" VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/rc_user_effect_handle_test.vibe \
      >"$ROOT_DIR/_build/_gate_rc_user_effect_handle.log" 2>&1; then
    echo "[compiler-gate] FAIL: fixtures/rc_user_effect_handle_test.vibe failed with VIBE_RC=$eh_lane (#3169). A trap or a churn value means an evidence dictionary or a value it reaches was released while still in use:" >&2
    tail -20 "$ROOT_DIR/_build/_gate_rc_user_effect_handle.log" >&2
    exit 1
  fi
done
rm -f "$ROOT_DIR/_build/_gate_rc_user_effect_handle.log"
echo "[compiler-gate] user-effect handle guard ok (10005000 on bump/rc/shadow/gc, rc heap_used=$eh_used B; dictionaries and captured values alive on rc + shadow)"

# 40f0l/40. #3203: the closure environment duplicates its array capture, so the
# defining binding keeps a reference to drop. A self-reading array
# reassignment can release the old slot after constructing a fresh array of
# immediate elements. Before these fixes the 2000 rounds leaked 704,108 B.
echo "[compiler-gate] 40f0l/40 RC local capture and self-reading array release (#3203)"
cldir="_build/_gate_rc_local_closure_capture"
rm -rf "$cldir"; mkdir -p "$cldir"
for cl_lane in bump rc shadow gc; do
  rm -f "$cldir/cl.wasm" "$cldir/cl.wasm.diag"
  case "$cl_lane" in
    bump) env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      fixtures/rc_local_closure_capture_bounded_test.vibe "$cldir/cl.wasm" main >/dev/null 2>&1 || true ;;
    rc) env VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      fixtures/rc_local_closure_capture_bounded_test.vibe "$cldir/cl.wasm" main >/dev/null 2>&1 || true ;;
    shadow) env VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      fixtures/rc_local_closure_capture_bounded_test.vibe "$cldir/cl.wasm" main >/dev/null 2>&1 || true ;;
    gc) env VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      fixtures/rc_local_closure_capture_bounded_test.vibe "$cldir/cl.wasm" main >/dev/null 2>&1 || true ;;
  esac
  if [ ! -s "$cldir/cl.wasm" ]; then
    echo "[compiler-gate] FAIL: rc_local_closure_capture_bounded did not compile on $cl_lane (#3203)" >&2
    cat "$cldir/cl.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  cl_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$cldir/cl.wasm" 2>&1 | tail -1)"
  if [ "$cl_out" != "6003000" ]; then
    echo "[compiler-gate] FAIL: rc_local_closure_capture_bounded got '$cl_out' on $cl_lane (want 6003000; #3203)" >&2
    exit 1
  fi
  if [ "$cl_lane" = rc ]; then
    cl_json="$(node scripts/measure_heap.mjs "$cldir/cl.wasm" main 2>/dev/null)"
    cl_used="$(printf '%s' "$cl_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
    if [ -z "$cl_used" ] || [ "$cl_used" -ge 20000 ]; then
      echo "[compiler-gate] FAIL: rc_local_closure_capture_bounded heap_used=$cl_used >= 20000 (#3203; before: 704108 B)" >&2
      exit 1
    fi
  fi
done
rm -rf "$cldir"
for cl_lane in 1 shadow; do
  if ! VIBE_RC="$cl_lane" VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/rc_local_closure_capture_bounded_test.vibe \
      >"$ROOT_DIR/_build/_gate_rc_local_closure_capture.log" 2>&1; then
    echo "[compiler-gate] FAIL: rc_local_closure_capture_bounded tests failed with VIBE_RC=$cl_lane (#3203)" >&2
    tail -20 "$ROOT_DIR/_build/_gate_rc_local_closure_capture.log" >&2
    exit 1
  fi
done
rm -f "$ROOT_DIR/_build/_gate_rc_local_closure_capture.log"
echo "[compiler-gate] RC local capture and self-reading array release ok (6003000 on all lanes, rc heap_used=$cl_used B; view control alive on rc + shadow)"

# #3199: a discarded call result owns its freshly returned enum and array.
# A wasm drop left 112 B per call live before the RC release (223996 B here).
echo "[compiler-gate] 132/132 RC discarded sequence result release (#3199)"
sqdir="_build/_gate_rc_seq_discard"
rm -rf "$sqdir"; mkdir -p "$sqdir"
for sq_lane in bump rc shadow gc; do
  rm -f "$sqdir/sq.wasm" "$sqdir/sq.wasm.diag"
  case "$sq_lane" in
    bump) sq_env="VIBE_RC=0" ;;
    rc) sq_env="VIBE_RC=1" ;;
    shadow) sq_env="VIBE_RC=shadow" ;;
    gc) sq_env="VIBE_BACKEND=gc" ;;
  esac
  env "$sq_env" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    fixtures/rc_seq_discard_bounded_test.vibe "$sqdir/sq.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$sqdir/sq.wasm" ]; then
    echo "[compiler-gate] FAIL: rc_seq_discard_bounded did not compile on $sq_lane (#3199)" >&2
    cat "$sqdir/sq.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  sq_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$sqdir/sq.wasm" 2>&1 | tail -1)"
  if [ "$sq_out" != "4000" ]; then
    echo "[compiler-gate] FAIL: rc_seq_discard_bounded got '$sq_out' on $sq_lane (want 4000; #3199)" >&2
    exit 1
  fi
  if [ "$sq_lane" = rc ]; then
    sq_json="$(node scripts/measure_heap.mjs "$sqdir/sq.wasm" main 2>/dev/null)"
    sq_used="$(printf '%s' "$sq_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
    if [ -z "$sq_used" ] || [ "$sq_used" -ge 20000 ]; then
      echo "[compiler-gate] FAIL: rc_seq_discard_bounded heap_used=$sq_used >= 20000 (#3199; before: 223996 B)" >&2
      exit 1
    fi
  fi
  rm -f "$sqdir/extended.wasm" "$sqdir/extended.wasm.diag"
  env "$sq_env" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    fixtures/rc_seq_discard_extended_test.vibe "$sqdir/extended.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$sqdir/extended.wasm" ]; then
    echo "[compiler-gate] FAIL: rc_seq_discard_extended did not compile on $sq_lane (#3199)" >&2
    cat "$sqdir/extended.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  sq_extended_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$sqdir/extended.wasm" 2>&1 | tail -1)"
  if [ "$sq_extended_out" != "52000" ]; then
    echo "[compiler-gate] FAIL: rc_seq_discard_extended got '$sq_extended_out' on $sq_lane (want 52000; #3199)" >&2
    exit 1
  fi
  if [ "$sq_lane" = rc ]; then
    sq_extended_json="$(node scripts/measure_heap.mjs "$sqdir/extended.wasm" main 2>/dev/null)"
    sq_extended_used="$(printf '%s' "$sq_extended_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
    if [ -z "$sq_extended_used" ] || [ "$sq_extended_used" -ge 20000 ]; then
      echo "[compiler-gate] FAIL: rc_seq_discard_extended heap_used=$sq_extended_used >= 20000 (#3199; before: 576084 B)" >&2
      exit 1
    fi
  fi
done
rm -rf "$sqdir"
for sq_lane in 1 shadow; do
  if ! VIBE_RC="$sq_lane" VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/rc_seq_discard_bounded_test.vibe fixtures/rc_seq_discard_extended_test.vibe fixtures/rc_seq_discard_borrow_test.vibe \
      >"$ROOT_DIR/_build/_gate_rc_seq_discard.log" 2>&1; then
    echo "[compiler-gate] FAIL: a discarded value leaked or released its owner on VIBE_RC=$sq_lane (#3199):" >&2
    tail -20 "$ROOT_DIR/_build/_gate_rc_seq_discard.log" >&2
    exit 1
  fi
done
rm -f "$ROOT_DIR/_build/_gate_rc_seq_discard.log"
echo "[compiler-gate] RC discarded sequence result ok (4000 + 52000 on all lanes, rc heap_used=$sq_used/$sq_extended_used B; borrows alive on rc + shadow)"

# 40f1a. #2427: the shadow table must not overlap the heap it describes.
#        40f above proves the marks catch a real dup/drop-of-freed; this
#        proves they are marks at all. The table sat at a FIXED 256 MiB while
#        the bump pointer started just above the static data, so any program
#        whose heap reached 256 MiB grew into it -- and the tool then answered
#        from the program's own bytes. Red-proven: against the compiler before
#        the fix this fixture aborts with
#        `drop of freed value at site 1650538809; freed at site 1717920867`,
#        both "sites" being ASCII of its padding string, while VIBE_RC=1
#        answers 418804. The fixture has no RC bug, so the two lanes must
#        agree. It is not named `*_test.vibe` on purpose: it allocates ~400 MB
#        to cross the old table address and belongs in this gate, not in every
#        unit run.
echo "[compiler-gate] 40f1a/40 RC shadow table / heap overlap (#2427)"
lhdir="_build/_gate_rc_shadow_large_heap"
rm -rf "$lhdir"; mkdir -p "$lhdir"
VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/rc_shadow_large_heap.vibe" "$lhdir/shadow.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$lhdir/shadow.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_shadow_large_heap did not compile under VIBE_RC=shadow (#2427)" >&2
  cat "$lhdir/shadow.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
lh_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_WASM_PRE_GROW_PAGES=40000 \
  bash scripts/run_wasm_vibe_host_runner.sh "$lhdir/shadow.wasm" 2>&1 | tail -1)"
if [ "$lh_out" != "418804" ]; then
  echo "[compiler-gate] FAIL: rc_shadow_large_heap got '$lh_out' (want 418804). This fixture has no RC bug: a shadow abort here means the shadow table and the heap overlap again, so VIBE_RC=shadow is reporting the program's own bytes as freed-marks -- see rc_shadow_heap_start in codegen/common_base and #2427." >&2
  exit 1
fi
rm -rf "$lhdir"
echo "[compiler-gate] RC shadow table / heap overlap ok (418804)"

# 40f1b. #2469: the shadow build must lower a render the way the RC build does.
#        A shadow build exists to REPRODUCE an RC bug, so a program that
#        lowers differently under it is a debugging tool that changes the
#        thing being debugged. The shadow entry parsed with plain
#        `lex`/`parse_program`, leaving every node at offset -1, so the
#        checker's offset-keyed typed-lowering tables were empty by
#        construction.
#
#        NO `VIBE_FS_COMPILE=1`, and that is the whole reason this step can
#        fail: the entry #2469 fixes is the DIRECT-SOURCE
#        `compile_source_wasi_only_rc_shadow_impl`, reached from
#        cli_adapter's non-FS_COMPILE branch. With FS_COMPILE set the compile
#        takes the module lane and this probe answers 4116 on a compiler that
#        has none of the fix -- measured against origin/main.
#
#        The probe is the #2462 shape (a lambda bound by a `let`
#        INSIDE a function body), which no syntactic rule reaches -- the table
#        is the whole mechanism. "true" -> 4*1000 + 't'(116) = 4116;
#        "1" -> 1*1000 + '1'(49) = 1049 is the pre-fix answer.
echo "[compiler-gate] 40f1b/40 shadow build typed-lowering tables (#2469)"
tlsdir="_build/_gate_typed_shadow"
rm -rf "$tlsdir"; mkdir -p "$tlsdir"
cat > "$tlsdir/bool_render.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let l = () -> Bool { 1 < 2 }
  let s = __to_string(l())
  String::length(s) * 1000 + String::char_code_at(s, 0)
}
EOF
VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tlsdir/bool_render.vibe" "$tlsdir/shadow.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tlsdir/shadow.wasm" ]; then
  echo "[compiler-gate] FAIL: VIBE_RC=shadow build of the #2469 probe produced no wasm" >&2
  cat "$tlsdir/shadow.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
tls_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$tlsdir/shadow.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$tls_out" != "4116" ]; then
  echo "[compiler-gate] FAIL: VIBE_RC=shadow rendered a Bool as '$tls_out' (want 4116 = \"true\"; 1049 = \"1\" means the shadow entry is back on the unlocated parse and its typed-lowering tables are empty -- #2469)" >&2
  exit 1
fi
rm -rf "$tlsdir"
echo "[compiler-gate] shadow build typed-lowering tables ok (#2469)"

# 40f2. Shadow-RC checked-artifact smoke (#1986).
#      40f covers the #715 shape corpus. That is not enough: the first cut of
#      #1964 (`460e8421c`) double-freed inside railway_rw when the compiled
#      program ran check_program over nontrivial input, and the gate (40d leak
#      guard, 40f shapes, RC parity, selfbuild fixpoint) stayed green. The
#      miscompiled compiler still reproduced itself byte-identically; only
#      the CI unit shards trapped. These three tests are the cheap empirical
#      detectors. Compile them with the just-built stage2 under VIBE_RC=shadow
#      (the same __no_entry__ / _start harness as unit_test_runner) and run
#      them. A trap here is either a failed test assertion or an RC
#      dup/drop under-provision -- `_start` traps the same way for both.
#      This list is closed on purpose -- it is a bounded smoke, not a fixture
#      inventory. Perceus / RC codegen still needs the full unit_test_runner
#      before push (see docs/internal/operations/operation-gate.md).
echo "[compiler-gate] 40f2/40 RC shadow checked-artifact smoke (#1986)"
cadir="_build/_gate_rc_shadow_checked"
rm -rf "$cadir"; mkdir -p "$cadir"
for ca in \
  lib/@vibe/compiler/tests/checked_effective_effect_row_artifact_test.vibe \
  lib/@vibe/compiler/tests/checked_statement_root_type_artifact_test.vibe \
  lib/@vibe/compiler/tests/checked_typed_occurrence_expression_path_observation_test.vibe
do
  [ -f "$ca" ] || { echo "[compiler-gate] FAIL: missing $ca (#1986)" >&2; exit 1; }
  ca_base="$(basename "$ca" .vibe)"
  VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$ca" "$cadir/$ca_base.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$cadir/$ca_base.wasm" ]; then
    echo "[compiler-gate] FAIL: $ca did not compile under VIBE_RC=shadow (#1986)" >&2
    cat "$cadir/$ca_base.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
      --invoke _start "$cadir/$ca_base.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: $ca trapped under VIBE_RC=shadow (#1986). A trap here is either a failed assert in the artifact test or an RC dup/drop accounting bug in the compiled program -- 40f's shape corpus stayed green on the first cut of #1964; these tests run check_program over nontrivial input." >&2
    exit 1
  fi
done
rm -rf "$cadir"
echo "[compiler-gate] RC shadow checked-artifact smoke ok (#1986)"

# 40g. #cfg conditional-compilation guard: the flag-off build must strip the
#      guarded statements entirely (compiles, dev symbols absent -> different
#      program), flag-on builds must select the matching statements.
echo "[compiler-gate] 40g/40 #cfg conditional compilation"
cfdir="_build/_gate_cfg"
rm -rf "$cfdir"; mkdir -p "$cfdir"
VIBE_CFG=dev VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/cfg_flag_test.vibe" "$cfdir/dev.wasm" main >/dev/null 2>&1
cf_dev="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$cfdir/dev.wasm" 2>&1 | tail -1)"
VIBE_CFG=release VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/cfg_flag_test.vibe" "$cfdir/rel.wasm" main >/dev/null 2>&1
cf_rel="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$cfdir/rel.wasm" 2>&1 | tail -1)"
if [ "$cf_dev" != "102" ] || [ "$cf_rel" != "2" ]; then
  echo "[compiler-gate] FAIL: #cfg selection wrong (dev='$cf_dev' want 102, release='$cf_rel' want 2)" >&2
  exit 1
fi
# FS lane (#2513): the flag set must reach IMPORTED modules too (the flags used
# to be appended to the entry source only, so a `#cfg` in a dependency was
# dropped whatever VIBE_CFG said), and a warm compile after switching the flag
# must be a cache miss, never a replay of the other flag's artifacts -- the
# third compile below reuses the cache directory the first two filled.
cat > "$cfdir/dep.vibe" <<'VIBE'
#cfg(dev)
export fn f(x: Int) -> Int { x + 100 }

#cfg(release)
export fn f(x: Int) -> Int { x + 1 }
VIBE
cat > "$cfdir/main.vibe" <<'VIBE'
import ./dep.vibe { f }

fn main() -> Int { f(1) }
VIBE
cf_fs_got=""
for cf_flag in dev release dev; do
  rm -f "$cfdir/fs.wasm" "$cfdir/fs.wasm.diag"
  VIBE_CFG="$cf_flag" VIBE_FS_COMPILE=1 VIBE_BUILD_CACHE_DIR="$cfdir/cache" \
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$cfdir/main.vibe" "$cfdir/fs.wasm" main >/dev/null 2>&1 || true
  if [ -s "$cfdir/fs.wasm" ]; then
    cf_fs_got="$cf_fs_got $(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$cfdir/fs.wasm" 2>&1 | tail -1)"
  else
    cf_fs_got="$cf_fs_got nocompile($(tr '\n' ' ' < "$cfdir/fs.wasm.diag" 2>/dev/null | cut -c1-80))"
  fi
done
if [ "$cf_fs_got" != " 101 2 101" ]; then
  echo "[compiler-gate] FAIL: #cfg on the FS lane (dev, release, warm dev) answered '$cf_fs_got', want ' 101 2 101' (#2513)" >&2
  exit 1
fi
rm -rf "$cfdir"
echo "[compiler-gate] #cfg conditional compilation ok (dev=102 release=2; FS lane + warm switch ok)"

# 40h. wasm-gc backend smoke: the VIBE_BACKEND=gc lane (selfhost port of the
#      gc backend, wired through the adapter) must compile and run the
#      supported-subset fixture identically to the linear backend. Guards the
#      gc/linear builtin-body name split (gc_gen_*) and the annotated-local-
#      lambda distribution on the gc path. See fixtures/gc_backend_smoke_test.vibe
#      for the covered subset and the known gc-lane gaps.
echo "[compiler-gate] 40h/40 wasm-gc backend smoke"
gcdir="_build/_gate_gc"
rm -rf "$gcdir"; mkdir -p "$gcdir"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/gc_backend_smoke_test.vibe" "$gcdir/smoke.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$gcdir/smoke.wasm" ]; then
  echo "[compiler-gate] FAIL: gc backend smoke did not compile under VIBE_BACKEND=gc" >&2
  cat "$gcdir/smoke.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
gc_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcdir/smoke.wasm" 2>&1 | tail -1)"
if [ "$gc_out" != "101556" ]; then
  echo "[compiler-gate] FAIL: gc backend smoke got '$gc_out' (want 101556)" >&2
  exit 1
fi
rm -rf "$gcdir"
echo "[compiler-gate] wasm-gc backend smoke ok (101556)"

# 40h-2. wasm-gc lane: a builtin called from INSIDE a closure must not be
#        collected as a free variable of that closure. `compile_call_gc`
#        dispatches ~60 builtins by spelling and the lambda capture scan has to
#        know the same set; the two lists had drifted (capture scan carried 6),
#        so a lambda calling e.g. `Double::to_i64_bits_lo` died with
#        "reached code generation unresolved" while the SAME call at statement
#        level compiled fine. Every gc fixture called these at the top level,
#        which is why it survived. The fixture also asserts the over-exclusion
#        direction (a real local must still be captured) -- widening the set
#        past namespaced spellings would drop real captures silently, which is
#        worse than the ICE. Runs on BOTH lanes: the bug is gc-only, so linear
#        is the control that proves the fixture is not vacuous.
echo "[compiler-gate] 40h-2/40 wasm-gc closure builtin capture"
gccapdir="_build/_gate_gc_closure_capture"
rm -rf "$gccapdir"; mkdir -p "$gccapdir"
for gccap_lane in linear-rc0 linear-rc1 gc; do
  case "$gccap_lane" in
    linear-rc0) gccap_be=linear; gccap_rc=0 ;;
    linear-rc1) gccap_be=linear; gccap_rc=1 ;;
    gc) gccap_be=gc; gccap_rc=0 ;;
  esac
  env -u VIBE_FS_COMPILE VIBE_RC="$gccap_rc" VIBE_BACKEND="$gccap_be" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/gc_closure_builtin_capture_test.vibe" "$gccapdir/$gccap_lane.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$gccapdir/$gccap_lane.wasm" ]; then
    echo "[compiler-gate] FAIL: gc_closure_builtin_capture_test.vibe did not compile on $gccap_lane" >&2
    cat "$gccapdir/$gccap_lane.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gccapdir/$gccap_lane.wasm" >"$gccapdir/$gccap_lane.out" 2>&1; then
    echo "[compiler-gate] FAIL: gc_closure_builtin_capture_test.vibe failed at run time on $gccap_lane" >&2
    cat "$gccapdir/$gccap_lane.out" >&2
    exit 1
  fi
done
rm -rf "$gccapdir"
echo "[compiler-gate] closure builtin capture ok (linear rc0/rc1 + gc)"

# 40h-3. Same rule reached through a SOURCE ALIAS. `compile_call_gc`
#        canonicalizes the callee before dispatching while the capture scan
#        sees the source spelling, so sharing the direct-ABI list was not
#        enough: `StringBuilder::build` (alias of `StringBuilder::freeze`)
#        matched neither the func table nor the list and was still captured.
#        Runs on BOTH lanes. Linear used to emit an invalid module while
#        reporting a successful compile (#1811).
echo "[compiler-gate] 40h-3/40 wasm-gc closure builtin alias capture"
gcaliasdir="_build/_gate_gc_closure_alias"
rm -rf "$gcaliasdir"; mkdir -p "$gcaliasdir"
for gcalias_lane in linear-rc0 linear-rc1 gc; do
  case "$gcalias_lane" in
    linear-rc0) gcalias_be=linear; gcalias_rc=0 ;;
    linear-rc1) gcalias_be=linear; gcalias_rc=1 ;;
    gc) gcalias_be=gc; gcalias_rc=0 ;;
  esac
  env -u VIBE_FS_COMPILE VIBE_RC="$gcalias_rc" VIBE_BACKEND="$gcalias_be" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/gc_closure_builtin_alias_test.vibe" "$gcaliasdir/$gcalias_lane.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$gcaliasdir/$gcalias_lane.wasm" ]; then
    echo "[compiler-gate] FAIL: gc_closure_builtin_alias_test.vibe did not compile on $gcalias_lane" >&2
    cat "$gcaliasdir/$gcalias_lane.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcaliasdir/$gcalias_lane.wasm" >"$gcaliasdir/$gcalias_lane.out" 2>&1; then
    echo "[compiler-gate] FAIL: gc_closure_builtin_alias_test.vibe failed at run time on $gcalias_lane" >&2
    cat "$gcaliasdir/$gcalias_lane.out" >&2
    exit 1
  fi
done
rm -rf "$gcaliasdir"
echo "[compiler-gate] closure builtin alias capture ok (linear rc0/rc1 + gc)"

# 40h-4. #1814: the gc lane must DECLARE its host ABI in the `vibe.abi` custom
#        section. The node runner picks the decoding convention from that
#        section when VIBE_IMPORT_ABI is unset -- the normal way a built
#        artifact runs -- and falls back to "tagged" without it, so every
#        host-import result came back wrong while the module stayed valid and
#        silent. `Fs::exists` on a MISSING path answered true.
#
#        Deliberately runs the produced modules with NO VIBE_IMPORT_ABI: the
#        point is that the module says so itself. Forcing the env var here
#        would make the gate pass with the section absent.
echo "[compiler-gate] 40h-4/40 wasm-gc host ABI declaration (#1814)"
gcabidir="_build/_gate_gc_host_abi"
rm -rf "$gcabidir"; mkdir -p "$gcabidir"
rm -rf _build/gc_host_abi_probe; mkdir -p _build/gc_host_abi_probe
printf 'hello\n' > _build/gc_host_abi_probe/a.txt
gcabi_out=""
for gcabi_be in linear gc; do
  env -u VIBE_FS_COMPILE VIBE_BACKEND="$gcabi_be" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/gc_host_abi_declaration.vibe" "$gcabidir/$gcabi_be.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$gcabidir/$gcabi_be.wasm" ]; then
    echo "[compiler-gate] FAIL: gc_host_abi_declaration.vibe did not compile on the $gcabi_be backend (#1814)" >&2
    cat "$gcabidir/$gcabi_be.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  gcabi_got="$(env -u VIBE_IMPORT_ABI VIBE_PREOPEN_DIR="$ROOT_DIR" \
    bash scripts/run_wasm_vibe_host_runner.sh "$gcabidir/$gcabi_be.wasm" 2>&1 | tail -1)"
  if [ "$gcabi_be" = "linear" ]; then
    gcabi_out="$gcabi_got"
  elif [ "$gcabi_got" != "$gcabi_out" ]; then
    echo "[compiler-gate] FAIL: gc host-import results disagree with linear: gc='$gcabi_got' linear='$gcabi_out' (#1814)" >&2
    exit 1
  fi
done
# 160 = missing:0 present:1 read_len:6 env_len:0 -- pin the value too, so a
# change that breaks BOTH lanes the same way cannot pass the agreement check.
if [ "$gcabi_out" != "160" ]; then
  echo "[compiler-gate] FAIL: host-import probe returned '$gcabi_out' (want 160) on both lanes (#1814)" >&2
  exit 1
fi
if ! grep -qa "vibe.abi" "$gcabidir/gc.wasm"; then
  echo "[compiler-gate] FAIL: the gc module carries no vibe.abi custom section (#1814)" >&2
  exit 1
fi
rm -rf "$gcabidir" _build/gc_host_abi_probe
echo "[compiler-gate] wasm-gc host ABI declaration ok (linear + gc, =160)"

# 40h-4b. #2759: the STATIC counterpart to the runtime probe below. Adding one
#         host import means editing SIX lists, and `check-host-runtime-contract`
#         -- the one machine check over them -- was its own pkf task inside
#         `release-check` and ran in NO lane of `scripts/compiler_gate.sh`. On
#         #2756 I ran the compiler gate, saw `[compiler-gate] ok`, and treated a
#         change that emits a new import as validated; measured afterwards, that
#         check catches both of the review findings that followed, in sequence,
#         from the first commit. It runs here, next to the runtime probe it is
#         the static half of, and costs well under a second (it reads five
#         files and never touches a stage2).
echo "[compiler-gate] 40h-4b/40 host-runtime ABI contract (#2759)"
python3 scripts/check_host_runtime_contract.py
python3 tests/gates/tooling-accounting/host-runtime/host_runtime_contract_test.py
echo "[compiler-gate] host-runtime ABI contract ok"

# 40h-4c. #2832: the async slot and request BANDS, the static half the
#         contract manifest cannot hold. The manifest pins each async import's
#         NAME and core type; what it cannot pin is that the four per-handle
#         slot regions in component_codegen.vibe are packed exactly (margin
#         zero at three adjacencies today) and that the future request band
#         `[2, 2 + comp_hf_max_handles]` stays below `lc_hs_req_base` -- a
#         relation whose two halves live in DIFFERENT files, which is why
#         linked_compile.vibe's own comment says the bands are disjoint "by
#         construction, not by runtime discipline". Reads two sources, runs in
#         milliseconds, touches no stage2. Its red test is
#         scripts/check_async_band_contract_test.sh, which the gate-self-test
#         ratchet runs -- not repeated here.
echo "[compiler-gate] 129/129 async slot and request bands (#2832)"
bash scripts/check_async_band_contract.sh

# 40h-5. #1262: the gc lane's host-import surface, extended by five builtins
#        that were "unknown constructor or function" there. Runs with NO
#        VIBE_IMPORT_ABI for the same reason as 40h-4 -- the module declares
#        its own ABI, and forcing the variable would hide a regression in that
#        declaration.
#
#        Every check is an affirmative/negative PAIR. Under #1814's mis-decode
#        these builtins agreed with linear on the affirmative case and
#        disagreed on the negative one, so a one-sided fixture stayed green
#        through the whole bug.
echo "[compiler-gate] 40h-5/40 wasm-gc host builtins (#1262)"
gchbdir="_build/_gate_gc_host_builtins"
rm -rf "$gchbdir"; mkdir -p "$gchbdir"
gchb_out=""
for gchb_be in linear gc; do
  rm -rf _build/gc_host_builtins_probe
  mkdir -p _build/gc_host_builtins_probe/adir _build/gc_host_builtins_probe/rd _build/gc_host_builtins_probe/rd_empty
  # #2738: Fs::remove_file must REFUSE this one. Recreated per lane because
  # the probe root is wiped above -- a leftover directory would let a
  # tree-removing remove_file pass on the second lane.
  mkdir -p _build/gc_host_builtins_probe/rfdir
  printf 'keep\n' > _build/gc_host_builtins_probe/rfdir/inside
  # #2758: Fs::remove_tree must REMOVE this one, contents and all -- the
  # opposite demand to rfdir above, and the pair that separates the two
  # builtins on the recursion axis now that Fs::remove is non-recursive on
  # both hosts. Nested, so a remove_tree that only unlinks the leaf fails.
  mkdir -p _build/gc_host_builtins_probe/rtdir/nested
  printf 'gone\n' > _build/gc_host_builtins_probe/rtdir/nested/inside
  printf 'hello\n' > _build/gc_host_builtins_probe/a.txt
  printf 'x\n' > _build/gc_host_builtins_probe/rd/f1
  printf 'y\n' > _build/gc_host_builtins_probe/rd/f2
  env -u VIBE_FS_COMPILE VIBE_BACKEND="$gchb_be" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/gc_host_builtins.vibe" "$gchbdir/$gchb_be.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$gchbdir/$gchb_be.wasm" ]; then
    echo "[compiler-gate] FAIL: gc_host_builtins.vibe did not compile on the $gchb_be backend (#1262)" >&2
    cat "$gchbdir/$gchb_be.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  gchb_got="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gchbdir/$gchb_be.wasm" 2>&1 | tail -1)"
  if [ "$gchb_be" = "linear" ]; then
    gchb_out="$gchb_got"
  elif [ "$gchb_got" != "$gchb_out" ]; then
    echo "[compiler-gate] FAIL: gc host builtins disagree with linear: gc='$gchb_got' linear='$gchb_out' (#1262)" >&2
    exit 1
  fi
done
# Pin the value too: agreement alone passes when BOTH lanes break the same way.
gchb_want="gc-host-builtins:10101010202101011"
if [ "$gchb_out" != "$gchb_want" ]; then
  echo "[compiler-gate] FAIL: gc host builtin probe returned '$gchb_out' (want $gchb_want) on both lanes (#1262)" >&2
  exit 1
fi
# Console::write_stream / write_char are aliases onto the stdout imports.
# The gc host table used to register only Stdout::write_stream, so
# @vibe/console's print compiled on linear and died in gc codegen.
printf '%s\n' 'fn main() -> Int allows Console {' '  Console::write_char(99)' '  Console::write_stream("onsole-gc")' '  1' '}' > "$gchbdir/console_write.vibe"
for gchb_be in linear gc; do
  env -u VIBE_FS_COMPILE VIBE_BACKEND="$gchb_be" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$gchbdir/console_write.vibe" "$gchbdir/console_$gchb_be.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$gchbdir/console_$gchb_be.wasm" ]; then
    echo "[compiler-gate] FAIL: Console::write_stream did not compile on the $gchb_be backend" >&2
    cat "$gchbdir/console_$gchb_be.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  gchb_con="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gchbdir/console_$gchb_be.wasm" 2>&1 | tail -1)"
  if [ "$gchb_con" != "console-gc1" ]; then
    echo "[compiler-gate] FAIL: Console write on $gchb_be returned '$gchb_con' (want console-gc1)" >&2
    exit 1
  fi
done
# `Fs::readdir` inside a CLOSURE, kept as its own check rather than folded
# into the fixture value. The surface rewrite is guarded on the name not
# resolving to anything real, and the gc capture scan collected `Fs::readdir`
# as a free variable -- which made that guard false and skipped the rewrite,
# so the call died with "unknown constructor or function" one lambda deep
# while the top-level call worked. Listing it as a direct-ABI spelling is what
# fixes it, and this is the shape that says so.
printf 'let main = () -> Int with Fs { let f = (p: String) -> Int { Array::length(Fs::readdir(p)) }; f("_build/gc_host_builtins_probe/rd") }\n' > "$gchbdir/rdclosure.vibe"
rm -rf _build/gc_host_builtins_probe
mkdir -p _build/gc_host_builtins_probe/rd
printf 'x\n' > _build/gc_host_builtins_probe/rd/f1
printf 'y\n' > _build/gc_host_builtins_probe/rd/f2
env -u VIBE_FS_COMPILE VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gchbdir/rdclosure.vibe" "$gchbdir/rdclosure.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$gchbdir/rdclosure.wasm" ]; then
  echo "[compiler-gate] FAIL: Fs::readdir inside a closure did not compile on the gc lane -- is it still listed in gc_direct_abi_names()? (#1262)" >&2
  cat "$gchbdir/rdclosure.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
gchb_rd="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gchbdir/rdclosure.wasm" 2>&1 | tail -1)"
if [ "$gchb_rd" != "2" ]; then
  echo "[compiler-gate] FAIL: Fs::readdir inside a closure returned '$gchb_rd' (want 2) on the gc lane (#1262)" >&2
  exit 1
fi
rm -rf "$gchbdir" _build/gc_host_builtins_probe
echo "[compiler-gate] wasm-gc host builtins ok (linear + gc, =$gchb_want; readdir incl. empty dir and closure)"

# 40h-6. ADR-0090 (#1262): `region r { .. }` on the gc lane, arena-free tier.
#        Correctness lives in the source-level rewrites; the arena is the
#        reclamation optimization on top of them. This asserts the gc lane
#        RUNS regions, and agrees with linear while doing it.
#
#        The EXPECTED VALUES live in the fixture as `inspect(..)` snapshots,
#        not here: `vibe test --update` maintains them and running the fixture
#        on its own says whether they hold. What this section adds is the part
#        a snapshot cannot express -- that BOTH backends satisfy it. So it
#        runs the fixture's own test block on each lane instead of restating
#        the number.
#
#        The fixture's load-bearing shapes -- a copy-out that must not alias,
#        and a region inside a lambda (plus a nested one, whose inner body is
#        itself a lambda) -- are the ones that pass a top-level-only or
#        identity-cast implementation. See the fixture header.
echo "[compiler-gate] 40h-6/40 wasm-gc region (arena-free tier, #1262)"
gcrgdir="_build/_gate_gc_region"
rm -rf "$gcrgdir"; mkdir -p "$gcrgdir"
for gcrg_be in linear gc; do
  env -u VIBE_FS_COMPILE VIBE_BACKEND="$gcrg_be" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/gc_region_arena_free.vibe" "$gcrgdir/$gcrg_be.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$gcrgdir/$gcrg_be.wasm" ]; then
    echo "[compiler-gate] FAIL: gc_region_arena_free.vibe did not compile on the $gcrg_be backend (#1262)" >&2
    cat "$gcrgdir/$gcrg_be.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcrgdir/$gcrg_be.wasm" >"$gcrgdir/$gcrg_be.out" 2>&1; then
    echo "[compiler-gate] FAIL: gc_region_arena_free.vibe's inspect snapshots did not hold on the $gcrg_be backend (#1262)" >&2
    tail -20 "$gcrgdir/$gcrg_be.out" >&2
    exit 1
  fi
done
rm -rf "$gcrgdir"
echo "[compiler-gate] wasm-gc region ok (linear + gc snapshots; copy-out, nested, in-lambda)"
