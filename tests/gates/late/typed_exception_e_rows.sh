#!/usr/bin/env bash
# Sourced by this lane's run.sh; shares its resolved compiler and gate state.
# 85/85. ADR-0085 typed exceptions (#1344): `throw(v)` requires
# `Exception[typeof(v)]` in the enclosing row, `Exception[E1]` neither
# authorizes nor discharges `Exception[E2]`, and the ERASED spellings
# (`Error` / `Exception`) stay compatible with every kind -- which is what
# makes the feature additive for the codebase's ~970 un-annotated throw sites.
# Positive: the typed-row fixture compiles and runs to 42 (so every spelling
# still lowers to the one abortive Wasm tag). Negatives: a kind mismatch is
# rejected and NAMES the missing kind with a spelling that actually parses in a
# row, and a kinded `handle` does not catch a foreign kind.
echo "[compiler-gate] 85/85 typed Exception[E] rows (ADR-0085/#1344)"
excdir="_build/_gate_1344"
rm -rf "$excdir"; mkdir -p "$excdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/exception_typed_row.vibe "$excdir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$excdir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: exception_typed_row.vibe did not compile (Exception[E] rows / kinded handle / erased alias regressed)" >&2
  cat "$excdir/pos.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! exc_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$excdir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: exception_typed_row got '$exc_out' (want 42) -- kinded exceptions must share one Wasm tag" >&2
  echo "$exc_out" >&2
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_exception_kind_mismatch.vibe "$excdir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$excdir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: with Exception[ParseError] authorized an IoError throw -- exact-kind rows are not enforced (#1344)" >&2
  exit 1
fi
if ! grep -q "missing { Exception\[IoError\] }" "$excdir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the diagnostic must name the missing KIND (#1344)" >&2
  cat "$excdir/neg.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# #1344 follow-up: the same rejection when the payload is a LOCAL binder rather
# than an inline constructor application. Until the payload-kind scope was
# threaded through the perform walk this compiled -- a local's type was
# invisible to that (untyped) pass, so the throw fell back to the erased
# `Error::Throw`, which every exception row authorizes. That exempted exactly
# the shape #1324's migration produces.
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_exception_local_binder_kind.vibe "$excdir/neglocal.wasm" main >/dev/null 2>&1 || true
if [ -s "$excdir/neglocal.wasm" ]; then
  echo "[compiler-gate] FAIL: a LOCAL binder's throw payload was not kind-checked (#1344 follow-up)" >&2
  exit 1
fi
if ! grep -q "missing { Exception\[IoError\] }" "$excdir/neglocal.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the local-binder diagnostic must name the missing KIND (#1344 follow-up)" >&2
  cat "$excdir/neglocal.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# The fix-it must be pasteable: the row grammar takes `Eff::Op` and `Eff[T]`
# but NOT `Eff[T]::Op`, so a `Exception[IoError]::Throw` hint would name a
# label that does not parse. Feed the hint's row back through the compiler.
cat > "$excdir/fixit.vibe" <<'EOF'
enum IoError {
  NotFound(String)
}

enum ParseError {
  Eof
}

let boom = () -> Int with Exception[IoError] + Exception[ParseError] {
  throw(NotFound("cfg"))
}

let main = () -> Int {
  handle {
    boom()
  } with Exception {
    Throw(_e) => 42
  }
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$excdir/fixit.vibe" "$excdir/fixit.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$excdir/fixit.wasm" ]; then
  echo "[compiler-gate] FAIL: the row the kind-mismatch hint suggests does not itself compile (#1344)" >&2
  cat "$excdir/fixit.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
cat > "$excdir/handle.vibe" <<'EOF'
enum IoError {
  NotFound(String)
}

enum ParseError {
  Eof
}

let boom = () -> Int {
  handle {
    throw(NotFound("cfg"))
  } with Exception[ParseError] {
    Throw(_e) => 42
  }
}

let main = () -> Int {
  boom()
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$excdir/handle.vibe" "$excdir/handle.wasm" main >/dev/null 2>&1 || true
if [ -s "$excdir/handle.wasm" ]; then
  echo "[compiler-gate] FAIL: handle with Exception[ParseError] discharged an IoError throw (#1344)" >&2
  exit 1
fi
# #2985: a kinded arm is a catch-all at run time, so the checker now refuses
# the foreign kind AT THE HANDLE ("it also raises { Exception[IoError] }")
# instead of leaving it in the row ("missing { Exception[IoError] }"); either
# spelling proves the kind was not discharged.
if ! grep -qE "missing \{ Exception\[IoError\] \}|it also raises \{ Exception\[IoError\] \}" "$excdir/handle.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a kinded handle must not discharge the foreign kind (#1344, #2985)" >&2
  cat "$excdir/handle.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$excdir"
echo "[compiler-gate] typed Exception[E] rows ok"

echo "[compiler-gate] 86/86 string interpolation renders derive(Show) structurally (#1392)"
# `"\{v}"` lowers in the parser to `__to_string(v)`, before any type is
# known, so every aggregate used to render as the ADR-0058 heuristic's raw
# pointer decimal -- `derive(Show)` or not. desugar_trait_dict now retargets
# the call to the generated `T::to_string` (slice 1) and expands the wrapper
# shapes (slice 2) whenever it can resolve the argument. The fixture returns
# one DIGIT per case, 1 = ok, so a partial regression names itself by which
# digit went to zero -- see the fixture header for the mapping. This exact
# program returned 1 before #1392 and 11111 with slice 1 alone. The top two
# digits are the spelled-out `to_string(v)`: prelude defines it as an
# unconditional `__to_string(x)`, so it kept printing the pointer decimal after
# interpolation was already fixed. They live in this fixture so a change that
# fixes one spelling and breaks the other cannot pass.
showdir="_build/_gate_interp_show"
rm -rf "$showdir"; mkdir -p "$showdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/interp_show_derive.vibe "$showdir/show.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$showdir/show.wasm" ]; then
  echo "[compiler-gate] FAIL: interp_show_derive.vibe did not compile (#1392)" >&2
  cat "$showdir/show.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! show_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$showdir/show.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: interpolation rendering got '$show_out' (want 1111111111111111111) (#1392)" >&2
  echo "$show_out" >&2
  exit 1
fi
rm -rf "$showdir"
echo "[compiler-gate] interpolation Show rendering ok"

# #1766: Array/tuple type arguments used to be discarded from fn_returns, so
# interpolation of a structural function result passed check and printed its
# raw pointer. The positive fixture covers direct and let-bound results,
# nesting under Option, plus nominal controls. The negative fixture locks the
# fail-closed diagnostic for a nominal result without a renderer.
retshowdir="_build/_gate_interp_function_return"
rm -rf "$retshowdir"; mkdir -p "$retshowdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$stage2_wasm" fixtures/interp_function_return_test.vibe "$retshowdir/show.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$retshowdir/show.wasm" ]; then
  echo "[compiler-gate] FAIL: structural function-return interpolation fixture did not compile (#1766)" >&2
  exit 1
fi
if ! retshow_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$retshowdir/show.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: structural function-return interpolation rendered incorrectly (#1766)" >&2
  printf '%s\n' "$retshow_out" >&2
  exit 1
fi
set +e
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$stage2_wasm" fixtures/interp_function_return_missing_show_error.vibe "$retshowdir/missing.wasm" main >/dev/null 2>&1
retshow_status=$?
set -e
if [ "$retshow_status" -eq 0 ] || [ -s "$retshowdir/missing.wasm" ] || ! grep -q 'cannot interpolate a value of type `Hidden`' "$retshowdir/missing.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: missing renderer function result was not rejected actionably (#1766)" >&2
  cat "$retshowdir/missing.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$retshowdir"
echo "[compiler-gate] structural function-return interpolation ok"

echo "[compiler-gate] 87/87 uncaught throw reports the payload VALUE (#1374 / #1392 slice 3)"
# ADR-0085's runtime carries one abortive tag with no kind, so the entry
# boundary's erased `with Error` arm binds the payload at CtUnknown and can
# resolve neither a `T::to_string` nor a `[T: Show]` witness. #1374 gave it the
# payload's TYPE; slice 3 gives it the payload RENDERED at the throw site,
# where the type is still known. Three cases, because the interesting part is
# that the third did NOT regress: a type with no structural renderer must keep
# printing `<Kind>` rather than the pointer decimal a naive "trust any non-empty
# render" reader would emit.
exnmsgdir="_build/_gate_exn_msg"
rm -rf "$exnmsgdir"; mkdir -p "$exnmsgdir"
cat > "$exnmsgdir/shown.vibe" <<'VIBEEOF'
enum AppError {
  Failed(String);
  Cancelled
} derive (Show)

let _start = () -> Int with Exception {
  throw(Failed("io"))
}
VIBEEOF
cat > "$exnmsgdir/plain.vibe" <<'VIBEEOF'
let _start = () -> Int with Exception {
  throw("plain message")
}
VIBEEOF
cat > "$exnmsgdir/noshow.vibe" <<'VIBEEOF'
enum NoShow {
  Bang(Int)
}

let _start = () -> Int with Exception {
  throw(Bang(5))
}
VIBEEOF
exn_msg_expect() {
  local name="$1" want="$2"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$exnmsgdir/$name.vibe" "$exnmsgdir/$name.wasm" _start >/dev/null 2>&1 || true
  if [ ! -s "$exnmsgdir/$name.wasm" ]; then
    echo "[compiler-gate] FAIL: $name.vibe did not compile (#1392 slice 3)" >&2
    cat "$exnmsgdir/$name.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  local got
  if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$exnmsgdir/$name.wasm" >"$exnmsgdir/$name.stdout" 2>"$exnmsgdir/$name.stderr"; then
    echo "[compiler-gate] FAIL: $name uncaught exception exited 0 (#1945)" >&2
    exit 1
  fi
  got="$(grep "uncaught error" "$exnmsgdir/$name.stderr" | head -1)"
  if [ "$got" != "vibe: uncaught error: $want" ]; then
    echo "[compiler-gate] FAIL: $name got '$got' (want 'vibe: uncaught error: $want') (#1392 slice 3)" >&2
    exit 1
  fi
}
# derive(Show) enum: the VALUE, not `<AppError>` (which is what #1374 printed).
exn_msg_expect shown "Failed(io)"
# String payload: `__to_string` is the identity, output unchanged.
exn_msg_expect plain "plain message"
# No structural renderer: the kind, NOT the pointer decimal.
exn_msg_expect noshow "<NoShow>"
# #1398 review (Codex P1): the render is SYNTHESIZED, runs on every throw even
# when no handler reads it, and its effects are absent from the throwing
# function's checked row -- so it must only ever call a renderer this pass
# GENERATED. A hand-written `T::to_string` is called for an interpolation the
# user wrote and for nothing else. Before the fix this program printed
# "FORMATTER RAN" twice; a formatter that threw would have replaced the
# original exception outright.
cat > "$exnmsgdir/handwritten.vibe" <<'VIBEEOF'
enum Boom {
  Bang(Int)
}

fn Boom::to_string(self: Boom) -> String with Console {
  println("FORMATTER RAN")
  "boom"
}

let _start = () -> Int with Console {
  println("interp=\{Bang(1)}")
  handle {
    throw(Bang(1))
  } with Exception {
    Throw(_m) => 7
  }
}
VIBEEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$exnmsgdir/handwritten.vibe" "$exnmsgdir/handwritten.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$exnmsgdir/handwritten.wasm" ]; then
  echo "[compiler-gate] FAIL: handwritten.vibe did not compile (#1398 review P1)" >&2
  cat "$exnmsgdir/handwritten.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
hw_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$exnmsgdir/handwritten.wasm" 2>&1)"
hw_runs="$(printf '%s\n' "$hw_out" | grep -c "FORMATTER RAN" || true)"
if [ "$hw_runs" != "1" ]; then
  echo "[compiler-gate] FAIL: hand-written formatter ran $hw_runs time(s), want 1 (#1398 review P1)" >&2
  printf '%s\n' "$hw_out" >&2
  exit 1
fi
if ! printf '%s\n' "$hw_out" | grep -q "^interp=boom$"; then
  echo "[compiler-gate] FAIL: an EXPLICIT interpolation must still use the hand-written formatter (#1398 review P1)" >&2
  printf '%s\n' "$hw_out" >&2
  exit 1
fi
rm -rf "$exnmsgdir"
echo "[compiler-gate] uncaught throw payload rendering ok"

echo "[compiler-gate] 88/88 a closure-captured let mut is always a HEADERED RC cell (ADR-0092/#1262)"
# The ref-cell contract used to be half-conditional: the name went into
# ctx.ref_cell_names unconditionally, but the RC-managed (headered) cell was
# only built when expr_is_intish(value) held. expr_is_intish accepts no unary
# op but `!`, so `let mut i = -1` alone took the raw 8-byte HEADERLESS box --
# while compile_lambda still treated the capture as RC-owned (odd tagging +
# emit_rc_word_inc_saturating at box-4 + the class-7 recursive __rt_rc_drop).
# That incremented whatever preceded the box and pushed a headerless pointer
# onto the RC free list; the allocator's walk later followed a wild link and
# trapped far away -- the long-standing "all-RC bootstrap" OOB.
#
# The program's OUTPUT does not witness this (the corrupted neighbour is
# usually dead), so the lock asserts the ALLOCATOR INVARIANT instead:
# rc_patch_freelist_assert.py splices "trap if alloc_size == 0" into
# __rt_rc_drop (a post-hoc binary patch -- wasm code is outside linear memory,
# so it cannot move the guest heap), and a headerless box reaching a drop
# turns into `unreachable`. Verified to fire on the pre-fix codegen.
refcelldir="_build/_gate_rc_ref_cell"
rm -rf "$refcelldir"; mkdir -p "$refcelldir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  VIBE_RC=1 VIBE_WASM_NAMES=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/rc_captured_let_mut.vibe "$refcelldir/cell.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$refcelldir/cell.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_captured_let_mut.vibe did not compile under VIBE_RC=1 (#1262)" >&2
  cat "$refcelldir/cell.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! VIBE_RC_ASSERT_SIZE0_ONLY=1 python3 scripts/rc_patch_freelist_assert.py \
  "$refcelldir/cell.wasm" "$refcelldir/cell_sz0.wasm" __rt_rc_drop >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: could not splice the alloc_size==0 assert into __rt_rc_drop (#1262)" >&2
  exit 1
fi
refcell_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$refcelldir/cell_sz0.wasm" 2>&1 | tail -1)"
if [ "$refcell_out" != "1" ]; then
  echo "[compiler-gate] FAIL: a headerless ref-cell box reached __rt_rc_drop (#1262)" >&2
  echo "  got '$refcell_out' (want 1); an 'unreachable' trap here means a captured" >&2
  echo "  let mut took the raw-bump path while the closure treated it as RC-owned" >&2
  exit 1
fi
rm -rf "$refcelldir"
echo "[compiler-gate] RC ref cell header ok"

# 89. #1262 / ADR-0055 Blocker-2: no codegen site may push a FULL f64 bit
#     pattern through an `Int`.
#
# `Double::to_i64_bits(Double) -> Int` cannot honour its own signature: a normal
# f64 pattern (`2.0` = 0x4000000000000000 = 2^62) exceeds Int::max_value
# (2^61-1). Under RC the value comes back HALVED, so `emit_f64_const_bits` --
# which slices the pattern with `>>8/16/.../56` -- writes `true_byte >> 1` for
# every one of the 8 bytes. The correct form splits the pattern into two 32-bit
# halves (each <= 2^32-1, both fit) via Double::to_i64_bits_lo/_hi +
# emit_f64_const_lohi.
#
# uniform-value-repr.md has recorded Blocker-2 as "FIXED" since #505, but the
# fix only ever landed in the LINEAR backend; codegen/gc/backend_expr.vibe kept
# the broken form and silently miscompiled every gc-lane float literal whenever
# the COMPILER ITSELF was RC-built (gate 40h read 91527 instead of 101557 --
# Double::to_int saturating to 0 and float interpolation stringifying to one
# char). A bump-built compiler hides it completely, which is why 40h never
# caught it: the DEFAULT self-build is VIBE_RC=0.
#
# So this lock is STATIC. A runtime lock would have to build an RC stage2 first
# (minutes), and the default gate has no RC-built compiler to ask.
badf64="$(grep -rn 'emit_f64_const_bits(\|Double::to_i64_bits(' lib/@vibe/compiler --include=*.vibe \
  | grep -v 'compiler_sources_bundle\|cli_adapter_bundle\|selfbuild_runtime_entry_bundle\|_cli_adapter_module_source' \
  | grep -v 'export fn emit_f64_const_bits(' \
  | grep -v 'declare Double::to_i64_bits(' || true)"
if [ -n "$badf64" ]; then
  echo "[compiler-gate] FAIL: full-f64-pattern-through-Int in codegen (#1262, ADR-0055 Blocker-2)" >&2
  echo "$badf64" >&2
  echo "  A full f64 bit pattern does not fit the 62-bit Int; under RC it arrives halved" >&2
  echo "  and every emitted f64.const byte becomes (true_byte >> 1)." >&2
  echo "  Use: emit_f64_const_lohi(buf, Double::to_i64_bits_lo(v), Double::to_i64_bits_hi(v))" >&2
  exit 1
fi
echo "[compiler-gate] f64 literal lo/hi split ok"

echo "[compiler-gate] 90/90 the @vibe/wit_runtime Result reaches the WIT projection (#1324)"
# #1324 removed `Result` from the language, but the WASM component boundary
# still needs one: WIT has `result<T, E>` and an `Exception[E]` row has no
# projection onto it (the signature is built from the return type alone, and
# exception labels are filtered out of the world imports the same way `Error`
# is), so a row-carrying export would render as plain `T`. @vibe/wit_runtime is the
# canonical `Result` for that boundary.
#
# TWO steps, because the WIT emission alone cannot see the import.
#
# VIBE_EMIT_WIT parses the ENTRY FILE ONLY and hands its raw annotations to
# wit_from_program -- it never resolves imports and never type-checks. Measured:
# swapping the import for a nonexistent package, or deleting it outright, still
# emits a byte-identical world (only the world NAME, derived from the filename,
# changes). So a golden diff by itself would pass with the package missing, and
# would NOT establish what this gate is for.
#
# Step 1 therefore FS-compiles the fixture (module resolution + checking), which
# does discriminate -- measured rc=1 with "no require pin for @vibe/..." on a
# broken import and "unknown name: Ok" with the import deleted. Step 2 then
# diffs the emitted WIT against the golden.
#
# Together they lock what the package is for: the IMPORTED type reaches the
# projection. wit_gen matches on the TypeExpr HEAD NAME, so a contract import
# only works as long as the annotation still reads `Result[..]` where wit_gen
# sees it. fixtures/wit_gen_result.vibe imports @vibe/wit_runtime rather than
# declaring a local copy, and also pins the boundary idiom itself (row inside,
# ONE `handle` in the export body producing Ok/Err).
witresdir="_build/_gate_wit_result"
rm -rf "$witresdir"; mkdir -p "$witresdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/wit_gen_result.vibe" "$witresdir/fixture.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$witresdir/fixture.wasm" ]; then
  echo "[compiler-gate] FAIL: fixtures/wit_gen_result.vibe did not FS-compile -- the @vibe/wit_runtime import does not resolve or does not type-check (#1324)" >&2
  cat "$witresdir/fixture.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
VIBE_EMIT_WIT=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/wit_gen_result.vibe" "$witresdir/out.wit" main >/dev/null 2>&1 || true
if [ ! -s "$witresdir/out.wit" ]; then
  echo "[compiler-gate] FAIL: VIBE_EMIT_WIT produced no output for the @vibe/wit_runtime fixture (#1324)" >&2
  cat "$witresdir/out.wit.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! diff -u "fixtures/wit_gen_result.golden.wit" "$witresdir/out.wit" >&2; then
  echo "[compiler-gate] FAIL: WIT output differs from fixtures/wit_gen_result.golden.wit. If the boundary contract changed intentionally, update the golden AND docs/internal/design/effect-wit-mapping.md together." >&2
  exit 1
fi
rm -rf "$witresdir"
echo "[compiler-gate] @vibe/wit_runtime Result projection ok"

echo "[compiler-gate] 91/91 resource declarations enforce logical identity (ADR-0075 / #1343)"
# ADR-0075 Phase 2: `resource Posts : S3::Bucket` declares a LOGICAL resource
# identity the executable requires a binding for. The rules that matter are
# about identity, so the gate checks that two spellings which would give one
# thing two names are both rejected, and that an ordinary declaration compiles.
#
# `Process::Root` is the singleton kind (ADR-0094's default for every host
# capability): its one inhabitant is itself, so a program declaring another
# resource of that kind would be aliasing the process under a second name --
# ADR-0075's alias check exists to catch exactly that, and rejecting it at the
# declaration is cheaper than detecting the alias at bind time.
resdir="_build/_gate_resource_decl"
rm -rf "$resdir"; mkdir -p "$resdir"
res_case() {
  # res_case <name> <expect: ok|err> <source> [substring the .diag must contain]
  local rname="$1" expect="$2" rsrc="$3" rneedle="${4:-}"
  printf '%s' "$rsrc" > "$resdir/$rname.vibe"
  rm -f "$resdir/$rname.wasm" "$resdir/$rname.wasm.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$resdir/$rname.vibe" "$resdir/$rname.wasm" main >/dev/null 2>&1 || true
  if [ "$expect" = "ok" ]; then
    if [ ! -s "$resdir/$rname.wasm" ]; then
      echo "[compiler-gate] FAIL: resource case '$rname' should compile but did not (ADR-0075/#1343)" >&2
      cat "$resdir/$rname.wasm.diag" >&2 2>/dev/null || true
      exit 1
    fi
  else
    if [ -s "$resdir/$rname.wasm" ]; then
      echo "[compiler-gate] FAIL: resource case '$rname' should be rejected but compiled (ADR-0075/#1343)" >&2
      exit 1
    fi
    if [ -n "$rneedle" ] && ! grep -q -- "$rneedle" "$resdir/$rname.wasm.diag" 2>/dev/null; then
      echo "[compiler-gate] FAIL: resource case '$rname' rejected without naming '$rneedle' (ADR-0075/#1343):" >&2
      cat "$resdir/$rname.wasm.diag" >&2 2>/dev/null || true
      exit 1
    fi
  fi
}
res_case basic ok 'resource Posts : S3::Bucket

fn main allows Console {
  println("ok")
}
'
res_case unqualified err 'resource Posts : Bucket

fn main allows Console {
  println("ok")
}
' 'must be qualified'
res_case duplicate err 'resource Posts : S3::Bucket
resource Posts : S3::Table

fn main allows Console {
  println("ok")
}
' 'already declared'
res_case singleton err 'resource Home : Process::Root

fn main allows Console {
  println("ok")
}
' 'singleton'
res_case exported err 'export resource Posts : S3::Bucket

fn main allows Console {
  println("ok")
}
' 'cannot be exported'
# `resource` stays an ordinary identifier: the declaration form needs an
# identifier right after the word, which no expression can have at statement
# position, so nothing that used the name breaks.
res_case as_name ok 'let resource = 1

fn main allows Console {
  println("ok")
}
'
rm -rf "$resdir"
echo "[compiler-gate] resource declaration identity rules ok"

# Section banner. `92/92` is this section's stable registry id (see
# tests/gates/registry.tsv), not a fixture count. It read "verdicts match"
# before anything had been checked, so a failing run announced a pass and then
# printed FAIL; "vs" states the subject without the verdict.
echo "[compiler-gate] 92/92 fixtures/typecheck verdicts vs expected.tsv, both lanes (#138, #2142, #2144)"
# The corpus and both of its lanes live in scripts/check_typecheck_fixtures.sh:
# every row is compiled with `__no_entry__` AND with the entry name a user
# passes, `main`, and a difference between the two verdicts has to be recorded
# in the row or the gate fails. It used to be compiled the first way only, and
# a `handle` rejected at the entry boundary was recorded as `ok` (#2142/#2144).
#
# It is a script rather than a loop here so that its row-checker can be driven
# with synthetic verdicts by its own self-test -- Red first, then green. The
# stage2 this lane resolved is passed explicitly: a gate that picks its own
# compiler picks the newest generation on disk, which is not the one under
# test (AGENTS.md, "Which compiler answered?").
TYPECHECK_FIXTURES_STAGE2="$stage2_wasm" bash scripts/check_typecheck_fixtures.sh

# --- #819: per-block `__test_*` exports + isolated invocation -----------------
# A `__no_entry__` test build exports one `__test_<name>` per `test {}` block
# (alongside the `__bench_<name>` exports that already existed), and the runner
# does NOT pre-run `_start` for those names -- `_start` IS the loop over every
# block, so pre-running it would make one failing block fail every per-block
# invoke. This is what gives merged builds (#819) per-block failure attribution
# and a per-block timeout; scripts/unit_test_runner.sh uses it to name the
# trapping block instead of reporting a bare file-level trap.
pbdir="_build/_gate_per_block_test"
rm -rf "$pbdir"; mkdir -p "$pbdir"
cat > "$pbdir/pb_test.vibe" <<'PBEOF'
test "alpha_ok" {
  let x = 1 + 1
  if x != 2 { throw("bad alpha") }
  println("from alpha")
}

test "beta_fails" {
  throw("boom beta")
}

test "gamma_ok" {
  let y = 3
  if y != 3 { throw("bad gamma") }
  println("from gamma")
}
PBEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pbdir/pb_test.vibe" "$pbdir/pb.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$pbdir/pb.wasm" ]; then
  echo "[compiler-gate] FAIL: per-block test fixture did not compile (#819)" >&2
  cat "$pbdir/pb.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
pbexports="$(node -e '
  const m = new WebAssembly.Module(require("fs").readFileSync(process.argv[1]));
  for (const e of WebAssembly.Module.exports(m)) {
    if (e.kind === "function" && e.name.startsWith("__test_")) console.log(e.name);
  }
' "$pbdir/pb.wasm" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' || true)"
if [ "$pbexports" != "__test_alpha_ok __test_beta_fails __test_gamma_ok " ]; then
  echo "[compiler-gate] FAIL: expected one __test_<name> export per test block, got: '$pbexports' (#819)" >&2
  exit 1
fi
# Isolation: the passing blocks must pass even though a sibling block traps.
# Before #819 this failed, because the runner ran `_start` (every block) first.
for pbname in __test_alpha_ok __test_gamma_ok; do
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
       --invoke "$pbname" "$pbdir/pb.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: $pbname trapped -- a per-block invoke is running its siblings (#819)" >&2
    exit 1
  fi
done
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
     --invoke __test_beta_fails "$pbdir/pb.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: __test_beta_fails did not trap -- per-block invoke is not running the body (#819)" >&2
  exit 1
fi
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
     --invoke _start "$pbdir/pb.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: _start did not trap on a file with a failing block (#819)" >&2
  exit 1
fi

# --- #141: batched per-block invokes -----------------------------------------
# `--invoke-batch-dir` runs every `--invoke` target in ONE process and keeps
# their outputs apart: target i's stdout/stderr/status land in
# `<dir>/<i>.{out,err,rc}`, 1-based in flag order. That separation is the whole
# point -- both callers (scripts/vibe_md.vibex's doctest blocks,
# unit_test_runner.sh's failure attribution) need EACH target's own output, so
# a plain repeated `--invoke` (which concatenates everything into one stream)
# cannot serve them.
pbbatch="$pbdir/batch"
VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke-batch-dir "$pbbatch" \
  --invoke __test_alpha_ok --invoke __test_beta_fails --invoke __test_gamma_ok \
  "$pbdir/pb.wasm" >/dev/null 2>&1 && pbbatch_rc=0 || pbbatch_rc=$?
if [ "$pbbatch_rc" -eq 0 ]; then
  echo "[compiler-gate] FAIL: --invoke-batch-dir exited 0 with a failing target (#141)" >&2
  exit 1
fi
for pbslot in 1 2 3; do
  if [ ! -f "$pbbatch/$pbslot.rc" ]; then
    echo "[compiler-gate] FAIL: --invoke-batch-dir wrote no $pbslot.rc -- a failing target aborted the batch (#141)" >&2
    exit 1
  fi
done
pbrcs="$(cat "$pbbatch/1.rc" "$pbbatch/2.rc" "$pbbatch/3.rc" | tr '\n' ' ')"
if [ "$pbrcs" != "0 1 0 " ]; then
  echo "[compiler-gate] FAIL: expected batch statuses '0 1 0 ', got '$pbrcs' (#141)" >&2
  exit 1
fi
# Each target's stdout is its OWN, not the concatenation -- this is what the
# doctest harness compares against a block's ```output.
if [ "$(cat "$pbbatch/1.out")" != "from alpha" ] || [ -s "$pbbatch/2.out" ] \
   || [ "$(cat "$pbbatch/3.out")" != "from gamma" ]; then
  echo "[compiler-gate] FAIL: batch stdout is not split per target (#141):" >&2
  for pbslot in 1 2 3; do echo "  $pbslot.out: $(cat "$pbbatch/$pbslot.out")" >&2; done
  exit 1
fi
# stderr is split the same way: the trap diagnostics belong to the target that
# trapped, and do not leak into a passing sibling's report. (What that
# diagnostic SAYS is a separate, pre-existing limit -- a thrown string reaches
# the host as an opaque `WebAssembly.Exception` on the single-invoke path too,
# so this asserts attribution, not message quality.)
if [ ! -s "$pbbatch/2.err" ] || [ -s "$pbbatch/1.err" ] || [ -s "$pbbatch/3.err" ]; then
  echo "[compiler-gate] FAIL: batch stderr is not split per target (#141)" >&2
  for pbslot in 1 2 3; do echo "  $pbslot.err: $(cat "$pbbatch/$pbslot.err")" >&2; done
  exit 1
fi
rm -rf "$pbdir"
echo "[compiler-gate] per-block __test_* exports + isolated invoke + batch ok"

echo "[compiler-gate] 93/93 an imported enum's variants reach the importing module (#1455)"
# #1455: the checker's cross-module transport is the flat TypeEnv, so an
# importing module used to see an imported enum's CONSTRUCTORS but nothing
# that said which enum owned them. That one missing edge produced three
# separate wrong behaviours, and this section locks all three plus the two
# collision cases the fix had to leave alone.
#
# Each case is a two-file program: `dep.vibe` declares the enums, `<name>.vibe`
# imports them. One file would not exercise anything -- a same-file
# declaration always registered its TDEnum.
endir="_build/_gate_enum_import"
rm -rf "$endir"; mkdir -p "$endir"
cat > "$endir/dep.vibe" <<'ENUMDEP'
export enum Box {
  Mk(Int);
  Nil
}

export enum Attempt[T] {
  Got(T);
  Missed
}

export enum Paint {
  Red;
  Blue
}
ENUMDEP
en_case() {
  # en_case <name> <expect: ok|err> <source> [substring the .diag must contain]
  local ename="$1" expect="$2" esrc="$3" eneedle="${4:-}"
  printf '%s' "$esrc" > "$endir/$ename.vibe"
  rm -f "$endir/$ename.wasm" "$endir/$ename.wasm.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$endir/$ename.vibe" "$endir/$ename.wasm" main >/dev/null 2>&1 || true
  if [ "$expect" = "ok" ]; then
    if [ ! -s "$endir/$ename.wasm" ]; then
      echo "[compiler-gate] FAIL: enum-import case '$ename' should compile but did not (#1455)" >&2
      cat "$endir/$ename.wasm.diag" >&2 2>/dev/null || true
      exit 1
    fi
  else
    if [ -s "$endir/$ename.wasm" ]; then
      echo "[compiler-gate] FAIL: enum-import case '$ename' should be rejected but compiled (#1455)" >&2
      exit 1
    fi
    if [ -n "$eneedle" ] && ! grep -q -- "$eneedle" "$endir/$ename.wasm.diag" 2>/dev/null; then
      echo "[compiler-gate] FAIL: enum-import case '$ename' rejected without naming '$eneedle' (#1455):" >&2
      cat "$endir/$ename.wasm.diag" >&2 2>/dev/null || true
      exit 1
    fi
  fi
}
# 1. `Box::Mk` resolves. This used to be `unknown name: Box::Mk`, which made
#    #1455's "require the qualified spelling" plan unimplementable: there was
#    no way to WRITE a qualified reference to an imported constructor.
en_case qualified ok 'import ./dep.vibe { Box, Mk, Nil }

fn main allows Console {
  let b = Box::Mk(7)
  let r = match b {
    Mk(n) => n,
    Nil => 0
  }
  println(__to_string(r))
}
'
# 2. The payload is TYPE-CHECKED. Without the TDEnum, find_ctor_in_defs fell
#    through to bind_unknown and bound every sub-pattern CtUnknown, so this
#    compiled with an Int `n` handed to a String parameter. That is the silent
#    one: a hole in checking, not a message-quality complaint.
en_case payload_checked err 'import ./dep.vibe { Box, Mk, Nil }

fn main allows Console {
  let b = Mk(7)
  match b {
    Mk(n) => println(String::concat(n, "!")),
    Nil => println("")
  }
}
' 'String::concat'
# 3. Exhaustiveness can NAME the missing variant. Before, the enum definition
#    was unknown here, so the check was skipped entirely and an unhandled
#    variant trapped at runtime instead.
en_case exhaustive err 'import ./dep.vibe { Box, Mk }

fn main allows Console {
  let b = Mk(7)
  let r = match b {
    Mk(n) => n
  }
  println(__to_string(r))
}
' 'variant `Nil` of enum Box'
# 4. A PARAMETERIZED enum crosses the boundary too (#1455 follow-up). The
#    carrier stores the enum'"'"'s formals plus NAME-parameterized payloads
#    (`CtNamed("T", [])`), not the declaring compilation'"'"'s CtVar ids, so the
#    importer can rebind `T` to ids of its own. Before that, `Attempt::Got`
#    was `unknown name` -- resolve_qualified_ctor_ident fell back to a flat
#    env_lookup that could not see the imported scheme.
en_case parameterized ok 'import ./dep.vibe { Attempt, Got, Missed }

fn main allows Console {
  let a = Got(3)
  let r = match a {
    Got(v) => v,
    Missed => 0
  }
  println(__to_string(r))
}
'
en_case parameterized_qualified ok 'import ./dep.vibe { Attempt, Got, Missed }

fn main allows Console {
  let a = Attempt::Got(3)
  let r = match a {
    Attempt::Got(v) => v,
    Attempt::Missed => 0
  }
  println(__to_string(r))
}
'
# 4b. The rebuilt scheme has to stay GENERIC. If the formal were bound to a
#     shared, non-quantified var, the second instantiation in one module would
#     unify against the first and the String use would be a type error.
en_case parameterized_two_instances ok 'import ./dep.vibe { Attempt, Got, Missed }

fn first() -> Int {
  match Attempt::Got(3) {
    Got(v) => v,
    Missed => 0
  }
}

fn second() -> String {
  match Attempt::Got("s") {
    Got(v) => v,
    Missed => ""
  }
}

fn main allows Console {
  println(String::concat(__to_string(first()), second()))
}
'
# 4c. #1455 step 3: the qualifier is CHECKED. `parse_pattern` lowers
#     `Attempt::Missed` to the same PCtor("Missed") the bare spelling produces,
#     so a swapped qualifier used to be accepted silently -- the parser now
#     records the pair on a side channel and the checker validates it against
#     the enum table (checker_pattern.vibe::check_qualified_pattern_refs).
#     `Box` is a real enum here, just not the one that owns `Missed`.
en_case pattern_qualifier_wrong_enum err 'import ./dep.vibe { Attempt, Box, Got, Missed }

fn main allows Console {
  let a = Got(3)
  let r = match a {
    Got(v) => v,
    Box::Missed => 0
  }
  println(__to_string(r))
}
' 'enum `Box` has no variant `Missed`'
# 4d. ...and a qualifier that is not an enum stays silent, which is what keeps
#     handle-arm operation patterns (`Log::Emit(m)`) working: they reach the
#     same side channel through the same parser branch.
en_case pattern_qualifier_effect_arm ok 'effect Log {
  Emit(String) -> Unit
}

fn shout(s: String) -> String with Log {
  perform Log::Emit(s)
  s
}

fn main allows Console {
  let r = handle {
    shout("hi")
  } with Log {
    Log::Emit(m) => resume(m)
  }
  println(r)
}
'
# 5. A local enum that reuses an imported constructor NAME still compiles.
#    This is the case that forced the variant-collision guard in
#    seed_imported_enum_defs: `find_ctor_in_defs` is first-match-wins over one
#    flat `defs`, so registering Paint would have made the `Red` arm resolve
#    to Paint and retyped the whole match. Shadowing an imported constructor
#    is ordinary code -- the local binding wins -- so the seeded enum has to
#    step aside rather than take it over.
en_case shadow_import ok 'import ./dep.vibe { Paint, Red, Blue }

enum Color {
  Red;
  Green
}

fn main allows Console {
  let c = Red
  match c {
    Red => println("red"),
    Green => println("green")
  }
}
'
# 6. ...but the collision #1078 is actually about -- two enums in ONE unit,
#    where the flat last-registered-wins env silently points a bare `Mk` at
#    the wrong signature -- is still rejected.
en_case collide_local err 'enum A {
  Mk(Int)
}

enum B {
  Mk(String)
}

fn main allows Console {
  println("unreachable")
}
' 'constructor name collision'
rm -rf "$endir"
echo "[compiler-gate] imported enum variant lists ok"

echo "[compiler-gate] 94/94 importing a name the dependency does not export is a CHECK error (#1521)"
# #1521: `bind_import_names_from_cache` bound CtUnknown for an imported name
# the dependency does not export. CtUnknown unifies with anything, so every
# USE of that name typechecked -- `vibe check` said ok -- and the program
# died in codegen with `undefined variable (ident): X`, naming no file and
# no line. Worse than having no diagnostic: the import SUPPRESSED the
# `unknown name` the same code gets without it.
#
# The negatives are the point of this section, not padding. Two earlier
# attempts at this check passed their positives while silently breaking
# valid code (or while wired into a lane `vibe check` never runs), so every
# shape that must stay clean is pinned right next to the shapes that must
# fail.
uidir="_build/_gate_unresolved_import"
rm -rf "$uidir"; mkdir -p "$uidir"
cat > "$uidir/dep.vibe" <<'UIDEP'
export enum Hue {
  Crimson;
  Cerulean
}

export fn hue_rank(h: Hue) -> Int {
  match h {
    Crimson => 0
    Cerulean => 1
  }
}
UIDEP
ui_case() {
  # ui_case <name> <expect: ok|err> <source>
  #   ok  -- compiles
  #   err -- rejected BY THE #1521 CHECK (diag names the unexported import)
  # (A third expectation, `gap`, used to pin the #1533 shape: a private
  # import that failed in CODEGEN instead of the check. #1533 is fixed --
  # published dependency environments are restricted to the export surface,
  # see runtime/typecheck_fs.vibe restrict_env_to_export_surface -- so that
  # shape is an ordinary `err` now and the expectation is gone.)
  local uname="$1" uexpect="$2" usrc="$3"
  printf '%s' "$usrc" > "$uidir/$uname.vibe"
  rm -f "$uidir/$uname.wasm" "$uidir/$uname.wasm.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$uidir/$uname.vibe" "$uidir/$uname.wasm" _start >/dev/null 2>&1 || true
  if [ "$uexpect" = "ok" ]; then
    if [ ! -s "$uidir/$uname.wasm" ]; then
      echo "[compiler-gate] FAIL: unresolved-import case '$uname' should compile but did not (#1521)" >&2
      cat "$uidir/$uname.wasm.diag" >&2 2>/dev/null || true
      exit 1
    fi
  else
    if [ -s "$uidir/$uname.wasm" ]; then
      echo "[compiler-gate] FAIL: unresolved-import case '$uname' compiled; the bogus import was not caught (#1521)" >&2
      exit 1
    fi
    if ! grep -q "is not exported by" "$uidir/$uname.wasm.diag" 2>/dev/null; then
      echo "[compiler-gate] FAIL: unresolved-import case '$uname' was rejected by something OTHER than the #1521 check" >&2
      cat "$uidir/$uname.wasm.diag" >&2 2>/dev/null || true
      exit 1
    fi
  fi
}
# 1. The reported shape: a value import that does not exist, and is used.
ui_case bogus_used err 'import ./dep.vibe { no_such_fn }

export let _start = () -> Int { no_such_fn(1) }
'
# 2. Reported even when UNUSED. The pre-existing "never used" warning fires
#    here too, but "unused" is not "no such name" -- the import is still wrong.
ui_case bogus_unused err 'import ./dep.vibe { no_such_fn }

export let _start = () -> Int { 1 }
'
# 3. An alias does not launder it: the ORIGINAL name is what must exist.
ui_case bogus_aliased err 'import ./dep.vibe { no_such_fn as f }

export let _start = () -> Int { f(1) }
'
# 4-6. Every valid shape stays clean: plain value + type + constructor,
#      the same through aliases, and constructors imported on their own.
ui_case good_plain ok 'import ./dep.vibe { hue_rank, Hue, Crimson }

export let _start = () -> Int { hue_rank(Crimson) }
'
ui_case good_aliased ok 'import ./dep.vibe { hue_rank as r, Hue as T, Crimson }

fn pick() -> T { T::Crimson }

export let _start = () -> Int { r(pick()) }
'
ui_case good_ctors ok 'import ./dep.vibe { Hue, Crimson, Cerulean }

export let _start = () -> Int {
  match Cerulean {
    Crimson => 0
    Cerulean => 1
  }
}
'
# 7. Declaration authority now travels with the dependency environment, so an
#    unknown uppercase selection is rejected by the same import-surface check.
#    (This case kept the name `bogus_uppercase_not_reported` long after it
#    stopped being a gap; the same stale claim outlived it in CLAUDE.md, which
#    still told readers uppercase names went undetected. Measured
#    2026-08-19: all four shapes below are caught.)
ui_case bogus_uppercase err 'import ./dep.vibe { Hue, NoSuchType }

export let _start = () -> Int { 1 }
'
# 7b-7d. The three uppercase shapes CLAUDE.md named as still-undetected. A
#    struct and a type alias are DECLARED in the dependency but not exported,
#    which is a different path from case 7's name-that-never-existed: the
#    dependency's own environment has them, and only the export-surface
#    restriction keeps them off the published one.
cat > "$uidir/upper.vibe" <<'UIUPPER'
export struct Shown {
  x: Int
}

struct Hidden {
  y: Int
}

export type ShownAlias = Int

type HiddenAlias = Int
UIUPPER
ui_case private_struct_reported err 'import ./upper.vibe { Hidden }

export let _start = () -> Int {
  let h = Hidden::{ y: 1 }
  h.y
}
'
ui_case private_type_alias_reported err 'import ./upper.vibe { HiddenAlias }

fn take(x: HiddenAlias) -> Int { x }

export let _start = () -> Int { take(1) }
'
# ...and the exported pair from that same module stays clean, so the two
# cases above are not passing because `upper.vibe` is broken.
ui_case public_upper_ok ok 'import ./upper.vibe { Shown, ShownAlias }

fn take(x: ShownAlias) -> Int { x }

export let _start = () -> Int {
  let s = Shown::{ x: 1 }
  take(s.x)
}
'
# 8. A dependency that binds NO values is still a checked dependency. Deriving
#    "known" from the binding count switched the check off for exactly these
#    (Codex review, PR #1532) -- a trait-only module is cached as an empty
#    value environment, and a bogus import from it went back to dying in
#    codegen. `dep_known` now comes from the cache lookup itself.
cat > "$uidir/traitonly.vibe" <<'UITRAIT'
export trait Pingable {
  ping(Self) -> Int
}
UITRAIT
ui_case bogus_from_traitonly err 'import ./traitonly.vibe { no_such_fn }

export let _start = () -> Int { no_such_fn(1) }
'
# 9. #1533, fixed (was pinned here as a `gap` case): a PRIVATE name is not in
#    the environment the dependency publishes -- check_module restricts it to
#    the export surface -- so the membership check reports it exactly like a
#    name that never existed. From the importer's side those are the same
#    fact: the dependency does not export it.
cat > "$uidir/privates.vibe" <<'UIPRIV'
fn private_fn(x: Int) -> Int {
  x + 1
}

export fn public_fn(x: Int) -> Int {
  private_fn(x)
}
UIPRIV
ui_case private_import_reported err 'import ./privates.vibe { private_fn }

export let _start = () -> Int { private_fn(1) }
'
# 10. ...and the public name from that same module still imports cleanly, so
#     case 9 is not passing because the module is broken.
ui_case public_from_mixed_module ok 'import ./privates.vibe { public_fn }

export let _start = () -> Int { public_fn(1) }
'
# 11-12. The same rule for PASS-THROUGH names (#1533's other face): a name the
#     dependency merely imported sits in its checked environment (the import
#     env is the base of the chain) but is NOT part of its export surface --
#     importing it from the middleman is an error unless the middleman
#     re-exports it, which puts the name on the surface for real.
cat > "$uidir/middleman.vibe" <<'UIMID'
import ./dep.vibe { hue_rank, Hue, Crimson }

export fn middleman_rank() -> Int {
  hue_rank(Crimson)
}
UIMID
ui_case passthrough_import_reported err 'import ./middleman.vibe { hue_rank }

export let _start = () -> Int { hue_rank(1) }
'
cat > "$uidir/reexporter.vibe" <<'UIREX'
export ./dep.vibe { hue_rank, Hue, Crimson }
UIREX
ui_case reexported_name_ok ok 'import ./reexporter.vibe { hue_rank, Hue, Crimson }

export let _start = () -> Int { hue_rank(Crimson) }
'
rm -rf "$uidir"
echo "[compiler-gate] unresolved import names ok"

echo "[compiler-gate] 95/95 a name reaching codegen unresolved says it is a COMPILER bug (#1521/#1491/#1529)"
# The shared exit of a whole family of defects. #1502, #1510, #1491, #1521,
# #1529 and #1533 are unrelated in cause -- an alias qualifier, a first-match
# lookup, a CtUnknown fallback, a struct shape collision -- and every one of
# them surfaced the same way: the checker accepted the program, and codegen
# died on a name it could not resolve, with a message naming no file, no line,
# and `locals=[__env,,__fn_val]` (pass state).
#
# The three codegen sites that can raise it now say whose bug it is, in one
# shared wording so they cannot drift. This section pins that wording, so the
# next defect in this family arrives as "internal compiler error, report it"
# rather than as something a user might read as their own mistake.
#
# It does NOT try to prove no program reaches those sites -- reaching them IS
# the open-issue set. What it pins is that arriving there is legible.
for cg_site in \
  "lib/@vibe/compiler/codegen/common_base/common_base_codegen_body_cache_from_bytes.vibe" \
  "lib/@vibe/compiler/codegen/expr/compile_expr.vibe" \
  "lib/@vibe/compiler/codegen/gc/backend_expr.vibe"
do
  # The load-bearing half: the OLD spelling must be gone. Asserting the new
  # helper "appears in the file" does not do it -- common_base DEFINES the
  # helper, so it matches whether or not `resolve_local` still calls it, and a
  # revert there would sail through. (Codex review on PR #1562; the check was
  # asking a different question from the one it meant, which is the very shape
  # ARCH011 was added for.)
  if grep -q '"undefined variable' "$ROOT_DIR/$cg_site"; then
    echo "[compiler-gate] FAIL: $cg_site raises a bare \"undefined variable\" again" >&2
    echo "[compiler-gate]       That message names no file, no line, and reads as the user's mistake." >&2
    grep -n '"undefined variable' "$ROOT_DIR/$cg_site" >&2
    exit 1
  fi
  if ! grep -q "codegen_unresolved_name_prefix()" "$ROOT_DIR/$cg_site"; then
    echo "[compiler-gate] FAIL: $cg_site no longer routes its unresolved-name error through the shared wording" >&2
    exit 1
  fi
done
# ...and specifically INSIDE resolve_local, not merely somewhere in the file
# that declares the helper.
if ! awk '/^export fn resolve_local\(/,/^}/' "$ROOT_DIR/lib/@vibe/compiler/codegen/common_base/common_base_codegen_body_cache_from_bytes.vibe" \
  | grep -q "codegen_unresolved_name_prefix()"; then
  echo "[compiler-gate] FAIL: resolve_local's own error no longer uses the shared wording" >&2
  exit 1
fi
if ! grep -q 'internal compiler error' "$ROOT_DIR/lib/@vibe/compiler/codegen/common_base/common_base_codegen_body_cache_from_bytes.vibe"; then
  echo "[compiler-gate] FAIL: the unresolved-name error no longer identifies itself as a compiler bug" >&2
  exit 1
fi
# And a normal program must NOT produce it -- the wording lock above is
# worthless if the message fires on correct code.
cgdir="_build/_gate_codegen_unresolved"
rm -rf "$cgdir"; mkdir -p "$cgdir"
printf 'enum Color {\n  Red;\n  Green\n}\n\nexport let _start = () -> Int {\n  match Color::Red {\n    Red => 1\n    Green => 2\n  }\n}\n' > "$cgdir/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cgdir/ok.vibe" "$cgdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cgdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: a correct program hit the unresolved-name path" >&2
  cat "$cgdir/ok.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$cgdir"
echo "[compiler-gate] codegen unresolved-name error is legible ok"

echo "[compiler-gate] 96/96 host-side tracing spans nest, propagate and record failures (docs/internal/compiler/tracing-design.md step 0)"
bash scripts/test_trace_spans.sh
echo "[compiler-gate] tracing spans ok"

echo "[compiler-gate] 97/97 desugar-emitted builtins resolve in BOTH compile lanes (#1590)"
# The three builtins desugar_trait_dict synthesizes -- str_lex_diff for String
# `<`, __generic_rel_diff / __generic_add for an erased type parameter -- were
# checker_visible=false, which is fine only while the checker runs BEFORE
# desugar. It does not in the lane that omits VIBE_FS_COMPILE=1 (the one
# generate_bundle.sh's bootstrap_merge_flatten_tool pass 3 uses), so each one
# died there with `unknown name: <builtin>` while compiling fine with
# VIBE_FS_COMPILE=1. Compiling every shape in the NON-FS lane specifically:
# the FS lane never had the bug and would pass either way.
dvdir="_build/_gate_desugar_builtins"
rm -rf "$dvdir"; mkdir -p "$dvdir"
printf 'export fn lt(a: String, b: String) -> Bool { a < b }\nexport fn main() -> Int { if lt("a","b") { 0 } else { 1 } }\n' > "$dvdir/str_lex_diff.vibe"
printf 'fn g[T](a: T, b: T) -> Bool { a < b }\nexport fn main() -> Int { if g(1,2) { 0 } else { 1 } }\n' > "$dvdir/generic_rel_diff.vibe"
printf 'fn ga[T](a: T, b: T) -> T { a + b }\nexport fn main() -> Int { ga(1,2) }\n' > "$dvdir/generic_add.vibe"
for dvsrc in "$dvdir"/*.vibe; do
  dvname="$(basename "$dvsrc" .vibe)"
  VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$dvsrc" "$dvdir/$dvname.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$dvdir/$dvname.wasm" ]; then
    echo "[compiler-gate] FAIL: $dvname did not compile in the non-FS lane (#1590)" >&2
    cat "$dvdir/$dvname.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
done
rm -rf "$dvdir"
echo "[compiler-gate] desugar-emitted builtins resolve in both lanes ok"

echo "[compiler-gate] 98/104 \`vibe grep\`'s typed filters resolve imports like \`vibe check\` (#1572)"
bash "$ROOT_DIR/scripts/test_vibe_grep_help.sh"
bash "$ROOT_DIR/scripts/test_vibe_rc_help.sh"
# grep_test.vibe covers the pattern language and the filters through
# grep_scan_source (no Fs). What only the REAL adapter mode exercises is the
# filesystem tier: sweeping a directory, and resolving a capture's type through
# the same FS import walk `vibe check` uses. That resolution is the whole point
# of the feature and it is the part that silently degrades -- seeding the module
# sources wrong makes every import type as `CtUnknown`, at which point the
# filters keep answering, just wrongly.
gvdir="_build/_gate_vibe_grep"
rm -rf "$gvdir"; mkdir -p "$gvdir"
cat > "$gvdir/dep.vibe" <<'VEOF'
export fn helper(v: Int) -> Int {
  v + 1
}
VEOF
cat > "$gvdir/main.vibe" <<'VEOF'
import ./dep.vibe {
  helper as h
}

fn readit(p: String) -> String with Fs {
  Fs::read_file(p)
}

fn plain(p: String) -> String {
  p
}

fn run(q: String) -> String with Fs {
  let a = readit(q)
  let b = h(1)
  String::concat(plain(a), __to_string(b))
}
VEOF
gv_run() {
  # $1 = output basename, $2.. = extra env assignments (name=value)
  local gv_out="$gvdir/$1"; shift
  rm -f "$gv_out" "$gv_out.diag" "$gv_out.warn"
  env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_GREP=1 "$@" \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$gvdir" "$gv_out" >/dev/null 2>&1 || true
}
# Parse-only tier: every call in the directory, whatever its arity.
gv_run all.txt VIBE_GREP_PATTERN='$(f:id)($(a:args))'
for gv_want in 'readit(q)' 'h(1)' 'plain(a)' 'Fs::read_file(p)'; do
  if ! grep -qF "$gv_want" "$gvdir/all.txt"; then
    echo "[compiler-gate] FAIL: vibe grep did not find $gv_want" >&2
    cat "$gvdir/all.txt" "$gvdir/all.txt.diag" >&2 2>/dev/null || true
    exit 1
  fi
done
if ! grep -q '^.*main\.vibe:[0-9][0-9]*:[0-9][0-9]*: ' "$gvdir/all.txt"; then
  echo "[compiler-gate] FAIL: vibe grep output is not path:line:col-prefixed" >&2
  cat "$gvdir/all.txt" >&2
  exit 1
fi
# Typed tier: the effect row of the CALLEE, which only exists if the import
# walk actually resolved the module graph.
gv_run row.txt VIBE_GREP_PATTERN='$(f:id)($(a:args))' VIBE_GREP_WHERE_ROW='$f with Fs'
if ! grep -qF 'readit(q)' "$gvdir/row.txt" || grep -qF 'plain(a)' "$gvdir/row.txt"; then
  echo "[compiler-gate] FAIL: --where-row '\$f with Fs' kept the wrong sites" >&2
  cat "$gvdir/row.txt" "$gvdir/row.txt.diag" >&2 2>/dev/null || true
  exit 1
fi
# Resolved-name filter: `h` is an ALIAS for dep.vibe's `helper`, so a text grep
# for `helper(` finds nothing here and this must still find it.
gv_run alias.txt VIBE_GREP_PATTERN='$(f:id)($(a:args))' VIBE_GREP_WHERE='$f = helper'
if ! grep -qF 'h(1)' "$gvdir/alias.txt"; then
  echo "[compiler-gate] FAIL: --where '\$f = helper' did not resolve the import alias" >&2
  cat "$gvdir/alias.txt" "$gvdir/alias.txt.diag" >&2 2>/dev/null || true
  exit 1
fi
# A bad pattern is an ERROR on the .diag sidecar, never a plausible-but-wrong
# match list on output_path (the VIBE_SYMBOLS convention).
gv_run bad.txt VIBE_GREP_PATTERN='f($(x:expr))'
if [ -s "$gvdir/bad.txt" ] || ! grep -q 'unknown metavariable kind' "$gvdir/bad.txt.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a bad grep pattern did not land on the .diag sidecar" >&2
  cat "$gvdir/bad.txt" "$gvdir/bad.txt.diag" >&2 2>/dev/null || true
  exit 1
fi

# A typing failure belongs to ONE file, not to the whole repository sweep.
# Keep the trustworthy hits on either side, drop the broken file, and report
# that skip once on the warning sidecar. This preserves fail-closed filtering
# without turning a work-in-progress file into a repo-wide abort (#1834).
cat > "$gvdir/a_sweep_good.vibe" <<'VEOF'
fn good_before() -> Int {
  let xs = [1]
  Array::length(xs)
}
VEOF
cat > "$gvdir/b_sweep_bad.vibe" <<'VEOF'
fn broken_between() -> Int {
  let wrong: String = 1
  let xs = [2]
  Array::length(xs)
}
VEOF
cat > "$gvdir/c_sweep_good.vibe" <<'VEOF'
fn good_after() -> Int {
  let xs = [3]
  Array::length(xs)
}
VEOF
gv_run sweep.txt VIBE_GREP_PATTERN='Array::length($(x:exp))' VIBE_GREP_WHERE='$x : Array[Int]'
if ! grep -qF 'a_sweep_good.vibe' "$gvdir/sweep.txt" || ! grep -qF 'c_sweep_good.vibe' "$gvdir/sweep.txt"; then
  echo "[compiler-gate] FAIL: a broken file aborted the typed grep repo sweep" >&2
  cat "$gvdir/sweep.txt" "$gvdir/sweep.txt.diag" "$gvdir/sweep.txt.warn" >&2 2>/dev/null || true
  exit 1
fi
if grep -qF 'b_sweep_bad.vibe' "$gvdir/sweep.txt" || [ -s "$gvdir/sweep.txt.diag" ]; then
  echo "[compiler-gate] FAIL: typed grep did not fail closed per broken file" >&2
  cat "$gvdir/sweep.txt" "$gvdir/sweep.txt.diag" "$gvdir/sweep.txt.warn" >&2 2>/dev/null || true
  exit 1
fi
if [ "$(grep -cF 'b_sweep_bad.vibe' "$gvdir/sweep.txt.warn" 2>/dev/null || true)" -ne 1 ]; then
  echo "[compiler-gate] FAIL: typed grep did not report the skipped file exactly once" >&2
  cat "$gvdir/sweep.txt.warn" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$gvdir"
echo "[compiler-gate] vibe grep typed filters ok"

# 99. #1571: `inspect` is a REWRITE, not a function, so the two ways it can be
#     wrong are both silent -- it can capture a name the user already bound, and
#     it can hijack a call the user meant for their own `inspect`. Both were
#     found by review rather than by a gate (the second twice: expression
#     binders in #1622, PATTERN binders after that), which is what this step is
#     for. Each case below fails DIFFERENTLY if the guard regresses.
echo "[compiler-gate] 99/104 the inspect rewrite neither captures nor hijacks (#1571)"
inspdir="_build/_gate_inspect_guard"
rm -rf "$inspdir"; mkdir -p "$inspdir"

# (a) Hygiene: the temporaries the expansion introduces must not capture a name
# the arguments already reference. With a fixed temp name this compared the
# literal against ITSELF and passed; the assertion has to see "wrong".
cat > "$inspdir/hygiene.vibe" <<'INSPH'
fn main() -> Int allows Console {
  let __vibe_inspect_actual = "wrong"
  inspect(1, __vibe_inspect_actual)
  0
}
INSPH
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$inspdir/hygiene.vibe" "$inspdir/hygiene.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$inspdir/hygiene.wasm" ]; then
  echo "[compiler-gate] FAIL: the inspect hygiene sample did not compile" >&2
  cat "$inspdir/hygiene.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if insp_hyg="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$inspdir/hygiene.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: inspect(1, __vibe_inspect_actual) PASSED -- the expansion's temporary captured the argument, so it compared a value against itself (#1571 hygiene)" >&2
  echo "$insp_hyg" >&2
  exit 1
fi

# The same freshness boundary when the candidate appears ONLY as a compound-
# assignment target inside the value expression. A target-blind scan reuses the
# name, so the generated let captures the mutation and the snapshot observes 1.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/inspect_assignop_target_freshness.vibe "$inspdir/assignop.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$inspdir/assignop.wasm" ]; then
  echo "[compiler-gate] FAIL: inspect EAssignOp target-only freshness fixture did not compile" >&2
  cat "$inspdir/assignop.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$inspdir/assignop.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: inspect temporary captured a target-only __vibe_inspect_actual" >&2
  exit 1
fi

# (b) Shadow, expression binder: a user function named `inspect` must keep its
# own body. 2 + 5 = 7; the rewrite would return Unit and not type.
cat > "$inspdir/shadow_fn.vibe" <<'INSPF'
fn inspect(v: Int, c: String) -> Int {
  v + 5
}

fn main() -> Int {
  inspect(2, "ignored")
}
INSPF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$inspdir/shadow_fn.vibe" "$inspdir/shadow_fn.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$inspdir/shadow_fn.wasm" ]; then
  echo "[compiler-gate] FAIL: a user-declared \`inspect\` did not compile -- the rewrite hijacked the call (#1571 shadow)" >&2
  cat "$inspdir/shadow_fn.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
insp_fn_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$inspdir/shadow_fn.wasm" 2>/dev/null | tail -1)"
if [ "$insp_fn_out" != "7" ]; then
  echo "[compiler-gate] FAIL: a user-declared \`inspect\` got '$insp_fn_out' (want 7) -- its body did not run (#1571 shadow)" >&2
  exit 1
fi

# (c) Shadow, PATTERN binder (Codex review on #1622): the same hijack via a
# match arm, which the expression-only guard could not see. The side effect is
# the observable: the rewrite runs a snapshot assertion instead and traps.
cat > "$inspdir/shadow_pat.vibe" <<'INSPP'
enum Box {
  B((Int, String) -> Unit with Console)
}

fn shout(v: Int, c: String) -> Unit with Console {
  println(c)
}

fn main() -> Int allows Console {
  match B(shout) {
    B(inspect) => {
      inspect(1, "SIDE EFFECT RAN")
      7
    }
  }
}
INSPP
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$inspdir/shadow_pat.vibe" "$inspdir/shadow_pat.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$inspdir/shadow_pat.wasm" ]; then
  echo "[compiler-gate] FAIL: a pattern-bound \`inspect\` did not compile (#1571 shadow, pattern binders)" >&2
  cat "$inspdir/shadow_pat.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
insp_pat_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$inspdir/shadow_pat.wasm" 2>&1)"
case "$insp_pat_out" in
  *"SIDE EFFECT RAN"*) ;;
  *)
    echo "[compiler-gate] FAIL: a match-arm-bound \`inspect\` was rewritten -- the user's function never ran (#1571 shadow; see dinsp_pat_binds in normalize/desugar_trait_dict.vibe)" >&2
    echo "$insp_pat_out" >&2
    exit 1
    ;;
esac
rm -rf "$inspdir"
echo "[compiler-gate] inspect rewrite hygiene + shadow guard ok"

# 100. #1567 slice 1: `vibe check` and `vibe diagnostics` must agree on the
#      COUNT of top-level parse errors, not just on their wording. The
#      recovering parser has already collected every one by the time
#      check_linked_file looks, so reporting `parse_diags[0]` and dropping the
#      rest made `check` a strictly worse answer to the same question -- three
#      broken statements cost three edit-and-rerun cycles. This pins the two
#      surfaces together so they cannot drift apart again.
echo "[compiler-gate] 100/104 check and diagnostics report the SAME parse errors (#1567)"
chkdir="_build/_gate_check_diag_parity"
rm -rf "$chkdir"; mkdir -p "$chkdir"
# Three top-level statements, two independently broken, one good between them.
# The good statement in the middle is what forces real resynchronization.
printf 'export let a = = 1\nexport let ok = 1\nexport let b = = 2\n' > "$chkdir/multi.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$chkdir/multi.vibe" "$chkdir/check.out" main >/dev/null 2>&1 || true
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$chkdir/multi.vibe" "$chkdir/diag.out" main >/dev/null 2>&1 || true
# check reports through the .diag sidecar, diagnostics through the output file.
# That is a COMPILER-side transport difference; the launcher normalizes both to
# stdout (#1567 slice 2, pinned in tests/integration/install/install_test.sh, which is
# the layer that owns the user-facing contract). This step stays at the
# compiler layer and only pins the counts.
chk_n="$(grep -c '^line ' "$chkdir/check.out.diag" 2>/dev/null || true)"
diag_n="$(grep -c '^line ' "$chkdir/diag.out" 2>/dev/null || true)"
[ -n "$chk_n" ] || chk_n=0
[ -n "$diag_n" ] || diag_n=0
if [ "$chk_n" != "2" ]; then
  echo "[compiler-gate] FAIL: vibe check reported $chk_n parse errors, want 2 -- check_linked_file is dropping diagnostics the recovering parser already collected (#1567)" >&2
  cat "$chkdir/check.out.diag" >&2 2>/dev/null || true
  exit 1
fi
if [ "$diag_n" != "2" ]; then
  echo "[compiler-gate] FAIL: vibe diagnostics reported $diag_n parse errors, want 2 (#1567)" >&2
  cat "$chkdir/diag.out" >&2 2>/dev/null || true
  exit 1
fi
# Same errors, not merely the same count: both must name line 1 and line 3.
for want in 'line 1:' 'line 3:'; do
  if ! grep -qF "$want" "$chkdir/check.out.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: vibe check's report is missing '$want' (#1567)" >&2
    cat "$chkdir/check.out.diag" >&2 2>/dev/null || true
    exit 1
  fi
  if ! grep -qF "$want" "$chkdir/diag.out" 2>/dev/null; then
    echo "[compiler-gate] FAIL: vibe diagnostics' report is missing '$want' (#1567)" >&2
    cat "$chkdir/diag.out" >&2 2>/dev/null || true
    exit 1
  fi
done
# A clean file must stay clean on both, with check still exiting 0.
printf 'export let a = 1\n' > "$chkdir/clean.vibe"
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$chkdir/clean.vibe" "$chkdir/clean.out" main >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: vibe check rejected a clean file (#1567)" >&2
  cat "$chkdir/clean.out.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$chkdir"
echo "[compiler-gate] check/diagnostics parse-error parity ok (#1567)"

# #1551: compiler-owned ingestion-pipeline observations are published only by
# successful checks and distinguish cold, warm, and list-to-group recovery.
node scripts/ingestion_pipeline_telemetry_integration.mjs "$ROOT_DIR" "$stage2_wasm"

# --- #988: `vibe deps` -- the resolved import closure ------------------------
#
# This verb exists to be MACHINE-consumed (scripts/affected_tests.mjs selects
# which tests to run from it), so the failure that matters is a list that is
# quietly incomplete: a caller then skips tests and reports green. Every check
# below is aimed at that, not at pretty output.
depdir="_build/_gate_vibe_deps"
rm -rf "$depdir"; mkdir -p "$depdir"
dep_run() {
  # $1 = output basename, $2 = input path, $3.. = extra env assignments
  local dep_out="$depdir/$1"; local dep_in="$2"; shift 2
  rm -f "$dep_out" "$dep_out.diag"
  env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_DEPS=1 "$@" \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$dep_in" "$dep_out" __no_entry__ >/dev/null 2>&1 || true
}

# (a) --direct resolves an `@scope/pkg` import to the package CONTRACT. The
# import line says `@vibe/ast`; only real resolution turns that into a path,
# which is precisely what a text scan of import lines cannot do.
dep_run direct.txt lib/@vibe/parser/parser_smoke_test.vibe VIBE_DEPS_DIRECT=1
if ! grep -qx 'lib/@vibe/ast/index.vpkg' "$depdir/direct.txt"; then
  echo "[compiler-gate] FAIL: vibe deps --direct did not resolve '@vibe/ast' to its index.vpkg (#988)" >&2
  cat "$depdir/direct.txt" "$depdir/direct.txt.diag" >&2 2>/dev/null || true
  exit 1
fi

# (b) The closure reaches a contract's SIBLING IMPLEMENTATION. No import line
# anywhere names lib/@vibe/ast/ast.vibe -- it enters the build only because the
# loader pulls a .vpkg's impls in. A selection built on anything less would
# miss every change to that file.
dep_run closure.txt lib/@vibe/parser/parser_smoke_test.vibe
if ! grep -qx 'lib/@vibe/ast/ast.vibe' "$depdir/closure.txt"; then
  echo "[compiler-gate] FAIL: vibe deps closure missed the .vpkg sibling impl lib/@vibe/ast/ast.vibe (#988)" >&2
  cat "$depdir/closure.txt" "$depdir/closure.txt.diag" >&2 2>/dev/null || true
  exit 1
fi
# The closure must cover the direct deps; a closure smaller than one hop means
# the walk terminated early and every caller under-selects.
while IFS= read -r dep_line; do
  [ -n "$dep_line" ] || continue
  if ! grep -qxF "$dep_line" "$depdir/closure.txt"; then
    echo "[compiler-gate] FAIL: vibe deps closure is missing direct dep '$dep_line' (#988)" >&2
    exit 1
  fi
done < "$depdir/direct.txt"
# The entry never lists itself (callers treat the output as "other files").
if grep -qx 'lib/@vibe/parser/parser_smoke_test.vibe' "$depdir/closure.txt"; then
  echo "[compiler-gate] FAIL: vibe deps listed the entry itself (#988)" >&2
  exit 1
fi

# (c) An unresolvable import is an ERROR on the .diag sidecar with EMPTY output
# -- never a truncated list. A partial dep list is not a degraded answer, it is
# a wrong one, and it is the shape that makes a caller silently skip tests.
printf 'import ./does_not_exist.vibe {\n  nope\n}\n\nexport let a = 1\n' > "$depdir/broken.vibe"
dep_run broken.txt "$depdir/broken.vibe" VIBE_DEPS_DIRECT=1
if [ -s "$depdir/broken.txt" ] || [ ! -s "$depdir/broken.txt.diag" ]; then
  echo "[compiler-gate] FAIL: an unresolvable import did not land on the .diag sidecar with empty output (#988)" >&2
  cat "$depdir/broken.txt" "$depdir/broken.txt.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$depdir"
echo "[compiler-gate] vibe deps import-closure ok (#988)"

# 101. #1262 / ADR-0100 (1): vibe answers "does this `let mut` escape?" with
#      TWO predicates on purpose -- lowering (`vibe escapes`, codegen's
#      `is_mut_captured_in`: box when unsure, since over-boxing only costs
#      speed) and enforcement (`vibe escapes --strict`, the checker's, whose
#      answer `TypeEnv` now carries via `env_bind_mut`: stay silent when
#      unsure, since a false positive is a wrong diagnostic). Two predicates
#      that are SUPPOSED to disagree are exactly the shape that rots into two
#      predicates that disagree by accident, so this pins WHERE they differ:
#      only on binder shadowing, and only in the one direction (strict's
#      output is a subset of the default's).
# 104/104. ADR-0091 (#1262): `vibe allocs` -- every heap-allocating site, as
#      `FN KIND OFFSET`. The direction is what matters and what this pins:
#      over-report, never under-report. A site this query misses lets
#      `#zero_alloc` certify something untrue, silently; a site it reports in
#      error costs the reader one line and argues back through a diagnostic.
#      So both halves are checked -- a function that allocates nothing really
#      produces EMPTY output (otherwise "clean" is worthless), and the sites
#      the source does not spell out (a closure's environment, a captured
#      `let mut` becoming a heap ref cell) really appear.
echo "[compiler-gate] 104/104 vibe allocs reports heap sites, and nothing else (ADR-0091 / #1262)"
bash "$ROOT_DIR/scripts/test_vibe_allocs_launcher.sh"
alcdir="_build/_gate_allocs"
rm -rf "$alcdir"; mkdir -p "$alcdir"
cat > "$alcdir/in.vibe" <<'ALCA'
fn pure_sum(a: Array[Int], n: Int) -> Int {
  let mut i = 0
  let mut acc = 0
  while i < n {
    acc = acc + Array::get(a, i)
    i = i + 1
  }
  acc
}

fn counter() -> () -> Int {
  let mut c = 0
  () -> Int {
    c = c + 1
    c
  }
}
ALCA
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_ALLOCS=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$alcdir/in.vibe" "$alcdir/out.txt" >/dev/null 2>&1 || true
if [ -s "$alcdir/out.txt.diag" ]; then
  echo "[compiler-gate] FAIL: vibe allocs failed on a valid file (ADR-0091 / #1262)" >&2
  cat "$alcdir/out.txt.diag" >&2 || true
  exit 1
fi
# The reads-only function must contribute NOTHING: "empty means zero-alloc" is
# the whole contract.
if grep -q '^pure_sum ' "$alcdir/out.txt" 2>/dev/null; then
  echo "[compiler-gate] FAIL: vibe allocs reported a site in an allocation-free function (ADR-0091 / #1262)" >&2
  cat "$alcdir/out.txt" >&2 || true
  exit 1
fi
# The two implicit sites -- neither is visible in the source text.
for want in "counter mut-cell" "counter closure"; do
  if ! grep -q "^$want " "$alcdir/out.txt" 2>/dev/null; then
    echo "[compiler-gate] FAIL: vibe allocs missed '$want' -- an implicit allocation ADR-0091 exists to surface (#1262)" >&2
    cat "$alcdir/out.txt" >&2 || true
    exit 1
  fi
done
# Exercise the advertised PUBLIC verb too. The adapter-only environment lane
# above cannot catch a missing `runtime/vibe` case (the original #1792 review
# regression): that would leave `vibe allocs` documented but unusable.
VIBE_RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
  VIBE_CLI_WASM="$stage2_wasm" \
  bash "$ROOT_DIR/runtime/vibe" allocs "$alcdir/in.vibe" > "$alcdir/public.txt"
for want in "counter mut-cell" "counter closure"; do
  if ! grep -q "^$want " "$alcdir/public.txt" 2>/dev/null; then
    echo "[compiler-gate] FAIL: public 'vibe allocs' missed '$want' (#1262)" >&2
    cat "$alcdir/public.txt" >&2 || true
    exit 1
  fi
done
# A file with no functions at all is empty output, not an error.
printf 'enum Empty {\n  E0\n}\n' > "$alcdir/none.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_ALLOCS=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$alcdir/none.vibe" "$alcdir/none.txt" >/dev/null 2>&1 || true
if [ -s "$alcdir/none.txt" ] || [ -s "$alcdir/none.txt.diag" ]; then
  echo "[compiler-gate] FAIL: vibe allocs on a function-free file should be empty and clean (#1262)" >&2
  cat "$alcdir/none.txt" "$alcdir/none.txt.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$alcdir"
echo "[compiler-gate] vibe allocs ok (ADR-0091 / #1262)"

echo "[compiler-gate] 101/104 the two escape predicates differ only on shadowing (#1262)"
escdir="_build/_gate_escapes"
rm -rf "$escdir"; mkdir -p "$escdir"

esc_run() { # esc_run <out> <src> <strict>
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_ESCAPES=1 VIBE_ESCAPES_STRICT="$3" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$2" "$escdir/$1" >/dev/null 2>&1 || true
}

# (a) A genuine capture: BOTH lanes must report it. If only one does, one of
# the two is broken -- they are meant to agree everywhere except shadowing.
cat > "$escdir/real.vibe" <<'ESCA'
fn main() -> Int {
  let mut acc = 0
  let bump = () -> Unit { acc = acc + 1 }
  bump()
  acc
}
ESCA
esc_run real_loose.txt "$escdir/real.vibe" 0
esc_run real_strict.txt "$escdir/real.vibe" 1
for lane in loose strict; do
  if ! grep -q '^acc ' "$escdir/real_$lane.txt" 2>/dev/null; then
    echo "[compiler-gate] FAIL: vibe escapes ($lane lane) missed a genuine closure capture (#1262)" >&2
    cat "$escdir/real_$lane.txt" "$escdir/real_$lane.txt.diag" >&2 2>/dev/null || true
    exit 1
  fi
done

# (b) A `for-in` binder that merely REUSES the outer `let mut`'s name. The
# closure captures the LOOP variable, so no authority crosses the binding --
# but codegen still boxes the outer cell on the name match. Loose must report
# it (that box is real, and a cost query must say so); strict must not.
cat > "$escdir/shadow.vibe" <<'ESCB'
fn main(xs: Array[Int]) -> Int {
  let mut n = 0
  for n in xs {
    let c = () -> Int { n }
    let _ = c()
  }
  n
}
ESCB
esc_run shadow_loose.txt "$escdir/shadow.vibe" 0
esc_run shadow_strict.txt "$escdir/shadow.vibe" 1
if ! grep -q '^n ' "$escdir/shadow_loose.txt" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the LOWERING escape lane stopped reporting a shadowed name -- it must stay conservative, because codegen really does box that cell (#1262)" >&2
  cat "$escdir/shadow_loose.txt" "$escdir/shadow_loose.txt.diag" >&2 2>/dev/null || true
  exit 1
fi
if [ -s "$escdir/shadow_strict.txt" ]; then
  echo "[compiler-gate] FAIL: \`vibe escapes --strict\` reported a binding a binder SHADOWS -- the enforcement predicate must subtract shadowing, or every check built on it (Spawnable today, region/Mut[c] next) inherits a false positive (#1262 / ADR-0100 (1))" >&2
  cat "$escdir/shadow_strict.txt" >&2
  exit 1
fi

# (c) A lex/parse failure goes to the .diag sidecar with EMPTY output, in both
# lanes -- "the query broke" must stay distinguishable from "nothing escapes",
# since empty output is this surface's clean signal.
printf 'fn main() -> Int {\n  let mut = =\n}\n' > "$escdir/broken.vibe"
esc_run broken_loose.txt "$escdir/broken.vibe" 0
esc_run broken_strict.txt "$escdir/broken.vibe" 1
for lane in loose strict; do
  if [ -s "$escdir/broken_$lane.txt" ] || [ ! -s "$escdir/broken_$lane.txt.diag" ]; then
    echo "[compiler-gate] FAIL: a broken source did not land on the .diag sidecar with empty output in the $lane escape lane (#1262)" >&2
    cat "$escdir/broken_$lane.txt" "$escdir/broken_$lane.txt.diag" >&2 2>/dev/null || true
    exit 1
  fi
done
rm -rf "$escdir"
echo "[compiler-gate] escape predicate two-lane split ok (#1262)"

# 102. ADR-0101 (3) / #1262: the Builder family's terminal verb is `build`, so
#      the type name and the verb correspond lexically. `freeze` is reserved
#      for the verb producing a Frozen- (persistent + Send) value, which a
#      Builder terminal is not -- the worst case of the old spelling was
#      `ArrayBuilder::freeze -> Array`, where the result of "freeze" is
#      mutable. The new spelling rides `canonical_builtin_name`, so it must
#      reach the SAME registry row and the SAME codegen dispatch as the legacy
#      one in BOTH backends: a source-level alias that only the checker knows
#      about would typecheck and then miscompile.
echo "[compiler-gate] 102/104 StringBuilder::build reaches the same lowering as ::freeze (ADR-0101 (3) / #1262)"
sbdir="_build/_gate_sb_build"
rm -rf "$sbdir"; mkdir -p "$sbdir"
cat > "$sbdir/build.vibe" <<'SBB'
fn joined() -> String {
  let b = StringBuilder::new()
  StringBuilder::push(b, "hello ")
  StringBuilder::push(b, "world")
  StringBuilder::build(b)
}

fn main() -> Int {
  String::length(joined())
}
SBB
sed 's/StringBuilder::build(b)/StringBuilder::freeze(b)/' "$sbdir/build.vibe" > "$sbdir/freeze.vibe"
for spelling in build freeze; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$sbdir/$spelling.vibe" "$sbdir/$spelling.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$sbdir/$spelling.wasm" ]; then
    echo "[compiler-gate] FAIL: StringBuilder::$spelling did not compile (ADR-0101 (3) / #1262)" >&2
    cat "$sbdir/$spelling.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  sb_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$sbdir/$spelling.wasm" 2>&1 | tail -1)"
  if [ "$sb_out" != "11" ]; then
    echo "[compiler-gate] FAIL: StringBuilder::$spelling produced '$sb_out' (want 11 = len(\"hello world\")) -- the two spellings must lower identically (#1262)" >&2
    exit 1
  fi
done
# Byte-identical output is the strong form of "same lowering": the alias is
# resolved before anything downstream can branch on the spelling, so the two
# programs are the same program.
if ! cmp -s "$sbdir/build.wasm" "$sbdir/freeze.wasm"; then
  echo "[compiler-gate] FAIL: StringBuilder::build and ::freeze produced DIFFERENT wasm -- the alias is being resolved somewhere downstream of a branch on the name (ADR-0101 (3) / #1262)" >&2
  exit 1
fi
rm -rf "$sbdir"
echo "[compiler-gate] StringBuilder::build terminal-verb alias ok (#1262)"

# 103. #1262 follow-up: `vibe check` must answer for a file that imports a
#      `@scope/pkg` package. It could not -- `check_linked_file` ran a SECOND
#      import resolution (`resolve_import_path`, a plain path join) alongside
#      the loader's real one, so `import @vibe/core { ... }` was read as the
#      filename `@vibe/core.vibe` and the check ABORTED. The same file
#      compiles, which is the exact shape CLAUDE.md calls a diagnostic hole:
#      the verb that is supposed to answer "does this compile?" could not.
#      The second consequence was quieter and worse -- `check_deprecated_warnings`
#      used that same resolver, so a `#deprecated` alias published by a PACKAGE
#      (every alias the ADR-0100 (3) collection rename shipped) was invisible
#      and the migration warning the rename PROMISED never appeared.
echo "[compiler-gate] 103/104 vibe check resolves @scope/pkg imports, and package deprecations warn (#1262)"
chkpkgdir="_build/_gate_check_scoped_pkg"
rm -rf "$chkpkgdir"; mkdir -p "$chkpkgdir"
cat > "$chkpkgdir/entry.vibe" <<'CHKPKG'
import @vibe/core {
  MutMap, MutMap::size, HashMap::new_string
}

fn main() -> Int {
  let m: MutMap[String, Int] = HashMap::new_string()
  MutMap::size(m)
}
CHKPKG
# Read the status rather than calling bare: the FAIL branch below exists to
# keep this surface from producing "a diagnostic-free failure", and under
# errexit a bare call made that branch unreachable -- the exact thing it
# guards against.
gate_status chk_rc env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$chkpkgdir/entry.vibe" "$chkpkgdir/check.out" main
# (a) it must SUCCEED. A crash here used to produce exit 1 with an empty
# output AND an empty .diag -- indistinguishable from a diagnostic-free
# failure, which is the one thing this surface must never be.
if [ "$chk_rc" != "0" ]; then
  echo "[compiler-gate] FAIL: vibe check exited $chk_rc on a file importing @vibe/core -- the second import resolver is back (#1262)" >&2
  cat "$chkpkgdir/check.out" "$chkpkgdir/check.out.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! grep -q '^ok$' "$chkpkgdir/check.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: vibe check on a @scope/pkg importer did not report clean (#1262)" >&2
  cat "$chkpkgdir/check.out" "$chkpkgdir/check.out.diag" >&2 2>/dev/null || true
  exit 1
fi
# (b) the deprecated alias must NAME its replacement. This is the half that
# was silently false: the scanner worked, but the package's marker never
# reached it, so the rename's documented migration path did not exist.
if ! grep -qF "'HashMap::new_string' is deprecated: use MutMap::new_string" "$chkpkgdir/check.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a #deprecated alias published by a PACKAGE did not warn -- ADR-0100 (3)'s staged migration depends on this (#1262)" >&2
  cat "$chkpkgdir/check.out" >&2
  exit 1
fi
# (c) warnings are NON-FATAL. The migration must not break builds, so the
# exit code above (0) and this line together are the contract.
if ! grep -q '^warning: ' "$chkpkgdir/check.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the deprecation line is not spelled as a warning (#1262)" >&2
  exit 1
fi
# (d) the control: the NEW spelling is silent. Without this, a check that
# warned unconditionally would pass every assertion above.
sed 's/, HashMap::new_string//; s/HashMap::new_string()/MutMap::new_string()/' \
  "$chkpkgdir/entry.vibe" > "$chkpkgdir/clean.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$chkpkgdir/clean.vibe" "$chkpkgdir/clean.out" main >/dev/null 2>&1 || true
if grep -q '^warning: ' "$chkpkgdir/clean.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the Mut- spelling warned -- the deprecation scan is not name-selective (#1262)" >&2
  cat "$chkpkgdir/clean.out" >&2
  exit 1
fi
rm -rf "$chkpkgdir"
echo "[compiler-gate] scoped-package check + package deprecation warnings ok (#1262)"

# 104. #1700: a generic transparent alias published by index.vpkg must keep
#      its formal parameters and target through the importer TypeEnv
#      projection. The committed seed predates that transport and diagnoses
#      `Box[Int]` vs `Cell[Int]`; the fresh stage2 must accept it. The opaque
#      control proves this is alias transparency, not a weakening that makes
#      every applied package type interchangeable.
echo "[compiler-gate] 104/104 generic aliases cross index.vpkg transparently (#1700)"
if ! VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/generic_alias_vpkg_test.vibe \
  fixtures/immutmap_alias_test.vibe \
  lib/@vibe/core/collection_alias_test.vibe >/dev/null; then
  echo "[compiler-gate] FAIL: a generic transparent alias did not cross an index.vpkg boundary (#1700)" >&2
  exit 1
fi
aliasdir="_build/_gate_generic_alias_vpkg"
rm -rf "$aliasdir"; mkdir -p "$aliasdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/generic_opaque_vpkg_mismatch.vibe "$aliasdir/opaque.wasm" __no_entry__ \
  >/dev/null 2>&1 || true
if [ -s "$aliasdir/opaque.wasm" ] \
  || ! grep -qF "expected Token[Int], got Seal[Int]" "$aliasdir/opaque.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: distinct opaque generic contract types stopped being nominal (#1700 control)" >&2
  cat "$aliasdir/opaque.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$aliasdir"
echo "[compiler-gate] generic transparent alias + opaque control ok (#1700)"

# 105. #2158: the checker's per-call-site Double type reaching the LINEAR
#      backend's floatish classifiers (CompileCtx.float_call_offsets).
#
#      Compiled through the SINGLE-SOURCE lane on purpose -- no
#      VIBE_FS_COMPILE, so `compile_source_wasi_only` runs, which is the linear
#      entry whose offsets come out of its whole-program check. The FS merge
#      lane carries the channel too since #2391 (fed by the modular check;
#      pinned by block 125 below and by the unit suite's
#      float_call_offset_fs_lane_test.vibe); this fixture pins the
#      single-source supply specifically, and is named without a `_test`
#      suffix so the unit runner's glob does not route it to the other lane.
echo "[compiler-gate] 105/105 checker Double call-result offsets on the linear source lane (#2158)"
fcodir="_build/_gate_float_call_offsets"
rm -rf "$fcodir"; mkdir -p "$fcodir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/float_call_offset_source_lane.vibe "$fcodir/fco.wasm" __no_entry__ \
  >/dev/null 2>&1 || true
if [ ! -s "$fcodir/fco.wasm" ]; then
  echo "[compiler-gate] FAIL: float call-offset fixture did not compile (#2158)" >&2
  cat "$fcodir/fco.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$fcodir/fco.wasm" >"$fcodir/run.log" 2>&1; then
  echo "[compiler-gate] FAIL: a Double reaching __to_string through a call still renders as raw bits (#2158)" >&2
  cat "$fcodir/run.log" >&2 || true
  exit 1
fi
rm -rf "$fcodir"
echo "[compiler-gate] linear source-lane Double call-result offsets ok (#2158)"

# ...and the offset that channel uses must not be one another node already
# owns. #2231's first fix gave a call-rooted dot-call the DOT FIELD NAME's
# offset, which `type_at.vibe` uses to identify that token; the type table is
# last-wins, so the call's result type would have overwritten it (#2248
# review). The `(` of the argument list belongs to no other node, and this
# pins that: an identifier in a call-rooted dot-call keeps its own type.
tadir="_build/_gate_typeat_callsite"
rm -rf "$tadir"; mkdir -p "$tadir"
cat > "$tadir/ta.vibe" <<'TAEOF'
struct Box { get: () -> Double }
fn mk_box() -> Box { Box::{ get: () -> { 2.5 } } }
fn main() -> Int {
  let v = mk_box().get()
  0
}
TAEOF
ta_out="$(VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" VIBE_CLI_WASM="$stage2_wasm" \
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/runtime/vibe" type-at "$tadir/ta.vibe" 4 11 2>/dev/null | head -1)"
if [ "$ta_out" != "() -> Box" ]; then
  echo "[compiler-gate] FAIL: type-at on \`mk_box\` in a call-rooted dot-call reports '$ta_out', not '() -> Box' -- the call-site offset is stealing an identifier token (#2231/#2248)" >&2
  exit 1
fi
rm -rf "$tadir"
echo "[compiler-gate] call-site offset does not steal an identifier token ok (#2231)"

# 106/106. `vibe fmt` (#2149). The formatter has always been real and
#      CI-enforced, but reachable only through lib/@vibe/cli/fmt_entry.vibe --
#      a separate wasm scripts/vibe_fmt.sh FS-compiles on demand, whose paths
#      must live under the repo checkout. So an INSTALLED user could not
#      format at all, while 21 documents told them to run `vibe fmt`.
#
#      Two halves. Since #2858 the formatter's decisions live in the verb
#      dispatcher (lib/@vibe/compiler/user_dispatch.vibe), so the launcher
#      test drives the stage2 under test through runtime/vibe and pins each
#      path as the user sees it (modes, both refusals, one file at a time,
#      inherited adapter-mode selectors cleared). Then the guest branch on
#      its own: the same stage2 formats a messy file through VIBE_FMT and
#      must produce the canonical layout.
echo "[compiler-gate] 106/106 vibe fmt reaches an installed user (#2149)"
VIBE_CLI_WASM="$stage2_wasm" bash "$ROOT_DIR/scripts/test_vibe_fmt_launcher.sh"
# cli_adapter dispatches on selectors in SOURCE ORDER, so a leaked one hijacks
# every verb whose selector is evaluated later. Keeping the launcher's `env -u`
# lists right by hand demonstrably does not work -- this PR shipped an arm
# missing six selectors, then fixed one arm at a time and still missed three.
# So the requirement is DERIVED from cli_adapter rather than restated.
bash "$ROOT_DIR/scripts/check_selector_precedence.sh"
# ...and prove that check can FAIL. It reported ok on a hijackable tree five
# separate times; each defect was caught by a reviewer, and each red test that
# proved the fix lived only in a commit message, so the guarantee did not
# survive the next edit. Every one of those five is now a case.
bash "$ROOT_DIR/scripts/check_selector_precedence_test.sh"
# The same rule, for every gate -- a new one ships with a self-test that mutates
# a real input and asserts the gate fails -- is enforced by
# check_gate_self_tests.sh, which now runs in its OWN workflow job
# (`gate-self-tests` in .github/workflows/ci.yml) and not here.
#
# It ran every companion in the tree serially, which is 208s of real work, and
# this lane is the whole CI critical path. Measured on main, run 34590373673:
# 419s wall, of which compiler-gate (late) was 411s, of which that one script
# was 208s -- half the run, spent on shell gates inside the compiler's lane.
# Moving it to a job with no `needs` overlaps it with the lanes instead of
# extending them. Same work, same serial order, ~208s earlier.
#
# scripts/test_ci_compiler_gate_layout.sh pins BOTH halves: a job must run it
# and start at t=0, and it must not come back here.
# ...and the two ways a self-test stops meaning anything without ever going
# red: it depends on a tool CI does not have (ripgrep -- five of them did, and
# were exempted rather than fixed), or its pattern quietly means something
# other than it reads (`grep -E` does not interpret `\t`, so `'x\t'` matches
# `xt` and the check answers "no match" forever). #2252.
bash "$ROOT_DIR/scripts/check_gate_portability.sh"
bash "$ROOT_DIR/scripts/check_gate_portability_test.sh"
# #2831 criterion 2: `vibe check --json` answers the same contract on the FS
# lane and under `--single-file` -- diagnostics, exit code, and the byte -> LSP
# offset conversion. The two lanes have SEPARATE argument parsers, which is how
# they could drift without either looking wrong on its own.
CHECK_JSON_PARITY_STAGE2="$stage2_wasm" bash "$ROOT_DIR/scripts/check_check_json_lane_parity.sh"
CHECK_JSON_PARITY_STAGE2="$stage2_wasm" bash "$ROOT_DIR/scripts/check_check_json_lane_parity_test.sh"
# ...and the third way a gate stops meaning anything: a DIAGNOSTIC in it aborts
# the work it explains. `ensure_generated.sh` reports which inputs moved before
# regenerating, sliced with `printf | head -20`; `head` leaves after its 20th
# line, so a diff larger than the pipe buffer gives printf SIGPIPE, and
# pipefail + set -e turn that into exit 141 with no artifacts written. Measured
# at 869 differing lines. It fires only in the LARGE case -- a fresh clone or a
# seed bump -- which is exactly when the regeneration is needed.
bash "$ROOT_DIR/scripts/check_generated_stamp_report.sh"
bash "$ROOT_DIR/scripts/check_generated_stamp_report_test.sh"
# ...and the fourth: a MEASUREMENT whose input moves with the change it is
# measuring. The lex/parse series read the live compiler sources, so a PR that
# edited the checker moved the input of the benchmark that measures the parser
# -- +17.3% B/op on one such PR with the compiler held fixed, reported to the
# reviewer as a warning about their own change (#2865). The corpus is frozen
# under bench/perf/corpus/; this keeps it frozen and the benches pointed at it.
bash "$ROOT_DIR/scripts/check_bench_corpus.sh"
bash "$ROOT_DIR/scripts/check_bench_corpus_test.sh"
# ...and the fifth: work a lane does that nobody reads. A compile that passes a
# fresh cache for BOTH body-cache parameters records a body, three meta counts,
# three slices and one vibe.linemap row per function into an out-cache the
# caller never bound -- and on the bump lane none of it is ever reclaimed
# (#2873). The OUT cache is the second of the pair, so an inline
# `codegen_body_cache_new()` there is provably unread.
bash "$ROOT_DIR/scripts/check_body_cache_discard.sh"
bash "$ROOT_DIR/scripts/check_body_cache_discard_test.sh"
# ...and the sixth: a lane that CAN no longer do its work and does not say so.
# Several compiler-sized compiles in one `--daemon` exhaust the wasm32 address
# space; before #2876 the next request answered a bare `unreachable` in 1us
# with no `.diag`, which is the shape a caller reserves for a crash rather than
# a refusal. Two directions, and the second is the sharper one: an ordinary
# trap must NOT be relabelled "out of memory", or a compiler bug reads as a
# reason to recycle the process.
bash "$ROOT_DIR/scripts/check_daemon_memory_diagnostic.sh"
bash "$ROOT_DIR/scripts/check_daemon_memory_diagnostic_test.sh"
# check_book_console.sh landed (#2253) with no self-test and CI caught it the
# same day -- the ratchet working as intended. Its cases hand the gate a STUB
# compiler so the transcripts fail identically for all of them, and assert the
# message each mutation adds on top: block count, ja/en parity, and whether the
# chapter's documented 42 -> 43 edit still applies. ~1s, no generation needed.
bash "$ROOT_DIR/scripts/check_book_console_test.sh"
# #2580: and the PRODUCTION gate, which ran nowhere in CI. Only its self-test
# was wired here, and a self-test proves its own red/green -- not that the book
# transcripts still match the launcher. check_gate_wiring.sh found it on its
# first correct run, and it was RED: the launcher had grown an `at off=62`
# line the chapter did not carry, and the paragraph under it still said the
# report has no position at all, a gap #2202 closed.
# The gate is handed THIS lane's stage2 (#2138): left to resolve_stage2 on a
# CI shard, whose generation lives outside _build/selfhost/generations, it
# fell back to the committed seed -- a compiler that predates the verb
# protocol the launcher now speaks (#2858).
BOOK_CONSOLE_STAGE2="$stage2_wasm" bash "$ROOT_DIR/scripts/check_book_console.sh"

# 107/107. The host runner's `[crash debug]` dump is OFF by default (#2199).
#      It is compiler-developer diagnostics -- heap bytes, the RC freelist, raw
#      memory windows -- and it printed on EVERY trap, so the first thing a
#      reader saw when `Array::get(xs, 10)` went out of range was a page of hex
#      ahead of the message naming the index and the length. Both directions
#      are asserted: silence alone would also pass if the program stopped
#      trapping, and the dump alone would pass if it were unconditional again.
echo "[compiler-gate] 107/107 the host runner's crash dump is opt-in (#2199)"
cdbg="_build/_gate_crash_debug"
rm -rf "$cdbg"; mkdir -p "$cdbg"
cat > "$cdbg/oob.vibe" <<'CDBGEOF'
fn main() -> Int allows Console {
  let xs = [1, 2, 3]
  println("get = \{Array::get(xs, 10)}")
  0
}
CDBGEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw   bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"   "$cdbg/oob.vibe" "$cdbg/oob.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$cdbg/oob.wasm" ]; then
  echo "[compiler-gate] FAIL: crash-debug fixture did not compile (#2199)" >&2
  cat "$cdbg/oob.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh   --invoke _start "$cdbg/oob.wasm" >"$cdbg/quiet.log" 2>&1 || true
VIBE_CRASH_DEBUG=1 VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh   --invoke _start "$cdbg/oob.wasm" >"$cdbg/loud.log" 2>&1 || true
if grep -qF '[crash debug]' "$cdbg/quiet.log"; then
  echo "[compiler-gate] FAIL: the crash dump printed without VIBE_CRASH_DEBUG (#2199)" >&2
  cat "$cdbg/quiet.log" >&2
  exit 1
fi
if ! grep -qF 'Array::get: index 10 out of bounds for length 3' "$cdbg/quiet.log"; then
  echo "[compiler-gate] FAIL: the bounds message the reader needs is gone too (#2199)" >&2
  cat "$cdbg/quiet.log" >&2
  exit 1
fi
if ! grep -qF '[crash debug]' "$cdbg/loud.log"; then
  echo "[compiler-gate] FAIL: VIBE_CRASH_DEBUG=1 produced no dump -- the gate above proves nothing (#2199)" >&2
  cat "$cdbg/loud.log" >&2
  exit 1
fi
rm -rf "$cdbg"
echo "[compiler-gate] crash dump opt-in ok (#2199)"
fmtdir="_build/_gate_vibe_fmt"
rm -rf "$fmtdir"; mkdir -p "$fmtdir"
printf 'let   add=(a:Int,b:Int)->Int{a+b}\n' > "$fmtdir/messy.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_FMT=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fmtdir/messy.vibe" "$fmtdir/out.vibe" >"$fmtdir/run.log" 2>&1 || true
if [ ! -s "$fmtdir/out.vibe" ]; then
  echo "[compiler-gate] FAIL: VIBE_FMT produced no output -- vibe fmt is not wired into the compiler (#2149)" >&2
  cat "$fmtdir/run.log" >&2 || true
  exit 1
fi
cat > "$fmtdir/expected.vibe" <<'FMTEXP'
let add = (a: Int, b: Int) -> Int {
  a + b
}
FMTEXP
if ! cmp -s "$fmtdir/expected.vibe" "$fmtdir/out.vibe"; then
  echo "[compiler-gate] FAIL: VIBE_FMT did not produce the canonical layout (#2149)" >&2
  diff -u "$fmtdir/expected.vibe" "$fmtdir/out.vibe" >&2 || true
  exit 1
fi
rm -rf "$fmtdir"
echo "[compiler-gate] vibe fmt ok (#2149)"
#      ...and #2636 on that same INSTALLED route (Codex on #2708): the branch
#      above is what runtime/vibe's `fmt` arm runs, and it formatted input that
#      did not parse -- `a==0?"z":"nz"` came back reflowed as
#      `a == 0?"z": "nz"` with verdict 0, which `--check` then certified.
#      Verdict 2, the input written back byte-for-byte, and the parse error in
#      the .diag sidecar; the messy file above already pins that a program
#      which parses is still formatted with verdict 0.
fmtdir="_build/_gate_vibe_fmt_parse"
rm -rf "$fmtdir"; mkdir -p "$fmtdir"
printf 'fn f(a: Int) -> String {\n  a==0?"z":"nz"\n}\n' > "$fmtdir/ternary.vibe"
fmt_rc="$(VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_FMT=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fmtdir/ternary.vibe" "$fmtdir/out.vibe" 2>"$fmtdir/run.err" | tail -1 || true)"
if [ "$fmt_rc" != "2" ]; then
  echo "[compiler-gate] FAIL: VIBE_FMT on a file that does not parse returned '$fmt_rc', not 2 -- the installed vibe fmt formats programs the compiler rejects (#2636)" >&2
  cat "$fmtdir/run.err" >&2 || true
  exit 1
fi
if ! cmp -s "$fmtdir/ternary.vibe" "$fmtdir/out.vibe"; then
  echo "[compiler-gate] FAIL: VIBE_FMT rewrote a file that does not parse (#2636)" >&2
  diff -u "$fmtdir/ternary.vibe" "$fmtdir/out.vibe" >&2 || true
  exit 1
fi
if ! grep -qF 'does not parse' "$fmtdir/out.vibe.diag" 2>/dev/null || ! grep -qF 'unexpected token' "$fmtdir/out.vibe.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: VIBE_FMT's refusal did not name the parse error in the .diag sidecar (#2636)" >&2
  cat "$fmtdir/out.vibe.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$fmtdir"
echo "[compiler-gate] vibe fmt refuses a file that does not parse on the installed route ok (#2636)"
