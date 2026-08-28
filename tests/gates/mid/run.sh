#!/usr/bin/env bash
# compiler-gate lane: mid (#1849 / #2001 Phase 1).
# Invoked by scripts/compiler_gate.sh or directly:
#   bash tests/gates/mid/run.sh
set -euo pipefail
# shellcheck source=../lib.sh
GATES_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck disable=SC1090
source "$GATES_LIB"
gate_resolve_stage2

# ADR-0068 (#2248): `@vibe/concurrent` needs `VIBE_UNSTABLE=1` to compile at
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
#     docs/simd-data-structures.md 3.1). A retired surface that quietly comes
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
  cat "$vdir/out.txt" "$vdir/v128.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$swdir/sw.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$sssdir/sss.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$sledir/sle.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$rcdir/rc.wasm.diag" 2>/dev/null >&2 || true
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

fn main() -> Int with Fs {
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
    cat "$mhdir/emit.wasm.diag" 2>/dev/null >&2 || true
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

fn main() -> Int with Fs {
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
    cat "$asdir/emit.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$hsdir/handler.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$shdir/sh.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$lkdir/rc.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
lk_json="$(node scripts/measure_heap.mjs "$lkdir/rc.wasm" main 2>/dev/null)"
lk_used="$(printf '%s' "$lk_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
lk_result="$(printf '%s' "$lk_json" | sed -n 's/.*"result":\([0-9]*\).*/\1/p')"
if [ -z "$lk_used" ]; then
  echo "[compiler-gate] FAIL: could not measure rc_reclaim_leak heap ($lk_json)" >&2; exit 1
fi
if [ "$lk_result" != "3200400000" ]; then
  echo "[compiler-gate] FAIL: rc_reclaim_leak wrong result $lk_result (want 3200400000)" >&2; exit 1
fi
if [ "$lk_used" -ge 2000 ]; then
  echo "[compiler-gate] FAIL: rc_reclaim_leak heap_used=$lk_used >= 2000 (RC reclamation regressed; ~800000 == full leak)" >&2; exit 1
fi
rm -rf "$lkdir"
echo "[compiler-gate] RC reclamation leak guard ok (heap_used=$lk_used B at N=20000)"

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
  cat "$shdir/shadow.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
sh_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$shdir/shadow.wasm" 2>&1 | tail -1)"
if [ "$sh_out" != "25297489" ]; then
  echo "[compiler-gate] FAIL: rc_shadow_regression got '$sh_out' (want 25297489). A trap here means an RC dup/drop accounting regression touched a freed block -- see fixtures/rc_shadow_regression_test.vibe for which shapes are covered and issue #715 for the debugging methodology." >&2
  exit 1
fi
rm -rf "$shdir"
echo "[compiler-gate] RC shadow-liveness regression guard ok (25297489)"

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
#      before push (see docs/operation-gate.md).
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
    cat "$cadir/$ca_base.wasm.diag" 2>/dev/null >&2 || true
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
rm -rf "$cfdir"
echo "[compiler-gate] #cfg conditional compilation ok (dev=102 release=2)"

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
  cat "$gcdir/smoke.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
gc_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcdir/smoke.wasm" 2>&1 | tail -1)"
if [ "$gc_out" != "101557" ]; then
  echo "[compiler-gate] FAIL: gc backend smoke got '$gc_out' (want 101557)" >&2
  exit 1
fi
rm -rf "$gcdir"
echo "[compiler-gate] wasm-gc backend smoke ok (101557)"

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
    cat "$gccapdir/$gccap_lane.wasm.diag" 2>/dev/null >&2 || true
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
    cat "$gcaliasdir/$gcalias_lane.wasm.diag" 2>/dev/null >&2 || true
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
    cat "$gcabidir/$gcabi_be.wasm.diag" 2>/dev/null >&2 || true
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
  printf 'hello\n' > _build/gc_host_builtins_probe/a.txt
  printf 'x\n' > _build/gc_host_builtins_probe/rd/f1
  printf 'y\n' > _build/gc_host_builtins_probe/rd/f2
  env -u VIBE_FS_COMPILE VIBE_BACKEND="$gchb_be" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/gc_host_builtins.vibe" "$gchbdir/$gchb_be.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$gchbdir/$gchb_be.wasm" ]; then
    echo "[compiler-gate] FAIL: gc_host_builtins.vibe did not compile on the $gchb_be backend (#1262)" >&2
    cat "$gchbdir/$gchb_be.wasm.diag" 2>/dev/null >&2 || true
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
if [ "$gchb_out" != "gc-host-builtins:10101010202" ]; then
  echo "[compiler-gate] FAIL: gc host builtin probe returned '$gchb_out' (want gc-host-builtins:10101010202) on both lanes (#1262)" >&2
  exit 1
fi
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
  cat "$gchbdir/rdclosure.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
gchb_rd="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gchbdir/rdclosure.wasm" 2>&1 | tail -1)"
if [ "$gchb_rd" != "2" ]; then
  echo "[compiler-gate] FAIL: Fs::readdir inside a closure returned '$gchb_rd' (want 2) on the gc lane (#1262)" >&2
  exit 1
fi
rm -rf "$gchbdir" _build/gc_host_builtins_probe
echo "[compiler-gate] wasm-gc host builtins ok (linear + gc, =10101010202; readdir incl. empty dir and closure)"

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
    cat "$gcrgdir/$gcrg_be.wasm.diag" 2>/dev/null >&2 || true
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

# 40h-6b. ADR-0090 tier 2 (#1262): the ARENA on the gc lane -- and this section
#         exists because the value assertions above cannot see it fail.
#
#         Measured, not asserted by value: an arena that quietly stops
#         releasing still returns every correct number, so 40h-6 and
#         region_arena_release_ok both stay green while the reclamation is
#         gone. That is not hypothetical -- the first wiring of this arena was
#         correct and reclaimed NOTHING (1,635,208 B, i.e. the pre-arena
#         figure) because MutList storage came from the segment while every
#         doubling regrow buffer still went to the main heap. Only this
#         measurement caught it.
#
#         gc is direct-source-compile only, so no VIBE_FS_COMPILE here (it
#         would silently force the linear lane -- see docs/wasm/
#         code-size-linear-vs-gc.md).
echo "[compiler-gate] 40h-6b/40 wasm-gc region arena reclamation (#1262)"
gcardir="_build/_gate_gc_arena"
rm -rf "$gcardir"; mkdir -p "$gcardir"
env -u VIBE_FS_COMPILE VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/region_arena_bounded.vibe" "$gcardir/bounded.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$gcardir/bounded.wasm" ]; then
  echo "[compiler-gate] FAIL: region_arena_bounded.vibe did not compile on the gc backend (#1262)" >&2
  cat "$gcardir/bounded.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! gcar_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$gcardir/bounded.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_arena_bounded.vibe got the wrong value on the gc backend (#1262)" >&2
  echo "$gcar_out" >&2
  exit 1
fi
gcar_delta="$(node scripts/region_arena_heap_delta.mjs "$gcardir/bounded.wasm")" || {
  echo "[compiler-gate] FAIL: could not read __heap_ptr from the gc region_arena_bounded.wasm (#1262)" >&2
  exit 1
}
# Same bound as the linear section, and deliberately just as loose: it only
# has to separate "releases" from "does not". Measured 3,208 B with the arena
# against 1,635,208 B without, so anything near the bound means the regrow
# lane or the watermark restore regressed.
if [ "$gcar_delta" -gt 100000 ]; then
  echo "[compiler-gate] FAIL: 200 gc regions grew the main bump heap by $gcar_delta B (want < 100000; ~3208 with the arena, 1635208 without) -- the gc arena stopped releasing (#1262)" >&2
  exit 1
fi
# The Bytes half, measured separately. Not redundant with the Array probe
# above: the two have INDEPENDENT regrow generators (gen_arr_push_body vs
# gen_bytes_push_body / gen_bytes_append_body), so wiring one to the arena and
# leaving the other on -1 is a real state -- and was the actual state of this
# branch until review caught it (182,408 B here while the Array probe already
# read 3,208 B).
env -u VIBE_FS_COMPILE VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/region_bytes_arena_bounded.vibe" "$gcardir/bbounded.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$gcardir/bbounded.wasm" ]; then
  echo "[compiler-gate] FAIL: region_bytes_arena_bounded.vibe did not compile on the gc backend (#1262)" >&2
  cat "$gcardir/bbounded.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! gcarb_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$gcardir/bbounded.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_bytes_arena_bounded.vibe got the wrong value on the gc backend (#1262)" >&2
  echo "$gcarb_out" >&2
  exit 1
fi
gcarb_delta="$(node scripts/region_arena_heap_delta.mjs "$gcardir/bbounded.wasm")" || {
  echo "[compiler-gate] FAIL: could not read __heap_ptr from the gc region_bytes_arena_bounded.wasm (#1262)" >&2
  exit 1
}
if [ "$gcarb_delta" -gt 100000 ]; then
  echo "[compiler-gate] FAIL: 200 gc Bytes regions grew the main bump heap by $gcarb_delta B (want < 100000; ~8000 with the arena, 182408 with the regrow lane off) -- the gc Bytes arena stopped releasing (#1262)" >&2
  exit 1
fi
rm -rf "$gcardir"
echo "[compiler-gate] wasm-gc region arena ok (reclamation measured: Array ${gcar_delta} B, Bytes ${gcarb_delta} B over 200 regions)"

# 40h-6c. #1937: exception unwind through a region must restore depth.
#         70 punches exceed the 64-slot save table. Values stay correct
#         either way; only the heap delta sees a skipped exit. Seed
#         without the wrap leaked 574708 B; with it the residual is the
#         per-call region-lambda closure on the main heap.
echo "[compiler-gate] 40h-6c/40 wasm-gc region exception-unwind restore (#1937)"
gcarudir="_build/_gate_gc_arena_unwind"
rm -rf "$gcarudir"; mkdir -p "$gcarudir"
# Entry is `main`, not `__no_entry__`: this file also pins nested-handle
# rethrow, and that shape is a pre-existing gc EHandle hole (handler throw
# is not seen by an outer handle, with or without a region). `main` is the
# 70-punch loop the heap delta observes.
env -u VIBE_FS_COMPILE VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/region_throw_unwind_test.vibe" "$gcarudir/unwind.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$gcarudir/unwind.wasm" ]; then
  echo "[compiler-gate] FAIL: region_throw_unwind_test.vibe did not compile on the gc backend (#1937)" >&2
  cat "$gcarudir/unwind.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! gcaru_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$gcarudir/unwind.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_throw_unwind_test.vibe main got the wrong value on the gc backend (#1937)" >&2
  echo "$gcaru_out" >&2
  exit 1
fi
gcaru_delta="$(node --experimental-wasm-exnref scripts/region_arena_heap_delta.mjs "$gcarudir/unwind.wasm")" || {
  echo "[compiler-gate] FAIL: could not read __heap_ptr from the gc region_throw_unwind_test.wasm (#1937)" >&2
  exit 1
}
if [ "$gcaru_delta" -gt 150000 ]; then
  echo "[compiler-gate] FAIL: 70 gc throw-through regions grew the main bump heap by $gcaru_delta B (want < 150000; seed without the wrap leaked 574708) -- region exit skipped on unwind (#1937)" >&2
  exit 1
fi
rm -rf "$gcarudir"
echo "[compiler-gate] wasm-gc region exception-unwind ok (reclamation measured: ${gcaru_delta} B over 70 punches)"

# 40h-8. #1262: `Map::delete` on the gc lane.
#
#        Unlike the region / MutList / MutBytes lowerings, this one is not a
#        shared AST rewrite -- linear emits wasm directly, so the gc arm is a
#        hand-port. That makes lane AGREEMENT the thing worth gating: a port
#        can look right and copy the wrong 8 bytes.
#
#        Expected values live in the fixture as `inspect(..)` snapshots (see
#        40h-6 for why). This section runs that same block on both lanes.
echo "[compiler-gate] 40h-8/40 wasm-gc Map::delete (#1262)"
gcmddir="_build/_gate_gc_map_delete"
rm -rf "$gcmddir"; mkdir -p "$gcmddir"
gcmd_out=""
for gcmd_be in linear gc; do
  env -u VIBE_FS_COMPILE VIBE_BACKEND="$gcmd_be" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/gc_map_delete.vibe" "$gcmddir/$gcmd_be.snap.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$gcmddir/$gcmd_be.snap.wasm" ]; then
    echo "[compiler-gate] FAIL: gc_map_delete.vibe did not compile on the $gcmd_be backend (#1262)" >&2
    cat "$gcmddir/$gcmd_be.snap.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcmddir/$gcmd_be.snap.wasm" >"$gcmddir/$gcmd_be.snap.out" 2>&1; then
    echo "[compiler-gate] FAIL: gc_map_delete.vibe's inspect snapshots did not hold on the $gcmd_be backend (#1262)" >&2
    tail -20 "$gcmddir/$gcmd_be.snap.out" >&2
    exit 1
  fi
  # The snapshots above already pin each case; this run exists so a lane that
  # somehow satisfies them and still diverges at the entry point is caught.
  env -u VIBE_FS_COMPILE VIBE_BACKEND="$gcmd_be" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/gc_map_delete.vibe" "$gcmddir/$gcmd_be.wasm" main >/dev/null 2>&1
  gcmd_got="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcmddir/$gcmd_be.wasm" 2>&1 | tail -1)"
  if [ "$gcmd_be" = "linear" ]; then
    gcmd_out="$gcmd_got"
  elif [ "$gcmd_got" != "$gcmd_out" ]; then
    echo "[compiler-gate] FAIL: gc Map::delete results disagree with linear: gc='$gcmd_got' linear='$gcmd_out' (#1262)" >&2
    exit 1
  fi
done
if [ -z "$gcmd_out" ]; then
  echo "[compiler-gate] FAIL: gc_map_delete.vibe main produced no output on either lane (#1262)" >&2
  exit 1
fi
rm -rf "$gcmddir"
echo "[compiler-gate] wasm-gc Map::delete ok (linear + gc snapshots; middle-entry compaction, functional source, reuse)"

# 40h-7. #1262: `Stdin::read_char` / `Stdin::read_stream` / `Int::parse` on the
#        gc lane. The stdin pair was held back in #1823 because the harness
#        fed neither lane any input, so both returned EOF and agreement proved
#        nothing. The feed is VIBE_STDIN_BYTES (an env var, not piped stdin),
#        so this section drives REAL input through both lanes and compares.
#
#        The fixture's own inspect snapshots carry the Int::parse expectations
#        (they need no stdin); the stdin half needs a fed run, which a snapshot
#        cannot express, so that part is compared lane-to-lane here.
echo "[compiler-gate] 40h-7/40 wasm-gc stdin + Int::parse (#1262)"
gcsidir="_build/_gate_gc_stdin"
rm -rf "$gcsidir"; mkdir -p "$gcsidir"
gcsi_out=""
for gcsi_be in linear gc; do
  env -u VIBE_FS_COMPILE VIBE_BACKEND="$gcsi_be" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/gc_stdin_int_parse.vibe" "$gcsidir/$gcsi_be.snap.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$gcsidir/$gcsi_be.snap.wasm" ]; then
    echo "[compiler-gate] FAIL: gc_stdin_int_parse.vibe did not compile on the $gcsi_be backend (#1262)" >&2
    cat "$gcsidir/$gcsi_be.snap.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcsidir/$gcsi_be.snap.wasm" >"$gcsidir/$gcsi_be.snap.out" 2>&1; then
    echo "[compiler-gate] FAIL: gc_stdin_int_parse.vibe's inspect snapshots did not hold on the $gcsi_be backend (#1262)" >&2
    tail -20 "$gcsidir/$gcsi_be.snap.out" >&2
    exit 1
  fi
  env -u VIBE_FS_COMPILE VIBE_BACKEND="$gcsi_be" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/gc_stdin_int_parse.vibe" "$gcsidir/$gcsi_be.wasm" main >/dev/null 2>&1
  gcsi_got="$(VIBE_STDIN_BYTES=AB VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcsidir/$gcsi_be.wasm" 2>&1 | tail -1)"
  if [ "$gcsi_be" = "linear" ]; then
    gcsi_out="$gcsi_got"
  elif [ "$gcsi_got" != "$gcsi_out" ]; then
    echo "[compiler-gate] FAIL: gc stdin results disagree with linear: gc='$gcsi_got' linear='$gcsi_out' (#1262)" >&2
    exit 1
  fi
done
# 65,066 = two distinct bytes read in order (a cursor that never advanced
# would give 65,065). Pinned so both lanes breaking the same way still fails.
if [ "$gcsi_out" != "65066123452" ]; then
  echo "[compiler-gate] FAIL: stdin probe returned '$gcsi_out' (want 65066123452) on both lanes (#1262)" >&2
  exit 1
fi
rm -rf "$gcsidir"
echo "[compiler-gate] wasm-gc stdin + Int::parse ok (linear + gc, real input via VIBE_STDIN_BYTES)"

# 40h-9. #1262: `vibe_process_exit_raw` on the gc lane -- the gc self-build's
#        stopping point. Every builtin LOWERING was already in place; the host
#        import itself was missing, so codegen reached an unresolved name.
#
#        Checked as a PROCESS EXIT STATUS, not a returned value. A lowering
#        that evaluated its argument and fell through would run the program to
#        completion and exit 0, and no value assertion downstream of the call
#        can see that -- the call is supposed to be the last thing that
#        happens. 7 is picked because nothing else produces it: a trap exits
#        134, an uncaught throw exits 1, a clean fallthrough exits 0.
echo "[compiler-gate] 40h-9/40 wasm-gc process exit (#1262)"
gcpedir="_build/_gate_gc_process_exit"
rm -rf "$gcpedir"; mkdir -p "$gcpedir"
for gcpe_be in linear gc; do
  env -u VIBE_FS_COMPILE VIBE_BACKEND="$gcpe_be" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/gc_process_exit.vibe" "$gcpedir/$gcpe_be.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$gcpedir/$gcpe_be.wasm" ]; then
    echo "[compiler-gate] FAIL: gc_process_exit.vibe did not compile on the $gcpe_be backend (#1262)" >&2
    cat "$gcpedir/$gcpe_be.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  # SUCCESS here is a NON-ZERO status (7), so the exit code is DATA -- read it
  # with gate_status (see the helper's header for what a bare call did).
  gate_status gcpe_rc env VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcpedir/$gcpe_be.wasm"
  if [ "$gcpe_rc" -ne 7 ]; then
    echo "[compiler-gate] FAIL: gc_process_exit.vibe exited $gcpe_rc on the $gcpe_be backend (want 7; 0 = the exit lowering is a no-op and the program fell through) (#1262)" >&2
    exit 1
  fi
done
rm -rf "$gcpedir"
echo "[compiler-gate] wasm-gc process exit ok (linear + gc, exit status 7)"

# 40h-10. #1985: sibling control-flow scopes share local slot numbers on the gc
#         lane, the way the linear lane always has -- except where an arm binds
#         a TYPED wasm-gc local (an array or struct reference), which a sibling
#         cannot then use as an i64 because a slot has one declared type.
#
#         Two halves, and they pull in opposite directions, which is why both
#         are here:
#
#           (a) mixed fixture, both lanes, same answer. RUNNING it is most of
#               the test -- a slot declared i64 and set from an array reference
#               (or the reverse) is caught at instantiation by wasm
#               validation, not by the value. Compiling alone would prove
#               nothing.
#           (b) local COUNT bounded by the linear lane's on a deeply nested
#               fixture that binds nothing typed. This is the regression the
#               issue is about: allocating per-path instead of per-level grows
#               as 2^depth (509 locals against linear's 15 at depth 7), and it
#               is invisible in a size comparison because the two lanes'
#               fixed preludes differ by more than the regression does.
echo "[compiler-gate] 40h-10/40 wasm-gc sibling slot reuse (#1985)"
gcssdir="_build/_gate_gc_slot_reuse"
rm -rf "$gcssdir"; mkdir -p "$gcssdir"
for gcss_be in linear gc; do
  env -u VIBE_FS_COMPILE VIBE_BACKEND="$gcss_be" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/gc_sibling_slot_reuse.vibe" "$gcssdir/mixed.$gcss_be.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$gcssdir/mixed.$gcss_be.wasm" ]; then
    echo "[compiler-gate] FAIL: gc_sibling_slot_reuse.vibe did not compile on the $gcss_be backend (#1985)" >&2
    cat "$gcssdir/mixed.$gcss_be.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  gcss_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcssdir/mixed.$gcss_be.wasm" 2>&1 | tail -1)"
  if [ "$gcss_out" != "105" ]; then
    echo "[compiler-gate] FAIL: gc_sibling_slot_reuse.vibe got '$gcss_out' on the $gcss_be backend (want 105; a wasm validation error here means an arm reused a slot another arm declared as a reference) (#1985)" >&2
    exit 1
  fi
  env -u VIBE_FS_COMPILE VIBE_BACKEND="$gcss_be" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/gc_nested_branch_locals.vibe" "$gcssdir/nested.$gcss_be.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$gcssdir/nested.$gcss_be.wasm" ]; then
    echo "[compiler-gate] FAIL: gc_nested_branch_locals.vibe did not compile on the $gcss_be backend (#1985)" >&2
    cat "$gcssdir/nested.$gcss_be.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  gcss_nested_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcssdir/nested.$gcss_be.wasm" 2>&1 | tail -1)"
  if [ "$gcss_nested_out" != "546" ]; then
    echo "[compiler-gate] FAIL: gc_nested_branch_locals.vibe got '$gcss_nested_out' on the $gcss_be backend (want 546) (#1985)" >&2
    exit 1
  fi
done
gcss_lin_locals="$(node scripts/wasm_local_counts.mjs --max "$gcssdir/nested.linear.wasm")"
gcss_gc_locals="$(node scripts/wasm_local_counts.mjs --max "$gcssdir/nested.gc.wasm")"
# The gc lane needs a few more scratch slots than linear for the same code, so
# the bound is a small ABSOLUTE margin rather than equality. It is nowhere near
# the failure it guards against: the pre-#1985 numbering produced 125 locals
# here against linear's 11.
gcss_budget=$((gcss_lin_locals + 4))
if [ "$gcss_gc_locals" -gt "$gcss_budget" ]; then
  echo "[compiler-gate] FAIL: gc lane declared $gcss_gc_locals locals for the depth-5 nested fixture, linear $gcss_lin_locals (budget $gcss_budget). Sibling arms are allocating per PATH again instead of per level (#1985)" >&2
  exit 1
fi
rm -rf "$gcssdir"
echo "[compiler-gate] wasm-gc sibling slot reuse ok (mixed fixture 105 on both lanes; nested locals gc=$gcss_gc_locals linear=$gcss_lin_locals)"

# #1295: String is a packed fat pointer, so the gc EForIn lowering must
# normalize it to character codes before its shared Array iteration loop.
echo "[compiler-gate] wasm-gc String for-in"
gcstrdir="_build/_gate_gc_string_forin"
rm -rf "$gcstrdir"; mkdir -p "$gcstrdir"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/gc_for_in_string_test.vibe" "$gcstrdir/out.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$gcstrdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: gc String for-in fixture did not compile" >&2
  cat "$gcstrdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
gcstr_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcstrdir/out.wasm" 2>&1 | tail -1)"
if [ "$gcstr_out" != "1666" ]; then
  echo "[compiler-gate] FAIL: gc String for-in got '$gcstr_out' (want 1666)" >&2
  exit 1
fi
rm -rf "$gcstrdir"
echo "[compiler-gate] wasm-gc String for-in ok (1666)"

# 40h2. ADR-0076 (#817) step 6: wasm-gc backend now also supports
#       evidence-dict-eligible USER-DEFINED effects (not just
#       `with Error { Throw(..) => .. }`), via the same evidence_dict_pass/
#       inline_direct_performs AST rewrite the linear backend already used,
#       now also wired into backend_body.vibe's compile_wasi_module_gc.
#       Confirmed via A/B testing against a pre-change baseline that this
#       fixture failed with "GC codegen: unsupported perform (no builtin
#       mapping)" before this change.
echo "[compiler-gate] 40h2/40 wasm-gc backend evidence-dict user-defined effect support (ADR-0076 step 6)"
gcedir="_build/_gate_gc_evidence_dict"
rm -rf "$gcedir"; mkdir -p "$gcedir"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/gc_backend_effect_evidence_dict.vibe" "$gcedir/out.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$gcedir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: gc_backend_effect_evidence_dict.vibe did not compile under VIBE_BACKEND=gc" >&2
  cat "$gcedir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
gce_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcedir/out.wasm" 2>&1 | tail -1)"
if [ "$gce_out" != "17" ]; then
  echo "[compiler-gate] FAIL: gc_backend_effect_evidence_dict.vibe got '$gce_out' (want 17) -- gc-lane evidence-dict wiring regressed" >&2
  exit 1
fi
rm -rf "$gcedir"
echo "[compiler-gate] wasm-gc backend evidence-dict user-defined effect support ok (17)"

# 40h3. ADR-0076 (#817) gc-backend follow-up: a needing function's OWN
#       eligibility no longer sinks the whole effect's migration once it is
#       provably UNREACHABLE (dead code) by the time evidence_dict_pass runs
#       -- e.g. #1070's dtpw_inline_trivial_wrappers rewrites `apply(inner)`
#       into `inner()`, leaving the trivial wrapper `apply`'s own top-level
#       definition uncalled anywhere; `apply`'s body (`f()`, a call through
#       an arbitrary closure PARAMETER) can never be proven safe by
#       edp_has_unsafe_construct, but since it can never actually run, that
#       no longer matters. evidence_dict_pass now reuses dce_keep_flags
#       (core/dce.vibe, the SAME reachability engine dce_stmts already uses
#       in production) to drop provably-dead needing functions before the
#       safety scan. This is the SAME fixture as gate 40aj's linear-backend
#       assertion (effect_local_closure_by_value_wrapper.vibe, want 105) --
#       confirmed via direct A/B testing that it failed under
#       VIBE_BACKEND=gc with "only `with Error`..." before this change.
echo "[compiler-gate] 40h3/40 wasm-gc backend: dead needing function no longer blocks effect migration (ADR-0076 gc follow-up)"
gcdeaddir="_build/_gate_gc_dead_needing"
rm -rf "$gcdeaddir"; mkdir -p "$gcdeaddir"
# #1571: the fixture is an inspect() test-block suite now, compiled AS-IS --
# no `__DATA__` tail to `sed` off, no temp copy, and the expected 105 is in
# the fixture instead of in this comparison. It still goes through the
# SINGLE-FILE lane (no VIBE_FS_COMPILE), which is the property this site
# exists to hold: `inspect` is import-free precisely so migrating a fixture
# does not force one.
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_local_closure_by_value_wrapper.vibe "$gcdeaddir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$gcdeaddir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_wrapper.vibe did not compile under VIBE_BACKEND=gc" >&2
  cat "$gcdeaddir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! gcdead_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$gcdeaddir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_wrapper.vibe under gc failed its inspect (want 105) -- dead-needing-function filtering regressed" >&2
  echo "$gcdead_out" >&2
  exit 1
fi
rm -rf "$gcdeaddir"
echo "[compiler-gate] wasm-gc backend dead needing function filtering ok (105)"

# 40h4. ADR-0076 (#817) gc-backend follow-up: a needing function's OWN
#       declared row can mention the migrated effect PURELY to satisfy a
#       separate checker requirement ("a `handle ... with Effect`
#       expression's enclosing declared row must authorize the whole effect
#       name") while its entire body is nothing but `handle {..} with
#       ename {..}` -- fully discharging the effect itself, never actually
#       needing the evidence dict passed to it. edp_has_unsafe_construct
#       correctly (for the general case) flags a same-effect nested
#       `EHandle` as unsafe, which used to sink the WHOLE effect's
#       migration whenever such a function existed. evidence_dict_pass now
#       drops a needing function from consideration when its body is
#       EXACTLY a bare same-effect `EHandle` (edp_drop_self_discharging_needing)
#       -- its handle site is already discovered and migrated independently.
#       fixtures/effect_effectset_expansion.vibe's `run_effectset` is exactly this
#       shape; confirmed via direct testing that it failed under
#       VIBE_BACKEND=gc with "only `with Error`..." before this change.
echo "[compiler-gate] 40h4/40 wasm-gc backend: self-discharging needing function no longer blocks effect migration (ADR-0076 gc follow-up)"
# #1571: fixture is an inspect() test-block suite now, compiled AS-IS (no
# `sed` strip; its import resolves from fixtures/). Its test block wraps the
# call to the self-discharging `run_effectset` in another `handle ... with Ask`,
# which additionally locks #1595 on the gc lane: the CALL to a
# self-discharging fn must be inert (edp_append_self_discharging_row_fns),
# not just the fn itself dropped from `needing`.
gcselfdir="_build/_gate_gc_self_discharge"
rm -rf "$gcselfdir"; mkdir -p "$gcselfdir"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_effectset_expansion.vibe "$gcselfdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$gcselfdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_effectset_expansion.vibe did not compile under VIBE_BACKEND=gc (self-discharging drop or #1595 call-inertness regressed)" >&2
  cat "$gcselfdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! gcself_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$gcselfdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_effectset_expansion.vibe under gc test failed (want inspect 42) -- self-discharging needing function filtering regressed" >&2
  echo "$gcself_out" >&2
  exit 1
fi
rm -rf "$gcselfdir"
echo "[compiler-gate] wasm-gc backend self-discharging needing function filtering ok (42)"

# 40h4b. #1595: a self-discharging fn CALLED FROM another row-carrying fn.
#        Dropping the callee from `needing` (40h4's fix) alone was
#        self-defeating for this shape: the drop removed the very
#        needing-membership that made the CALL to it safe in
#        edp_has_unsafe_construct, so the caller went ineligible and the
#        whole effect's migration failed hard ("cannot be compiled here").
#        The second half (edp_append_self_discharging_row_fns) makes such
#        calls inert -- mirroring the perform-free class's dual treatment.
#        Positive: fixtures/effect_self_discharging_callee.vibe (inspect
#        test block, both backends). Negative:
#        fixtures/err_effect_self_discharge_arm_reperform.vibe -- a handler
#        arm that RE-PERFORMS the effect escapes the callee, so that fn is
#        NOT call-inert; the program must stay a hard error (never a
#        silently-migrated outer handle blind to the arm's perform), and
#        the diagnostic must name the callee + the arm re-perform (#1591:
#        the old enumeration listed only forms this program satisfies).
echo "[compiler-gate] 40h4b/40 self-discharging callee call-inertness (#1595) + dirty-arm rejection (#1591)"
sdcdir="_build/_gate_self_discharge_callee"
rm -rf "$sdcdir"; mkdir -p "$sdcdir"
for sdc_backend in "" gc; do
  rm -f "$sdcdir/out.wasm" "$sdcdir/out.wasm.diag"
  env ${sdc_backend:+VIBE_BACKEND="$sdc_backend"} VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    fixtures/effect_self_discharging_callee.vibe "$sdcdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$sdcdir/out.wasm" ]; then
    echo "[compiler-gate] FAIL: effect_self_discharging_callee.vibe did not compile${sdc_backend:+ under VIBE_BACKEND=$sdc_backend} (#1595 call-inertness regressed)" >&2
    cat "$sdcdir/out.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  if ! sdc_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$sdcdir/out.wasm" 2>&1)"; then
    echo "[compiler-gate] FAIL: effect_self_discharging_callee.vibe test failed${sdc_backend:+ under VIBE_BACKEND=$sdc_backend} (want inspect 42 -- the callee's own handler must win)" >&2
    echo "$sdc_out" >&2
    exit 1
  fi
done
rm -f "$sdcdir/rej.wasm" "$sdcdir/rej.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_effect_self_discharge_arm_reperform.vibe "$sdcdir/rej.wasm" main >/dev/null 2>&1 || true
if [ -s "$sdcdir/rej.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effect_self_discharge_arm_reperform.vibe compiled -- an arm re-perform escapes the callee, so call-inertness must NOT apply (P0 silent-wrong risk)" >&2
  exit 1
fi
if ! grep -qF "hides a perform from it" "$sdcdir/rej.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effect_self_discharge_arm_reperform.vibe rejection lacks the #1591 culprit diagnostic (want 'hides a perform from it')" >&2
  cat "$sdcdir/rej.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$sdcdir"
echo "[compiler-gate] self-discharging callee call-inertness ok (#1595/#1591)"

# 40h5. ADR-0076 (#817) gc-backend follow-up: a local closure literal with
#       NO explicit `with` annotation (its `eff` field is blank in the
#       AST -- the checker infers the row internally but never writes it
#       back onto the node) that performs an effect and gets lambda-lifted
#       to a fresh top-level binding (dlh_hoist_expr, the capture-free
#       case) used to keep the BLANK row on the hoisted definition too --
#       evidence_dict_pass classifies top-level "needing" functions purely
#       by reading that row string, so the hoisted function was silently
#       never recognized as needing anything and its `perform` was never
#       migrated. Harmless on the linear backend (falls back to replay,
#       still correct) but a hard "unsupported perform" error on gc, which
#       has no such fallback.
#
#       Fixed in two parts: (1) dlh_hoist_expr now backfills a blank `eff`
#       from what the closure's body actually performs BEFORE hoisting
#       (dlh_collect_performed_effect_names); (2) edp_plan_migrations now
#       tries the FULL needing set (including provably-dead functions like
#       this fixture's deliberately-uncalled `never_called`) BEFORE falling
#       back to dropping dead ones -- trying dead-code-dropping first would
#       have UNDONE fix (1) by re-excluding this now-correctly-classified-
#       but-still-dead function, right back to the same "unsupported
#       perform" failure (found via direct testing after landing fix (1)
#       alone still didn't fix this fixture under gc).
echo "[compiler-gate] 40h5/40 wasm-gc backend: unannotated hoisted closure literal row backfill (ADR-0076 gc follow-up)"
gcclosdir="_build/_gate_gc_closure_literal_row"
rm -rf "$gcclosdir"; mkdir -p "$gcclosdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_call_evidence_closure_literal.vibe "$gcclosdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$gcclosdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_closure_literal.vibe did not compile under VIBE_BACKEND=gc" >&2
  cat "$gcclosdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! gcclos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$gcclosdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_closure_literal.vibe under gc got '$gcclos_out' (want 6) -- hoisted closure row backfill or try-full-before-dropping-dead regressed" >&2
  echo "$gcclos_out" >&2
  exit 1
fi
rm -rf "$gcclosdir"
echo "[compiler-gate] wasm-gc backend closure literal row backfill ok (6)"

# 40h6. ADR-0076 (#817) gc-backend follow-up: edp_has_unsafe_construct's
#       pure-builtin allowlist was missing `__index` (`obj[i]` sugar),
#       `Array::get`/`Map::get`/`Bytes::get`, and
#       `Array::length`/`Map::size`/`Bytes::length` -- all individually
#       checker-verified pure. A needing function's body calling any of
#       these (e.g. `items[i]` inside a `while i < Array::length(items)`
#       loop) was sunk to ineligible purely because the call wasn't on the
#       allowlist. Harmless on linear (replay fallback); a hard
#       "unsupported perform" error on gc, which has none.
echo "[compiler-gate] 40h6/40 wasm-gc backend: __index/length pure-builtin allowlist gap (ADR-0076 gc follow-up)"
gcidxdir="_build/_gate_gc_pure_builtin_index"
rm -rf "$gcidxdir"; mkdir -p "$gcidxdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/gc_backend_effect_pure_builtin_index.vibe "$gcidxdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$gcidxdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: gc_backend_effect_pure_builtin_index.vibe did not compile under VIBE_BACKEND=gc" >&2
  cat "$gcidxdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! gcidx_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$gcidxdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: gc_backend_effect_pure_builtin_index.vibe under gc got '$gcidx_out' (want 3) -- pure-builtin allowlist regressed" >&2
  echo "$gcidx_out" >&2
  exit 1
fi
rm -rf "$gcidxdir"
echo "[compiler-gate] wasm-gc backend pure-builtin allowlist ok (3)"

# 40h7. gc-backend follow-up: `suberror` constructors were never registered
#       in the wasm-gc backend's ctor table (backend_body.vibe's ctor-
#       registration loop had SEnum/SStruct cases but no SSuberror case,
#       unlike linked_compile.vibe which has always had one) --
#       `throw(KeyInvalid(...))` hit backend_call.vibe's "unknown
#       constructor or function" hard error. Mirrors linked_compile.vibe's
#       SSuberror handling exactly.
echo "[compiler-gate] 40h7/40 wasm-gc backend: suberror constructor registration (gc follow-up)"
gcsuberrdir="_build/_gate_gc_suberror_ctor"
rm -rf "$gcsuberrdir"; mkdir -p "$gcsuberrdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/gc_backend_suberror_ctor.vibe "$gcsuberrdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$gcsuberrdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: gc_backend_suberror_ctor.vibe did not compile under VIBE_BACKEND=gc" >&2
  cat "$gcsuberrdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! gcsuberr_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$gcsuberrdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: gc_backend_suberror_ctor.vibe under gc got '$gcsuberr_out' (want 4200) -- suberror ctor registration regressed" >&2
  echo "$gcsuberr_out" >&2
  exit 1
fi
rm -rf "$gcsuberrdir"
echo "[compiler-gate] wasm-gc backend suberror constructor registration ok (4200)"

# 40h8. Exercise test-block lowering and runtime assertions through the
# wasm-gc path, rather than only calling exported `main` functions above.
# These fixtures jointly cover structural equality of nested aggregates,
# MapBuilder growth/freeze, record field-name collision handling, and
# same-file `to_string` shadowing of a gc fast path. Keep this as an enforced
# gate: test_gc_selfbuild.sh also runs three of these probes, but
# is deliberately informational while the full gc selfbuild frontier moves.
echo "[compiler-gate] 40h8/40 wasm-gc test-block runtime regression suite"
if ! VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_BACKEND=gc \
  bash scripts/vibe_test.sh \
    fixtures/eq_structural_aggregates_test.vibe \
    fixtures/map_builder_growth_test.vibe \
    fixtures/string_byte_alias_shadow_test.vibe \
    fixtures/string_byte_semantics_test.vibe \
    fixtures/struct_field_collision_test.vibe \
    fixtures/to_string_shadow_gc_test.vibe \
    fixtures/array_hof_parity_test.vibe \
    fixtures/gc_builtin_parity_batch2_test.vibe \
    fixtures/gc_builtin_parity_batch3_test.vibe \
    fixtures/gc_builtin_parity_batch4_test.vibe \
    fixtures/int_bit_primitives_test.vibe \
    fixtures/bytes_alloc_backend_parity_test.vibe \
    fixtures/bytes_index_of_bytes_test.vibe \
    fixtures/bytes_index_of_byte_test.vibe \
    fixtures/bytes_count_last_index_of_test.vibe \
    fixtures/bytes_compare_test.vibe; then
  echo "[compiler-gate] FAIL: wasm-gc test-block runtime regression suite" >&2
  exit 1
fi
echo "[compiler-gate] wasm-gc test-block runtime regression suite ok"

# 40h8b. #1861: the Array HOFs (map/filter/fold/reverse/any/all/find) were the
# `gc-hof-gap` rows of scripts/builtin_parity_classification.tsv -- served by
# the linear callsite chain, absent from the gc one. They are now served by
# both, so the property to hold is not "gc can do map" but "the two lanes
# agree": a gc-only run goes green on a lowering that quietly computes
# something else, and silently-wrong outranks a crash (docs/issue-triage.md).
# So the same file runs on the LINEAR lane too, as the oracle.
#
# check_builtin_parity.sh already fails if either lane loses an arm. It reads
# callsite arms, though, and cannot tell a correct lowering from a wrong one.
echo "[compiler-gate] 40h8b/40 gc<->linear builtin lane parity (#1861)"
if ! VIBE_TEST_CLI_WASM="$stage2_wasm" \
  bash scripts/vibe_test.sh \
    fixtures/array_hof_parity_test.vibe \
    fixtures/gc_builtin_parity_batch2_test.vibe \
    fixtures/gc_builtin_parity_batch3_test.vibe \
    fixtures/gc_builtin_parity_batch4_test.vibe; then
  echo "[compiler-gate] FAIL: a builtin parity fixture failed on the LINEAR lane." >&2
  echo "  It passed on gc just above, so this is the oracle disagreeing --" >&2
  echo "  the fixture's expectations are wrong, or linear regressed." >&2
  exit 1
fi
echo "[compiler-gate] builtin lane parity ok (gc + linear agree)"

# 40h8c. #1976: the wasm-gc lane's single-file limitation must SAY SO.
#
# Referencing an imported name cannot work on this backend, and for a long time
# it answered with the codegen internal error -- "this is a bug in the compiler
# and not in your program -- please report the source that triggers it". That is
# false for this shape, and it hid the cause well enough that three separate
# wrong explanations for it reached the docs (#1929, corrected there).
#
# Pinned in both directions: the message must name the imported binding and the
# lane, and must NOT be the report-a-compiler-bug text. The second half matters
# most -- the rewrite is narrow on purpose, and a future change that widened it
# would swallow the genuine unresolved-name class (#1502/#1510/#1521) that
# message exists for.
echo "[compiler-gate] 40h8c/40 wasm-gc import diagnostic (#1976)"
gcimpdir="_build/_gate_gc_import_diag"
rm -rf "$gcimpdir"; mkdir -p "$gcimpdir"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/gc_import_diag_use.vibe "$gcimpdir/out.wasm" main >/dev/null 2>&1 || true
gcimp_diag="$(cat "$gcimpdir/out.wasm.diag" 2>/dev/null || true)"
if [ -s "$gcimpdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: fixtures/gc_import_diag_use.vibe COMPILED on the gc lane." >&2
  echo "  If the lane gained cross-file resolution, delete this step and the two" >&2
  echo "  fixtures -- but update #1976 and AGENTS.md's gc section first." >&2
  exit 1
fi
if ! printf '%s' "$gcimp_diag" | grep -q 'gc_import_diag_helper` is imported'; then
  echo "[compiler-gate] FAIL: the gc import diagnostic no longer names the imported binding (#1976)" >&2
  echo "  got: $gcimp_diag" >&2
  exit 1
fi
if printf '%s' "$gcimp_diag" | grep -q 'please report the source that triggers it'; then
  echo "[compiler-gate] FAIL: the gc import diagnostic reverted to the report-a-compiler-bug text (#1976)" >&2
  echo "  got: $gcimp_diag" >&2
  exit 1
fi

# The step above drives the compiler directly with VIBE_BACKEND=gc, so it
# proves the DIAGNOSTIC and nothing about the wrapper users actually type.
# `vibe test` read no backend variable at all: VIBE_TEST_BACKEND=gc compiled
# with compile_to's default and ran LINEAR, reporting a pass for a lane it
# never used. Only scripts/vibe_test.sh honoured it, and nothing said so --
# the same silent-wrong shape #1701 fixed for `vibe bench`. Pinned end to end
# here: the wrapper must reach the gc lane, and the gc-only failure must be
# the one the fixture is built to produce.
#
# The probe is written here rather than committed as a fixture for the same
# reason its sibling pair is not named `*_test.vibe`: it exists to be REJECTED,
# and unit_test_runner discovers that glob. It reuses the committed dep so the
# only thing this step adds is the `test {}` wrapper `vibe test` requires.
gcwrapdir="_build/_gate_gc_test_backend"
rm -rf "$gcwrapdir"; mkdir -p "$gcwrapdir"
cat > "$gcwrapdir/gc_backend_probe_test.vibe" <<'GCWRAP'
import ../../fixtures/gc_import_diag_dep.vibe {
  gc_import_diag_helper
}

test "reaches the gc lane" {
  assert(gc_import_diag_helper(21) == 42)
}
GCWRAP
gcwrap_out="$(VIBE_TEST_BACKEND=gc VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" \
  VIBE_CLI_WASM="$stage2_wasm" \
  bash "$ROOT_DIR/runtime/vibe" test "$gcwrapdir/gc_backend_probe_test.vibe" 2>&1 || true)"
if ! printf '%s' "$gcwrap_out" | grep -q 'gc_import_diag_helper` is imported'; then
  echo "[compiler-gate] FAIL: VIBE_TEST_BACKEND=gc did not reach the gc lane (#1976)" >&2
  echo "  \`vibe test\` compiled on linear while the caller asked for gc -- a pass here" >&2
  echo "  says nothing about which backend produced it." >&2
  echo "  got: $gcwrap_out" >&2
  exit 1
fi
rm -rf "$gcwrapdir"
rm -rf "$gcimpdir"
echo "[compiler-gate] wasm-gc import diagnostic ok (names the binding, not an internal error; VIBE_TEST_BACKEND=gc reaches the lane)"

# 40i. effect->WIT golden (#537): `vibe compile --wit` (adapter VIBE_EMIT_WIT=1)
#      must render fixtures/wit_gen_http.vibe byte-exactly as the committed
#      golden. Pins the WIT mapping contract (docs/effect-wit-mapping.md):
#      declared effect -> inline interface import, host-capability effect ->
#      comment marker, exported fns -> world exports, type mapping.
echo "[compiler-gate] 40i/40 effect->WIT golden (#537)"
witdir="_build/_gate_wit"
rm -rf "$witdir"; mkdir -p "$witdir"
VIBE_EMIT_WIT=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/wit_gen_http.vibe" "$witdir/out.wit" main >/dev/null 2>&1 || true
if [ ! -s "$witdir/out.wit" ]; then
  echo "[compiler-gate] FAIL: VIBE_EMIT_WIT produced no output" >&2
  cat "$witdir/out.wit.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! diff -u "fixtures/wit_gen_http.golden.wit" "$witdir/out.wit" >&2; then
  echo "[compiler-gate] FAIL: WIT output differs from fixtures/wit_gen_http.golden.wit. If the mapping contract changed intentionally, update the golden AND docs/effect-wit-mapping.md together." >&2
  exit 1
fi
rm -rf "$witdir"
echo "[compiler-gate] effect->WIT golden ok"

# 40j. `vibe serve` handler componentization (#537): the adapter's
#      VIBE_SERVE_COMPONENT=1 step must turn the serve smoke handler into a
#      valid component exporting
#        handler: func(method, url, headers, body: string) -> string
#      via the packed-string trampoline (component_codegen). Executed on
#      wasmtime when available (the same auth check the full HTTP gate curls);
#      otherwise only the emission is asserted.
echo "[compiler-gate] 40j/40 serve handler componentization (#537)"
svdir="_build/_gate_serve"
rm -rf "$svdir"; mkdir -p "$svdir"
VIBE_SERVE_COMPONENT=1 VIBE_SERVE_WIT_OUT="$svdir/handler.wit" \
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/serve_handler_smoke.vibe" "$svdir/handler.component.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$svdir/handler.component.wasm" ]; then
  echo "[compiler-gate] FAIL: VIBE_SERVE_COMPONENT produced no component" >&2
  cat "$svdir/handler.component.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
sv_magic="$(od -An -t x1 -N 4 "$svdir/handler.component.wasm" | tr -d ' \n')"
if [ "$sv_magic" != "0061736d" ]; then
  echo "[compiler-gate] FAIL: serve component is not wasm (magic=$sv_magic)" >&2
  exit 1
fi
if [ ! -s "$svdir/handler.wit" ]; then
  echo "[compiler-gate] FAIL: VIBE_SERVE_WIT_OUT sidecar missing" >&2
  exit 1
fi
SERVE_WASMTIME="$(bash scripts/wasmtime_bin.sh 2>/dev/null || command -v wasmtime || true)"
if [ -n "$SERVE_WASMTIME" ] && "$SERVE_WASMTIME" --version >/dev/null 2>&1; then
  sv_out="$("$SERVE_WASMTIME" run -W exceptions=y \
    --invoke 'handler("GET", "/gate", "x-token: secret", "")' \
    "$svdir/handler.component.wasm" 2>&1 | tail -1)"
  case "$sv_out" in
    *"ok:GET:/gate"*) ;;
    *)
      echo "[compiler-gate] FAIL: serve component invoke got '$sv_out' (want 200 ok:GET:/gate). The packed-string trampoline (comp_emit_component_wasm_string_handler) no longer matches the linear-backend string ABI." >&2
      exit 1
      ;;
  esac
  echo "[compiler-gate] serve handler componentization ok (invoked on wasmtime)"
else
  echo "[compiler-gate] serve handler componentization ok (emission only; wasmtime unavailable)"
fi
rm -rf "$svdir"

# 40k. #1015 P2: gc-lane to_string(Bool) regressions -- the gc-backend twin
#      of the linear-lane #1015 fix, plus the two shadow/scope-leak fixes
#      code review found in the gc-lane port specifically. Same test-block
#      compile+run pattern as step 5, with VIBE_BACKEND=gc swapped in for
#      VIBE_FS_COMPILE=1 (per VIBE_TEST_BACKEND=gc's own compile_env
#      selection in vibe_test.sh). Each fixture is single-file (the gc lane
#      has no cross-file FS import resolution) and compiled+run separately.
#   - to_string_bool_gc_test.vibe: a self-contained Show-bounded generic
#     `to_string` wrapper (the gc lane cannot import the prelude's) and a
#     Bool-typed fn param forwarding through it; both must render
#     "true"/"false", not "1"/"0".
#   - to_string_shadow_gc_test.vibe: a SAME-file user-defined `to_string(x:
#     Bool) -> String { "custom" }` must NOT be silently overridden by the
#     call-site fast path (ctx.gc_to_string_is_show_wrapper structural
#     guard, backend_body.vibe).
#   - to_string_bool_scope_gc_test.vibe: an if/else branch rebinding the
#     same local slot to a non-Bool value in the other branch must not
#     leak the Bool classification across the branch boundary
#     (ctx.gc_bool_locals is slot-indexed and pruned at every
#     branch/match-arm/for-in scope exit, backend_expr.vibe /
#     backend_match.vibe).
#   - to_string_float_scope_gc_test.vibe (#1032): the Float analog of the
#     scope-leak fixture above -- ctx.gc_float_locals was the same
#     name-keyed, unpruned design as gc_bool_locals pre-#1030 (a KNOWN
#     LATENT BUG noted but not fixed there); now slot-indexed and pruned
#     the same way.
echo "[compiler-gate] 40k/40 gc-lane call/to_string regressions (#1015, #2160)"
gcbdir="_build/_gate_gc_to_string_bool"
rm -rf "$gcbdir"; mkdir -p "$gcbdir"
# gc_scratch_name_collision.vibe intentionally stays out of the linear unit
# lane because it guards GC-backend scratch naming specifically.
for gcb_fixture in to_string_bool_gc_test to_string_shadow_gc_test to_string_bool_scope_gc_test to_string_float_scope_gc_test gc_local_top_level_shadow_test gc_scratch_name_collision; do
  VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/${gcb_fixture}.vibe" "$gcbdir/${gcb_fixture}.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$gcbdir/${gcb_fixture}.wasm" ]; then
    echo "[compiler-gate] FAIL: gc-lane regression fixture ${gcb_fixture}.vibe did not compile" >&2
    cat "$gcbdir/${gcb_fixture}.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
      --invoke _start "$gcbdir/${gcb_fixture}.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: gc-lane regression fixture ${gcb_fixture}.vibe trapped" >&2
    exit 1
  fi
done
rm -rf "$gcbdir"
echo "[compiler-gate] gc-lane call/to_string regressions ok"

# 40l. handle-replay side-effect corruption regression guard (M2,
#      eval/lang-review/findings/2026-07-12-r2.md; tracked by ADR-0076/#817).
#      `handle` used to re-execute the whole handled body from the top on
#      every `resume` ("replay"); this fixture has 2 performs + a `let mut`
#      counter mutated around each, so replay's re-execution corrupted both
#      the counter and the handle's own return value in a specific,
#      deterministic way (see the fixture's header comment for the full
#      trace, pre-fix output was 6016). ADR-0076 Phase 2 (direct-perform
#      inlining, common_base/inline_direct_perform.vibe) fixes this exact
#      shape -- the handled body has no unsafe construct, so both performs
#      inline directly into the tail-resumptive arm instead of going through
#      replay. This gate now pins the FIXED output (3013 == 1000*3 +
#      (5+5+3)) as a regression lock: fixtures/effect_*.vibe with `__DATA__`
#      are not otherwise wired into any automated harness today
#      (generate_runtime_fixture_tests.mjs explicitly excludes `perform`/
#      `handle` sources).
echo "[compiler-gate] 40l/40 handle-replay side-effect corruption regression guard (M2/#817)"
m2dir="_build/_gate_effect_replay_m2"
rm -rf "$m2dir"; mkdir -p "$m2dir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_replay_corruption.vibe "$m2dir/m2.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$m2dir/m2.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_replay_corruption.vibe did not compile" >&2
  cat "$m2dir/m2.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! m2_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$m2dir/m2.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_replay_corruption got '$m2_out' (want 3013, the ADR-0076 Phase 2 direct-perform-inlining fixed value). This means the fix regressed -- e.g. inline_direct_performs stopped firing for this fixture's shape and it fell back to buggy replay (6016)." >&2
  echo "$m2_out" >&2
  exit 1
fi
rm -rf "$m2dir"
echo "[compiler-gate] handle-replay side-effect corruption regression guard ok (3013, ADR-0076 Phase 2 fix verified)"

# 40m. ADR-0071 step 1 (#755, docs/effectset.md): a `with` row item
#      may now name a single qualified operation (`Effect::op`), not just a
#      whole effect name -- collect_effect_names in
#      lib/@vibe/parser/parser_base.vibe. Parser-only slice: the row stays
#      an opaque comma-joined String (no new AST shape), so round-trip is
#      automatic; this gate just pins that the new grammar actually parses
#      and compiles/runs end to end. Operation-level CHECKING (rejecting a
#      perform of a DIFFERENT operation of the same effect when only one is
#      named) is a separate, larger change (step 3), not covered here.
echo "[compiler-gate] 40m/40 effect row operation-item grammar (ADR-0071 step 1/#755)"
# #1571: the fixture carries its expectation as an inspect() test block now
# (compiled AS-IS, no `sed` strip -- its `import ../lib/@vibe/core` resolves
# from fixtures/); the test-block wrapper also locks #1595's shape (calling
# the self-discharging `run_operation_row` from under another `handle` for the same
# effect).
a71dir="_build/_gate_effectset_row_item"
rm -rf "$a71dir"; mkdir -p "$a71dir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_row_operation_item.vibe "$a71dir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$a71dir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_row_operation_item.vibe did not compile (with Effect::op row-item grammar regressed, or #1595 self-discharging call-inertness regressed)" >&2
  cat "$a71dir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! a71_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$a71dir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_row_operation_item test failed (want inspect 42)" >&2
  echo "$a71_out" >&2
  exit 1
fi
rm -rf "$a71dir"
echo "[compiler-gate] effect row operation-item grammar ok"

# 40n. ADR-0071 step 3 (#755, docs/effectset.md): a VALID `effectset` (no
#      cycle, no operation-name collision) is now ACCEPTED and its members
#      are expanded into any `with EffectsetName` row item that
#      references it (checker_stmt.vibe's es_expand_stmts_effect_rows),
#      before the existing string-label containment machinery
#      (decl_authorizes_effect et al., unmodified) runs. This gate compiles
#      fixtures/effect_effectset_expansion.vibe, where a function's OWN
#      declared row is JUST an effectset name (`with AskAll`) and that
#      alone must authorize a transitively-called function requiring the
#      operation the effectset expands to (`Ask::Get`) -- proving expansion
#      is actually wired in, not just that the effectset parses. (Step 2's
#      prior behavior -- rejecting EVERY effectset declaration regardless of
#      validity -- is superseded by this step; see gate 40o below for what
#      STILL gets rejected.)
echo "[compiler-gate] 40n/40 effectset row expansion authorizes a transitive call (ADR-0071 step 3/#755)"
# #1571: fixture is an inspect() test-block suite now, compiled AS-IS (no
# `sed` strip; its import resolves from fixtures/). See gate 40m's note.
a71bdir="_build/_gate_effectset_expand"
rm -rf "$a71bdir"; mkdir -p "$a71bdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_effectset_expansion.vibe "$a71bdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$a71bdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_effectset_expansion.vibe did not compile -- effectset row expansion regressed" >&2
  cat "$a71bdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! a71b_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$a71bdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_effectset_expansion test failed (want inspect 42)" >&2
  echo "$a71b_out" >&2
  exit 1
fi
rm -rf "$a71bdir"
echo "[compiler-gate] effectset row expansion ok"

# 40o. ADR-0071 resolver core (#755, docs/effectset.md): the ADR's Decision
#      section calls out two specific invalid-definition cases by name -- a
#      cycle through effectset member references, and a qualified name
#      colliding with an operation of the same effect (shared effect-row
#      member namespace) -- both implemented as local helpers in
#      checker_stmt.vibe (es_detect_cycle / es_qualified_collision) with a
#      whole-statement-list pre-pass, order-independent. Since step 3 (gate
#      40n above) made a VALID effectset declaration succeed instead of
#      always failing, this gate is what now proves an INVALID one still
#      doesn't silently slip through to acceptance.
echo "[compiler-gate] 40o/40 effectset cycle + operation-collision detection (ADR-0071 step 2/#755)"
a71cdir="_build/_gate_effectset_resolver"
rm -rf "$a71cdir"; mkdir -p "$a71cdir"
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_effectset_cycle.vibe "$a71cdir/cycle.wasm" main >/dev/null 2>&1 || true
if [ -s "$a71cdir/cycle.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effectset_cycle.vibe compiled successfully -- circular effectset references must be rejected" >&2
  exit 1
fi
if ! grep -q "effectset cycle: A -> B -> A" "$a71cdir/cycle.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effectset_cycle.vibe did not produce the expected cycle diagnostic" >&2
  cat "$a71cdir/cycle.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_effectset_operation_collision.vibe "$a71cdir/collision.wasm" main >/dev/null 2>&1 || true
if [ -s "$a71cdir/collision.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effectset_operation_collision.vibe compiled successfully -- an effectset colliding with an operation name must be rejected" >&2
  exit 1
fi
if ! grep -q "collides with an operation of the same name" "$a71cdir/collision.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effectset_operation_collision.vibe did not produce the expected collision diagnostic" >&2
  cat "$a71cdir/collision.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$a71cdir"
echo "[compiler-gate] effectset cycle + operation-collision detection ok"

# 40p. ADR-0071 step 3, parameter-type expansion (#755, docs/effectset.md):
#      effectset row expansion also covers a function PARAMETER's own
#      function-typed row (the #885 callback-overlay case), not just a
#      function's own top-level declared row -- es_expand_top_value in
#      checker_stmt.vibe walks `params`, and the expansion now runs ONCE,
#      early, in check_program (before check_stmts) so BOTH the type-level
#      argument-compatibility subtyping check (checker.vibe's
#      effect_row_dropped) and the perform-effect leak-through check
#      (checker_effects.vibe's #885 overlay) see already-expanded rows
#      instead of comparing raw, never-equal strings like "AskAll" vs
#      "Ask::Get". This gate compiles
#      fixtures/effect_effectset_param_expansion.vibe, where a callback
#      parameter's row is JUST an effectset name.
echo "[compiler-gate] 40p/40 effectset parameter-type row expansion (ADR-0071 step 3/#755)"
# #1571: fixture is an inspect() test-block suite now, compiled AS-IS (no
# `sed` strip; its import resolves from fixtures/). See gate 40m's note.
a71ddir="_build/_gate_effectset_param_expand"
rm -rf "$a71ddir"; mkdir -p "$a71ddir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_effectset_param_expansion.vibe "$a71ddir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$a71ddir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_effectset_param_expansion.vibe did not compile -- parameter-type effectset expansion regressed" >&2
  cat "$a71ddir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! a71d_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$a71ddir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_effectset_param_expansion test failed (want inspect 42)" >&2
  echo "$a71d_out" >&2
  exit 1
fi
rm -rf "$a71ddir"
echo "[compiler-gate] effectset parameter-type row expansion ok"

# 40q. ADR-0071 step 4 (#755, docs/effectset.md): `handle body with Effect
#      {...}` is exhaustive over every operation of Effect (ADR-0050), so
#      discharging the bare effect name is semantically equivalent to
#      discharging every one of its qualified operation names --
#      collect_handle_effects (checker_effects.vibe) now records BOTH,
#      instead of just the bare name, fixing a case where a handled body
#      transitively calling a function with an operation-level declared row
#      (`with Ask::Get`, not the bare effect `Ask`) was incorrectly
#      rejected as still missing that requirement even though the handle
#      plainly covers it. This gate compiles
#      fixtures/effect_handle_operation_level_discharge.vibe, which has
#      exactly that shape and NO with-clause of its own on main.
echo "[compiler-gate] 40q/40 handler operation-level discharge (ADR-0071 step 4/#755)"
a71edir="_build/_gate_effectset_handle_discharge"
rm -rf "$a71edir"; mkdir -p "$a71edir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_operation_level_discharge.vibe "$a71edir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$a71edir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_operation_level_discharge.vibe did not compile -- handler operation-level discharge regressed" >&2
  cat "$a71edir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! a71e_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$a71edir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_operation_level_discharge got '$a71e_out' (want 42)" >&2
  echo "$a71e_out" >&2
  exit 1
fi
rm -rf "$a71edir"
echo "[compiler-gate] handler operation-level discharge ok"

# 40r. ADR-0071 step 5, contract passthrough (#755, docs/effectset.md): an
#      `effectset` is a transparent, compile-time-only alias like `effect`
#      -- classify_contract_stmts (contract.vibe) now passes an SEffectSet
#      through into the facade verbatim, exported, the same way it already
#      does for SEffectDef, instead of hitting the "unsupported statement
#      in a contract file" catch-all. This gate compiles
#      fixtures/contract_effectset_vpkg_main.vibe, which imports
#      fixtures/contract_effectset_vpkg/ (an index.vpkg declaring both
#      `effect Ask` and `effectset AskAll` alongside a bodyless
#      `fn read_one`) through the ordinary package-import path -- proving
#      the declaration survives the contract facade end to end, not just
#      that it parses in isolation.
echo "[compiler-gate] 40r/40 effectset contract passthrough (ADR-0071 step 5/#755)"
a71fdir="_build/_gate_effectset_contract"
rm -rf "$a71fdir"; mkdir -p "$a71fdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/contract_effectset_vpkg_main.vibe" "$a71fdir/out.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$a71fdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: contract_effectset_vpkg_main.vibe did not compile -- effectset contract passthrough regressed" >&2
  cat "$a71fdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
a71f_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$a71fdir/out.wasm" 2>&1 | tail -1)"
if [ "$a71f_out" != "42" ]; then
  echo "[compiler-gate] FAIL: contract_effectset_vpkg_main got '$a71f_out' (want 42)" >&2
  exit 1
fi
rm -rf "$a71fdir"
echo "[compiler-gate] effectset contract passthrough ok"

# 40s. ADR-0071 step 5, signature-matching effectset awareness (#755,
#      docs/effectset.md): check_contract (contract.vibe) previously
#      compared a contract's and an implementation's effect row as raw,
#      unexpanded strings -- a contract signature spelled with an
#      effectset alias (`fn f() -> T with AskAll`) reported a false
#      "signature mismatch" against an implementation spelled with the
#      literal operations it expands to (`with Ask::Get`), even though
#      they are semantically identical. check_contract now expands both
#      sides (ctr_expand_sig_row, using an ES table built from the
#      contract's own type_defs) before comparing. This gate compiles
#      fixtures/contract_effectset_signature_alias_main.vibe, which imports
#      fixtures/contract_effectset_signature_alias/ -- exactly that shape.
echo "[compiler-gate] 40s/40 effectset contract signature-matching (ADR-0071 step 5/#755)"
a71gdir="_build/_gate_effectset_sig_alias"
rm -rf "$a71gdir"; mkdir -p "$a71gdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/contract_effectset_signature_alias_main.vibe" "$a71gdir/out.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$a71gdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: contract_effectset_signature_alias_main.vibe did not compile -- effectset-aware contract signature matching regressed" >&2
  cat "$a71gdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
a71g_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$a71gdir/out.wasm" 2>&1 | tail -1)"
if [ "$a71g_out" != "42" ]; then
  echo "[compiler-gate] FAIL: contract_effectset_signature_alias_main got '$a71g_out' (want 42)" >&2
  exit 1
fi
rm -rf "$a71gdir"
echo "[compiler-gate] effectset contract signature-matching ok"

# 40t. ADR-0071 step 5, WIT generation effectset/qualified resolution (#755,
#      docs/effectset.md): wit_gen.vibe previously resolved each raw
#      effect-row label verbatim against the effect definitions it collected,
#      so an `effectset` alias (`with AskAll`) or a bare qualified
#      operation item with no accompanying plain effect-name item
#      (`with Ask::Get`) never matched `Ask`'s definition and fell
#      through to the "host capability effect ... no WIT mapping yet"
#      comment marker, even though `Ask` has a real interface mapping.
#      wit_gen.vibe now expands effectset aliases and resolves qualified
#      operation items back to their underlying effect name before
#      rendering. This gate compiles fixtures/wit_gen_effectset.vibe (one
#      export using the effectset alias, one using the bare qualified item)
#      via `vibe compile --wit` and diffs against the golden.
echo "[compiler-gate] 40t/40 effect->WIT effectset/qualified resolution (ADR-0071 step 5/#755)"
witesdir="_build/_gate_wit_effectset"
rm -rf "$witesdir"; mkdir -p "$witesdir"
VIBE_EMIT_WIT=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/wit_gen_effectset.vibe" "$witesdir/out.wit" main >/dev/null 2>&1 || true
if [ ! -s "$witesdir/out.wit" ]; then
  echo "[compiler-gate] FAIL: VIBE_EMIT_WIT produced no output for wit_gen_effectset.vibe" >&2
  cat "$witesdir/out.wit.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! diff -u "fixtures/wit_gen_effectset.golden.wit" "$witesdir/out.wit" >&2; then
  echo "[compiler-gate] FAIL: WIT output differs from fixtures/wit_gen_effectset.golden.wit -- effectset/qualified WIT resolution regressed" >&2
  exit 1
fi
rm -rf "$witesdir"
echo "[compiler-gate] effect->WIT effectset/qualified resolution ok"

# 40u. ADR-0076 Phase 3, first slice (#817): evidence_dict_pass (appended to
#      common_base/inline_direct_perform.vibe -- see that file's doc comment
#      -- to avoid the bootstrap flatten gotcha of a brand-new cross-file
#      export + its first cross-file caller in the same commit). Same M2
#      shape as gate 40l, except the two performs are reached via a helper
#      function call (`ask_helper()`) instead of directly in the handle
#      body -- exactly the case Phase 2 (inline_direct_perform.vibe's
#      idp_has_unsafe_construct) bails out on, which fell to replay and
#      reproduced the SAME 6016 corruption pre-fix. This gate pins the
#      FIXED output (3013, same math as gate 40l) as a regression lock.
echo "[compiler-gate] 40u/40 evidence-dict threading through a helper-function call (ADR-0076 Phase 3/#817)"
edpdir="_build/_gate_evidence_dict_call"
rm -rf "$edpdir"; mkdir -p "$edpdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_call_evidence.vibe "$edpdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edpdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence.vibe did not compile" >&2
  cat "$edpdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edp_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edpdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence.vibe got '$edp_out' (want 3013) -- evidence-dict threading through a helper call regressed" >&2
  echo "$edp_out" >&2
  exit 1
fi
rm -rf "$edpdir"
echo "[compiler-gate] evidence-dict threading through a helper-function call ok"

# 40v. ADR-0076 Phase 3 (#817): a needing-function call nested inside an
#      `if`/`else` branch of a handle body used to compile to genuinely
#      INVALID wasm ("not enough arguments on the stack for call"). Root-
#      caused (docs/effect-evidence-passing.md "追記 6"): the handle-site
#      rewrite used to collect handle sites then re-locate each one
#      afterward via a hand-rolled structural-equality check covering only
#      a handful of Expr constructors -- any OTHER shape (EIf being the
#      first one hit) made it silently fail to re-find the site, leaving
#      the handle body unmodified while the needing function's signature
#      had already gained the extra evidence-dict parameter. Fixed by
#      rewriting a matching EHandle the instant it's found, in one
#      traversal (edp_find_rewrite_handles), eliminating the whole bug
#      class regardless of which Expr shape appears -- branching
#      constructs are now genuinely safe again, not just conservatively
#      disallowed. This gate pins that the branching case now runs
#      CORRECTLY (a single evidence-dict call, no replay-style duplicate
#      execution) rather than merely not crashing.
echo "[compiler-gate] 40v/40 evidence-dict pass: branching handle body runs correctly via the evidence dict (ADR-0076 Phase 3/#817)"
edpbdir="_build/_gate_evidence_dict_branch"
rm -rf "$edpbdir"; mkdir -p "$edpbdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_call_evidence_branch.vibe "$edpbdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edpbdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_branch.vibe did not compile" >&2
  cat "$edpbdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edpb_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edpbdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_branch.vibe got '$edpb_out' (want 2007) -- either the invalid-wasm crash regressed, or the evidence-dict rewrite for branching bodies regressed" >&2
  echo "$edpb_out" >&2
  exit 1
fi
rm -rf "$edpbdir"
echo "[compiler-gate] evidence-dict pass branching handle body ok"

# 40w. ADR-0076 Phase 3 (#817): a needing function (declared row exactly
#      one effect) whose body ALSO performs `Error::Throw` -- legal per
#      #640 Stage 2, which exempts `Error` from row declaration -- used to
#      hit a COMPILE-TIME error ("unknown struct field") because
#      edp_rewrite_perform_via_dict rewrote every perform through the
#      evidence dict regardless of which effect it targeted. Fixed by
#      checking the perform's own effect prefix before rewriting; anything
#      else (only Error can occur here) is left untouched. This gate's
#      fixture includes a needing function that ONLY performs
#      Error::Throw and is never called -- evidence_dict_pass migrates
#      every function whose row matches, not only ones reachable from a
#      handle site, so its mere presence was enough to trigger the bug at
#      compile time regardless of whether it ever runs.
echo "[compiler-gate] 40w/40 evidence-dict pass: Error::Throw mixed into a needing function's body compiles (ADR-0076 Phase 3/#817)"
edpemdir="_build/_gate_evidence_dict_error_mix"
rm -rf "$edpemdir"; mkdir -p "$edpemdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_call_evidence_error_mix.vibe "$edpemdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edpemdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_error_mix.vibe did not compile" >&2
  cat "$edpemdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edpem_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edpemdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_error_mix.vibe got '$edpem_out' (want 5)" >&2
  echo "$edpem_out" >&2
  exit 1
fi
rm -rf "$edpemdir"
echo "[compiler-gate] evidence-dict pass Error::Throw mixing ok"

# 40x. ADR-0076 Phase 3 (#817): a function whose declared effect row
#      contains MULTIPLE effects (`{ Ask, Fs }`), discharged via a directly-
#      nested handle pair split across a wrapper function
#      (`ask_only_wrapper`'s body IS `handle {...} with Ask {...}`, itself
#      inside `compute`'s `handle {...} with Fs {...}`). BOTH effects now
#      migrate to evidence-dict independently: edp_has_unsafe_construct
#      recurses into a nested handle for a DIFFERENT effect instead of
#      unconditionally rejecting it (see inline_direct_perform.vibe's
#      edp_has_unsafe_construct doc comment; this shape used to disqualify
#      the outer effect entirely -- containment itself was tried and
#      reverted TWICE before either fix landed, both times crashing on an
#      unrelated rewrite-coverage bug, not a multi-effect-row issue -- see
#      edp_row_is_exactly's doc comment for that history). With neither
#      effect left on the old replay/frontier machinery, `compute`'s
#      handled body now runs EXACTLY ONCE end to end -- this gate pins the
#      semantically-ideal value (2017), not the old replay-inflated
#      fallback value (3018) an earlier, less complete version of this
#      pass used to produce for the same program.
echo "[compiler-gate] 40x/40 evidence-dict pass: multi-effect row migrates both effects through a nested handle pair (ADR-0076 Phase 3/#817)"
edpmedir="_build/_gate_evidence_dict_multi_effect"
rm -rf "$edpmedir"; mkdir -p "$edpmedir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_multi_effect_row_nested.vibe "$edpmedir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edpmedir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_multi_effect_row_nested.vibe did not compile" >&2
  cat "$edpmedir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edpme_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edpmedir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_multi_effect_row_nested.vibe got '$edpme_out' (want 2017) -- multi-effect nested-handle migration regressed" >&2
  echo "$edpme_out" >&2
  exit 1
fi
rm -rf "$edpmedir"
echo "[compiler-gate] evidence-dict pass multi-effect row nested-handle migration ok"

# 40z. ADR-0076 Phase 3 (#817): a minimal directly-nested handle pair for
#      TWO DIFFERENT effects (`handle { handle { both() } with A {...} }
#      with B {...}`), no wrapper-function indirection at all -- the
#      general case edp_has_unsafe_construct's nested-EHandle relaxation
#      targets, isolated from gate 40x's multi-effect-row-plus-wrapper-
#      function combination. Verified (via a temporary migration-plan
#      probe during development) that BOTH `A` and `B` genuinely migrate to
#      evidence-dict; this gate pins the resulting value (7 == 3 + 4).
echo "[compiler-gate] 40z/40 evidence-dict pass: minimal directly-nested handle pair, both effects migrate (ADR-0076 Phase 3/#817)"
edpnhdir="_build/_gate_evidence_dict_nested_handles"
rm -rf "$edpnhdir"; mkdir -p "$edpnhdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_multi_effect_nested_handles.vibe "$edpnhdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edpnhdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_multi_effect_nested_handles.vibe did not compile" >&2
  cat "$edpnhdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edpnh_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edpnhdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_multi_effect_nested_handles.vibe got '$edpnh_out' (want 7) -- directly-nested handle pair migration regressed" >&2
  echo "$edpnh_out" >&2
  exit 1
fi
rm -rf "$edpnhdir"
echo "[compiler-gate] evidence-dict pass directly-nested handle pair migration ok"

# 40y. ADR-0076 Phase 3 (#817): a `perform` bound via `let` inside a needing
#      function's OWN body (`let a = perform Ask::Get; a + 1`), rather than
#      written as a bare tail expression, used to compile cleanly but crash
#      at runtime with an UNCAUGHT exception. edp_rewrite_needing_body (and
#      its handle-site counterpart edp_rewrite_handle_body) rewrite a
#      needing function's body by pattern-matching the same shapes
#      edp_has_unsafe_construct already verified are safe, but the two
#      traversals used to disagree about which positions they visit --
#      edp_has_unsafe_construct correctly recurses into ELet's/EAssign's
#      value/RHS position (among several others: EIf's condition, EMatch's
#      scrutinee, EWhile/EForIn/ELoop bodies, ...) when deciding
#      eligibility, but the two rewrite traversals only recursed into a
#      narrower set of positions. A perform reached only through one of the
#      skipped positions passed eligibility (nothing unsafe about it, by
#      has_unsafe_construct's own correct judgment) but was silently left
#      un-rewritten -- still a raw `perform`, throwing a tag the enclosing
#      handle site no longer catches once migration drops it. Found via
#      runtime instrumentation (temporarily exporting every per-effect wasm
#      exception tag by name) while investigating an unrelated multi-
#      effect-row crash; reproducible with a single exact-match effect,
#      independent of that investigation. Fixed by making both rewrite
#      traversals structurally mirror edp_has_unsafe_construct's coverage
#      exactly.
echo "[compiler-gate] 40y/40 evidence-dict pass: perform bound via let inside a needing function's own body (ADR-0076 Phase 3/#817)"
edpletdir="_build/_gate_evidence_dict_let_bound"
rm -rf "$edpletdir"; mkdir -p "$edpletdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_call_evidence_let_bound.vibe "$edpletdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edpletdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_let_bound.vibe did not compile" >&2
  cat "$edpletdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edplet_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edpletdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_let_bound.vibe got '$edplet_out' (want 6) -- let-bound perform inside a needing function's body regressed (either an uncaught-exception crash or a wrong value)" >&2
  echo "$edplet_out" >&2
  exit 1
fi
rm -rf "$edpletdir"
echo "[compiler-gate] evidence-dict pass let-bound perform ok"

# 40aa. ADR-0076 Phase 3 (#817): a needing function's body calls an
#       ordinary user-defined PURE helper function (no `with` clause, so
#       the checker has already proven it performs no effect) that is
#       neither a needing function itself nor a hand-listed
#       `edp_pure_builtin_names` entry. edp_has_unsafe_construct now
#       recognizes a call to any function whose OWN declared effect row is
#       checker-verified empty (edp_pure_fn_names) as safe, generalizing
#       the old hand-audited builtin allowlist to every pure user-defined
#       function -- verified (via a temporary migration-plan probe during
#       development) that `Ask` genuinely migrates here, not merely
#       "produces the right answer via replay by coincidence".
echo "[compiler-gate] 40aa/40 evidence-dict pass: call to a plain user-defined pure helper function (ADR-0076 Phase 3/#817)"
edppurdir="_build/_gate_evidence_dict_pure_helper"
rm -rf "$edppurdir"; mkdir -p "$edppurdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_call_evidence_pure_helper.vibe "$edppurdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edppurdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_pure_helper.vibe did not compile" >&2
  cat "$edppurdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edppur_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edppurdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_pure_helper.vibe got '$edppur_out' (want 11) -- pure-helper-call eligibility regressed" >&2
  echo "$edppur_out" >&2
  exit 1
fi
rm -rf "$edppurdir"
echo "[compiler-gate] evidence-dict pass pure-helper call ok"

# 40ab. ADR-0076 Phase 3 (#817): a needing function's body reads a struct
#       field (`b.value`, an `EDot`) rather than only ever binding/
#       returning plain values. edp_has_unsafe_construct's `EDot` case
#       used to be unconditionally unsafe (deliberately conservative --
#       this AST-level pass has no type information); it now recurses
#       into the object expression instead, since a bare `.field` READ
#       (not a call through it) cannot itself hide a perform or a
#       needing-call regardless of the field's static type. Verified (via
#       a temporary migration-plan probe during development) that `Ask`
#       genuinely migrates here.
echo "[compiler-gate] 40ab/40 evidence-dict pass: struct field read via EDot (ADR-0076 Phase 3/#817)"
edpdotdir="_build/_gate_evidence_dict_struct_field"
rm -rf "$edpdotdir"; mkdir -p "$edpdotdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_call_evidence_struct_field.vibe "$edpdotdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edpdotdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_struct_field.vibe did not compile" >&2
  cat "$edpdotdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edpdot_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edpdotdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_struct_field.vibe got '$edpdot_out' (want 6) -- EDot eligibility regressed" >&2
  echo "$edpdot_out" >&2
  exit 1
fi
rm -rf "$edpdotdir"
echo "[compiler-gate] evidence-dict pass struct field read ok"

# 40ac. ADR-0076 Phase 3 (#817): a needing function's body defines a
#       closure LITERAL that itself performs the migrated effect
#       (deliberately never invoked -- see the fixture's own doc comment
#       for why calling an arbitrary local closure remains a separate,
#       unaddressed restriction). edp_has_unsafe_construct's `EFn` case
#       used to be unconditionally unsafe regardless of what the
#       closure's own body contained; it now recurses into the body the
#       same way as everywhere else. Verified (via a temporary
#       migration-plan probe during development) that `Ask` genuinely
#       migrates and the rewrite of the closure's body (dict capture)
#       produces valid wasm even though the closure is unreachable.
echo "[compiler-gate] 40ac/40 evidence-dict pass: closure literal defining a perform (ADR-0076 Phase 3/#817)"
edpclodir="_build/_gate_evidence_dict_closure_literal"
rm -rf "$edpclodir"; mkdir -p "$edpclodir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_call_evidence_closure_literal.vibe "$edpclodir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edpclodir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_closure_literal.vibe did not compile" >&2
  cat "$edpclodir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edpclo_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edpclodir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_closure_literal.vibe got '$edpclo_out' (want 6) -- closure-literal eligibility regressed" >&2
  echo "$edpclo_out" >&2
  exit 1
fi
rm -rf "$edpclodir"
echo "[compiler-gate] evidence-dict pass closure literal ok"

# 40ad. ADR-0076 Phase 3 (#817): a needing function's row is spelled with an
#       `effectset` alias (`with AskAll` where `effectset AskAll = {
#       Ask }`) instead of the bare effect name. checker_stmt.vibe's own
#       effectset expansion deliberately runs on a non-mutating copy of
#       `stmts` used only for type-checking ("codegen never reads the row's
#       text content") -- codegen (this pass included) actually sees the
#       row string still literally "AskAll", so it silently fell back to
#       replay no matter how simple the alias. Fixed with a small local
#       (re-)expansion of the effectset tables inside
#       inline_direct_perform.vibe itself (edp_es_collect_into/
#       edp_resolve_effect_names_into), the same pattern wit_gen.vibe/
#       contract.vibe/checker_stmt.vibe each already use for their own
#       consumers of effect-row text. This gate's fixture uses the same
#       replay-vs-evidence-dict `count` discriminator as gate 40u's own
#       fixture: pinning `count == 2` (not replay-inflated) is what proves
#       migration genuinely happened, not merely that the answer still
#       looks plausible via the pre-existing fallback.
echo "[compiler-gate] 40ad/40 evidence-dict pass: needing function's row spelled via an effectset alias (ADR-0076 Phase 3/#817)"
edpesdir="_build/_gate_evidence_dict_effectset_alias"
rm -rf "$edpesdir"; mkdir -p "$edpesdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_call_evidence_effectset_alias.vibe "$edpesdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edpesdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_effectset_alias.vibe did not compile" >&2
  cat "$edpesdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edpes_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edpesdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_effectset_alias.vibe got '$edpes_out' (want 2007) -- either effectset-alias row recognition regressed, or it regressed back to the replay-inflated value" >&2
  echo "$edpes_out" >&2
  exit 1
fi
rm -rf "$edpesdir"
echo "[compiler-gate] evidence-dict pass effectset alias ok"

# 40ae. ADR-0076 Phase 3 (#817): a needing function's row directly
#       enumerates a QUALIFIED operation (`with Ask::Get`) instead of
#       the bare effect name -- no `effectset` alias involved, exercising
#       edp_effect_name_of's `::`-prefix stripping directly rather than
#       effectset-table expansion (gate 40ad's own code path). Completeness
#       check written alongside the effectset-alias fix.
echo "[compiler-gate] 40ae/40 evidence-dict pass: needing function's row is a directly-qualified operation (ADR-0076 Phase 3/#817)"
edpqodir="_build/_gate_evidence_dict_qualified_op"
rm -rf "$edpqodir"; mkdir -p "$edpqodir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_call_evidence_qualified_op.vibe "$edpqodir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edpqodir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_qualified_op.vibe did not compile" >&2
  cat "$edpqodir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edpqo_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edpqodir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_qualified_op.vibe got '$edpqo_out' (want 2007) -- qualified-operation row recognition regressed, or it regressed back to the replay-inflated value" >&2
  echo "$edpqo_out" >&2
  exit 1
fi
rm -rf "$edpqodir"
echo "[compiler-gate] evidence-dict pass qualified-operation row ok"

# 40af. ADR-0076 Phase 3 (#817): a needing function's row combines a
#       concrete effect with an open row-variable TAIL (`with Ask + e`).
#       Initially assumed a genuine limitation alongside the
#       fully-row-polymorphic case; verified directly instead of continuing
#       to assume -- this already migrates its concrete effect via the same
#       row-containment mechanism as any other multi-effect row, since the
#       row-variable token never matches a real declared effect name and
#       is therefore inert to this pass's own matching logic.
echo "[compiler-gate] 40af/40 evidence-dict pass: row combines a concrete effect with an open row-variable tail (ADR-0076 Phase 3/#817)"
edprvdir="_build/_gate_evidence_dict_row_variable_tail"
rm -rf "$edprvdir"; mkdir -p "$edprvdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_call_evidence_row_variable_tail.vibe "$edprvdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edprvdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_row_variable_tail.vibe did not compile" >&2
  cat "$edprvdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edprv_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edprvdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_row_variable_tail.vibe got '$edprv_out' (want 2007) -- row-variable-tail row recognition regressed, or it regressed back to the replay-inflated value" >&2
  echo "$edprv_out" >&2
  exit 1
fi
rm -rf "$edprvdir"
echo "[compiler-gate] evidence-dict pass row-variable-tail row ok"

# 40ag. ADR-0076 Phase 3 (#817) + #786: a needing function's body calls a
#       locally `let`-bound, CAPTURE-FREE closure that performs the
#       migrated effect (not a top-level function name). #786 already
#       lambda-lifts such a closure to a fresh top-level binding BEFORE
#       evidence_dict_pass ever runs, so the call site becomes an ordinary
#       call to a genuine top-level function -- no evidence_dict_pass
#       changes needed for this to migrate correctly. This gate locks in
#       that composition. (The CAPTURING case remains broken independent
#       of evidence_dict_pass entirely -- #1069, a pre-existing closure-
#       codegen bug #786's landed fix explicitly declined to touch.)
echo "[compiler-gate] 40ag/40 evidence-dict pass: needing function calls a capture-free local closure (ADR-0076 Phase 3/#817, #786)"
edplccfdir="_build/_gate_evidence_dict_local_closure_capture_free"
rm -rf "$edplccfdir"; mkdir -p "$edplccfdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_call_evidence_local_closure_capture_free.vibe "$edplccfdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edplccfdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_local_closure_capture_free.vibe did not compile" >&2
  cat "$edplccfdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edplccf_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edplccfdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_local_closure_capture_free.vibe got '$edplccf_out' (want 2007) -- either #786's hoist regressed or evidence_dict_pass no longer forwards to the hoisted top-level name" >&2
  echo "$edplccf_out" >&2
  exit 1
fi
rm -rf "$edplccfdir"
echo "[compiler-gate] evidence-dict pass capture-free local closure call ok"

# 40ah. #1069: a locally `let`-bound effectful closure that CAPTURES an
#       ordinary enclosing local (a function parameter AND a local, in this
#       fixture) used to miscompile to invalid wasm at instantiation --
#       #786's own landed fix only lambda-lifts the CAPTURE-FREE case,
#       leaving a capturing closure on the original broken local-closure+
#       effect combinator path. Fixed via closure conversion in
#       desugar_trait_dict.vibe's dlh_hoist_expr: a provably-safe capturing
#       closure (every call site direct, no captured name ever reassigned)
#       is now ALSO lambda-lifted, with captures threaded through as extra
#       leading parameters.
echo "[compiler-gate] 40ah/40 local effectful closure capturing an enclosing local now compiles and runs (#1069)"
lcccdir="_build/_gate_local_closure_capture_conversion"
rm -rf "$lcccdir"; mkdir -p "$lcccdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_local_closure_capture_conversion.vibe "$lcccdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$lcccdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_capture_conversion.vibe did not compile" >&2
  cat "$lcccdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! lccc_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$lcccdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_local_closure_capture_conversion.vibe got '$lccc_out' (want 1015) -- #1069's closure conversion regressed" >&2
  echo "$lccc_out" >&2
  exit 1
fi
rm -rf "$lcccdir"
echo "[compiler-gate] local effectful closure capture conversion ok (#1069)"

# 40ai. #1070 (narrow slice): a capturing effectful local closure passed BY
#       VALUE to a trivial pass-through wrapper (`apply = (f) -> { f() }`)
#       used to crash at runtime -- #1069's closure conversion only
#       rewrites provably-direct call sites, and `apply(inner)` uses
#       `inner` as a bare argument, not a direct call target. Fixed by
#       dtpw_inline_trivial_wrappers (desugar_trait_dict.vibe), which
#       rewrites `apply(inner)` into `inner()` BEFORE #786/#1069's hoist+
#       conversion logic runs, whenever `apply`'s entire body is provably
#       just a same-arity direct call to its own sole parameter -- always
#       sound (identity-wrapper inlining changes no observable behavior),
#       leaving `apply`'s own definition untouched for any other use.
echo "[compiler-gate] 40ai/40 capturing effectful closure passed by value through a trivial wrapper (#1070 narrow slice)"
lcbvwdir="_build/_gate_local_closure_by_value_wrapper"
rm -rf "$lcbvwdir"; mkdir -p "$lcbvwdir"
# #1571: inspect() test block in the fixture, compiled as-is (see the gc site
# for this same fixture above).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_local_closure_by_value_wrapper.vibe "$lcbvwdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$lcbvwdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_wrapper.vibe did not compile" >&2
  cat "$lcbvwdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! lcbvw_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$lcbvwdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_wrapper.vibe failed its inspect (want 105) -- #1070's trivial-wrapper inlining regressed" >&2
  echo "$lcbvw_out" >&2
  exit 1
fi
rm -rf "$lcbvwdir"
echo "[compiler-gate] local effectful closure passed through trivial wrapper ok (#1070 narrow slice)"

# 40aj. #1070 narrow-slice safety boundary: dtpw_inline_trivial_wrappers must
#       only rewrite call sites syntactically named after the wrapper itself
#       (`apply(...)`). `apply` used as an ordinary VALUE -- aliased into
#       another binding and called through THAT binding -- must keep working
#       via apply's own untouched top-level definition, unaffected by the
#       inlining pass.
echo "[compiler-gate] 40aj/40 trivial-wrapper inlining leaves wrapper-as-value references correct (#1070 narrow slice)"
lcwrvdir="_build/_gate_local_closure_wrapper_referenced_as_value"
rm -rf "$lcwrvdir"; mkdir -p "$lcwrvdir"
# #1571 (first slice): this fixture carries its expectation as an
# `inspect(main(), "30")` test block rather than a `__DATA__` tail, so it is
# compiled AS-IS -- no `sed` strip, no temp copy (its `import ../lib/@vibe/core`
# has to resolve from fixtures/ anyway) -- and the expected value lives beside
# the code that produces it, updatable with `vibe test --update`. Entry is
# `__no_entry__`, which synthesizes the test-block runner; a mismatch prints
# actual vs expected from inside the run, so the output is surfaced on failure.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_local_closure_wrapper_referenced_as_value.vibe "$lcwrvdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$lcwrvdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_wrapper_referenced_as_value.vibe did not compile" >&2
  cat "$lcwrvdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! lcwrv_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$lcwrvdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_local_closure_wrapper_referenced_as_value.vibe tests failed -- trivial-wrapper inlining broke a wrapper-as-value reference" >&2
  echo "$lcwrv_out" >&2
  exit 1
fi
rm -rf "$lcwrvdir"
echo "[compiler-gate] trivial-wrapper inlining wrapper-as-value reference ok (#1070 narrow slice)"

# 40ak. #1070 narrow-slice safety boundary: dtpw_collect_wrappers must only
#       recognize a wrapper whose body is EXACTLY a same-arity direct call
#       to its own sole parameter with NO extra arguments. A function that
#       calls its parameter WITH an argument is a different shape and must
#       be left completely untouched -- inlining it the same way would drop
#       the call's argument (the exact class of bug caught in
#       dtpw_inline_expr's first draft before it shipped).
echo "[compiler-gate] 40ak/40 trivial-wrapper inlining does not misfire on wrong-arity wrapper bodies (#1070 narrow slice)"
lcwadir="_build/_gate_local_closure_wrapper_wrong_arity"
rm -rf "$lcwadir"; mkdir -p "$lcwadir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/local_closure_wrapper_wrong_arity_not_inlined.vibe "$lcwadir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$lcwadir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: local_closure_wrapper_wrong_arity_not_inlined.vibe did not compile" >&2
  cat "$lcwadir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! lcwa_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$lcwadir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: local_closure_wrapper_wrong_arity_not_inlined.vibe got '$lcwa_out' (want 6) -- trivial-wrapper pattern misfired on a wrong-arity call" >&2
  echo "$lcwa_out" >&2
  exit 1
fi
rm -rf "$lcwadir"
echo "[compiler-gate] trivial-wrapper inlining wrong-arity non-match ok (#1070 narrow slice)"

# 40al. Found while investigating effect_row_open.vibe (2026-07-23): an
#       inline `EFn` lambda literal -- never let-bound to a name -- that
#       performs an effect, either as a bare IIFE or passed as a CALL
#       ARGUMENT to a named function that calls it internally, evaded every
#       existing local-closure fix (#786/#1069/#1070, all pattern-matching
#       on `ELet(name, EFn(...), body)`) and produced invalid wasm /
#       crashed at runtime. Fixed in desugar_trait_dict.vibe's
#       dlh_hoist_expr: an IIFE desugars into the already-handled
#       `ELet(fresh, EFn(...), fresh())` shape; a literal-EFn call argument
#       is let-bound immediately before the call
#       (dlh_letbind_literal_args). Both reduce to the existing, separately
#       -verified ELet/EFn hoist logic. Scope: capture-free literals only
#       (a capturing literal passed as a HOF argument still hits #1070's
#       already-known general case -- see the fixture's own doc comment).
echo "[compiler-gate] 40al/40 inline effectful lambda literal (IIFE / HOF argument, capture-free) no longer crashes"
illhadir="_build/_gate_inline_lambda_literal_hof_arg"
rm -rf "$illhadir"; mkdir -p "$illhadir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_inline_lambda_literal_hof_arg.vibe "$illhadir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$illhadir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_inline_lambda_literal_hof_arg.vibe did not compile" >&2
  cat "$illhadir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! illha_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$illhadir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_inline_lambda_literal_hof_arg.vibe got '$illha_out' (want 10) -- inline lambda literal IIFE/HOF-arg fix regressed" >&2
  echo "$illha_out" >&2
  exit 1
fi
rm -rf "$illhadir"
echo "[compiler-gate] inline effectful lambda literal IIFE/HOF-arg fix ok (10)"

# 40am. Found while verifying gate 40al against labeled-argument syntax
#       (2026-07-23): a literal EFn one layer inside an ELabeledArg wrapper
#       (`with_log(f = () -> ... { perform ... })`) evaded that fix
#       entirely -- dlh_args_have_literal_efn/dlh_letbind_literal_args only
#       matched a BARE EFn argument. Fixed by recursing one layer into
#       ELabeledArg in both helpers.
echo "[compiler-gate] 40am/40 inline effectful lambda literal as a LABELED call argument no longer crashes"
illladir="_build/_gate_inline_lambda_literal_labeled_arg"
rm -rf "$illladir"; mkdir -p "$illladir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_inline_lambda_literal_labeled_arg.vibe "$illladir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$illladir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_inline_lambda_literal_labeled_arg.vibe did not compile" >&2
  cat "$illladir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! illla_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$illladir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_inline_lambda_literal_labeled_arg.vibe got '$illla_out' (want 5) -- labeled-arg literal fix regressed" >&2
  echo "$illla_out" >&2
  exit 1
fi
rm -rf "$illladir"
echo "[compiler-gate] inline effectful lambda literal labeled-arg fix ok (5)"

# 40an. #1074 PR review (chatgpt-codex-connector, P1): trivial-wrapper
#       inlining (#1070 narrow slice) used to match `apply(arg)` call sites
#       by NAME ONLY, with no scope tracking -- a local binding (here, a
#       function parameter) reusing a top-level trivial wrapper's name got
#       incorrectly rewritten too, silently calling the wrong thing. Fixed
#       by dropping a wrapper name entirely if it's ever shadowed anywhere
#       in the program (dtpw_collect_wrappers).
echo "[compiler-gate] 40an/40 trivial-wrapper inlining respects lexical shadowing (#1074 review)"
dtpwsdir="_build/_gate_dtpw_wrapper_shadowed"
rm -rf "$dtpwsdir"; mkdir -p "$dtpwsdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/dtpw_wrapper_shadowed_by_parameter.vibe "$dtpwsdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$dtpwsdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: dtpw_wrapper_shadowed_by_parameter.vibe did not compile" >&2
  cat "$dtpwsdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! dtpws_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$dtpwsdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: dtpw_wrapper_shadowed_by_parameter.vibe got '$dtpws_out' (want 99) -- trivial-wrapper shadowing fix regressed" >&2
  echo "$dtpws_out" >&2
  exit 1
fi
rm -rf "$dtpwsdir"
echo "[compiler-gate] trivial-wrapper inlining shadowing fix ok (99)"

# 40ao. #1074 PR review (chatgpt-codex-connector, P1): evidence_dict_pass's
#       needing-forwarding rewrite (edp_rewrite_needing_body) also matched
#       a call's callee by NAME ONLY against the global `needing` set, with
#       no scope tracking -- a local binding shadowing a needing function's
#       name got the evidence-dict argument incorrectly prepended to ITS
#       calls too, even though the local closure was never rewritten to
#       accept it (arity mismatch / invalid call). Fixed by
#       edp_drop_shadowed_needing, applied unconditionally alongside the
#       existing self-discharging-needing filter.
echo "[compiler-gate] 40ao/40 evidence-dict needing-forwarding respects lexical shadowing (#1074 review)"
edpsdir="_build/_gate_edp_needing_shadowed"
rm -rf "$edpsdir"; mkdir -p "$edpsdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/evidence_dict_needing_shadowed_by_local.vibe "$edpsdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edpsdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: evidence_dict_needing_shadowed_by_local.vibe did not compile" >&2
  cat "$edpsdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edps_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edpsdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: evidence_dict_needing_shadowed_by_local.vibe got '$edps_out' (want 47) -- evidence-dict needing-forwarding shadowing fix regressed" >&2
  echo "$edps_out" >&2
  exit 1
fi
rm -rf "$edpsdir"
echo "[compiler-gate] evidence-dict needing-forwarding shadowing fix ok (47)"

# 40ap. #1070 (general case): a needing function calling its OWN
#       closure-typed parameter (not another named needing function) --
#       `apply_twice`'s body calls `f` (a `with Ask`-typed parameter)
#       twice, so #1074's trivial-pass-through-wrapper inlining (a single
#       same-arity call only) correctly declines to touch it. Previously
#       this crashed at runtime ("null function or function signature
#       mismatch"): the indirect call to `f` carried no evidence for
#       `Ask`. Fixed by extending evidence_dict_pass to treat a call
#       through a closure-typed parameter exactly like a call to another
#       needing function (dict forwarded the same way), but ONLY when
#       every call site of the owning function can be proven, across the
#       whole program, to pass a migratable closure literal at that exact
#       position (edp_closure_param_universally_safe/edp_own_closure_
#       params in inline_direct_perform.vibe) -- both the caller
#       (`apply_twice`) and the callee value (`inner`) are migrated
#       together, never just one side.
echo "[compiler-gate] 40ap/40 evidence-dict forwarding through an own closure-typed HOF parameter (#1070 general case)"
edpgdir="_build/_gate_edp_closure_hof_general"
rm -rf "$edpgdir"; mkdir -p "$edpgdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_local_closure_by_value_hof_general.vibe "$edpgdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edpgdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_hof_general.vibe did not compile" >&2
  cat "$edpgdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edpg_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edpgdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_hof_general.vibe got '$edpg_out' (want 210) -- #1070 general-case closure-HOF-parameter fix regressed" >&2
  echo "$edpg_out" >&2
  exit 1
fi
rm -rf "$edpgdir"
echo "[compiler-gate] evidence-dict forwarding through own closure-typed HOF parameter ok (210)"

# 40aq. #1070 general-case safety boundary: a capturing effectful local
#       closure used MORE than once (once passed by value into a
#       closure-typed HOF parameter, once called directly) must NOT be
#       migrated -- edp_closure_param_universally_safe can only prove a
#       parameter position safe when every flow into it is a provably
#       single-use closure literal; a second, unrelated use makes that
#       unprovable, so the whole position stays on the pre-existing
#       (unsafe -> replay) fallback instead of migrating one side without
#       the other (which would be a wrong-arity miscompile, not just a
#       missed optimization).
echo "[compiler-gate] 40aq/40 closure-typed HOF parameter safety boundary: multi-use closure stays unmigrated (#1070 general case)"
edpedir="_build/_gate_edp_closure_hof_escaping"
rm -rf "$edpedir"; mkdir -p "$edpedir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_local_closure_by_value_hof_escaping.vibe "$edpedir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edpedir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_hof_escaping.vibe did not compile" >&2
  cat "$edpedir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edpe_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edpedir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_hof_escaping.vibe got '$edpe_out' (want 206) -- #1070 closure-HOF-parameter safety boundary regressed" >&2
  echo "$edpe_out" >&2
  exit 1
fi
rm -rf "$edpedir"
echo "[compiler-gate] closure-typed HOF parameter safety boundary ok (206)"
# #1070 final sub-case (pure closure STORED through a by-value param,
# outliving the callee frame): historically the 3rd stored closure corrupted
# the RC heap (`unreachable` on a later read), and only an inline-store
# workaround avoided it (@vibe/concurrent Nursery::spawn was the canary).
# Now fixed; pin BOTH RC lanes -- the corruption was RC bookkeeping, so the
# bump lane alone cannot see a regression.
cbvsdir="_build/_gate_closure_by_value_store"
rm -rf "$cbvsdir"; mkdir -p "$cbvsdir"
for cbvs_rc in 1 0; do
  VIBE_RC="$cbvs_rc" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    fixtures/closure_by_value_store_test.vibe "$cbvsdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$cbvsdir/out.wasm" ]; then
    echo "[compiler-gate] FAIL: closure_by_value_store_test.vibe did not compile under VIBE_RC=$cbvs_rc" >&2
    cat "$cbvsdir/out.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  if ! cbvs_out="$(VIBE_RC="$cbvs_rc" VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$cbvsdir/out.wasm" 2>&1)"; then
    echo "[compiler-gate] FAIL: closure_by_value_store_test.vibe under VIBE_RC=$cbvs_rc got '$cbvs_out' -- #1070 stored-closure ABI regressed" >&2
    echo "$cbvs_out" >&2
    exit 1
  fi
  rm -f "$cbvsdir/out.wasm" "$cbvsdir/out.wasm.diag"
done
rm -rf "$cbvsdir"
echo "[compiler-gate] stored-by-value closure ABI ok (#1070 final sub-case, RC both modes)"

# 40ar. #1070 (general case, second slice -- docs/effect-evidence-passing.md
#       追記25): a SELF-DISCHARGING owner -- a function with NO `with Ask`
#       row that establishes its own `handle .. with Ask` and calls its
#       closure-typed parameter inside that handle's body. Never "needing"
#       (no row), so 40ap's edp_own_closure_params path can't see it; was
#       the exact shape #1077's original lsp_run_with_handler trapped on
#       under real wasmtime. Fixed by edp_handle_owner_cps
#       (inline_direct_perform.vibe): same universal call-site proof as
#       40ap plus the two extra guards a missing row makes necessary (no
#       value references to the owner; every param use is a direct call
#       inside the owner's own Ask-handle bodies).
echo "[compiler-gate] 40ar/40 self-discharging owner's closure-typed parameter (#1070 general case, second slice)"
edphdir="_build/_gate_edp_handle_owner_param"
rm -rf "$edphdir"; mkdir -p "$edphdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_local_closure_handle_owner_param.vibe "$edphdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edphdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_handle_owner_param.vibe did not compile" >&2
  cat "$edphdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! edph_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edphdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_local_closure_handle_owner_param.vibe got '$edph_out' (want 285) -- #1070 self-discharging-owner closure-param fix regressed" >&2
  echo "$edph_out" >&2
  exit 1
fi
rm -rf "$edphdir"
echo "[compiler-gate] self-discharging owner's closure-typed parameter ok (285)"
