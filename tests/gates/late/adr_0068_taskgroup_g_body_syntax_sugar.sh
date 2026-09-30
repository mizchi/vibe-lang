#!/usr/bin/env bash
# Sourced by this lane's run.sh; shares its resolved compiler and gate state.
# #1081 step 4 (surface polish): `taskgroup { g => body }` is pure parser
# sugar for `TaskGroup::run((g) -> { body })` -- no dedicated AST node, no
# desugar pass, no checker special-casing (docs/internal/design/concurrency.md's naming
# note: the actually-implemented library type is `TaskGroup`, not the
# earlier illustrative `Nursery`/`Task`/`Spawn[r]` capability-effect
# design). Positive: the sugar compiles + runs identically to a
# hand-written `TaskGroup::run(...)` call. Negative: the EXISTING region-
# escape check (hardcoded by name on `TaskGroup::run`, unchanged by this
# sugar) still rejects a leaked `TaskHandle`.
echo "[compiler-gate] 62/67 ADR-0068 taskgroup { g => body } syntax sugar (#1081 step 4)"
taskgroupdir="_build/_gate_taskgroup_sugar"
rm -rf "$taskgroupdir"; mkdir -p "$taskgroupdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_taskgroup_sugar.vibe "$taskgroupdir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$taskgroupdir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_taskgroup_sugar.vibe did not compile" >&2
  cat "$taskgroupdir/pos.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! taskgroup_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$taskgroupdir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_taskgroup_sugar.vibe got '$taskgroup_pos_out' (want 42)" >&2
  echo "$taskgroup_pos_out" >&2
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_taskgroup_sugar_region_escape.vibe "$taskgroupdir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$taskgroupdir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_taskgroup_sugar_region_escape.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'region escapes its nursery scope' "$taskgroupdir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_taskgroup_sugar_region_escape.vibe did not produce the expected diagnostic" >&2
  cat "$taskgroupdir/neg.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$taskgroupdir"
echo "[compiler-gate] taskgroup { g => body } syntax sugar ok"

# #906 (compiler self-parallelization prerequisite,
# docs/internal/design/compiler-parallelism.md "FrozenArray"): FrozenArray[T] is a
# checker-only phantom-type distinction over Array[T]'s exact same runtime
# layout (mirrors ArrayBuilder's new/push/freeze technique, checker.vibe
# #938 -- from_array/to_array are pure identity casts, get/length alias
# Array::get/Array::length's own bodies). Its whole point is the Send
# judgment: checker_trait.vibe's send_ok_rec now has a
# CtNamed("FrozenArray", [elem]) arm recognizing it Send exactly when
# `elem` is, unlike Array[T] (permanently rejected, unaffected). Four
# fixtures: (1) region_ok_frozen_array_basic.vibe -- functional smoke test
# of from_array/get/length/to_array, compiled+run. (2)
# send_bound_frozen_array.vibe -- FrozenArray[Int] satisfies a `[T: Send]`
# bound, compiled+run. (3) err_type_send_frozen_array_of_array_bound.vibe
# -- the judgment truly recurses: FrozenArray[Array[Int]] (non-Send
# element) is still rejected. (4)
# region_ok_frozen_array_taskgroup_capture.vibe -- end-to-end: a
# `TaskGroup::spawn` closure capturing a FrozenArray[Int] built OUTSIDE
# the closure is Spawnable-legal (checker_spawnable.vibe falls back to
# type_send_ok), where the same capture of a plain Array[Int] is rejected
# (fixtures/err_spawnable_capture_array.vibe, gate 61 above, unaffected).
echo "[compiler-gate] 63/67 FrozenArray[T] Send-eligible immutable container (#906)"
frozenarrdir="_build/_gate_frozen_array"
rm -rf "$frozenarrdir"; mkdir -p "$frozenarrdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_frozen_array_basic.vibe "$frozenarrdir/basic.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$frozenarrdir/basic.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_frozen_array_basic.vibe did not compile" >&2
  cat "$frozenarrdir/basic.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! frozenarr_basic_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$frozenarrdir/basic.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_frozen_array_basic.vibe got '$frozenarr_basic_out' (want 42)" >&2
  echo "$frozenarr_basic_out" >&2
  exit 1
fi
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/send_bound_frozen_array.vibe "$frozenarrdir/send.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$frozenarrdir/send.wasm" ]; then
  echo "[compiler-gate] FAIL: send_bound_frozen_array.vibe did not compile -- FrozenArray[Int] Send acceptance regressed" >&2
  cat "$frozenarrdir/send.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! frozenarr_send_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$frozenarrdir/send.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: send_bound_frozen_array.vibe got '$frozenarr_send_out' (want 42)" >&2
  echo "$frozenarr_send_out" >&2
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_type_send_frozen_array_of_array_bound.vibe "$frozenarrdir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$frozenarrdir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_type_send_frozen_array_of_array_bound.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'no impl `Send` for `FrozenArray[Array[Int]]`' "$frozenarrdir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_type_send_frozen_array_of_array_bound.vibe did not produce the expected diagnostic" >&2
  cat "$frozenarrdir/neg.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_frozen_array_taskgroup_capture.vibe "$frozenarrdir/capture.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$frozenarrdir/capture.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_frozen_array_taskgroup_capture.vibe did not compile -- FrozenArray Spawnable capture regressed" >&2
  cat "$frozenarrdir/capture.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! frozenarr_capture_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$frozenarrdir/capture.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_frozen_array_taskgroup_capture.vibe got '$frozenarr_capture_out' (want 40)" >&2
  echo "$frozenarr_capture_out" >&2
  exit 1
fi
rm -rf "$frozenarrdir"
echo "[compiler-gate] FrozenArray[T] Send-eligible immutable container ok"

# 64/64. #639: effect-row mismatch diagnostic snapshots -- criterion 1 (no
#        'with' clause at all) and criterion 2 (a `handle` locally
#        discharges one effect while another stays genuinely missing; the
#        message must show the handled one folded into "declared" rather
#        than re-flagging it as missing). Pins the exact wording so it
#        can't silently drift; see #639's discussion for why the riskier
#        "over-declared with () is itself a hard error" reading was
#        deliberately NOT implemented.
echo "[compiler-gate] 64/67 effect-row mismatch diagnostic snapshots (#639)"
eff639dir="_build/_gate_eff639"
rm -rf "$eff639dir"; mkdir -p "$eff639dir"
cp fixtures/err_effect_missing_annotation.vibe "$eff639dir/no_with.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eff639dir/no_with.vibe" "$eff639dir/no_with.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$eff639dir/no_with.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effect_missing_annotation.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF "missing { Ask::Value } (no 'with' clause, requires { Ask::Value })" "$eff639dir/no_with.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effect_missing_annotation.vibe did not produce the expected diagnostic" >&2
  cat "$eff639dir/no_with.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
cp fixtures/err_effect_handle_partial_discharge.vibe "$eff639dir/partial.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eff639dir/partial.vibe" "$eff639dir/partial.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$eff639dir/partial.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effect_handle_partial_discharge.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF "missing { Fs } (no 'with' clause, requires { Fs })" "$eff639dir/partial.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effect_handle_partial_discharge.vibe did not produce the expected diagnostic" >&2
  cat "$eff639dir/partial.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$eff639dir"
echo "[compiler-gate] effect-row mismatch diagnostic snapshots ok"

# 65/65. #1157: a zero-arg `perform Eff::Op` (no parens) previously bypassed
#        the direct effect-row check entirely (silent soundness gap -- see
#        #1157 for the repro). Pin that it is now rejected with the same
#        message as the parenthesized form.
echo "[compiler-gate] 65/67 zero-arg perform (no parens) effect-row check (#1157)"
eff1157dir="_build/_gate_eff1157"
rm -rf "$eff1157dir"; mkdir -p "$eff1157dir"
cp fixtures/err_effect_zero_arg_perform_no_parens.vibe "$eff1157dir/x.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eff1157dir/x.vibe" "$eff1157dir/x.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$eff1157dir/x.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effect_zero_arg_perform_no_parens.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF "missing { Ask::Get } (no 'with' clause, requires { Ask::Get })" "$eff1157dir/x.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effect_zero_arg_perform_no_parens.vibe did not produce the expected diagnostic" >&2
  cat "$eff1157dir/x.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$eff1157dir"
echo "[compiler-gate] zero-arg perform effect-row check ok"

# 66/66. #1161 (Codex review of #1157's fix): a DIRECT-discipline mismatch
#        must report the qualified operation, not the stripped base effect
#        name, when the enclosing function already declares a SIBLING
#        operation of the same effect at operation granularity -- otherwise
#        the generated fix-it would grant the whole effect and over-widen
#        the caller's capability surface (docs/internal/design/effectset.md's operation-
#        level diagnostic contract).
echo "[compiler-gate] 66/67 operation-level fix-it precision for partial rows (#1161)"
eff1161dir="_build/_gate_eff1161"
rm -rf "$eff1161dir"; mkdir -p "$eff1161dir"
cp fixtures/err_effect_op_level_partial_row_bare_perform.vibe "$eff1161dir/x.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eff1161dir/x.vibe" "$eff1161dir/x.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$eff1161dir/x.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effect_op_level_partial_row_bare_perform.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF "missing { Ask::Get } (declared { Ask::Other }, requires { Ask::Get, Ask::Other })" "$eff1161dir/x.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effect_op_level_partial_row_bare_perform.vibe did not produce the expected diagnostic" >&2
  cat "$eff1161dir/x.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! grep -qF "hint: add 'with Ask::Get + Ask::Other' to 'asks'" "$eff1161dir/x.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effect_op_level_partial_row_bare_perform.vibe did not produce the expected operation-level fix-it hint" >&2
  cat "$eff1161dir/x.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$eff1161dir"
echo "[compiler-gate] operation-level fix-it precision ok"

# 67/67. #820 sub-item 3: `vibe context-pack` bundles docs/user/reference/cheatsheet.md +
#        the verified eval/lang-review/golden corpus for AI-harness context
#        ingestion. Pure shell (scripts/gen_context_pack.sh), no wasm
#        involved -- pin determinism, the expected section markers, and the
#        missing-input error path.
#
#        Codex review (PR #1162): the pack's own text claims every golden
#        example "compiled and ran against the current compiler" -- that
#        claim must actually be re-verified against THIS gate run's stage2
#        (eval/lang-review/run_golden.sh, the existing writability
#        regression check), not just assumed still true. A compiler change
#        that broke a golden example without anyone re-running run_golden.sh
#        separately would otherwise ship a pack that lies about its own
#        examples.
echo "[compiler-gate] 67/67 vibe context-pack generator (#820 sub-item 3)"
if ! LANG_REVIEW_STAGE2="$stage2_wasm" bash eval/lang-review/run_golden.sh; then
  echo "[compiler-gate] FAIL: eval/lang-review/run_golden.sh -- the golden corpus context-pack bundles no longer compiles/runs as claimed" >&2
  exit 1
fi
# r4: the repair corpus is the measurement the `repair_convergence` score rests
# on (rubric dimension 8). It is a TWO-WAY ratchet -- a diagnostic that stops
# firing, whose wording drifts, OR that starts firing on a case recorded as
# silent all fail here, because each of those invalidates the recorded score.
if ! LANG_REVIEW_STAGE2="$stage2_wasm" bash eval/lang-review/run_repair.sh; then
  echo "[compiler-gate] FAIL: eval/lang-review/run_repair.sh -- the diagnostics the repair_convergence score was measured against changed; re-score in eval/lang-review/repair/README.md" >&2
  exit 1
fi
ctxpackdir="_build/_gate_ctxpack"
rm -rf "$ctxpackdir"; mkdir -p "$ctxpackdir"
bash scripts/gen_context_pack.sh "$ROOT_DIR" > "$ctxpackdir/a.md"
bash scripts/gen_context_pack.sh "$ROOT_DIR" > "$ctxpackdir/b.md"
if ! cmp -s "$ctxpackdir/a.md" "$ctxpackdir/b.md"; then
  echo "[compiler-gate] FAIL: gen_context_pack.sh is not deterministic" >&2
  exit 1
fi
if ! grep -qF "## Quick Start" "$ctxpackdir/a.md"; then
  echo "[compiler-gate] FAIL: context pack missing cheatsheet content" >&2
  exit 1
fi
if ! grep -qF "### 01_fizzbuzz" "$ctxpackdir/a.md"; then
  echo "[compiler-gate] FAIL: context pack missing golden example section" >&2
  exit 1
fi
if bash scripts/gen_context_pack.sh "$ctxpackdir" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: gen_context_pack.sh must fail on a dir with no docs/eval tree" >&2
  exit 1
fi
rm -rf "$ctxpackdir"
echo "[compiler-gate] vibe context-pack generator ok"

# 68/68. #1203: a linked (multi-file) program's top-level function can share
#        a bare name with an UNRELATED closure's own parameter declared in an
#        imported file (here, `compose`'s own `f`/`g` params) without the
#        closure silently losing that parameter from its capture list.
#        `collect_free_vars_expr_sc`'s plain EIdent case checked `fn_names`
#        (the whole linked program's top-level names, via a shared
#        capture-name index) BEFORE `encl` (the enclosing scope's own
#        locals) -- so `compose`'s own `f` parameter, referenced inside its
#        returned closure `(z) -> g(f(z))`, was wrongly treated as "already
#        global, no capture needed" whenever the merged program ALSO defined
#        an unrelated top-level `fn f()` anywhere (main.vibe below). The
#        returned closure's captured-environment struct then allocated one
#        field too few and silently dropped the store/load for `f`,
#        corrupting the wasm (invalid at instantiation) or, if it happened
#        to validate, producing a wrong runtime result instead of any
#        diagnostic. Single-file compiles never exercised this: only the
#        LINKED merge pipeline builds one shared name index across every
#        file, so this fixture must use a real cross-file import (matching
#        the smallest repro from the #1203 investigation trail), not the
#        `__DATA__` single-file fixture harness other closure-capture gates
#        above use.
echo "[compiler-gate] 68/68 closure param shadowing a same-named top-level fn in another linked file (#1203)"
c1203dir="_build/_gate_closure_param_shadows_toplevel"
rm -rf "$c1203dir"; mkdir -p "$c1203dir/pkg"
cat > "$c1203dir/pkg/lib.vibe" <<'VEOF'
export fn compose(f: (x: Int) -> Int, g: (y: Int) -> Int) -> (z: Int) -> Int {
  (z) -> g(f(z))
}
export fn addone(x: Int) -> Int { x + 1 }
export fn double(x: Int) -> Int { x * 2 }
VEOF
cat > "$c1203dir/main.vibe" <<'VEOF'
import ./pkg/lib.vibe { compose, addone, double }

// Unrelated top-level fn sharing a bare name with compose's own closure
// parameter (declared in the OTHER, imported file) -- never called, its
// mere presence in the linked program's name table is the trigger.
fn f() -> Int { 1 }

export let main = () -> Int {
  let c = compose(addone, double)
  c(3)
}
VEOF
rm -f "$c1203dir/out.wasm" "$c1203dir/out.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$c1203dir/main.vibe" "$c1203dir/out.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$c1203dir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: closure-param/top-level-name collision program did not compile (#1203)" >&2
  cat "$c1203dir/out.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
c1203_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$c1203dir/out.wasm" 2>&1 | tail -1)"
if [ "$c1203_out" != "8" ]; then
  echo "[compiler-gate] FAIL: closure-param/top-level-name collision program got '$c1203_out' (want 8 = double(addone(3))) -- #1203 regressed (compose's own 'f'/'g' params silently dropped from its returned closure's captures)" >&2
  exit 1
fi
rm -rf "$c1203dir"
echo "[compiler-gate] closure param shadowing a same-named top-level fn ok (8)"

# 69/69. #1212 Codex review (P1): the #1203 fix above only covered `f`/`g`
#        used as a plain identifier / bare call callee. An enclosing `let
#        mut f` reassigned ONLY via `f = ...` / `f += ...` inside a returned
#        closure (never read as a plain EIdent) goes through
#        collect_free_vars_expr_sc's EAssign/EAssignOp cases instead, which
#        had the identical fn_names-before-encl precedence bug, checked
#        separately from the EIdent case -- so it needed its own fix and its
#        own end-to-end regression coverage, not just a unit-level check.
echo "[compiler-gate] 69/69 closure write-only capture of a let-mut shadowing a same-named top-level fn (#1203 follow-up, #1212 review)"
c1203bdir="_build/_gate_closure_assign_target_shadows_toplevel"
rm -rf "$c1203bdir"; mkdir -p "$c1203bdir/pkg"
cat > "$c1203bdir/pkg/lib.vibe" <<'VEOF'
export fn make_ticker() -> () -> Unit {
  let mut f = 0
  () -> {
    f += 1
  }
}
VEOF
cat > "$c1203bdir/main.vibe" <<'VEOF'
import ./pkg/lib.vibe { make_ticker }

// Unrelated top-level fn sharing a bare name with the enclosing `let mut f`
// that the returned closure ONLY writes to (never reads as a plain
// identifier) -- never called, its mere presence in the linked program's
// name table is the trigger.
fn f() -> Int { 1 }

export let main = () -> Int {
  let t = make_ticker()
  t()
  t()
  0
}
VEOF
rm -f "$c1203bdir/out.wasm" "$c1203bdir/out.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$c1203bdir/main.vibe" "$c1203bdir/out.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$c1203bdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: write-only closure capture / top-level-name collision program did not compile (#1203 follow-up) -- #1212 review regressed" >&2
  cat "$c1203bdir/out.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
c1203b_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$c1203bdir/out.wasm" 2>&1 | tail -1)"
if [ "$c1203b_out" != "0" ]; then
  echo "[compiler-gate] FAIL: write-only closure capture / top-level-name collision program got '$c1203b_out' (want 0) -- #1212 review regressed" >&2
  exit 1
fi
rm -rf "$c1203bdir"
echo "[compiler-gate] closure write-only capture shadowing a same-named top-level fn ok"

# 70/70. inspect() snapshot auto-update tool regression lock (#1061 follow-up,
#        docs/internal/design/adr.md #0087): scripts/vibe_inspect_update.sh reads a failing
#        `inspect(value, content)` run's "actual/expected" diagnostic and
#        rewrites the stale `content` literal in place. Lock both the
#        multi-call convergence loop (two wrong snapshots in one file, fixed
#        across two compile/run/patch iterations) and that a clean file is
#        left untouched (exits 0, reports "already up to date", no rewrite).
echo "[compiler-gate] 70/70 inspect() snapshot auto-update mode (#1061 follow-up, vibe test --update)"
# VIBE_INSPECT_UPDATE=1 is cli_adapter.vibe::cli_main's low-level mode behind
# `vibe test --update` (runtime/vibe's `test)` case) -- same (input_path,
# output_path) + extra-env-var-for-a-second-path convention as
# VIBE_NORMALIZE/VIBE_TYPE_AT right above it in that file. Exercised here the
# same way those are: directly against the stage2 wasm via
# run_wasm_vibe_host_runner.sh, without needing an installed viberun/vibe-cli
# toolchain layout. Locks both the call-scoped patch (an unrelated earlier
# literal with the same text is left untouched -- #1235 review P1) and that
# an already-correct file's inspect() calls round-trip unchanged (P2's
# trailing-newline handling: a snapshot ending in "\n" survives one patch
# pass byte-identical to the true actual value).
inspupddir="_build/_gate_inspect_update"
rm -rf "$inspupddir"; mkdir -p "$inspupddir"
cat > "$inspupddir/demo.vibe" <<'VEOF'
import ../../lib/@vibe/core { inspect }

let label = "old"

test "demo" {
  inspect(String::concat("line1", "\n"), "old")
  assert(label == "old")
}
VEOF
cat > "$inspupddir/captured.txt" <<'VEOF'
inspect mismatch:
  actual:   line1

  expected: old
VEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_INSPECT_UPDATE=1 VIBE_INSPECT_UPDATE_STDOUT="$inspupddir/captured.txt" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$inspupddir/demo.vibe" "$inspupddir/patched.vibe" >/dev/null 2>&1 || true
if [ ! -s "$inspupddir/patched.vibe" ]; then
  echo "[compiler-gate] FAIL: VIBE_INSPECT_UPDATE mode produced no output" >&2
  exit 1
fi
if ! grep -q 'inspect(String::concat("line1", "\\n"), "line1\\n")' "$inspupddir/patched.vibe" || ! grep -q 'let label = "old"' "$inspupddir/patched.vibe"; then
  echo "[compiler-gate] FAIL: VIBE_INSPECT_UPDATE patched to unexpected content (unrelated literal touched, or trailing-newline snapshot mishandled)" >&2
  cat "$inspupddir/patched.vibe" >&2
  exit 1
fi
# A run whose captured output has no recognizable mismatch leaves the source
# byte-identical (echoed back via output_path, not an error).
printf 'unrelated crash output\nRuntimeError: unreachable\n' > "$inspupddir/nomatch.txt"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_INSPECT_UPDATE=1 VIBE_INSPECT_UPDATE_STDOUT="$inspupddir/nomatch.txt" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$inspupddir/demo.vibe" "$inspupddir/unchanged.vibe" >/dev/null 2>&1 || true
if ! cmp -s "$inspupddir/demo.vibe" "$inspupddir/unchanged.vibe"; then
  echo "[compiler-gate] FAIL: VIBE_INSPECT_UPDATE rewrote a file despite no recognizable mismatch" >&2
  exit 1
fi
rm -rf "$inspupddir"
echo "[compiler-gate] inspect() snapshot auto-update mode ok"

# 71/71. #1239 step 4(A): an import cycle is rejected by the coordinator-side
#        upfront plan -- @vibe/compiler/module_graph's plan_module_order, wired into
#        runtime/typecheck_fs.vibe's ensure_fingerprint_fs_impl -- BEFORE any
#        module is committed, rather than incidentally partway through the
#        walk on whichever module the DFS happened to re-enter first.
#
#        What makes that observable is the persistent cache. The old inline
#        "currently visiting" stack check could only fire after
#        ensure_fingerprint_fs_go had already written each module's dep list
#        on the way down, so a cyclic pair left dep-list entries behind; the
#        upfront pass resolves the whole graph without committing anything,
#        so a cyclic pair now leaves none. Measured on this exact fixture at
#        cb16be5 (before the wiring) vs after: 2 dep-list files -> 0.
#
#        The acyclic control is what gives the 0 its meaning: same file
#        shape, same isolated cache dir, and it DOES write dep lists. Without
#        it, "0 files" would also pass if dep lists simply stopped being
#        written at all.
echo "[compiler-gate] 71/71 import cycle rejected before any module is committed (#1239 step 4A)"
cycdir="_build/_gate_import_cycle"
rm -rf "$cycdir"; mkdir -p "$cycdir/cyclic" "$cycdir/acyclic" "$cycdir/cache_cyclic" "$cycdir/cache_acyclic"
printf 'import ./b.vibe { bee }\nexport let _start = () -> Int { bee() }\n' > "$cycdir/cyclic/a.vibe"
printf 'import ./a.vibe { _start }\nexport let bee = () -> Int { 42 }\n' > "$cycdir/cyclic/b.vibe"
printf 'import ./b.vibe { bee }\nexport let _start = () -> Int { bee() }\n' > "$cycdir/acyclic/a.vibe"
printf 'export let bee = () -> Int { 42 }\n' > "$cycdir/acyclic/b.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  VIBE_BUILD_CACHE_DIR="$ROOT_DIR/$cycdir/cache_cyclic" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cycdir/cyclic/a.vibe" "$cycdir/cyclic/a.wasm" _start >/dev/null 2>&1 && cyc_rc=0 || cyc_rc=$?
if [ "$cyc_rc" = "0" ]; then
  echo "[compiler-gate] FAIL: a cyclic import pair compiled successfully -- the cycle rejection is gone" >&2
  exit 1
fi
cyc_deps="$(find "$cycdir/cache_cyclic" -name 'vibe_selfhost_dep_list_*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$cyc_deps" != "0" ]; then
  echo "[compiler-gate] FAIL: rejecting a cyclic import pair left $cyc_deps dep-list cache entries behind (want 0) -- modules are being committed before the upfront plan rejects the cycle" >&2
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  VIBE_BUILD_CACHE_DIR="$ROOT_DIR/$cycdir/cache_acyclic" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cycdir/acyclic/a.vibe" "$cycdir/acyclic/a.wasm" _start >/dev/null 2>&1
acyc_deps="$(find "$cycdir/cache_acyclic" -name 'vibe_selfhost_dep_list_*' 2>/dev/null | wc -l | tr -d ' ')"
if [ ! -s "$cycdir/acyclic/a.wasm" ] || [ "$acyc_deps" = "0" ]; then
  echo "[compiler-gate] FAIL: the acyclic control did not compile (wasm present: $([ -s "$cycdir/acyclic/a.wasm" ] && echo yes || echo no)) or wrote no dep lists ($acyc_deps) -- the cyclic assertion above proves nothing" >&2
  exit 1
fi
rm -rf "$cycdir"
echo "[compiler-gate] import cycle rejected before any commit ok (cyclic 0 dep lists, acyclic $acyc_deps)"

# 72/72. #1239 step 4(D): VIBE_MODULE_PLAN must describe the SAME graph the
#        per-file VIBE_LIST_DEPS loop it replaces described.
#
#        The host-side parallel pre-warm (scripts/parallel_frontend_warm.mjs)
#        used to spawn one compiler per module to discover the import DAG;
#        it now takes the whole graph, already in canonical rank order, from
#        one VIBE_MODULE_PLAN call. That is only safe while the two agree,
#        and disagreement would not fail loudly -- it would silently warm a
#        cache for the wrong graph. So the old per-file mode is kept as the
#        oracle here and diffed against the new one.
#
#        Two checks, split by cost. On the fixture (the leaf/mid/main
#        diamond, where main imports leaf both directly and through mid) the
#        agreement is EXACT: same dep rows in declaration order, duplicates
#        included, and byte-identical ingested source. On this repo's own
#        compiler graph the oracle would need ~200 process spawns, so that
#        one is checked structurally instead, from the plan alone: every
#        dependency must itself be a planned module with a strictly smaller
#        rank. That is the property a wave-at-a-time dispatcher relies on.
echo "[compiler-gate] 72/72 VIBE_MODULE_PLAN agrees with the per-file VIBE_LIST_DEPS graph (#1239 step 4D)"
plandir="_build/_gate_module_plan"
rm -rf "$plandir"; mkdir -p "$plandir/src"
cp scripts/fixtures/parallel_project_sample/leaf.vibe \
   scripts/fixtures/parallel_project_sample/mid.vibe \
   scripts/fixtures/parallel_project_sample/main.vibe "$plandir/src/"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_MODULE_PLAN=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$plandir/src/main.vibe" "$plandir/plan.txt" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$plandir/plan.txt" ]; then
  echo "[compiler-gate] FAIL: VIBE_MODULE_PLAN produced no manifest$([ -s "$plandir/plan.txt.diag" ] && echo ": $(cat "$plandir/plan.txt.diag")")" >&2
  exit 1
fi
plan_mods="$(awk -F'\t' '$1=="module"{print $2"\t"$4}' "$plandir/plan.txt")"
if [ "$(echo "$plan_mods" | grep -c .)" != "3" ]; then
  echo "[compiler-gate] FAIL: expected 3 planned modules for the leaf/mid/main fixture, got:" >&2
  cat "$plandir/plan.txt" >&2
  exit 1
fi
while IFS="$(printf '\t')" read -r idx modpath; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_LIST_DEPS=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$modpath" "$plandir/ld$idx.out" __no_entry__ >/dev/null 2>&1
  awk -F'\t' -v i="$idx" '$1=="dep" && $2==i{print $3}' "$plandir/plan.txt" > "$plandir/plan$idx.deps"
  grep -v '^[[:space:]]*$' "$plandir/ld$idx.out" > "$plandir/ld$idx.deps" || true
  if ! cmp -s "$plandir/plan$idx.deps" "$plandir/ld$idx.deps"; then
    echo "[compiler-gate] FAIL: VIBE_MODULE_PLAN and VIBE_LIST_DEPS disagree on $modpath's dependencies" >&2
    diff "$plandir/ld$idx.deps" "$plandir/plan$idx.deps" >&2 || true
    exit 1
  fi
  if ! cmp -s "$plandir/ld$idx.out.src" "$plandir/plan.txt.$idx.src"; then
    echo "[compiler-gate] FAIL: VIBE_MODULE_PLAN and VIBE_LIST_DEPS disagree on $modpath's INGESTED source -- a driver would check different text than the serial walk" >&2
    exit 1
  fi
done <<PLANMODS
$plan_mods
PLANMODS
echo "[compiler-gate] module plan matches per-file discovery on the fixture (3 modules)"
# Structural check on a real graph: one spawn, no oracle needed.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_MODULE_PLAN=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  lib/@vibe/compiler/tests/codegen_lexer_test.vibe "$plandir/big.txt" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$plandir/big.txt" ]; then
  echo "[compiler-gate] FAIL: VIBE_MODULE_PLAN produced no manifest for the compiler's own graph$([ -s "$plandir/big.txt.diag" ] && echo ": $(cat "$plandir/big.txt.diag")")" >&2
  exit 1
fi
plan_check="$(awk -F'\t' '
  $1=="module"{ rank[$4]=$3; idxpath[$2]=$4; n++ }
  $1=="dep"{ dep[++d]=$2 "\t" $3 }
  END{
    bad=0
    for (k=1; k<=d; k++) {
      split(dep[k], parts, "\t")
      importer=idxpath[parts[1]]; target=parts[2]
      if (!(target in rank)) { print "unplanned dependency: " importer " -> " target; bad++ }
      else if (rank[target]+0 >= rank[importer]+0) { print "rank not strictly decreasing: " importer " (" rank[importer] ") -> " target " (" rank[target] ")"; bad++ }
    }
    if (bad==0) print "ok " n
  }' "$plandir/big.txt")"
case "$plan_check" in
  ok\ *) echo "[compiler-gate] module plan rank invariant holds ($(echo "$plan_check" | cut -d' ' -f2) modules)" ;;
  *) echo "[compiler-gate] FAIL: module plan rank invariant violated -- a wave-at-a-time dispatcher would run a module before its dependency:" >&2
     echo "$plan_check" | head -5 >&2
     exit 1 ;;
esac
rm -rf "$plandir"
echo "[compiler-gate] VIBE_MODULE_PLAN agrees with per-file discovery ok"

# 73/73. Bytes::append on the wasm-gc lane, actually RUN.
#
#        Both backends share gen_bytes_append_body (a `Bytes` lives in linear
#        memory on the gc lane too -- gen_bytes_push_body is shared as well),
#        but codegen_bytes_test.vibe's gc cases only assert the module
#        VALIDATES. Nothing executed an append on the gc backend, so a change
#        to that shared generator could pass every gc test while producing a
#        module that computes the wrong bytes.
#
#        The fixture exercises the two paths the small appends elsewhere never
#        reach: crossing the initial capacity of 64 (so the grow branch runs)
#        and appending a buffer to ITSELF (source and destination alias). Its
#        checksum is position-weighted, so a copy landing at the wrong offset
#        or with the wrong length changes it -- a plain sum would not.
echo "[compiler-gate] 73/73 wasm-gc backend runs Bytes::append (grow + self-alias)"
bagdir="_build/_gate_bytes_append_gc"
rm -rf "$bagdir"; mkdir -p "$bagdir"
for bag_be in gc linear; do
  bag_env=""
  [ "$bag_be" = "gc" ] && bag_env="VIBE_BACKEND=gc"
  env $bag_env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/gc_bytes_append_grow.vibe" "$bagdir/$bag_be.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$bagdir/$bag_be.wasm" ]; then
    echo "[compiler-gate] FAIL: gc_bytes_append_grow.vibe did not compile on the $bag_be backend" >&2
    cat "$bagdir/$bag_be.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  bag_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$bagdir/$bag_be.wasm" 2>&1 | tail -1)"
  if [ "$bag_out" != "4027170" ]; then
    echo "[compiler-gate] FAIL: Bytes::append on the $bag_be backend got '$bag_out' (want 4027170) -- a grow or an aliased append copied the wrong bytes" >&2
    exit 1
  fi
done
rm -rf "$bagdir"
echo "[compiler-gate] Bytes::append runs correctly on both backends ok (4027170)"

# 74/74. #1259 (#1239 step 5's prerequisite): cross-module diagnostic
#        collection, and its canonical order.
#
#        The fs walk used to throw on the FIRST module diagnostic, so step 5's
#        "sort diagnostics into a canonical order and compare across jobs"
#        had nothing to sort. VIBE_DIAGNOSTICS_ALL=1 collects one diagnostic
#        per failing module instead; off (the default) is unchanged.
#
#        The fixture is two INDEPENDENT bad leaves plus a main that imports
#        both. Independent matters: they land in the same wave, so neither
#        failure removes any input the other needs, and both must be reported.
#        main must NOT be -- it is blocked, and a "no binding a" cascade on
#        top of the real error is exactly the noise a canonical set excludes.
#
#        Order is checked against VIBE_DEP_ORDER_SEED, the #906 Phase 0
#        within-wave permutation. That is the one knob that reproduces what a
#        parallel coordinator varies between runs, so byte-identical output
#        across seeds is the property step 5 actually wants; without the sort,
#        collection order leaks through and the seeds disagree.
echo "[compiler-gate] 74/74 cross-module diagnostics collected in canonical order (#1259)"
dcolldir="_build/_gate_diag_collect"
rm -rf "$dcolldir"; mkdir -p "$dcolldir/src" "$dcolldir/cache"
printf 'export let a: Int = "alpha is not an Int"\n' > "$dcolldir/src/alpha.vibe"
printf 'export let b: Int = "beta is not an Int"\n' > "$dcolldir/src/beta.vibe"
printf 'import ./alpha.vibe { a }\nimport ./beta.vibe { b }\nexport let _start = () -> Int { a + b }\n' > "$dcolldir/src/main.vibe"
# Each run gets a pristine cache dir: a persistent type env published by an
# earlier run would let the next one skip a module and report fewer
# diagnostics, which would make the comparisons below vacuous.
run_diag_collect() {
  # $1 = output tag, $2.. = extra env assignments
  local tag="$1"; shift
  rm -rf "$dcolldir/cache_$tag"; mkdir -p "$dcolldir/cache_$tag"
  env "$@" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    VIBE_BUILD_CACHE_DIR="$ROOT_DIR/$dcolldir/cache_$tag" \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$dcolldir/src/main.vibe" "$dcolldir/$tag.wasm" _start >/dev/null 2>&1 || true
  grep -c . "$dcolldir/$tag.wasm.diag" 2>/dev/null || echo 0
}
diag_default_lines="$(run_diag_collect default)"
if [ "$diag_default_lines" != "1" ]; then
  echo "[compiler-gate] FAIL: the default walk reported $diag_default_lines diagnostic lines (want 1) -- fail-fast is supposed to be unchanged without VIBE_DIAGNOSTICS_ALL" >&2
  cat "$dcolldir/default.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
diag_all_lines="$(run_diag_collect all VIBE_DIAGNOSTICS_ALL=1)"
if [ "$diag_all_lines" != "2" ]; then
  echo "[compiler-gate] FAIL: VIBE_DIAGNOSTICS_ALL=1 reported $diag_all_lines diagnostic lines (want 2: one per independent bad leaf, none for the blocked importer)" >&2
  cat "$dcolldir/all.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if [ "$(sed -n 1p "$dcolldir/all.wasm.diag" | grep -c 'alpha\.vibe')" != "1" ] || \
   [ "$(sed -n 2p "$dcolldir/all.wasm.diag" | grep -c 'beta\.vibe')" != "1" ]; then
  echo "[compiler-gate] FAIL: collected diagnostics are not in canonical (module path) order -- want alpha.vibe then beta.vibe:" >&2
  cat "$dcolldir/all.wasm.diag" >&2
  exit 1
fi
if grep -q 'main\.vibe' "$dcolldir/all.wasm.diag"; then
  echo "[compiler-gate] FAIL: the blocked importer produced a cascade diagnostic -- only the two real failures belong in the set:" >&2
  cat "$dcolldir/all.wasm.diag" >&2
  exit 1
fi
for diag_seed in 1 7 23; do
  run_diag_collect "seed$diag_seed" VIBE_DIAGNOSTICS_ALL=1 VIBE_DEP_ORDER_SEED="$diag_seed" >/dev/null
  if ! cmp -s "$dcolldir/all.wasm.diag" "$dcolldir/seed$diag_seed.wasm.diag"; then
    echo "[compiler-gate] FAIL: collected diagnostics changed under VIBE_DEP_ORDER_SEED=$diag_seed -- the within-wave visit order is leaking through the canonical sort" >&2
    diff "$dcolldir/all.wasm.diag" "$dcolldir/seed$diag_seed.wasm.diag" >&2 || true
    exit 1
  fi
done
# Vacuity guard for the loop above: prove seed 7 actually REORDERS this wave,
# so "identical across seeds" means the sort held rather than the seed being
# inert. Fail-fast reports whichever module the wave visited first, so at
# seed 7 it must report beta -- the opposite of the unseeded run's alpha.
run_diag_collect ffseed VIBE_DEP_ORDER_SEED=7 >/dev/null
if ! grep -q 'beta\.vibe' "$dcolldir/ffseed.wasm.diag"; then
  echo "[compiler-gate] FAIL: VIBE_DEP_ORDER_SEED=7 did not reorder the two-module wave (fail-fast still reported alpha first) -- the seed-invariance check above proves nothing" >&2
  cat "$dcolldir/ffseed.wasm.diag" >&2
  exit 1
fi
# The control: with collection on and NOTHING wrong, the same shape still
# compiles. Without this, every assertion above would also pass if
# VIBE_DIAGNOSTICS_ALL had simply broken the compiler.
printf 'export let a: Int = 1\n' > "$dcolldir/src/alpha.vibe"
printf 'export let b: Int = 2\n' > "$dcolldir/src/beta.vibe"
rm -rf "$dcolldir/cache_ok"; mkdir -p "$dcolldir/cache_ok"
VIBE_DIAGNOSTICS_ALL=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  VIBE_BUILD_CACHE_DIR="$ROOT_DIR/$dcolldir/cache_ok" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$dcolldir/src/main.vibe" "$dcolldir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$dcolldir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: a clean project failed to compile with VIBE_DIAGNOSTICS_ALL=1" >&2
  cat "$dcolldir/ok.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
diag_ok_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$dcolldir/ok.wasm" 2>&1 | tail -1)"
if [ "$diag_ok_out" != "3" ]; then
  echo "[compiler-gate] FAIL: the clean control got '$diag_ok_out' (want 3) with VIBE_DIAGNOSTICS_ALL=1" >&2
  exit 1
fi
rm -rf "$dcolldir"
echo "[compiler-gate] cross-module diagnostic collection ok (1 fail-fast, 2 collected, seed-invariant)"
# 75/75. ADR-0090 Phase 1 (#1262): `region r { body }` + MutList[T, r]
# vertical slice. The parser lowers the syntax to the reserved
# `__region_run((r) -> { body })`; the checker mints a rigid `#region_N`
# skolem for the binder and scans fully-zonked return/outer-binding types
# for escapes; MutList is a checker-only phantom over the ArrayBuilder
# runtime layout (freeze/to_array are the sanctioned exits). Positive:
# build a MutList inside the region, freeze, read it outside -- compiles
# and returns 42 (region_arena_ok.vibe). Negative: returning the
# region-tainted MutList itself out of the region body is a STATIC error
# (err_region_escape_return_value.vibe). Same known generalize-gap caveat
# as the ADR-0068 section above: the return-position escape is the hard
# guarantee in this slice. #1725 added the closure-capture direction, which
# the result-TYPE scan structurally cannot see (types do not record
# captures) -- both a negative and a false-positive guard, at the end.
echo "[compiler-gate] 75/75 ADR-0090 region + MutList/MutBytes vertical slice (#1262 / #1770)"
r90dir="_build/_gate_region90"
rm -rf "$r90dir"; mkdir -p "$r90dir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_arena_ok.vibe "$r90dir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_arena_ok.vibe did not compile -- ADR-0090 region/MutList slice regressed" >&2
  cat "$r90dir/pos.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! r90_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_arena_ok.vibe got '$r90_pos_out' (want 42)" >&2
  echo "$r90_pos_out" >&2
  exit 1
fi
cp fixtures/err_region_escape_return_value.vibe "$r90dir/neg.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$r90dir/neg.vibe" "$r90dir/neg.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$r90dir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_region_escape_return_value.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'region escapes its scope' "$r90dir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_region_escape_return_value.vibe did not produce the expected diagnostic" >&2
  cat "$r90dir/neg.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# #1274 Codex P1: the token is unforgeable -- MutList::empty with a
# non-skolem argument must be rejected.
cp fixtures/err_region_token_forged.vibe "$r90dir/forged.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$r90dir/forged.vibe" "$r90dir/forged.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$r90dir/forged.wasm" ]; then
  echo "[compiler-gate] FAIL: err_region_token_forged.vibe compiled successfully -- the region token must be unforgeable" >&2
  exit 1
fi
if ! grep -qF 'region token' "$r90dir/forged.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_region_token_forged.vibe did not produce the expected diagnostic" >&2
  cat "$r90dir/forged.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# #1725: the return-position check above scans the region body's RESULT TYPE
# for the skolem, so a region value hidden in a CLOSURE's captured
# environment slips past it -- the result type `() -> Array[Int]` mentions no
# region. These two fixtures pin BOTH directions, which is the whole
# difficulty: capture is legitimate, only escape is not.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_region_escape_closure_capture.vibe "$r90dir/cap.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$r90dir/cap.wasm" ]; then
  echo "[compiler-gate] FAIL: err_region_escape_closure_capture.vibe compiled successfully -- a region value must not escape inside a closure (#1725)" >&2
  exit 1
fi
if ! grep -qF 'region escapes its scope' "$r90dir/cap.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_region_escape_closure_capture.vibe did not produce the expected diagnostic" >&2
  cat "$r90dir/cap.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# The sharper negative: the escaping closure holds the region TOKEN, with no
# outer binding for a spine walk to find.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_region_escape_token_capture.vibe "$r90dir/tok.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$r90dir/tok.wasm" ]; then
  echo "[compiler-gate] FAIL: err_region_escape_token_capture.vibe compiled successfully -- a closure holding the region token must not escape (#1725)" >&2
  exit 1
fi
if ! grep -qF 'region escapes its scope' "$r90dir/tok.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_region_escape_token_capture.vibe did not produce the expected diagnostic" >&2
  cat "$r90dir/tok.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# #1938: capture provenance is part of the checked function type, not a
# terminal-lambda syntax check. Pin every laundering shape that the old
# stopgap missed (plus a deep alias witness).
for r90_fixture in \
  fixtures/err_region_escape_outer_assignment.vibe \
  fixtures/err_region_escape_container.vibe \
  fixtures/err_region_escape_helper.vibe \
  fixtures/err_region_escape_global_helper.vibe \
  fixtures/err_region_escape_multiple_regions.vibe \
  fixtures/err_region_escape_nested_closure.vibe \
  fixtures/err_region_escape_alias_chain.vibe \
  fixtures/err_region_escape_monomorphic_callback.vibe \
  fixtures/err_region_escape_array_write.vibe \
  fixtures/err_region_escape_field_write.vibe \
  fixtures/err_region_escape_record.vibe \
  fixtures/err_region_escape_generic_defer.vibe \
  fixtures/err_region_escape_named_struct.vibe \
  fixtures/err_region_escape_mutlist_write.vibe \
  fixtures/err_region_escape_array_alias_write.vibe \
  fixtures/err_region_escape_local_callee.vibe \
  fixtures/err_region_escape_callback_defer.vibe \
  fixtures/err_region_escape_named_projection.vibe \
  fixtures/err_region_escape_named_projection_alias.vibe \
  fixtures/err_region_escape_call_alias_write.vibe \
  fixtures/err_region_escape_inline_projection.vibe \
  fixtures/err_region_escape_inline_call_alias_write.vibe \
  fixtures/err_region_escape_aggregate_struct.vibe \
  fixtures/err_region_escape_callback_return.vibe \
  fixtures/err_region_escape_early_return.vibe \
  fixtures/err_region_escape_generalized_local_callee.vibe \
  fixtures/err_region_escape_direct_call_alias_write.vibe \
  fixtures/err_region_escape_alias_result.vibe \
  fixtures/err_region_escape_conditional_alias_result.vibe \
  fixtures/err_region_escape_multi_payload_constructor.vibe \
  fixtures/err_region_escape_enum_alias.vibe \
  fixtures/err_region_escape_enum_container.vibe \
  fixtures/err_region_escape_enum_outer_assignment.vibe \
  fixtures/err_region_escape_enum_payload.vibe \
  fixtures/err_region_escape_struct_alias.vibe \
  fixtures/err_region_escape_struct_container.vibe \
  fixtures/err_region_escape_constructor_helper.vibe \
  fixtures/err_region_escape_bound_struct.vibe \
  fixtures/err_region_escape_mutmap_write.vibe \
  fixtures/err_region_escape_deque_write.vibe \
  fixtures/err_region_escape_option_aggregate.vibe \
  fixtures/err_region_escape_result_aggregate.vibe \
  fixtures/err_region_escape_enum_aggregate.vibe \
  fixtures/err_region_escape_deque_dot_write.vibe \
  fixtures/err_region_escape_param_forwarding.vibe \
  fixtures/err_region_escape_nested_tuple_param.vibe \
  fixtures/err_region_escape_nested_record_param.vibe \
  fixtures/err_region_escape_nested_nominal_param.vibe \
  fixtures/err_region_escape_named_struct_bound.vibe \
  fixtures/err_region_escape_named_struct_field_alias.vibe \
  fixtures/err_region_escape_mutmap_key_write.vibe \
  fixtures/err_region_escape_mutmap_value_write.vibe \
  fixtures/err_region_escape_mutset_write.vibe \
  fixtures/err_region_escape_sortedmap_key_write.vibe \
  fixtures/err_region_escape_sortedmap_value_write.vibe \
  fixtures/err_region_escape_sortedset_write.vibe \
  fixtures/err_region_escape_priority_queue_write.vibe \
  fixtures/err_region_escape_deque_back_write.vibe \
  fixtures/err_region_escape_deque_front_write.vibe \
  fixtures/err_region_escape_hashmap_alias_write.vibe \
  fixtures/err_region_escape_hashset_alias_write.vibe \
  fixtures/err_region_escape_sortedmap_alias_write.vibe \
  fixtures/err_region_escape_sortedset_alias_write.vibe; do
  r90_escape="${r90_fixture#fixtures/err_region_escape_}"
  r90_escape="${r90_escape%.vibe}"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$r90_fixture" "$r90dir/${r90_escape}.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ -s "$r90dir/${r90_escape}.wasm" ]; then
    echo "[compiler-gate] FAIL: $r90_fixture compiled successfully -- region capture provenance was lost (#1938)" >&2
    exit 1
  fi
  if ! grep -qF 'region escapes its scope' "$r90dir/${r90_escape}.wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $r90_fixture did not produce the expected diagnostic (#1938)" >&2
    cat "$r90dir/${r90_escape}.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
done

# The false-positive guard: a closure that captures a region value but stays
# inside the region is valid, and the body still exits via freeze. It also
# covers shadowing and an initialiser that merely touches the token while
# evaluating to a scalar -- both shapes an over-eager taint rule rejects.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_closure_local.vibe "$r90dir/caplocal.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/caplocal.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_closure_local.vibe did not compile -- the #1725 capture check is over-approximating" >&2
  cat "$r90dir/caplocal.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! r90_cap_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/caplocal.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_closure_local.vibe got '$r90_cap_out' (want 55)" >&2
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_capture_provenance.vibe "$r90dir/provenance_ok.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/provenance_ok.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_capture_provenance.vibe did not compile -- capture provenance over-approximated (#1938)" >&2
  cat "$r90dir/provenance_ok.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/provenance_ok.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: region_ok_capture_provenance.vibe snapshots failed (#1938)" >&2
  exit 1
fi
# ADR-0090's sanctioned exits COPY. The rest of the FrozenArray surface is
# identity casts, so this is the one place the distinction is load-bearing:
# an aliasing exit both changes under the caller (the list handle is still in
# scope) and hands out a pointer into the segment the arena slice will
# release by watermark reset. Pushing after the exit must not reach the
# result -- inspect prints actual/expected itself on a regression.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_freeze_copies_out.vibe "$r90dir/copyout.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/copyout.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_freeze_copies_out.vibe did not compile" >&2
  cat "$r90dir/copyout.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! r90_copy_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/copyout.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: MutList::freeze/to_array aliased the list instead of copying out (want 250, aliasing gives 330)" >&2
  echo "$r90_copy_out" >&2
  exit 1
fi
# The arena segment + watermark bulk release. Two fixtures, because the
# release fails in two different ways: reclaiming something still live gives a
# WRONG VALUE (quietly -- reused bump memory reads as plausible data), and
# not releasing at all gives the RIGHT value while leaking. Only the second
# fixture can see the second failure, and only by measuring.
for r90_rc in 1 0; do
  VIBE_RC="$r90_rc" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    fixtures/region_arena_release_ok.vibe "$r90dir/release.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$r90dir/release.wasm" ]; then
    echo "[compiler-gate] FAIL: region_arena_release_ok.vibe did not compile (VIBE_RC=$r90_rc)" >&2
    cat "$r90dir/release.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  if ! r90_rel_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/release.wasm" 2>&1)"; then
    echo "[compiler-gate] FAIL: region arena release reclaimed live memory (VIBE_RC=$r90_rc, want 109965)" >&2
    echo "$r90_rel_out" >&2
    exit 1
  fi
  rm -f "$r90dir/release.wasm" "$r90dir/release.wasm.diag"
done
# Boundedness. Bump lane only: that is where the arena is wired (under RC a
# region block would carry an RC header and reach the free list, which the
# bulk release invalidates -- see linked_compile.vibe) and also where it is
# worth anything, since the bump allocator never frees. 200 regions x 500
# elements leaked 1,644,008 B before the arena and cost 6,408 B after; the
# bound below is deliberately loose (it only has to separate "releases" from
# "does not"), because the residual is per-call closure environments and
# grows if that lambda's shape changes.
VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_arena_bounded.vibe "$r90dir/bounded.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/bounded.wasm" ]; then
  echo "[compiler-gate] FAIL: region_arena_bounded.vibe did not compile" >&2
  cat "$r90dir/bounded.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! r90_bounded_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/bounded.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_arena_bounded.vibe got the wrong value" >&2
  echo "$r90_bounded_out" >&2
  exit 1
fi
r90_heap_delta="$(node scripts/region_arena_heap_delta.mjs "$r90dir/bounded.wasm")" || {
  echo "[compiler-gate] FAIL: could not read __heap_ptr from region_arena_bounded.wasm" >&2
  exit 1
}
if [ "$r90_heap_delta" -gt 100000 ]; then
  echo "[compiler-gate] FAIL: 200 regions grew the main bump heap by $r90_heap_delta B (want < 100000; ~6408 with the arena, 1644008 without) -- the arena stopped releasing" >&2
  exit 1
fi

# #1937: exception unwind through a region must restore depth. 70 punches
# exceed the 64-slot save table. The value assertion cannot see a skipped
# exit; only the heap delta can. Seed without the wrap leaked 574708 B.
echo "[compiler-gate] ADR-0090 #1937 exception-unwind region restore"
VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_throw_unwind_test.vibe "$r90dir/unwind.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/unwind.wasm" ]; then
  echo "[compiler-gate] FAIL: region_throw_unwind_test.vibe did not compile" >&2
  cat "$r90dir/unwind.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! r90_unwind_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/unwind.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_throw_unwind_test.vibe got the wrong value" >&2
  echo "$r90_unwind_out" >&2
  exit 1
fi
r90_unwind_delta="$(node --experimental-wasm-exnref scripts/region_arena_heap_delta.mjs "$r90dir/unwind.wasm")" || {
  echo "[compiler-gate] FAIL: could not read __heap_ptr from region_throw_unwind_test.wasm" >&2
  exit 1
}
if [ "$r90_unwind_delta" -gt 150000 ]; then
  echo "[compiler-gate] FAIL: 70 throw-through regions grew the main bump heap by $r90_unwind_delta B (want < 150000; seed without the wrap leaked 574708) -- region exit skipped on unwind (#1937)" >&2
  exit 1
fi
echo "[compiler-gate] region exception-unwind restore ok (70 punches, main heap +${r90_unwind_delta} B)"

# ADR-0090 #1262: a REFERENCE CYCLE inside a region also costs the main heap
# nothing -- the property the ADR calls the complement to RC's permanent
# limitation. The watermark reset reclaims it without inspecting the graph.
#
# Asserted on the MARGINAL cost, not the total: the fixed setup is not zero,
# so a total bound would either be loose enough to miss a leak or tight enough
# to break on unrelated changes. Two iteration counts, and the per-region cost
# has to stay small.
for r90_cyc_n in 200 800; do
  sed -e "s/while k < 200 {/while k < $r90_cyc_n {/" \
      -e "s/inspect(main(), \"1400\")/inspect(main(), \"$((r90_cyc_n * 7))\")/" \
      fixtures/region_arena_cycles.vibe > "$r90dir/cycles_$r90_cyc_n.vibe"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_RC=0 \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$r90dir/cycles_$r90_cyc_n.vibe" "$r90dir/cycles_$r90_cyc_n.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$r90dir/cycles_$r90_cyc_n.wasm" ]; then
    echo "[compiler-gate] FAIL: region_arena_cycles.vibe ($r90_cyc_n) did not compile" >&2
    cat "$r90dir/cycles_$r90_cyc_n.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/cycles_$r90_cyc_n.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: region_arena_cycles.vibe ($r90_cyc_n) got the wrong value" >&2
    exit 1
  fi
done
r90_cyc_lo="$(node scripts/region_arena_heap_delta.mjs "$r90dir/cycles_200.wasm")" || exit 1
r90_cyc_hi="$(node scripts/region_arena_heap_delta.mjs "$r90dir/cycles_800.wasm")" || exit 1
r90_cyc_per=$(( (r90_cyc_hi - r90_cyc_lo) / 600 ))
if [ "$r90_cyc_per" -gt 64 ]; then
  echo "[compiler-gate] FAIL: a reference cycle inside a region costs $r90_cyc_per B/region on the main heap (want <= 64; ~24 with the arena) -- the cycle is no longer reclaimed by the watermark reset" >&2
  exit 1
fi
echo "[compiler-gate] region arena reclaims reference cycles ok ($r90_cyc_per B/region)"
echo "[compiler-gate] region arena bulk release ok (200 regions, main heap +${r90_heap_delta} B)"

# ADR-0090 MutBytes (#1770 Phase 1): the region-bound byte buffer, same
# vertical slice as MutList above -- positive build/copy-out, unforgeable
# token, closure-capture escape (pins the MutBytes::empty row in
# checker_escape.vibe's taint predicate), copy-out semantics, and the
# boundedness of gen_bytes_push_body's arena regrow (which the MutList
# fixtures never exercise: Array growth and Bytes growth are separate
# builtin bodies).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_bytes_ok.vibe "$r90dir/bpos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/bpos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_bytes_ok.vibe did not compile -- ADR-0090 MutBytes slice regressed" >&2
  cat "$r90dir/bpos.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/bpos.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: region_bytes_ok.vibe test blocks failed" >&2
  exit 1
fi
for r90b_neg in err_region_bytes_token_forged:'region token' err_region_bytes_escape_return:'region escapes its scope' err_region_bytes_escape_closure_capture:'region escapes its scope'; do
  r90b_fixture="${r90b_neg%%:*}"
  r90b_needle="${r90b_neg#*:}"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/$r90b_fixture.vibe" "$r90dir/bneg.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ -s "$r90dir/bneg.wasm" ]; then
    echo "[compiler-gate] FAIL: $r90b_fixture.vibe compiled successfully -- must be rejected" >&2
    exit 1
  fi
  if ! grep -qF "$r90b_needle" "$r90dir/bneg.wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $r90b_fixture.vibe did not produce the expected diagnostic ('$r90b_needle')" >&2
    cat "$r90dir/bneg.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  rm -f "$r90dir/bneg.wasm" "$r90dir/bneg.wasm.diag"
done
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_bytes_ok_copy_out.vibe "$r90dir/bcopy.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/bcopy.wasm" ] \
  || ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/bcopy.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: region_bytes_ok_copy_out.vibe failed -- MutBytes::to_bytes must COPY (an alias sees the post-snapshot push)" >&2
  cat "$r90dir/bcopy.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_bytes_arena_bounded.vibe "$r90dir/bbounded.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/bbounded.wasm" ]; then
  echo "[compiler-gate] FAIL: region_bytes_arena_bounded.vibe did not compile" >&2
  cat "$r90dir/bbounded.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/bbounded.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: region_bytes_arena_bounded.vibe got the wrong value" >&2
  exit 1
fi
r90b_heap_delta="$(node scripts/region_arena_heap_delta.mjs "$r90dir/bbounded.wasm")" || {
  echo "[compiler-gate] FAIL: could not read __heap_ptr from region_bytes_arena_bounded.wasm" >&2
  exit 1
}
if [ "$r90b_heap_delta" -gt 100000 ]; then
  echo "[compiler-gate] FAIL: 200 MutBytes regions grew the main bump heap by $r90b_heap_delta B (want < 100000; ~8024 with the arena, 194424 without) -- the bytes arena regrow stopped releasing" >&2
  exit 1
fi
echo "[compiler-gate] MutBytes arena bulk release ok (200 regions, main heap +${r90b_heap_delta} B)"
# ADR-0090 / #1770: MutList::get / MutList::length -- the in-region reads
# that make "accumulate AND consume inside the region, escape only the
# reduced value" writable (the shape #1794's rejection identified as the
# only one where the arena is pure profit). Pins a growing worklist read
# back during iteration.
# Both RC modes: RC=1 exercises the borrow-return handling of MutList::get
# on heap-valued (String) elements -- a get treated as fresh-owned would
# over-release there (Codex #1820).
for r90_consume_rc in 1 0; do
  VIBE_RC="$r90_consume_rc" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    fixtures/region_ok_consume_in_region.vibe "$r90dir/consume.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$r90dir/consume.wasm" ] \
    || ! VIBE_RC="$r90_consume_rc" VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/consume.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: region_ok_consume_in_region.vibe failed under VIBE_RC=$r90_consume_rc -- MutList::get/length in-region reads regressed" >&2
    cat "$r90dir/consume.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  rm -f "$r90dir/consume.wasm"
done
echo "[compiler-gate] MutList in-region reads ok (get/length, RC both modes)"
# Codex #1801 P1: an outer region's buffer regrown inside a NESTED region
# must survive the inner exit (the replacement must not land in the inner
# region's span). Pins the saves[depth-1] guard in gen_arr_push_body /
# gen_bytes_push_body / gen_bytes_append_body for BOTH MutList and MutBytes.
VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_arena_nested_regrow_ok.vibe "$r90dir/nested.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/nested.wasm" ] \
  || ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/nested.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: region_arena_nested_regrow_ok.vibe failed -- an outer buffer regrown inside a nested region was rewound/overwritten" >&2
  cat "$r90dir/nested.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
echo "[compiler-gate] nested-region regrow guard ok (MutList + MutBytes)"
rm -rf "$r90dir"
echo "[compiler-gate] ADR-0090 region + MutList/MutBytes vertical slice ok"

# 76/76. ADR-0091 Phase 1 (#1262): `#zero_alloc` attribute. The attribute
# lexes as a single ident token, parses as a top-level SExpr the checker
# skips (checker_stmt.vibe) and the linear backend drops; enforcement is
# common_analysis.vibe's zero_alloc_check, run at the top of
# compile_wasi_module_linked_impl -- a conservative AST walk (constructors,
# container/closure/string-building literals, float literals, effect
# handlers, and any call not on the safe-builtin list or resolvable to a
# proven-clean top-level fn are rejected; transitive through top-level fn
# calls). Positive: a pure-arithmetic #zero_alloc fn compiles and returns
# 42 (zero_alloc_ok.vibe). Negative: a #zero_alloc fn constructing an enum
# value is a STATIC error naming the site (err_zero_alloc_ctor.vibe).
echo "[compiler-gate] 76/76 ADR-0091 #zero_alloc allocation check (#1262)"
za91dir="_build/_gate_zero_alloc91"
rm -rf "$za91dir"; mkdir -p "$za91dir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/zero_alloc_ok.vibe "$za91dir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$za91dir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: zero_alloc_ok.vibe did not compile -- ADR-0091 #zero_alloc slice regressed" >&2
  cat "$za91dir/pos.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! za91_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$za91dir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: zero_alloc_ok.vibe got '$za91_pos_out' (want 42)" >&2
  echo "$za91_pos_out" >&2
  exit 1
fi
cp fixtures/err_zero_alloc_ctor.vibe "$za91dir/neg.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$za91dir/neg.vibe" "$za91dir/neg.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$za91dir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_zero_alloc_ctor.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'zero_alloc' "$za91dir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_zero_alloc_ctor.vibe did not produce the expected diagnostic" >&2
  cat "$za91dir/neg.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# #1274 Codex P1: a param shadowing a clean top-level fn is an indirect
# callee and must be rejected.
cp fixtures/err_zero_alloc_shadowed_call.vibe "$za91dir/shadowed.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$za91dir/shadowed.vibe" "$za91dir/shadowed.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$za91dir/shadowed.wasm" ]; then
  echo "[compiler-gate] FAIL: err_zero_alloc_shadowed_call.vibe compiled successfully -- shadowed callees must be treated as indirect" >&2
  exit 1
fi
if ! grep -qF 'zero_alloc' "$za91dir/shadowed.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_zero_alloc_shadowed_call.vibe did not produce the expected diagnostic" >&2
  cat "$za91dir/shadowed.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# #1838: typed operators can allocate even when their operands are variables.
# Pin both allocating overloads: linear Double arithmetic boxes its result,
# and String `+` lowers to concatenation. Int arithmetic remains covered by
# the positive fixture above.
for za_typed in double_operator string_operator shadowed_operator; do
  cp "fixtures/err_zero_alloc_${za_typed}.vibe" "$za91dir/${za_typed}.vibe"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$za91dir/${za_typed}.vibe" "$za91dir/${za_typed}.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ -s "$za91dir/${za_typed}.wasm" ]; then
    echo "[compiler-gate] FAIL: err_zero_alloc_${za_typed}.vibe compiled successfully -- typed allocating operator must be rejected" >&2
    exit 1
  fi
  if ! grep -qF 'zero_alloc' "$za91dir/${za_typed}.wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: err_zero_alloc_${za_typed}.vibe did not produce the expected diagnostic" >&2
    cat "$za91dir/${za_typed}.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
done
rm -rf "$za91dir"
# ADR-0091 #1262: the check and the MEASUREMENT pin each other. The two
# fixtures above prove a clean fn compiles and a violating one is rejected;
# neither proves the annotation is TRUE at run time -- a checker that quietly
# stopped looking keeps both green. So state it twice, independently: the
# check says the marked fns allocate nothing, and `__heap_ptr` says the loop
# does not move it.
#
# Asserted on INVARIANCE, not on a total. The setup (`FixedArray::make`) is
# not free, so "total == 0" is unachievable and any fixed bound is arbitrary.
# Two iteration counts with the SAME delta means the per-iteration cost is
# exactly zero.
za91mdir="_build/_gate_zero_alloc91_measured"
rm -rf "$za91mdir"; mkdir -p "$za91mdir"
for za_n in 200 800; do
  sed -e "s/while k < 200 {/while k < $za_n {/" \
      -e "s/inspect(main(), \"22400\")/inspect(main(), \"$((za_n * 112))\")/" \
      fixtures/zero_alloc_measured.vibe > "$za91mdir/measured_$za_n.vibe"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_RC=0 \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$za91mdir/measured_$za_n.vibe" "$za91mdir/measured_$za_n.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$za91mdir/measured_$za_n.wasm" ]; then
    echo "[compiler-gate] FAIL: zero_alloc_measured.vibe ($za_n) did not compile -- the #zero_alloc check rejected a fn the measurement says is clean" >&2
    cat "$za91mdir/measured_$za_n.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$za91mdir/measured_$za_n.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: zero_alloc_measured.vibe ($za_n) got the wrong value" >&2
    exit 1
  fi
done
za_lo="$(node scripts/region_arena_heap_delta.mjs "$za91mdir/measured_200.wasm")" || exit 1
za_hi="$(node scripts/region_arena_heap_delta.mjs "$za91mdir/measured_800.wasm")" || exit 1
if [ "$za_lo" -ne "$za_hi" ]; then
  echo "[compiler-gate] FAIL: #zero_alloc fns allocated $(( (za_hi - za_lo) / 600 )) B per iteration (200 trips: $za_lo B, 800 trips: $za_hi B) -- the check says clean but the heap moved" >&2
  exit 1
fi
rm -rf "$za91mdir"
echo "[compiler-gate] #zero_alloc check and measurement agree ok (0 B/op, $za_lo B fixed setup)"
echo "[compiler-gate] ADR-0091 #zero_alloc allocation check ok"

# 77/77. ADR-0089 Decision 1, increment 1 (#1218): entry-row-Async sleep
# boundary. An entry whose declared row carries `Async` gets (a) a
# synthesized top-level `__slp_perform` that IS `perform
# Async::Suspend(-ms)`, with every unshadowed `sleep(..)` call retargeted
# to it, and (b) a tail-resumptive entry-boundary Async handler settling
# the debt via the row-free `sleep_blocking` (linked_compile.vibe
# lc_inject_async_sleep_boundary). Positive: a wrapper-fn `sleep` chain
# under an Async-row main compiles and returns 42
# (async_sleep_boundary_test.vibe -- behavior parity with the old blocking
# builtin). Since #2065 wall 2, spawning suspend-class tasks (TaskGroup
# spawn_suspend) under an Async-row entry COMPILES and answers 42
# (async_boundary_spawn_suspend_test.vibe); since #1537 host futures and host
# stream reads beside such tasks compile too, and tasks park on them
# (test_named_hostfutures_component_gate.sh / test_named_hoststreams_component_gate.sh
# run them).
echo "[compiler-gate] spawn_suspend refuses a named plain task closure (#3194)"
ssldir="_build/_gate_spawn_suspend_local"
rm -rf "$ssldir"; mkdir -p "$ssldir"
cat > "$ssldir/reject.vibe" <<'VIBE'
import @vibe/concurrent/experimental { TaskGroup, TaskHandle }
fn main() -> Int allows Async + Exception {
  TaskGroup::run((g) -> {
    let p = () -> Int with Async + Exception { 5 }
    let h = TaskGroup::spawn_suspend(g, p)
    TaskGroup::pump_all(g)
    TaskHandle::join(h) + 1
  })
}
VIBE
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ssldir/reject.vibe" "$ssldir/reject.wasm" main >/dev/null 2>&1 || true
if [ -s "$ssldir/reject.wasm" ] || ! grep -qF 'pass the task closure inline at `TaskGroup::spawn_suspend`' "$ssldir/reject.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a named plain task closure compiled or lacked the inline edit (#3194)" >&2
  cat "$ssldir/reject.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawn_suspend_alias_plain.vibe "$ssldir/alias.wasm" main >/dev/null 2>&1 || true
if [ -s "$ssldir/alias.wasm" ] || ! grep -qF 'pass the task closure inline at `TaskGroup::spawn_suspend`' "$ssldir/alias.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a spawn_suspend alias bypassed the named task closure guard (#3194)" >&2
  cat "$ssldir/alias.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawn_suspend_ascribed_plain.vibe "$ssldir/ascribed.wasm" main >/dev/null 2>&1 || true
if [ -s "$ssldir/ascribed.wasm" ] || ! grep -qF 'pass the task closure inline at `TaskGroup::spawn_suspend`' "$ssldir/ascribed.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: an ascribed plain task closure bypassed the named task closure guard (#3194)" >&2
  cat "$ssldir/ascribed.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
for rebound_case in rebound_plain wrapper_rebound_plain; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/err_spawn_suspend_${rebound_case}.vibe" "$ssldir/${rebound_case}.wasm" main >/dev/null 2>&1 || true
  if [ -s "$ssldir/${rebound_case}.wasm" ] || ! grep -qF 'no impl `Spawnable` for closure `q`' "$ssldir/${rebound_case}.wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: a rebound plain task closure escaped Spawnable (#3194, $rebound_case)" >&2
    cat "$ssldir/${rebound_case}.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
done
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawn_suspend_wrapper_plain.vibe "$ssldir/wrapper.wasm" main >/dev/null 2>&1 || true
if [ -s "$ssldir/wrapper.wasm" ] || ! grep -qF 'pass the task closure inline at `my_spawn`' "$ssldir/wrapper.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: an Async-taking wrapper accepted a plain local task closure (#3194)" >&2
  cat "$ssldir/wrapper.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/spawn_suspend_wrapper_inline.vibe "$ssldir/wrapper_inline.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$ssldir/wrapper_inline.wasm" ]; then
  echo "[compiler-gate] FAIL: the inline edit for an Async-taking wrapper did not compile (#3194)" >&2
  cat "$ssldir/wrapper_inline.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
wrapper_inline_result="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$ssldir/wrapper_inline.wasm" 2>/dev/null | tail -1)"
if [ "$wrapper_inline_result" != "6" ]; then
  echo "[compiler-gate] FAIL: the inline edit for an Async-taking wrapper returned '$wrapper_inline_result' (want 6, #3194)" >&2
  exit 1
fi
cat > "$ssldir/inline.vibe" <<'VIBE'
import @vibe/concurrent/experimental { TaskGroup, TaskHandle }
fn main() -> Int allows Async + Exception {
  TaskGroup::run((g) -> {
    let h = TaskGroup::spawn_suspend(g, () -> Int with Async + Exception { 5 })
    TaskGroup::pump_all(g)
    TaskHandle::join(h) + 1
  })
}
VIBE
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_UNSTABLE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ssldir/inline.vibe" "$ssldir/inline.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$ssldir/inline.wasm" ]; then
  echo "[compiler-gate] FAIL: the inline task closure did not compile (#3194)" >&2
  cat "$ssldir/inline.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
ssl_result="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$ssldir/inline.wasm" 2>/dev/null | tail -1)"
if [ "$ssl_result" != "6" ]; then
  echo "[compiler-gate] FAIL: the inline task closure returned '$ssl_result' instead of 6 (#3194)" >&2
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/spawn_suspend_user_defined_named.vibe "$ssldir/user_defined.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$ssldir/user_defined.wasm" ]; then
  echo "[compiler-gate] FAIL: user-defined qualified spawn_suspend was mistaken for the builtin (#3194)" >&2
  cat "$ssldir/user_defined.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
ssl_user_result="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$ssldir/user_defined.wasm" 2>/dev/null | tail -1)"
if [ "$ssl_user_result" != "5" ]; then
  echo "[compiler-gate] FAIL: user-defined spawn_suspend returned '$ssl_user_result' instead of 5 (#3194)" >&2
  exit 1
fi
rm -rf "$ssldir"

echo "[compiler-gate] 77/77 ADR-0089 D1 async sleep boundary (#1218)"
asb89dir="_build/_gate_async_sleep89"
rm -rf "$asb89dir"; mkdir -p "$asb89dir"
cp fixtures/async_sleep_boundary_test.vibe "$asb89dir/pos.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/pos.vibe" "$asb89dir/pos.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: async_sleep_boundary_test.vibe did not compile -- ADR-0089 D1 sleep boundary regressed" >&2
  cat "$asb89dir/pos.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
asb89_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$asb89dir/pos.wasm" 2>/dev/null | tail -1)"
if [ "$asb89_pos_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_sleep_boundary_test.vibe got '$asb89_pos_out' (want 42)" >&2
  exit 1
fi
cp fixtures/async_boundary_spawn_suspend_test.vibe "$asb89dir/spawn.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/spawn.vibe" "$asb89dir/spawn.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/spawn.wasm" ]; then
  echo "[compiler-gate] FAIL: async_boundary_spawn_suspend_test.vibe did not compile -- an Async entry spawning suspend-class tasks is refused again (#2065 wall 2)" >&2
  cat "$asb89dir/spawn.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
asb89_spawn_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$asb89dir/spawn.wasm" 2>/dev/null | tail -1)"
if [ "$asb89_spawn_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_boundary_spawn_suspend_test.vibe got '$asb89_spawn_out' (want 42)" >&2
  exit 1
fi
# #1342: the boundary must key on what is actually injected:
# async_boundary_user_sleep_test.vibe supplies its OWN `sleep`, so no
# boundary is built -- it must COMPILE and return 42.
cp fixtures/async_boundary_user_sleep_test.vibe "$asb89dir/usersleep.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/usersleep.vibe" "$asb89dir/usersleep.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/usersleep.wasm" ]; then
  echo "[compiler-gate] FAIL: async_boundary_user_sleep_test.vibe was rejected -- the guard fired without an injected boundary (#1342)" >&2
  cat "$asb89dir/usersleep.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
asb89_us_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$asb89dir/usersleep.wasm" 2>/dev/null | tail -1)"
if [ "$asb89_us_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_boundary_user_sleep_test.vibe got '$asb89_us_out' (want 42)" >&2
  exit 1
fi
echo "[compiler-gate] async boundary mixing guard: position-independent + injection-keyed ok (#1342)"
# Increment 2 (#1218): a `handle ... with Async` discharges the builtin
# row (the enclosing fn needs no `with Async`) and the handler REALLY
# receives the operations -- sleep(20)+sleep(15) reach the arm as
# Suspend(-20)/Suspend(-15) (debt-payload convention), accumulate to 35,
# and 7 + 35 = 42 (async_sleep_handler_discharge_test.vibe).
cp fixtures/async_sleep_handler_discharge_test.vibe "$asb89dir/dis.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/dis.vibe" "$asb89dir/dis.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/dis.wasm" ]; then
  echo "[compiler-gate] FAIL: async_sleep_handler_discharge_test.vibe did not compile -- handle-with-Async must discharge the builtin row (ADR-0089 D1 increment 2)" >&2
  cat "$asb89dir/dis.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
asb89_dis_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$asb89dir/dis.wasm" 2>/dev/null | tail -1)"
if [ "$asb89_dis_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_sleep_handler_discharge_test.vibe got '$asb89_dis_out' (want 42 -- the user handler must intercept the sleeps)" >&2
  exit 1
fi
# Increment 4 (#1218): `await` of a PENDING future drives through a user
# Async handler -- the poll loop is a synthesized named `__aw_poll` fn, so
# the tail-resumptive evidence migration sees it (an inline while-wrapped
# perform was invisible). Arm resolves the future and counts one poll:
# 40 + 1 + 1 = 42 (async_await_handler_discharge_test.vibe).
cp fixtures/async_await_handler_discharge_test.vibe "$asb89dir/aw.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/aw.vibe" "$asb89dir/aw.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/aw.wasm" ]; then
  echo "[compiler-gate] FAIL: async_await_handler_discharge_test.vibe did not compile -- a pending-future await under a user Async handler must be evidence-eligible (ADR-0089 D1 increment 4)" >&2
  cat "$asb89dir/aw.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
asb89_aw_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$asb89dir/aw.wasm" 2>/dev/null | tail -1)"
if [ "$asb89_aw_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_await_handler_discharge_test.vibe got '$asb89_aw_out' (want 42 -- the handler must receive the poll and its resolution must unblock the await)" >&2
  exit 1
fi
# Codex P1 on #1312: scoped retargeting. A handler receives its own
# lexical sleeps while an Async-row top-level fn called from row-free code
# keeps the blocking builtin (no stranded perform). 40 + 1 + 1 = 42.
cp fixtures/async_sleep_mixed_scope_test.vibe "$asb89dir/mx.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/mx.vibe" "$asb89dir/mx.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/mx.wasm" ]; then
  echo "[compiler-gate] FAIL: async_sleep_mixed_scope_test.vibe did not compile -- scoped retargeting must not strand performs (Codex P1 on #1312)" >&2
  cat "$asb89dir/mx.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
asb89_mx_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$asb89dir/mx.wasm" 2>/dev/null | tail -1)"
if [ "$asb89_mx_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_sleep_mixed_scope_test.vibe got '$asb89_mx_out' (want 42)" >&2
  exit 1
fi
# ADR-0089 Decision 2 (#1218): the Future cell primitives
# (Future::pending/ready/resolve) are inert callees for the evidence
# migration -- a pending future created, resolved, and awaited under an
# Async-row entry (boundary installed by the sleep) must compile and run
# (async_future_boundary_resolved_test.vibe, 1 + 41 = 42). Before the
# allowlist entries the opaque callee names sank the whole boundary-wrapped
# entry body to ineligible.
cp fixtures/async_future_boundary_resolved_test.vibe "$asb89dir/fr.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/fr.vibe" "$asb89dir/fr.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/fr.wasm" ]; then
  echo "[compiler-gate] FAIL: async_future_boundary_resolved_test.vibe did not compile -- Future cell primitives must be evidence-inert (ADR-0089 D2)" >&2
  cat "$asb89dir/fr.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
asb89_fr_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$asb89dir/fr.wasm" 2>/dev/null | tail -1)"
if [ "$asb89_fr_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_future_boundary_resolved_test.vibe got '$asb89_fr_out' (want 42)" >&2
  exit 1
fi
# ...and awaiting a pending future NOTHING can resolve under the
# tail-resumptive boundary is a deadlock that must trap deterministically
# (the boundary arm asserts req < 1 -> `unreachable`), not livelock:
# compilation succeeds, execution fails fast with the unreachable trap
# (async_future_boundary_deadlock_test.vibe).
cp fixtures/async_future_boundary_deadlock_test.vibe "$asb89dir/fd.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/fd.vibe" "$asb89dir/fd.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/fd.wasm" ]; then
  echo "[compiler-gate] FAIL: async_future_boundary_deadlock_test.vibe did not compile (ADR-0089 D2 -- the deadlock case must compile and trap at runtime)" >&2
  cat "$asb89dir/fd.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
asb89_fd_out="$(run_bounded 30 bash -c "VIBE_PREOPEN_DIR='$ROOT_DIR' bash scripts/run_wasm_vibe_host_runner.sh --invoke main '$asb89dir/fd.wasm' 2>&1" || true)"
if [ "$(printf '%s\n' "$asb89_fd_out" | tail -1)" = "42" ]; then
  echo "[compiler-gate] FAIL: async_future_boundary_deadlock_test.vibe returned 42 -- an unresolvable await under the boundary must trap, not complete" >&2
  exit 1
fi
if ! printf '%s\n' "$asb89_fd_out" | grep -q "unreachable"; then
  echo "[compiler-gate] FAIL: async_future_boundary_deadlock_test.vibe did not trap with 'unreachable' (livelock or wrong failure mode?)" >&2
  printf '%s\n' "$asb89_fd_out" | tail -5 >&2
  exit 1
fi
rm -rf "$asb89dir"
echo "[compiler-gate] ADR-0089 D1 async sleep boundary ok"

# 78/78. ADR-0089 (c) (#1218/#1337): the named-host-future NAME COLLECTOR must
# be total over expression containers and shadow-aware.
#
# compile_call lowers `host_future_named("price")` to `vibe_hf_get_raw$price`
# wherever it appears, so a container linked_compile's collector fails to walk
# reserves no import and no func-table entry -- the program then fails to
# compile with `undefined variable (local): vibe_hf_get_raw$price` (measured on
# the record-literal form before the fix). The mirror hazard is the same walk
# being shadow-BLIND: a local named `host_future_named` is an ordinary closure
# call compile_call leaves alone, so collecting its argument would demand a
# component import the program never uses.
#
# These are compile-level properties, so they belong here rather than only in
# the viberun-driven test_named_hostfutures_component_gate.sh (which also
# covers them, at runtime).
echo "[compiler-gate] 128/128 evidence pass admits a first-order row-variable callee under an Async boundary (#2065)"
# #2065 wall 1. The ADR-0076 追記34 V1 guard refuses a program that holds
# row-E closure VALUES when the migration cannot plan, and a row-VARIABLE
# callee used to make it fail to plan unconditionally
# (edp_append_effect_irrelevant_row_fns). edp_callee_first_order ports the
# suspend pass's rule: a callee whose every parameter is annotated and
# mentions no function type -- and whose return type does not either -- has
# a row variable that can only be instantiated to the empty row.
#
# The pair is what makes this checkable. The positive alone would also pass
# if the port admitted EVERYTHING; the negative alone would also pass if the
# port admitted nothing.
fo65dir="_build/_gate_first_order_rowvar"
rm -rf "$fo65dir"; mkdir -p "$fo65dir"
cp fixtures/async_first_order_rowvar_boundary_test.vibe "$fo65dir/pos.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fo65dir/pos.vibe" "$fo65dir/pos.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$fo65dir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: async_first_order_rowvar_boundary_test.vibe did not compile -- the #2065 first-order row-variable admission regressed" >&2
  cat "$fo65dir/pos.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
fo65_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$fo65dir/pos.wasm" 2>/dev/null | tail -1)"
if [ "$fo65_pos_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_first_order_rowvar_boundary_test.vibe got '$fo65_pos_out' (want 42)" >&2
  exit 1
fi
# The HIGHER-ORDER twin, called with a closure LITERAL that cannot perform
# Async, is admitted by the call-site argument-inertness rule
# (edp_argcond_admits) and must answer 42 too.
cp fixtures/async_higher_order_rowvar_literal_boundary_test.vibe "$fo65dir/lit.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fo65dir/lit.vibe" "$fo65dir/lit.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$fo65dir/lit.wasm" ]; then
  echo "[compiler-gate] FAIL: async_higher_order_rowvar_literal_boundary_test.vibe did not compile -- the #2065 call-site argument-inertness admission regressed" >&2
  cat "$fo65dir/lit.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
fo65_lit_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$fo65dir/lit.wasm" 2>/dev/null | tail -1)"
if [ "$fo65_lit_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_higher_order_rowvar_literal_boundary_test.vibe got '$fo65_lit_out' (want 42)" >&2
  exit 1
fi
# The shape that motivates it: a spawn-free `TaskGroup::run` under the same
# injected Async boundary, whose body parameter sits under a row variable.
cp fixtures/async_taskgroup_run_boundary_test.vibe "$fo65dir/tg.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fo65dir/tg.vibe" "$fo65dir/tg.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$fo65dir/tg.wasm" ]; then
  echo "[compiler-gate] FAIL: async_taskgroup_run_boundary_test.vibe did not compile -- TaskGroup::run under an Async entry is refused again (#2065)" >&2
  cat "$fo65dir/tg.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
fo65_tg_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$fo65dir/tg.wasm" 2>/dev/null | tail -1)"
if [ "$fo65_tg_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_taskgroup_run_boundary_test.vibe got '$fo65_tg_out' (want 42)" >&2
  exit 1
fi
# #1962 (Codex on #3059): an entry granted through its binding annotation
# (`let main: () -> Int with Fs = () -> { .. }`) gets the host provider too.
cp fixtures/host_provider_annotated_entry.vibe "$fo65dir/annot.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fo65dir/annot.vibe" "$fo65dir/annot.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$fo65dir/annot.wasm" ]; then
  echo "[compiler-gate] FAIL: host_provider_annotated_entry.vibe did not compile" >&2
  cat "$fo65dir/annot.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
fo65_annot_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$fo65dir/annot.wasm" 2>/dev/null | tail -1)"
if [ "$fo65_annot_out" != "1" ]; then
  echo "[compiler-gate] FAIL: host_provider_annotated_entry.vibe got '$fo65_annot_out' (want 1) -- an annotation-granted entry lost the host provider" >&2
  exit 1
fi
# ... and with a NAMED function in that position it must stay refused: the
# argument's row is not readable at the call site, so it could instantiate the
# row variable to Async and the perform would happen where the injected
# boundary cannot see it.
cp fixtures/err_async_rowvar_higher_order_refused.vibe "$fo65dir/neg.vibe"
rm -f "$fo65dir/neg.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fo65dir/neg.vibe" "$fo65dir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$fo65dir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_async_rowvar_higher_order_refused.vibe compiled -- a higher-order row-variable callee must keep the ADR-0076 追記34 V1 rejection" >&2
  exit 1
fi
if ! grep -qF "type-directed evidence" "$fo65dir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_async_rowvar_higher_order_refused.vibe did not produce the V1 guard diagnostic" >&2
  cat "$fo65dir/neg.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi

echo "[compiler-gate] 78/78 named host future collector: total + shadow-aware (#1337)"
nhf37dir="_build/_gate_1337"
rm -rf "$nhf37dir"; mkdir -p "$nhf37dir"
# The record literal lives in a row-free NAMED fn, not in the handled body:
# ADR-0076's evidence-migration eligibility independently rejects a container
# literal on the handled spine, and that rejection (a clear diagnostic) is not
# what this section is about. What it IS about is that the collector must walk
# INTO the record at all -- pre-fix this exact file failed with
# `undefined variable (local): vibe_hf_get_raw$price`.
cat > "$nhf37dir/nested.vibe" <<'EOF'
fn make_cell() -> Future[Int] {
  let r = record {
    p: host_future_named("price")
  }
  r.p
}

let run: () -> Int with Async = () -> {
  await(make_cell())
}
EOF
rm -f "$nhf37dir/nested.wasm" "$nhf37dir/nested.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw   bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"   "$nhf37dir/nested.vibe" "$nhf37dir/nested.wasm" run >/dev/null 2>&1 || true
if [ ! -s "$nhf37dir/nested.wasm" ]; then
  echo "[compiler-gate] FAIL: host_future_named nested in a record literal did not compile (#1337)" >&2
  cat "$nhf37dir/nested.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! grep -q "price" "$nhf37dir/nested.wasm"; then
  echo "[compiler-gate] FAIL: record-nested host_future_named compiled without a 'price' import (#1337)" >&2
  exit 1
fi
# A SHADOWED builtin must reserve nothing.
cat > "$nhf37dir/shadowed.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let host_future_named = (s: String) -> Int {
    41
  }
  host_future_named("price") + 1
}
EOF
rm -f "$nhf37dir/shadowed.wasm" "$nhf37dir/shadowed.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw   bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"   "$nhf37dir/shadowed.vibe" "$nhf37dir/shadowed.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$nhf37dir/shadowed.wasm" ]; then
  echo "[compiler-gate] FAIL: a shadowed host_future_named did not compile (#1337)" >&2
  cat "$nhf37dir/shadowed.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if grep -q 'host_future_get\$price' "$nhf37dir/shadowed.wasm"; then
  echo "[compiler-gate] FAIL: a SHADOWED host_future_named still reserved the 'price' host import (#1337)" >&2
  exit 1
fi
nhf37_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$nhf37dir/shadowed.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$nhf37_out" != "42" ]; then
  echo "[compiler-gate] FAIL: shadowed host_future_named output '$nhf37_out' (want 42, #1337)" >&2
  exit 1
fi
rm -rf "$nhf37dir"
echo "[compiler-gate] named host future collector ok"

# 79/79. ADR-0071 generic-effect instantiation (#1340): generic effect
# declarations now REGISTER their operation signatures (checker_stmt.vibe's
# SEffectDef arm keeps the type params; perform/handle sites instantiate
# them with fresh inference vars — one shared instantiation per handle),
# and `with State[Int]` row items parse (collect_row_item_targs,
# parser_base.vibe) with base-name-aware containment. Positive: the
# instantiated-row fixture compiles and runs to 42. Negatives: the #1218
# hole (a 3-argument perform against a 0-arity generic op used to pass
# silently) is rejected with an arity diagnostic, and a bracketed row item
# naming a NON-generic effect is rejected by geff_validate_row_targs.
echo "[compiler-gate] 79/79 generic effect instantiation registration + rows (ADR-0071/#1340)"
g1340dir="_build/_gate_1340"
rm -rf "$g1340dir"; mkdir -p "$g1340dir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_generic_row_instantiation.vibe "$g1340dir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$g1340dir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_generic_row_instantiation.vibe did not compile (with State[Int] row grammar or generic registration regressed)" >&2
  cat "$g1340dir/pos.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! g1340_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$g1340dir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_generic_row_instantiation got '$g1340_out' (want 42)" >&2
  echo "$g1340_out" >&2
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_generic_effect_perform_arity.vibe "$g1340dir/arity.wasm" main >/dev/null 2>&1 || true
if [ -s "$g1340dir/arity.wasm" ]; then
  echo "[compiler-gate] FAIL: err_generic_effect_perform_arity.vibe compiled -- the #1218 generic-effect arity hole is back" >&2
  exit 1
fi
if ! grep -q "perform State::Get expects 0 argument(s), got 3" "$g1340dir/arity.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_generic_effect_perform_arity.vibe did not produce the arity diagnostic" >&2
  cat "$g1340dir/arity.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_generic_effect_row_targ.vibe "$g1340dir/rowtarg.wasm" main >/dev/null 2>&1 || true
if [ -s "$g1340dir/rowtarg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_generic_effect_row_targ.vibe compiled -- a bracketed row item on a non-generic effect must be rejected" >&2
  exit 1
fi
if ! grep -q "effect Log declares no type parameters" "$g1340dir/rowtarg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_generic_effect_row_targ.vibe did not produce the row-instantiation diagnostic" >&2
  cat "$g1340dir/rowtarg.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$g1340dir"
echo "[compiler-gate] generic effect instantiation ok"

# 80/80. ADR-0071 operation-level rows, BUILTIN slice (#1343): host capabilities
# can be granted one operation at a time. Before this the builtin call path
# compared only the bare effect label (builtin_call_effect -> decl_authorizes_
# effect), so `with Fs::read_file` was rejected with `missing { Fs }` and the
# only expressible grant for a host capability was the whole effect -- which is
# what forced coarse rows like `with Http` (serve + outbound request in one
# grant). The row is the CONSUMER axis (minimal permission); the effect name
# stays the PROVIDER axis (which host provider implements it), so this needs no
# splitting of provider labels.
#
# Three directions, all required: the operation grant ADMITS its own operation,
# RESTRICTS a sibling operation (naming the missing OPERATION, not the effect),
# and the bare effect keeps granting everything (every existing row).
echo "[compiler-gate] 80/80 operation-level rows authorize builtin calls (ADR-0071/#1343)"
opb="_build/_gate_1343_op_rows"
rm -rf "$opb"; mkdir -p "$opb"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_builtin_operation_row.vibe "$opb/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$opb/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: with Fs::read_file no longer authorizes the Fs::read_file builtin (#1343)" >&2
  cat "$opb/pos.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! op_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$opb/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_builtin_operation_row got '$op_out' (want 42)" >&2
  echo "$op_out" >&2
  exit 1
fi
cat > "$opb/neg.vibe" <<'EOF'
fn only_read(p: String) -> Unit with Fs::read_file {
  Fs::write_file(p, "x")
}

let main = () -> Int {
  0
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$opb/neg.vibe" "$opb/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$opb/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: with Fs::read_file authorized Fs::write_file -- operation grants are not minimal (#1343)" >&2
  exit 1
fi
if ! grep -q "missing { Fs::write_file }" "$opb/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the diagnostic must name the missing OPERATION, not the whole effect (ADR-0071/#1343)" >&2
  cat "$opb/neg.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
cat > "$opb/bare.vibe" <<'EOF'
fn both(p: String) -> Unit with Fs {
  Fs::write_file(p, Fs::read_file(p))
}

let main = () -> Int {
  0
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$opb/bare.vibe" "$opb/bare.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$opb/bare.wasm" ]; then
  echo "[compiler-gate] FAIL: the bare effect row stopped granting all of its operations (#1343 must be a pure widening)" >&2
  cat "$opb/bare.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$opb"
echo "[compiler-gate] operation-level builtin rows ok"

# 81/81. #1358: a `for` over an ASYNC iterator requires `Async`. The loop's
# `await(..)` is injected AFTER the checker (desugar_trait_dict's
# build_await_iter_for), so nothing in the program text is an async primitive
# and the Async pass used to find nothing to require -- the loop could suspend
# from a context that neither declares nor handles Async. The requirement is now
# read from the ITERAND's type (type_name_has_async_iterator_impl), which is the
# same bit the desugar switches on. Both directions are required: the declared
# row still compiles AND runs (the await lowering is unchanged), and the
# undeclared one is rejected naming `<T>::next`.
echo "[compiler-gate] 81/81 async for-loop requires the Async row (#1358)"
afdir="_build/_gate_1358"
rm -rf "$afdir"; mkdir -p "$afdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_async_for_row.vibe "$afdir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$afdir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_async_for_row.vibe did not compile -- a declared `with Async` row must still accept the async for loop (#1358)" >&2
  cat "$afdir/pos.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! af_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$afdir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_async_for_row got '$af_out' (want 42) -- the await lowering of the async for loop regressed" >&2
  echo "$af_out" >&2
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_async_for_undeclared.vibe "$afdir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$afdir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_async_for_undeclared.vibe compiled -- a for loop over a Future-returning iterator must require { Async } (#1358)" >&2
  exit 1
fi
if ! grep -q "Countdown::next" "$afdir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the async-for diagnostic must name the iterator's next method (#1358)" >&2
  cat "$afdir/neg.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# Codex review on PR #1364 (P1 x2): two iterand shapes reached the await
# lowering but slipped past the row requirement -- a GENERIC impl (recorded as
# EnvTraitImplGen, skipped by the scan) and an ENUM iterand (CtEnum, dropped by
# the head-name helper). Both were verified against repros that actually RAN
# the await loop (a sync EForIn over the value would have trapped), so each was
# a real hole. Locked here because neither is reachable through the struct-
# literal fixture above.
cat > "$afdir/generic.vibe" <<'EOF'
trait AIter[T] {
  next(Self) -> Future[Option[(T, Self)]]
}

struct Iter[T] {
  n: Int
}

impl [T] AIter for Iter[T] {
  next(self) -> Future[Option[(Int, Iter[T])]] {
    Future::ready(if self.n > 0 {
      Some((self.n, Iter::{
        n: self.n - 1
      }))
    } else {
      None
    })
  }
}

let main = () -> Int {
  let mut acc = 0
  for x in Iter::{
    n: 3
  } {
    acc = acc + x
  }
  acc
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$afdir/generic.vibe" "$afdir/generic.wasm" main >/dev/null 2>&1 || true
if [ -s "$afdir/generic.wasm" ]; then
  echo "[compiler-gate] FAIL: a GENERICALLY implemented async iterator escaped the Async requirement -- EnvTraitImplGen must be matched like EnvTraitImpl (#1358, Codex P1 on #1364)" >&2
  exit 1
fi
cat > "$afdir/enum.vibe" <<'EOF'
trait AIter[T] {
  next(Self) -> Future[Option[(T, Self)]]
}

enum Chan {
  Chan(Int)
}

impl AIter for Chan {
  next(self) -> Future[Option[(Int, Chan)]] {
    Future::ready(match self {
      Chan(n) => if n > 0 {
        Some((n, Chan(n - 1)))
      } else {
        None
      }
    })
  }
}

let main = () -> Int {
  let mut acc = 0
  for x in Chan(3) {
    acc = acc + x
  }
  acc
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$afdir/enum.vibe" "$afdir/enum.wasm" main >/dev/null 2>&1 || true
if [ -s "$afdir/enum.wasm" ]; then
  echo "[compiler-gate] FAIL: an ENUM async iterand escaped the Async requirement -- CtEnum must keep its head name (#1358, Codex P1 on #1364)" >&2
  exit 1
fi
rm -rf "$afdir"
echo "[compiler-gate] async for-loop Async requirement ok"

# 82/82. #1361: a LOCAL closure's declared row leaks at its CALL site. Before
# this the closure was checked against its OWN row (so it always satisfied
# itself) and the call site consulted only the top-level call-graph map, in
# which a local name never appears -- so the row escaped the enclosing
# declaration silently, and file_entry_cacheable / file_tests_cacheable (which
# reuse this walk) judged such an entry deterministic. Registering the binding
# in the #885 callback overlay closes both. Measured on the corpus at the time
# of the fix: 499/499 test files and 27/27 doctest ```vibe run blocks keep their
# cache judgment, so nothing was de-cached to buy this.
echo "[compiler-gate] 82/82 local closure rows leak at the call site (#1361)"
lcdir="_build/_gate_1361"
rm -rf "$lcdir"; mkdir -p "$lcdir"
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_local_closure_effect_leak.vibe "$lcdir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$lcdir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_local_closure_effect_leak.vibe compiled -- a local closure's declared row must leak into its caller (#1361)" >&2
  exit 1
fi
if ! grep -q "missing { Env }" "$lcdir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the local-closure leak must be reported as the caller's missing row label (#1361)" >&2
  cat "$lcdir/neg.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
cat > "$lcdir/pos.vibe" <<'EOF'
let main = () -> Unit with Console + Env {
  let read_home = () -> String with Env {
    Env::get("HOME")
  }
  println(read_home())
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$lcdir/pos.vibe" "$lcdir/pos.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$lcdir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: declaring the local closure's row must satisfy the leak check (#1361)" >&2
  cat "$lcdir/pos.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
cat > "$lcdir/pure.vibe" <<'EOF'
let main = () -> Unit with Console {
  let twice = (n: Int) -> Int {
    n * 2
  }
  println(__to_string(twice(21)))
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$lcdir/pure.vibe" "$lcdir/pure.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$lcdir/pure.wasm" ]; then
  echo "[compiler-gate] FAIL: a PURE local closure must stay free of any row requirement (#1361 must not over-require)" >&2
  cat "$lcdir/pure.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$lcdir"
echo "[compiler-gate] local closure row leak ok"

# 83/83. #1347 (ADR-0089 Part A): a `handle ... with E` that can never fire. A
# continuation captured by handler H carries H with it (the suspend lowering
# bakes H's driver into the closure handed to the arm), so re-driving a stored
# continuation under a NEW handle switches nothing -- the new arms are dead.
# Measured before the fix on this exact program: the wrapping handler's arm
# never ran and the second yield still went to the ORIGINAL arm, silently. The
# suspend lowering already rejected the same shape when the WRAPPING arm was
# itself suspend-class; this restores the symmetry for the tail-resumptive one.
#
# Three shapes are locked: the dead handle is REJECTED, a handle whose body
# performs the effect directly still compiles, and -- the false-positive
# direction that actually bit during implementation -- a body whose only callee
# is a row-carrying PARAMETER or annotated local still compiles.
echo "[compiler-gate] 83/83 a handle that can never fire is rejected (#1347)"
hsdir="_build/_gate_1347_switch"
rm -rf "$hsdir"; mkdir -p "$hsdir"
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_handler_switch_dead_handle.vibe "$hsdir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$hsdir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_handler_switch_dead_handle.vibe compiled -- the handler-switch no-op is silent again (#1347)" >&2
  exit 1
fi
if ! grep -q "can never fire" "$hsdir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the dead-handle diagnostic is missing (#1347)" >&2
  cat "$hsdir/neg.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
cat > "$hsdir/live.vibe" <<'EOF'
effect Yield {
  Yield(Int) -> Unit
}

fn gen() -> Unit with Yield {
  perform Yield::Yield(1)
}

let main = () -> Int {
  handle {
    gen()
    41
  } with Yield {
    Yield(x) => resume(())
  } + 1
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hsdir/live.vibe" "$hsdir/live.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$hsdir/live.wasm" ]; then
  echo "[compiler-gate] FAIL: a handle whose body DOES reach the effect must still compile (#1347 must not over-reject)" >&2
  cat "$hsdir/live.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
cat > "$hsdir/param.vibe" <<'EOF'
effect Yield {
  Yield(Int) -> Unit
}

fn gen() -> Unit with Yield {
  perform Yield::Yield(1)
}

fn run(f: () -> Int with Yield) -> Int {
  handle {
    f()
  } with Yield {
    Yield(x) => resume(())
  }
}

let main = () -> Int {
  let body: () -> Int with Yield = () -> {
    gen()
    42
  }
  run(body)
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hsdir/param.vibe" "$hsdir/param.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$hsdir/param.wasm" ]; then
  echo "[compiler-gate] FAIL: a handled body whose only callee is a row-carrying PARAMETER (or annotated local) must compile -- #1347 must consult the #885/#1361 overlay, not just top-level bindings" >&2
  cat "$hsdir/param.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$hsdir"
echo "[compiler-gate] dead-handle rejection ok"

# 84/84. #1347: the higher-order-effect message. An operation parameterised by
# an EFFECTFUL block was already rejected, but the generic migration error
# blamed the handle and told the reader to restructure ITS body -- unactionable,
# since the gap is in the operation's signature one level away. The diagnostic
# now names the operation. The PURE-block form must keep working (that is the
# supported half, pinned by fixtures/effect_talk_tracing_span_test.vibe).
echo "[compiler-gate] 84/84 higher-order effectful block names the operation (#1347)"
hodir="_build/_gate_1347_ho"
rm -rf "$hodir"; mkdir -p "$hodir"
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_higher_order_effectful_block.vibe "$hodir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$hodir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: an operation taking an EFFECTFUL block must still be rejected (#1347)" >&2
  exit 1
fi
if ! grep -q "Higher-order effects" "$hodir/neg.wasm.diag" 2>/dev/null || ! grep -q "Tracing::Span" "$hodir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the diagnostic must name the higher-order OPERATION and the limitation (#1347)" >&2
  cat "$hodir/neg.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$hodir"
echo "[compiler-gate] higher-order effect diagnostic ok"
