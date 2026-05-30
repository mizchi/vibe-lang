# wasm-gc coverage `--coverage-run-tests` trap — root cause (#417)

Status: **root-caused, fix designed, not yet implemented**. Captured here
because the interactive session hit harness instability mid-diagnosis; this
note lets the work be picked up cleanly.

## Symptom

`vibe compile --wasm-gc --coverage --coverage-run-tests <file>` produces a
`.wasm` that **traps (`unreachable`) when its `_start` runs the generated
tests**, so `scripts/coverage_wasm_source.sh` with
`VIBE_WASM_SOURCE_COVERAGE_MODE=wasm-gc` reports `execution: trap (unreachable)`
and never reaches full coverage. The linear backend (`--wasm`) works (e.g.
`if x>0 {1} else {0}` + 2 tests → points 11/11, exec ok).

The wasm-gc backtrace (run under `wasmtime -W gc=y -W function-references=y
-W exceptions=y --invoke _start`):

```
wasm backtrace:
  0: __vibe_cov_test_0
  1: _start
wasm trap: unreachable instruction executed
```

It reproduces with an **always-true assert**: `test "t" { assert(1 == 1) }`
→ trap. So it is NOT an assertion logic failure.

## Root cause

`assert` is desugared in the prelude (`src/checker/prelude.mbt:14-16`) to the
builtin `__assert(cond)` / `__assert_eq(a, b)`:

```
let assert = (cond: Bool) -> Unit { __assert(cond) }
let assert_eq = [T](a: T, b: T) -> Unit { __assert_eq(a, b) }
```

- The **linear** backend has a real codegen arm for these
  (`src/codegen/wasm_codegen_builtin_numeric.mbt:86-113`): evaluate the
  condition, compare against tagged-bool `true`, `i32.eqz`, `if (trap via
  unreachable) end`, then push Unit.
- The **wasm-gc** backend has **NO dispatch arm** for `__assert` /
  `__assert_eq`. (`__assert` only appears in gc as a *builtin-name predicate*
  at `wasm_gc_codegen.mbt:1832-1833`, not as a compiled Call arm.) So a
  `__assert` Call falls through to the default path and emits `unreachable`.

Why it was hidden until now: the non-coverage gc emit prologue runs
`static_fold_module(...)` (`wasm_gc_codegen.mbt:13152`), which constant-folds
away `assert(<constant>)` before codegen, so trivially-true asserts vanished.
**Coverage mode deliberately skips static folding** to preserve every
instrumentation point (`wasm_gc_codegen.mbt:13150-13152`):

```moonbit
if coverage_enabled {
  strip_type_assert_module(ast)              // no static_fold
} else {
  static_fold_module(strip_type_assert_module(ast))
}
```

With folding skipped, the unhandled `__assert` survives to codegen and the
missing arm surfaces as the trap.

Note `vibe test --backend gc` (the non-coverage test harness in
`cli_test_cmd.mbt`) works on the same asserts because it uses a *different*
test-running path, not `lower_top_level_tests_to_exprs` +
`emit_module_wasm_gc`. The coverage path
(`runtime_compile/compile.mbt:2243` `lower_top_level_tests_to_exprs` →
`emit_module_wasm_gc_with_coverage`) is the one that exercises the missing arm.

## Fix (designed, not implemented)

Add `__assert` / `__assert_eq` (and the `assert` / `assert_true` / `assert_eq`
aliases, for safety) dispatch arms to the wasm-gc Call match in
`src/codegen/wasm_gc_codegen.mbt`, mirroring the linear logic but using the
**gc Bool representation, which is `i32` (`1`=true / `0`=false)**, not the
linear tagged-i64 bool. Sketch:

```
// __assert(cond): cond is i32 (gc Bool). Trap if false.
"__assert" | "assert" | "assert_true" => {
  compile_expr_gc(ctx, fctx, buf, pos_args[0])   // -> i32 (0/1)
  emit_i32_eqz_gc(buf)                            // 1 if cond==false
  emit_if_gc(buf, None)                           // if (cond was false)
  emit_unreachable_gc(buf)
  emit_end_gc(buf)
  emit_i32_const_gc(buf, 0)                       // Unit
}
// __assert_eq(a, b): compile __eq(a,b) -> i32, then same trap-if-false.
```

Relevant gc helpers already exist: `emit_i32_eqz_gc` (786), `emit_if_gc`
(1101), `emit_unreachable_gc` (677), `emit_end_gc` (1112), `emit_i32_const_gc`,
and the `__eq` arm is at `wasm_gc_codegen.mbt:9250` (reuse for `__assert_eq`).
Bool literal lowering for reference: `wasm_gc_codegen.mbt:8832` (`i32.const
1/0`). Also register the return kind for `__assert`/`__assert_eq` as Unit-ish
(`I32`) in `infer_expr_kind_gc` if needed.

## Verification plan

```
# repro (should stop trapping, reach high coverage):
cat > /tmp/m.vibe <<'EOF'
let classify: (Int) -> Int = (x) -> { if x > 0 { 1 } else { 0 } }
test "pos" { assert(classify(5) == 1) }
test "neg" { assert(classify(-3) == 0) }
EOF
VIBE_BIN=_build/native/debug/build/cmd/vibe/vibe.exe \
VIBE_WASM_SOURCE_COVERAGE_MODE=wasm-gc VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS=1 \
VIBE_WASM_SOURCE_COVERAGE_REUSE_CACHE=0 \
  bash scripts/coverage_wasm_source.sh /tmp/m.vibe
# expect: execution ok, and line/point/branch ≈ the linear numbers (#417 ±5%)

# parity check vs linear on the same file (MODE=wasm) — should match.
# regression: full wasm-gc e2e suite + linear coverage tests unchanged.
```

Acceptance criterion from #417: linear and wasm-gc coverage within ±5% on the
same source. On the demo above, linear reports point 100% (11/11), line 100%
(3/3), branch 100% (2/2); gc must reach the same once the assert arm lands.

## Already landed (this branch)

- `3c46086f` / `872c3b48`: `coverage_wasm_source.sh` accepts
  `VIBE_WASM_SOURCE_COVERAGE_MODE=wasm-gc` (the opt-in switch from #417 item 5).
  This is correct and independent of the trap; it just lets the gc path be
  exercised end-to-end (which is how the trap was found).

The wasm-gc coverage **codegen** (counter memory, `__vibe_cov_base` /
`__vibe_cov_count` globals + `memory` export, `emit_coverage_gc`,
`emit_module_wasm_gc_with_coverage`, CLI dispatch, `wasm_gc_coverage_wbtest.mbt`)
was already implemented prior to this session and works for the non-test
(`_start`-invoke) path; the only functional gap is the missing `__assert` arm
that the run-tests path needs.
