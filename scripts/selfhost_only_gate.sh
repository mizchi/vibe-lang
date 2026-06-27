#!/usr/bin/env bash
# Moon-free selfhost-only gate (#594 Stage 5): the post-`src/`-removal sign-off.
# Needs no MoonBit host — only the committed seed, the Rust runner, and the
# committed selfhost compiler source/bundles. Verifies:
#   1. committed bundles are in sync with the compiler source,
#   2. the committed flat module source is in sync (regenerated via the seed),
#   3. the selfhost compiler self-reproduces moon-free (seed -> stage1 -> stage2
#      -> stage3) with stage2 == stage3 (fixpoint) and each stage validates a
#      compiled sample (compile -> run smoke).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

echo "[selfhost-only-gate] 1/3 bundle sync"
bash scripts/check_selfhost_bundle_sync.sh

echo "[selfhost-only-gate] 2/3 module-source sync (via seed)"
bash scripts/check_selfhost_module_source_sync.sh

echo "[selfhost-only-gate] 3/3 moon-free selfbuild seed->stage1->stage2->stage3"
bash scripts/selfhost_generations.sh build --stage3

# Assert the stage2==stage3 fixpoint from the freshest generation manifest.
latest_gen="$(ls -dt _build/selfhost/generations/*/ 2>/dev/null | head -1 || true)"
if [ -z "$latest_gen" ] || [ ! -f "${latest_gen}generation.json" ]; then
  echo "[selfhost-only-gate] FAIL: no generation manifest produced" >&2
  exit 1
fi
python3 - "${latest_gen}generation.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d.get("stages", {})
s2 = s.get("stage2", {}).get("sha256")
s3 = s.get("stage3", {}).get("sha256")
if not s2 or not s3:
    print("[selfhost-only-gate] FAIL: missing stage2/stage3 sha", file=sys.stderr); sys.exit(1)
if s2 != s3:
    print(f"[selfhost-only-gate] FAIL: stage2 != stage3 ({s2[:12]} != {s3[:12]})", file=sys.stderr); sys.exit(1)
print(f"[selfhost-only-gate] fixpoint ok: stage2==stage3 ({s2[:12]})")
PY

# 4. multi-file compile regression (#594): the selfhost compiler must resolve
#    imports from the filesystem. collect_import_path once built import paths via
#    string interpolation, which a selfhost codegen bug rendered as garbage (only
#    hit by real `import` statements, which the merged/bundle selfbuild source
#    strips — so the fixpoint above does not exercise it). Compile a 2-file
#    program via the fresh stage2 (VIBE_FS_COMPILE) and assert it runs to 42.
echo "[selfhost-only-gate] 4/4 multi-file FS-compile regression"
fsdir="_build/_gate_fscompile"
rm -rf "$fsdir"; mkdir -p "$fsdir"
printf 'export let add = (a: Int, b: Int) -> Int { a + b }\n' > "$fsdir/helper.vibe"
printf 'import ./helper.vibe { add }\nexport let _start = () -> Int { add(40, 2) }\n' > "$fsdir/main.vibe"
stage2_wasm="${latest_gen}stage2.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fsdir/main.vibe" "$fsdir/main.wasm" _start
if [ ! -s "$fsdir/main.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: multi-file FS-compile produced no wasm" >&2
  exit 1
fi
fsres="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$fsdir/main.wasm" 2>/dev/null | tr -dc '0-9')"
rm -rf "$fsdir"
if [ "$fsres" != "42" ]; then
  echo "[selfhost-only-gate] FAIL: multi-file FS-compile sample returned '$fsres' (expected 42)" >&2
  exit 1
fi
echo "[selfhost-only-gate] multi-file FS-compile ok (42)"

# 5. test-block regression (#594): a file with only `test {}` blocks (no entry)
#    must compile to a valid module whose `_start` runs every test; a passing
#    file exits clean and a failing assert traps. Guards the codegen fix that
#    stopped exporting a nonexistent entry function (call/export index -1).
echo "[selfhost-only-gate] 5/5 test-block compile+run regression"
tdir="_build/_gate_testblock"
rm -rf "$tdir"; mkdir -p "$tdir"
printf 'test "ok" {\n  assert_eq(2 + 2, 4)\n}\n' > "$tdir/pass_test.vibe"
printf 'test "bad" {\n  assert_eq(2 + 2, 5)\n}\n' > "$tdir/fail_test.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/pass_test.vibe" "$tdir/pass_test.wasm" __no_entry__ >/dev/null 2>&1
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/fail_test.vibe" "$tdir/fail_test.wasm" __no_entry__ >/dev/null 2>&1
if [ ! -s "$tdir/pass_test.wasm" ] || [ ! -s "$tdir/fail_test.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: test-block compile produced no wasm" >&2; exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$tdir/pass_test.wasm" >/dev/null 2>&1; then
  echo "[selfhost-only-gate] FAIL: passing test file did not run clean" >&2; exit 1
fi
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$tdir/fail_test.wasm" >/dev/null 2>&1; then
  echo "[selfhost-only-gate] FAIL: failing test file did not trap" >&2; exit 1
fi
rm -rf "$tdir"
echo "[selfhost-only-gate] test-block regression ok"

# 6. normalize regression (#594): `vibe normalize` (VIBE_NORMALIZE=1) canonicalizes
#    a source file — module flatten + DCE from exported roots + section layout —
#    via the in-compiler engine. Guards that a future seed keeps it working and
#    idempotent. The flat selfbuild source strips imports/modules, so the
#    fixpoint above does not exercise the normalize entry; assert it directly.
echo "[selfhost-only-gate] 6/6 normalize compile+run regression"
ndir="_build/_gate_normalize"
rm -rf "$ndir"; mkdir -p "$ndir"
printf 'export module m {\n  let dead: () -> Int = () -> { 0 }\n  let helper: () -> Int = () -> { 1 }\n  export let run: () -> Int = () -> { helper() }\n}\n' > "$ndir/in.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/in.vibe" "$ndir/out.vibe" >/dev/null 2>&1
if [ ! -s "$ndir/out.vibe" ]; then
  echo "[selfhost-only-gate] FAIL: normalize produced no output" >&2; exit 1
fi
# `dead` must be eliminated; `m::helper` (reached from the exported `m::run`) kept.
if grep -q "dead" "$ndir/out.vibe" || ! grep -q "m::helper" "$ndir/out.vibe"; then
  echo "[selfhost-only-gate] FAIL: normalize DCE/flatten incorrect" >&2
  cat "$ndir/out.vibe" >&2; exit 1
fi
# Idempotency: normalize(normalize(x)) == normalize(x).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/out.vibe" "$ndir/out2.vibe" >/dev/null 2>&1
if ! cmp -s "$ndir/out.vibe" "$ndir/out2.vibe"; then
  echo "[selfhost-only-gate] FAIL: normalize not idempotent" >&2; exit 1
fi
# Flattened output must still typecheck: intra-module refs are qualified
# (`m::run` calls `m::helper`), so compiling a copy with an entry must succeed.
cp "$ndir/out.vibe" "$ndir/compile.vibe"
printf '\nexport let _start: () -> Int = () -> { m::run() }\n' >> "$ndir/compile.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/compile.vibe" "$ndir/out.wasm" _start >/dev/null 2>&1
if [ ! -s "$ndir/out.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: normalized output does not compile" >&2
  cat "$ndir/compile.vibe" >&2; exit 1
fi
rm -rf "$ndir"
echo "[selfhost-only-gate] normalize regression ok"

# 7. literal sub-pattern regression (#603): a literal (PInt/PString) argument of a
#    constructor pattern must be tested, not just the tag — `I("x")` must not
#    match `I("y")`, `I(1)` must not match `I(2)`. Guards the match-codegen fix.
echo "[selfhost-only-gate] 7/7 literal sub-pattern regression"
pdir="_build/_gate_litpat"
rm -rf "$pdir"; mkdir -p "$pdir"
cat > "$pdir/litpat.vibe" <<'EOF'
enum E { I(Int); S(String); N }
let classify: (E) -> Int = (e) -> {
  match e {
    I(7) => 10,
    I(_) => 11,
    S("perform") => 20,
    S(_) => 21,
    N => 30
  }
}
export let _start: () -> Int = () -> {
  classify(I(5)) + classify(S("foo")) + classify(I(7)) + classify(S("perform"))
}
EOF
# Expected: 11 + 21 + 10 + 20 = 62
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pdir/litpat.vibe" "$pdir/litpat.wasm" _start >/dev/null 2>&1
if [ ! -s "$pdir/litpat.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: literal sub-pattern program did not compile" >&2; exit 1
fi
litpat_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$pdir/litpat.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$litpat_out" != "62" ]; then
  echo "[selfhost-only-gate] FAIL: literal sub-pattern mismatch (got '$litpat_out', want 62 -> #603 regressed)" >&2
  exit 1
fi
rm -rf "$pdir"
echo "[selfhost-only-gate] literal sub-pattern regression ok"

# 8. labeled-param round-trip regression (#604/#606): normalizing a function
#    with labeled (`x~`) / optional (`x?`) parameters must preserve the parameter
#    names. `parse_one_param` builds the names with string interpolation
#    (`"\{name}~"`); before the #606 `__to_string` root fix this leaked a heap
#    pointer (`(1285664100319233~)`), and the #604 mitigation routed around it
#    with `String::concat`. With the root fix the interpolation form is correct,
#    so this guards the root fix directly. The result must still compile + run.
echo "[selfhost-only-gate] 8/8 labeled-param round-trip regression"
ldir="_build/_gate_labeled"
rm -rf "$ldir"; mkdir -p "$ldir"
printf 'let sum: (x~: Int, y~: Int) -> Int = (x~, y~) -> { x + y }\nexport let run: () -> Int = () -> { sum(x=1, y=2) }\nexport { run }\n' > "$ldir/in.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ldir/in.vibe" "$ldir/out.vibe" >/dev/null 2>&1
if [ ! -s "$ldir/out.vibe" ]; then
  echo "[selfhost-only-gate] FAIL: labeled-param normalize produced no output" >&2; exit 1
fi
# Param names must survive verbatim; a digit before `~` means the gensym bug is back.
if ! grep -q "(x~, y~)" "$ldir/out.vibe" || grep -Eq "[0-9]+~" "$ldir/out.vibe"; then
  echo "[selfhost-only-gate] FAIL: labeled param names mangled (#604 regressed)" >&2
  cat "$ldir/out.vibe" >&2; exit 1
fi
# The normalized output must still compile + run.
cp "$ldir/out.vibe" "$ldir/compile.vibe"
printf '\nexport let _start: () -> Int = () -> { run() }\n' >> "$ldir/compile.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ldir/compile.vibe" "$ldir/out.wasm" _start >/dev/null 2>&1
labeled_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$ldir/out.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$labeled_out" != "3" ]; then
  echo "[selfhost-only-gate] FAIL: normalized labeled-param output did not compile/run to 3 (got '$labeled_out')" >&2
  cat "$ldir/compile.vibe" >&2; exit 1
fi
rm -rf "$ldir"
echo "[selfhost-only-gate] labeled-param round-trip regression ok"

# 9. constant-folding regression (#594): `vibe normalize` folds `+ - *` over int
#    literals. The folded value must replace the expression and the result must
#    compile + run unchanged.
echo "[selfhost-only-gate] 9/9 constant-folding regression"
fdir="_build/_gate_fold"
rm -rf "$fdir"; mkdir -p "$fdir"
printf 'let x = 40 + 2 * 10\nexport let run: () -> Int = () -> { x }\nexport { run }\n' > "$fdir/in.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fdir/in.vibe" "$fdir/out.vibe" >/dev/null 2>&1
# 40 + 2*10 = 60; the arithmetic must be gone and `60` present.
if ! grep -q "let x: Int = 60" "$fdir/out.vibe" || grep -q "40 + 2" "$fdir/out.vibe"; then
  echo "[selfhost-only-gate] FAIL: constant folding incorrect" >&2
  cat "$fdir/out.vibe" >&2; exit 1
fi
cp "$fdir/out.vibe" "$fdir/compile.vibe"
printf '\nexport let _start: () -> Int = () -> { run() }\n' >> "$fdir/compile.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fdir/compile.vibe" "$fdir/out.wasm" _start >/dev/null 2>&1
fold_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$fdir/out.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$fold_out" != "60" ]; then
  echo "[selfhost-only-gate] FAIL: folded program did not run to 60 (got '$fold_out')" >&2; exit 1
fi
rm -rf "$fdir"
echo "[selfhost-only-gate] constant-folding regression ok"

# 10. nested constructor sub-pattern regression (#608): a constructor pattern
#     whose argument is itself a constructor (`SL(_, None, _)` vs
#     `SL(_, Some(x), _)`) must (a) discriminate on the nested tag — arms sharing
#     the outer tag must route distinctly — and (b) bind the nested fields, so
#     using `x` in the arm body compiles instead of trapping codegen. Adjacent to
#     #603 (literal sub-patterns); both live in the single-condition PCtor path.
echo "[selfhost-only-gate] 10/10 nested ctor sub-pattern regression"
ndir="_build/_gate_nestedctor"
rm -rf "$ndir"; mkdir -p "$ndir"
cat > "$ndir/nested.vibe" <<'EOF'
enum Stmt { SL(Int, Option[Int], Int) }
let classify: (Stmt) -> Int = (stmt) -> {
  match stmt {
    SL(a, None, c) => a + c,
    SL(a, Some(x), c) => a + x + c,
    _ => 0
  }
}
export let _start: () -> Int = () -> {
  classify(SL(4, None, 6)) + classify(SL(4, Some(7), 6))
}
EOF
# Expected: (4+6) + (4+7+6) = 10 + 17 = 27.
# The bound `x` in Some(x) must compile (no trap), and Some must not route to None.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/nested.vibe" "$ndir/nested.wasm" _start >/dev/null 2>&1
if [ ! -s "$ndir/nested.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: nested ctor sub-pattern program did not compile (#608 regressed: codegen trap)" >&2; exit 1
fi
nested_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$ndir/nested.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$nested_out" != "27" ]; then
  echo "[selfhost-only-gate] FAIL: nested ctor sub-pattern mismatch (got '$nested_out', want 27 -> #608 regressed)" >&2
  exit 1
fi
rm -rf "$ndir"
echo "[selfhost-only-gate] nested ctor sub-pattern regression ok"

# 11. forward-reference regression (#602): a top-level `let` may reference another
#     top-level `let` defined later in the same file. The checker now hoists
#     top-level binding signatures, so this compiles instead of aborting with an
#     opaque trap. A genuinely-undefined name must still error (no over-permit).
echo "[selfhost-only-gate] 11/11 forward-reference regression"
wdir="_build/_gate_fwdref"
rm -rf "$wdir"; mkdir -p "$wdir"
cat > "$wdir/fwd.vibe" <<'EOF'
let early: () -> Int = () -> { late() }
let late: () -> Int = () -> { 41 }
export let _start: () -> Int = () -> { early() + 1 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$wdir/fwd.vibe" "$wdir/fwd.wasm" _start >/dev/null 2>&1
if [ ! -s "$wdir/fwd.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: forward-reference program did not compile (#602 regressed: checker trap)" >&2; exit 1
fi
fwd_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$wdir/fwd.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$fwd_out" != "42" ]; then
  echo "[selfhost-only-gate] FAIL: forward-reference mismatch (got '$fwd_out', want 42 -> #602 regressed)" >&2
  exit 1
fi
# Guard: a genuinely-undefined name must still be rejected (hoist only adds names
# that are actually defined later).
printf 'export let _start: () -> Int = () -> { genuinely_undefined_name() }\n' > "$wdir/undef.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$wdir/undef.vibe" "$wdir/undef.wasm" _start >/dev/null 2>&1 || true
if [ -s "$wdir/undef.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: undefined name compiled (#602 hoist over-permitted)" >&2; exit 1
fi
rm -rf "$wdir"
echo "[selfhost-only-gate] forward-reference regression ok"

# 12. string-interpolation conversion regression (#606): `"\{e}"` lowers to
#     `__to_string(e)`, which was an `identity` stub (so interpolating an int
#     yielded garbage) reachable only via a dead inline path. The root fix makes
#     `__to_string` always use the real conversion (int -> decimal, string ->
#     passthrough with an in-bounds pointer check). Assert an int interpolates to
#     its digits and a string interpolates verbatim.
echo "[selfhost-only-gate] 12/12 string-interpolation conversion regression"
idir="_build/_gate_interp"
rm -rf "$idir"; mkdir -p "$idir"
cat > "$idir/interp.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let n = 42
  let s = "v\{n}"
  let name = "ab"
  let t = "\{name}!"
  // s = "v42" (length 3, s[1]='4'=52), t = "ab!" (length 3, t[0]='a'=97).
  String::length(s) * 1000 + String::char_code_at(s, 1) * 100 + String::length(t) * 10 + (String::char_code_at(t, 0) - 97)
}
EOF
# 3*1000 + 52*100 + 3*10 + 0 = 3000 + 5200 + 30 = 8230
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$idir/interp.vibe" "$idir/interp.wasm" _start >/dev/null 2>&1
if [ ! -s "$idir/interp.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: interpolation program did not compile" >&2; exit 1
fi
interp_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$idir/interp.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$interp_out" != "8230" ]; then
  echo "[selfhost-only-gate] FAIL: interpolation mismatch (got '$interp_out', want 8230 -> #606 regressed)" >&2
  exit 1
fi
rm -rf "$idir"
echo "[selfhost-only-gate] string-interpolation conversion regression ok"

# 13. coverage instrumentation regression (#cov): VIBE_COVERAGE=1 must produce an
#     instrumented build whose vibe_cov / vibe_cov_branch sections the runner can
#     read. A test that exercises only the then-branch of an `if` must report
#     both functions hit and exactly one of the two branches taken — the signal
#     that powers `vibe test --coverage`.
echo "[selfhost-only-gate] 13/13 coverage instrumentation regression"
cdir="_build/_gate_cov"
rm -rf "$cdir"; mkdir -p "$cdir"
cat > "$cdir/cov_test.vibe" <<'EOF'
let pick: (Int) -> Int = (n) -> {
  if n > 0 {
    1
  } else {
    2
  }
}
test "pos" {
  assert(pick(5) == 1)
}
EOF
VIBE_COVERAGE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir/cov_test.vibe" "$cdir/cov_test.wasm" __vibe_test_no_entry__ >/dev/null 2>&1
if [ ! -s "$cdir/cov_test.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: coverage build produced no wasm (#cov regressed)" >&2; exit 1
fi
VIBE_COV_OUT="$cdir/cov.json" VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$cdir/cov_test.wasm" >/dev/null 2>&1
if [ ! -s "$cdir/cov.json" ]; then
  echo "[selfhost-only-gate] FAIL: no coverage report produced (vibe_cov section missing?)" >&2; exit 1
fi
cov_check="$(python3 - "$cdir/cov.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
b = r.get("branch") or {}
# pick + __test_pos both run -> all functions hit; only the then-branch of `if`
# is taken -> 1 of 2 branches. `pick` must appear hit and with a branch gap.
ok = (r.get("hit") == r.get("total") and r.get("total", 0) >= 2
      and b.get("total") == 2 and b.get("hit") == 1
      and "pick" in r.get("hit_fns", []))
print("ok" if ok else f"bad fn={r.get('hit')}/{r.get('total')} br={b.get('hit')}/{b.get('total')}")
PY
)"
if [ "$cov_check" != "ok" ]; then
  echo "[selfhost-only-gate] FAIL: coverage report wrong ($cov_check -> #cov regressed)" >&2; exit 1
fi
rm -rf "$cdir"
echo "[selfhost-only-gate] coverage instrumentation regression ok"

# 14. method-bearing-trait dictionary passing regression (#641 PR-3): a
#     `[T: Trait]` generic calling `T::method(x)` must dispatch to the concrete
#     impl via a synthesized witness dictionary (desugar_trait_dict.vibe). Covers
#     a primitive impl, a struct impl, multiple methods (incl. `Self`-returning
#     `scale`), literal and let-bound receivers, generic->generic dict
#     forwarding, and supertrait method inheritance (flattened witness).
echo "[selfhost-only-gate] 14/14 method-bearing-trait dict-passing regression"
mbtdir="_build/_gate_mbtrait"
rm -rf "$mbtdir"; mkdir -p "$mbtdir"
cat > "$mbtdir/mbt.vibe" <<'EOF'
trait Measurable { measure(Self) -> Int; scale(Self, Int) -> Self }
trait Sized: Measurable { bump(Self) -> Int }
struct Point { x: Int; y: Int }
impl Measurable for Int {
  measure(self) -> Int { self }
  scale(self, k) -> Int { self * k }
}
impl Measurable for Point {
  measure(self) -> Int { self.x + self.y }
  scale(self, k) -> Point { Point::{ x: self.x * k, y: self.y * k } }
}
impl Sized for Int { bump(self) -> Int { self + 1 } }
impl Sized for Point { bump(self) -> Int { self.x + self.y + 1 } }
let measure_one = [T: Measurable](x: T) -> Int { T::measure(x) }
let twice = [T: Measurable](x: T) -> Int { T::measure(T::scale(x, 2)) }
let forward = [T: Measurable](x: T) -> Int { measure_one(x) + twice(x) }
let sized_sum = [T: Sized](x: T) -> Int { T::measure(x) + T::bump(x) }
export let _start: () -> Int = () -> {
  let p = Point::{ x: 40, y: 2 }
  measure_one(42) + twice(21) + measure_one(p) + twice(p)
  + forward(10) + sized_sum(7) + sized_sum(p)
}
EOF
# Expected: 42 + 42 + 42 + 84 + (10+20) + (7+8) + (42+43) = 340
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mbtdir/mbt.vibe" "$mbtdir/mbt.wasm" _start >/dev/null 2>&1
if [ ! -s "$mbtdir/mbt.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: trait dict-passing program did not compile" >&2
  cat "$mbtdir/mbt.wasm.diag" 2>/dev/null >&2; exit 1
fi
mbt_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$mbtdir/mbt.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$mbt_out" != "340" ]; then
  echo "[selfhost-only-gate] FAIL: trait dict-passing mismatch (got '$mbt_out', want 340 -> #641 PR-3 regressed)" >&2
  exit 1
fi
rm -rf "$mbtdir"
echo "[selfhost-only-gate] method-bearing-trait dict-passing regression ok"

# 15. derive(...) structural generation regression (#638): `derive(Ord)` and
#     `derive(Show)` on a struct must generate working `Type::compare` (-1/0/1
#     lexicographic over fields) and `Type::to_string` free functions. Also
#     covers multiple-derive and `Eq` accepted as a no-op marker.
echo "[selfhost-only-gate] 15/15 derive(Ord/Show) structural-generation regression"
drvdir="_build/_gate_derive"
rm -rf "$drvdir"; mkdir -p "$drvdir"
cat > "$drvdir/drv.vibe" <<'EOF'
struct P { x: Int; y: Int } derive(Eq, Ord, Show)
export let _start: () -> Int = () -> {
  P::compare(P::{ x: 1, y: 1 }, P::{ x: 1, y: 2 })
  + P::compare(P::{ x: 2, y: 0 }, P::{ x: 1, y: 9 })
  + P::compare(P::{ x: 5, y: 5 }, P::{ x: 5, y: 5 })
  + String::length(P::to_string(P::{ x: 7, y: 9 }))
}
EOF
# Expected: -1 + 1 + 0 + len("P { x: 7, y: 9 }")=16 -> 16
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$drvdir/drv.vibe" "$drvdir/drv.wasm" _start >/dev/null 2>&1
if [ ! -s "$drvdir/drv.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: derive program did not compile" >&2
  cat "$drvdir/drv.wasm.diag" 2>/dev/null >&2; exit 1
fi
drv_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$drvdir/drv.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$drv_out" != "16" ]; then
  echo "[selfhost-only-gate] FAIL: derive mismatch (got '$drv_out', want 16 -> #638 regressed)" >&2
  exit 1
fi
rm -rf "$drvdir"
echo "[selfhost-only-gate] derive(Ord/Show) structural-generation regression ok"

# 16. trait type parameters / Iterator regression (#636): a method-bearing trait
#     with a type parameter (`Iterator[T] { next(Self) -> Option[T] }`) must be
#     declarable, and a `[I: Iterator]` generic must dispatch `I::next` through
#     the witness dictionary — driving a stateful, functional iterator
#     (`next(Self) -> Option[(T, Self)]`) to completion.
echo "[selfhost-only-gate] 16/16 trait-type-parameter / Iterator regression"
itdir="_build/_gate_iter"
rm -rf "$itdir"; mkdir -p "$itdir"
cat > "$itdir/iter.vibe" <<'EOF'
trait Iter[T] { next(Self) -> Option[(T, Self)] }
trait Iterable[T] { iter(Self) -> Range }
struct Range { lo: Int; hi: Int }
struct Span { from: Int; to: Int }
impl Iterable for Span { iter(self) -> Range { Range::{ lo: self.from, hi: self.to } } }
impl Iter for Range {
  next(self) -> Option[(Int, Range)] {
    if self.lo < self.hi {
      Some((self.lo, Range::{ lo: self.lo + 1, hi: self.hi }))
    } else {
      None
    }
  }
}
let iter_sum = [I: Iter](it: I) -> Int {
  let mut acc = 0
  let mut cur = it
  let mut go = true
  while go {
    match I::next(cur) {
      Some(pair) => { let (v, rest) = pair; acc = acc + v; cur = rest },
      None => { go = false }
    }
  }
  acc
}
export let _start: () -> Int = () -> {
  // `for x in <iterator>` desugars to a next-driven loop (10);
  // `for x in <iterable>` calls iter() then drives next (10);
  // iter_sum dispatches I::next through the witness dict (10).
  let mut acc = 0
  for x in Range::{ lo: 1, hi: 5 } { acc = acc + x }
  for y in Span::{ from: 1, to: 5 } { acc = acc + y }
  acc + iter_sum(Range::{ lo: 1, hi: 5 })
}
EOF
# Expected: (1+2+3+4) + (1+2+3+4) + (1+2+3+4) = 30
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$itdir/iter.vibe" "$itdir/iter.wasm" _start >/dev/null 2>&1
if [ ! -s "$itdir/iter.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: Iterator trait program did not compile" >&2
  cat "$itdir/iter.wasm.diag" 2>/dev/null >&2; exit 1
fi
it_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$itdir/iter.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$it_out" != "30" ]; then
  echo "[selfhost-only-gate] FAIL: Iterator dispatch mismatch (got '$it_out', want 30 -> #636 regressed)" >&2
  exit 1
fi
rm -rf "$itdir"
echo "[selfhost-only-gate] trait-type-parameter / Iterator regression ok"

# 17. lazy iterator combinators regression (#636): a lazy `Stream` (a struct
#     holding a `pull` closure) with `impl Iter for Stream` supports lazy
#     `map`/`filter` and eager `fold`/`sum`/`count` consumers (driven by the
#     `for` desugar) — the trait-based replacement for prelude/lazy_iter.vibe's
#     `() -> Option[T]` function iterator. All library code, no compiler support
#     beyond the trait machinery.
echo "[selfhost-only-gate] 17/17 lazy iterator combinators regression"
lcdir="_build/_gate_lazyiter"
rm -rf "$lcdir"; mkdir -p "$lcdir"
cat > "$lcdir/lc.vibe" <<'EOF'
trait Iter[T] { next(Self) -> Option[(T, Self)] }
struct Stream { pull: (Int) -> Option[(Int, Int)]; state: Int }
impl Iter for Stream {
  next(self) -> Option[(Int, Stream)] {
    match (self.pull)(self.state) {
      Some(p) => { let (v, ns) = p; Some((v, Stream::{ pull: self.pull, state: ns })) },
      None => None
    }
  }
}
let range = (lo: Int, hi: Int) -> Stream {
  Stream::{ pull: (s) -> { if s < hi { Some((s, s + 1)) } else { None } }, state: lo }
}
let smap = (s: Stream, f: (Int) -> Int) -> Stream {
  Stream::{ pull: (st) -> { match (s.pull)(st) { Some(p) => { let (v, ns) = p; Some((f(v), ns)) }, None => None } }, state: s.state }
}
let sfilter = (s: Stream, pred: (Int) -> Bool) -> Stream {
  Stream::{ pull: (st) -> {
    let mut cur = st
    let mut result = None
    let mut go = true
    while go {
      match (s.pull)(cur) {
        Some(p) => { let (v, ns) = p; if pred(v) { result = Some((v, ns)); go = false } else { cur = ns } },
        None => { go = false }
      }
    }
    result
  }, state: s.state }
}
let sfold = (s: Stream, init: Int, f: (Int, Int) -> Int) -> Int {
  let mut acc = init
  for x in s { acc = f(acc, x) }
  acc
}
let ssum = (s: Stream) -> Int { sfold(s, 0, (a, b) -> { a + b }) }
let scount = (s: Stream) -> Int { sfold(s, 0, (a, _) -> { a + 1 }) }
let is_even = (x: Int) -> Bool { x - (x / 2) * 2 == 0 }
export let _start: () -> Int = () -> {
  ssum(smap(range(1, 5), (x) -> { x * 2 }))   // 2+4+6+8 = 20
  + ssum(sfilter(range(1, 10), is_even))       // 2+4+6+8 = 20
  + scount(range(0, 7))                        // 7
}
EOF
# Expected: 20 + 20 + 7 = 47
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$lcdir/lc.vibe" "$lcdir/lc.wasm" _start >/dev/null 2>&1
if [ ! -s "$lcdir/lc.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: lazy combinators program did not compile" >&2
  cat "$lcdir/lc.wasm.diag" 2>/dev/null >&2; exit 1
fi
lc_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$lcdir/lc.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$lc_out" != "47" ]; then
  echo "[selfhost-only-gate] FAIL: lazy combinators mismatch (got '$lc_out', want 47 -> #636 regressed)" >&2
  exit 1
fi
rm -rf "$lcdir"
echo "[selfhost-only-gate] lazy iterator combinators regression ok"

# 18. cross-import trait-iterator regression (#636): the iterator type + its
#     `impl ::next` + a `for x in <iter>` driver live in an IMPORTED module
#     (the prelude shape — lazy_iter.vibe is always imported). A qualified impl
#     method `LazyIter::next` is a non-exported `let`, so the import namespacer
#     used to path-suffix it (`LazyIter::next$path`), orphaning it from the
#     `LazyIter` type and making the `for` desugar's `Type::next` lookup miss —
#     the loop silently fell back to array iteration and trapped. Qualified
#     `Type::method` names must follow the *type's* namespacing, not get an
#     independent value suffix. Guards import_alias_rewrite + the generic-struct
#     `for`-iterator desugar across the import boundary.
echo "[selfhost-only-gate] 18/18 cross-import trait-iterator regression"
xidir="_build/_gate_import_iter"
rm -rf "$xidir"; mkdir -p "$xidir"
cat > "$xidir/li.vibe" <<'EOF'
export trait Iterator[T] { next(Self) -> Option[(T, Self)] }
export struct LazyIter[T] { pull: (Int) -> Option[(T, Int)]; state: Int }
impl Iterator for LazyIter {
  next(self) -> Option[(T, LazyIter)] {
    match (self.pull)(self.state) {
      Some(p) => { let (v, ns) = p; Some((v, LazyIter::{ pull: self.pull, state: ns })) },
      None => None
    }
  }
}
export let lazy_iter_arr = [T](xs: Array[T]) -> LazyIter[T] {
  LazyIter::{ pull: (i) -> Option[(T, Int)] {
    if i < Array::length(xs) { Some((Array::get(xs, i), i + 1)) } else { None }
  }, state: 0 }
}
export let lazy_iter_count = [T](src: LazyIter[T]) -> Int {
  let mut n = 0
  for x in src { n = n + 1 }
  n
}
EOF
cat > "$xidir/main.vibe" <<'EOF'
import ./li.vibe { lazy_iter_arr, lazy_iter_count }
export let _start: () -> Int = () -> { lazy_iter_count(lazy_iter_arr([10, 20, 30, 40, 50])) }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xidir/main.vibe" "$xidir/main.wasm" _start >/dev/null 2>&1
if [ ! -s "$xidir/main.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: cross-import trait-iterator program did not compile" >&2
  exit 1
fi
xi_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$xidir/main.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$xi_out" != "5" ]; then
  echo "[selfhost-only-gate] FAIL: cross-import trait-iterator mismatch (got '$xi_out', want 5 -> import method namespacing regressed)" >&2
  exit 1
fi
rm -rf "$xidir"
echo "[selfhost-only-gate] cross-import trait-iterator regression ok"

# 19. `for await` unification regression (#636): `for await x in s` shares one
#     type-directed desugar with sync `for`. The parser wraps the iterable in a
#     `__await_iter` marker (the checker unwraps it; the desugar strips it) so
#     the desugar — which has type info the parser lacks — picks the loop shape:
#       - a struct `C` with `C::next -> Future[Option[..]]` (an AsyncIterator /
#         `Stream[T]`) drives an `await`-wrapped next loop (`await` unwraps the
#         ready future on the synchronous backend), and
#       - any other iterable (a pull closure `() -> Option[T]`, the pre-existing
#         M2c-3 model) drives the pull-to-`None` loop.
#     Guards the parser marker + checker unwrap + always-run desugar pass.
echo "[selfhost-only-gate] 19/19 for-await unification regression"
fadir="_build/_gate_forawait"
rm -rf "$fadir"; mkdir -p "$fadir"
cat > "$fadir/fa.vibe" <<'EOF'
trait AsyncIterator[T] { next(Self) -> Future[Option[(T, Self)]] }
struct AStream { pull: (Int) -> Option[(Int, Int)]; state: Int }
impl AsyncIterator for AStream {
  next(self) -> Future[Option[(Int, AStream)]] {
    Future::ready(match (self.pull)(self.state) {
      Some(p) => { let (v, ns) = p; Some((v, AStream::{ pull: self.pull, state: ns })) },
      None => None
    })
  }
}
let mkstream = (xs: Array[Int]) -> AStream {
  AStream::{ pull: (i) -> Option[(Int, Int)] { if i < Array::length(xs) { Some((Array::get(xs, i), i + 1)) } else { None } }, state: 0 }
}
let counter_stream = () -> (() -> Option[Int]) {
  let mut n = 0
  () -> Option[Int] { if n < 4 { n = n + 1; Some(n) } else { None } }
}
export let _start: () -> Int with { Async } = () -> {
  let mut t = 0
  for await x in mkstream([10, 20, 30]) { t = t + x }
  for await y in counter_stream() { t = t + y }
  t
}
EOF
# Expected: async iterator 10+20+30 = 60, pull closure 1+2+3+4 = 10 -> 70.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fadir/fa.vibe" "$fadir/fa.wasm" _start >/dev/null 2>&1
if [ ! -s "$fadir/fa.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: for-await program did not compile" >&2
  cat "$fadir/fa.wasm.diag" 2>/dev/null >&2; exit 1
fi
fa_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$fadir/fa.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$fa_out" != "70" ]; then
  echo "[selfhost-only-gate] FAIL: for-await unification mismatch (got '$fa_out', want 70 -> #636 regressed)" >&2
  exit 1
fi
rm -rf "$fadir"
echo "[selfhost-only-gate] for-await unification regression ok"

# 20. cross-import trait-iterator ELEMENT-TYPE inference: `for x in <C[T]>` binds
#     `x` to the iterator's element type `T`, recovered from the iterable's type
#     `C[T]` (the `next(Self) -> Option[(T, Self)]` convention puts the element
#     first) — even though the `impl Iterator for C` lives in the imported module
#     and is NOT in this file's import env. Two assertions:
#       (a) POSITIVE: a `LazyIter[Int]` loop body uses `x` directly in element
#           arithmetic (`total + x`) and runs to the right sum.
#       (b) NEGATIVE: a `LazyIter[String]` loop with an `Int` accumulator
#           (`total + x`, total : Int, x : String) MUST be rejected by the
#           checker — proving the element is typed `String`, not `CtUnknown`
#           (which silently accepted any use and dropped element-type safety).
echo "[selfhost-only-gate] 20/20 cross-import trait-iterator element-type regression"
eidir="_build/_gate_import_iter_elem"
rm -rf "$eidir"; mkdir -p "$eidir"
cat > "$eidir/li.vibe" <<'EOF'
export trait Iterator[T] { next(Self) -> Option[(T, Self)] }
export struct LazyIter[T] { pull: (Int) -> Option[(T, Int)]; state: Int }
impl Iterator for LazyIter {
  next(self) -> Option[(T, LazyIter)] {
    match (self.pull)(self.state) {
      Some(p) => { let (v, ns) = p; Some((v, LazyIter::{ pull: self.pull, state: ns })) },
      None => None
    }
  }
}
export let lazy_iter_arr = [T](xs: Array[T]) -> LazyIter[T] {
  LazyIter::{ pull: (i) -> Option[(T, Int)] {
    if i < Array::length(xs) { Some((Array::get(xs, i), i + 1)) } else { None }
  }, state: 0 }
}
EOF
# (a) positive: direct element arithmetic compiles + runs (10+20+30+40 = 100).
cat > "$eidir/pos.vibe" <<'EOF'
import ./li.vibe { lazy_iter_arr }
let sum_direct = (src: LazyIter[Int]) -> Int {
  let mut total = 0
  for x in src { total = total + x }
  total
}
export let _start: () -> Int = () -> { sum_direct(lazy_iter_arr([10, 20, 30, 40])) }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eidir/pos.vibe" "$eidir/pos.wasm" _start >/dev/null 2>&1
if [ ! -s "$eidir/pos.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: element-type positive program did not compile" >&2
  cat "$eidir/pos.wasm.diag" 2>/dev/null >&2; exit 1
fi
ei_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$eidir/pos.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$ei_out" != "100" ]; then
  echo "[selfhost-only-gate] FAIL: element-type positive mismatch (got '$ei_out', want 100)" >&2
  exit 1
fi
# (b) negative: Int accumulator + String element must be a type error.
cat > "$eidir/neg.vibe" <<'EOF'
import ./li.vibe { lazy_iter_arr }
let bad = (src: LazyIter[String]) -> Int {
  let mut total = 0
  for x in src { total = total + x }
  total
}
export let _start: () -> Int = () -> { bad(lazy_iter_arr(["a", "b"])) }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eidir/neg.vibe" "$eidir/neg.wasm" _start >/dev/null 2>&1 || true
if [ -s "$eidir/neg.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: element-type negative program compiled (element typed CtUnknown, not String -> element-type safety regressed)" >&2
  exit 1
fi
if ! grep -q "type mismatch in '+'" "$eidir/neg.wasm.diag" 2>/dev/null; then
  echo "[selfhost-only-gate] FAIL: element-type negative rejected for the wrong reason" >&2
  cat "$eidir/neg.wasm.diag" 2>/dev/null >&2; exit 1
fi
rm -rf "$eidir"
echo "[selfhost-only-gate] cross-import trait-iterator element-type regression ok"

# 21. prelude iterator combinator suites: compile + run the real prelude test
#     files through the fresh stage2 and assert every `test "..."` block passes
#     (each `assert` traps on failure, so a clean `_start` run == all passed).
#     Covers the sync `lazy_iter` and async `async_iter` combinator libraries
#     (take / drop / take_while / enumerate / zip / flat_map / find / any / all,
#     and the async `for await`-driven terminals) — these prelude tests are not
#     otherwise exercised by the moon-free gate.
echo "[selfhost-only-gate] 21/21 prelude iterator combinator suites"
for suite in vibe/prelude/lazy_iter_test.vibe vibe/prelude/async_iter_test.vibe; do
  out="_build/_gate_prelude_iter_$(basename "${suite%.vibe}").wasm"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$suite" "$out" _start >/dev/null 2>&1
  if [ ! -s "$out" ]; then
    echo "[selfhost-only-gate] FAIL: $suite did not compile" >&2
    cat "$out.diag" 2>/dev/null >&2; exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
      --invoke _start "$out" >/dev/null 2>&1; then
    echo "[selfhost-only-gate] FAIL: $suite has a failing test (assert trapped)" >&2
    exit 1
  fi
  rm -f "$out" "$out.diag" "$out.funcmap"
done
echo "[selfhost-only-gate] prelude iterator combinator suites ok"

# 22. generic trait impls — Increment A (#5): an UNbounded, method-bearing
#     `impl [T] Trait for C` makes `C[K]` satisfy a `[U: Trait]` bound for any K,
#     and the witness dict (`{ method: C::method }`) dispatches through the
#     existing dict-passing desugar — so a generic function called with an array
#     runs the array impl. Two assertions:
#       (a) POSITIVE: `impl [T] Len2 for Array` + `[U: Len2] total(x)` runs.
#       (b) SOUNDNESS: a marker-trait generic impl (`impl [T: Eq] Eq for
#           Option[T]`, Eq has no methods) must STILL be rejected — matching it
#           would let `==` (which is not structural on Option) silently misbehave.
echo "[selfhost-only-gate] 22/22 generic trait impl (Increment A)"
gidir="_build/_gate_generic_impl"
rm -rf "$gidir"; mkdir -p "$gidir"
cat > "$gidir/pos.vibe" <<'EOF'
trait Len2[T] { len2(Self) -> Int }
struct Box[T] { v: T }
impl Len2 for Box { len2(self) -> Int { 1 } }
impl [T] Len2 for Array { len2(self) -> Int { Array::length(self) } }
let total = [U: Len2](x: U) -> Int { U::len2(x) }
export let _start: () -> Int = () -> { total([10, 20, 30, 40]) + total(Box::{ v: 99 }) }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gidir/pos.vibe" "$gidir/pos.wasm" _start >/dev/null 2>&1
if [ ! -s "$gidir/pos.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: generic-impl positive program did not compile" >&2
  cat "$gidir/pos.wasm.diag" 2>/dev/null >&2; exit 1
fi
gi_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$gidir/pos.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$gi_out" != "5" ]; then
  echo "[selfhost-only-gate] FAIL: generic-impl positive mismatch (got '$gi_out', want 5)" >&2
  exit 1
fi
# Soundness: a marker-trait generic impl must NOT satisfy the bound.
cat > "$gidir/neg.vibe" <<'EOF'
trait Marky[T]
impl [T] Marky for Array
let needs = [U: Marky](x: U) -> Int { 1 }
export let _start: () -> Int = () -> { needs([1, 2, 3]) }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gidir/neg.vibe" "$gidir/neg.wasm" _start >/dev/null 2>&1 || true
if [ -s "$gidir/neg.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: marker-trait generic impl was accepted (unsound — should be rejected)" >&2
  exit 1
fi
rm -rf "$gidir"
echo "[selfhost-only-gate] generic trait impl (Increment A) ok"

# 23. generic trait impls — Increment B (#5): a BOUNDED generic impl
#     `impl [T: Bound] Trait for C` whose body dispatches `T`'s methods on the
#     elements. The witness for `C[K]` is a nested dictionary-of-dictionaries:
#     `{ method: (w) -> C::method(<K's Bound dict>, w) }`. Assertions:
#       (a) `impl [T: Show2] Show2 for Array` summing `T::show2` over elements
#           runs for `Array[Box]` (→60) and nests for `Array[Array[Box]]` (→6).
#       (b) SOUNDNESS: an element type with no impl must NOT silently dispatch —
#           the witness refuses to build, so the program fails to produce a
#           runnable module (never returns a wrong number).
echo "[selfhost-only-gate] 23/23 generic trait impl (Increment B, dict-of-dict)"
gjdir="_build/_gate_generic_impl_b"
rm -rf "$gjdir"; mkdir -p "$gjdir"
gj_prelude='trait Show2[T] { show2(Self) -> Int }
struct Box[T] { v: T }
impl Show2 for Box { show2(self) -> Int { self.v } }
impl [T: Show2] Show2 for Array { show2(self) -> Int {
  let mut s = 0
  for x in self { s = s + T::show2(x) }
  s
} }
let use_it = [U: Show2](x: U) -> Int { U::show2(x) }'
{ printf '%s\n' "$gj_prelude"
  printf 'export let _start: () -> Int = () -> { use_it([Box::{ v: 10 }, Box::{ v: 20 }, Box::{ v: 30 }]) + use_it([[Box::{ v: 1 }, Box::{ v: 2 }], [Box::{ v: 3 }]]) }\n'
} > "$gjdir/pos.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gjdir/pos.vibe" "$gjdir/pos.wasm" _start >/dev/null 2>&1
if [ ! -s "$gjdir/pos.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: dict-of-dict positive program did not compile" >&2
  cat "$gjdir/pos.wasm.diag" 2>/dev/null >&2; exit 1
fi
gj_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$gjdir/pos.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$gj_out" != "66" ]; then
  echo "[selfhost-only-gate] FAIL: dict-of-dict mismatch (got '$gj_out', want 66 = 60 + 6)" >&2
  exit 1
fi
# Soundness: an element type with no Show2 impl must not silently dispatch.
{ printf '%s\n' "$gj_prelude"
  printf 'struct Qux[T] { w: T }\n'
  printf 'export let _start: () -> Int = () -> { use_it([Qux::{ w: 5 }]) }\n'
} > "$gjdir/neg.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gjdir/neg.vibe" "$gjdir/neg.wasm" _start >/dev/null 2>&1 || true
neg_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$gjdir/neg.wasm" 2>/dev/null | tr -dc '0-9-' || true)"
if [ "$neg_out" = "5" ]; then
  echo "[selfhost-only-gate] FAIL: element without an impl silently dispatched (miscompile — returned 5)" >&2
  exit 1
fi
rm -rf "$gjdir"
echo "[selfhost-only-gate] generic trait impl (Increment B, dict-of-dict) ok"

# 24. async-lifted component EXECUTION on wasmtime (docs/spec/wasi-p3-async.md
#     §3.1). The async-lift codegen (`comp_emit_component_wasm_async*` — task.return
#     canon + async functype + async lift) is byte-tested on node, but the emitted
#     component had no moon-free EXECUTION check (the only runner was the retired
#     host `vibe.exe`). `fixtures/async_lift_run42.component.wasm` is a committed
#     async component (its `run()` returns 42) emitted by the selfhost codegen;
#     here wasmtime runs it with the async-stackful flags and we assert 42 — so
#     the async runtime path is proven to EXECUTE on wasmtime 45 (no wasmtime 46
#     needed). SKIPs cleanly when wasmtime / the async flags are unavailable.
#     Regenerate the fixture with: scripts/emit_async_lift_fixture.sh
echo "[selfhost-only-gate] 24/24 async-lifted component execution (wasmtime)"
WT_BIN="$(command -v wasmtime || "$ROOT_DIR/scripts/wasmtime_bin.sh" 2>/dev/null || true)"
ac_fixture="$ROOT_DIR/fixtures/async_lift_run42.component.wasm"
if [ -z "${WT_BIN:-}" ] || ! "$WT_BIN" --version >/dev/null 2>&1; then
  echo "[selfhost-only-gate] SKIP: wasmtime not available"
elif ! "$WT_BIN" -W help 2>&1 | grep -q "component-model-async-stackful"; then
  echo "[selfhost-only-gate] SKIP: wasmtime lacks component-model-async-stackful"
elif [ ! -s "$ac_fixture" ]; then
  echo "[selfhost-only-gate] SKIP: async-lift fixture missing (run scripts/emit_async_lift_fixture.sh)"
else
  ac_out="$(VIBE_WASMTIME_WASM_FLAGS="component-model-async=y concurrency-support=y component-model-async-stackful=y" \
    bash scripts/wasmtime_run.sh --invoke 'run()' "$ac_fixture" 2>/dev/null | tr -dc '0-9-' || true)"
  if [ "$ac_out" != "42" ]; then
    echo "[selfhost-only-gate] FAIL: async component did not execute to 42 (got '$ac_out')" >&2; exit 1
  fi
  echo "[selfhost-only-gate] async-lifted component execution (wasmtime $("$WT_BIN" --version | awk '{print $2}')) -> 42 ok"
fi

# 25. nested literal sub-pattern discrimination (#613 follow-up): a boolean (or
#     any) literal nested INSIDE a constructor argument that is itself a
#     constructor (`N(W(false), n)`) or a tuple (`T((false, n))`) must be
#     discriminated — the prior codegen only tag-tested nested ctors and did not
#     test tuple sub-patterns at all, silently routing `W(true)`/`(true, _)` to
#     the `false` arm (wrong result, not a trap). compile_match now emits the
#     literal test recursively at every nesting level.
echo "[selfhost-only-gate] 25/25 nested literal sub-pattern discrimination"
nldir="_build/_gate_nestedlit"
rm -rf "$nldir"; mkdir -p "$nldir"
cat > "$nldir/nestedlit.vibe" <<'EOF'
enum W { W(Bool) }
enum N { N(W, Int) }
enum T { T((Bool, Int)) }
let cn: (N) -> Int = (e) -> {
  match e {
    N(W(false), n) => n,
    N(W(true), n) => n + 1000
  }
}
let ct: (T) -> Int = (e) -> {
  match e {
    T((false, n)) => n,
    T((true, n)) => n + 1000
  }
}
export let _start: () -> Int = () -> {
  cn(N(W(true), 7)) + cn(N(W(false), 3)) + ct(T((true, 5))) + ct(T((false, 1)))
}
EOF
# Expected: 1007 + 3 + 1005 + 1 = 2016. A regressed compiler ignores the nested
# `true`/`false` literal and returns 7+3+5+1 = 16.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$nldir/nestedlit.vibe" "$nldir/nestedlit.wasm" _start >/dev/null 2>&1
if [ ! -s "$nldir/nestedlit.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: nested literal sub-pattern program did not compile" >&2; exit 1
fi
nestedlit_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$nldir/nestedlit.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$nestedlit_out" != "2016" ]; then
  echo "[selfhost-only-gate] FAIL: nested literal sub-pattern mismatch (got '$nestedlit_out', want 2016 -> #613 regressed)" >&2
  exit 1
fi
rm -rf "$nldir"
echo "[selfhost-only-gate] nested literal sub-pattern discrimination ok"

# 26. effect-call discipline (#626 criteria 1 & 3-builtin-slice): both
#     `perform EffName::Op` and a call to an effectful BUILTIN (`Fs::read_file`,
#     ...) are type errors unless the enclosing function declares that effect in
#     `with { ... }` (or it is inside a `handle`). Declared variants must
#     compile; undeclared variants must be REJECTED. (`Error`/`Async` are out of
#     this slice; pure builtins like `Array::length` are never flagged.)
echo "[selfhost-only-gate] 26/26 effect-call discipline (perform + builtin)"
pfdir="_build/_gate_perform"
rm -rf "$pfdir"; mkdir -p "$pfdir"
cat > "$pfdir/good.vibe" <<'EOF'
let emit: () -> Unit with { Stdout } = () -> {
  perform Stdout::WriteStream("hi")
}
let load: (String) -> String with { Fs } = (p) -> {
  Fs::read_file(p)
}
let pure_use: (Array[Int]) -> Int = (xs) -> {
  Array::length(xs)
}
export let _start: () -> Int = () -> {
  emit()
  pure_use([1, 2, 3]) + 39
}
EOF
cat > "$pfdir/bad_perform.vibe" <<'EOF'
let emit: () -> Unit = () -> {
  perform Stdout::WriteStream("hi")
}
export let _start: () -> Int = () -> {
  emit()
  42
}
EOF
cat > "$pfdir/bad_builtin.vibe" <<'EOF'
let load: (String) -> String = (p) -> {
  Fs::read_file(p)
}
export let _start: () -> Int = () -> {
  42
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/good.vibe" "$pfdir/good.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$pfdir/good.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: declared effect calls did not compile (#626 over-rejects)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_perform.vibe" "$pfdir/bad_perform.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_perform.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: undeclared perform compiled (#626 criterion 1 regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_builtin.vibe" "$pfdir/bad_builtin.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_builtin.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: undeclared effectful builtin call compiled (#626 builtin slice regressed)" >&2; exit 1
fi
rm -rf "$pfdir"
echo "[selfhost-only-gate] effect-call discipline ok"

# 27. handle effect discharge (#626 criterion 2): `handle ... with E` discharges
#     E for its body (a perform of E inside need not be declared), but ONLY E —
#     a perform of a DIFFERENT undeclared effect inside the same handle still
#     leaks and is a type error. The parser qualifies arm patterns as `E::Op`, so
#     the discharged effect is recovered from the handler arms.
echo "[selfhost-only-gate] 27/27 handle effect discharge"
hdir="_build/_gate_handle"
rm -rf "$hdir"; mkdir -p "$hdir"
cat > "$hdir/discharge.vibe" <<'EOF'
effect Console { Print(String) -> Unit }
let greet: () -> Int = () -> {
  handle {
    perform Console::Print("hi")
    7
  } with Console {
    Print(s) => resume(0)
  }
}
export let _start: () -> Int = () -> { greet() }
EOF
cat > "$hdir/leak.vibe" <<'EOF'
effect Console { Print(String) -> Unit }
effect Logger { Log(String) -> Unit }
let greet: () -> Int = () -> {
  handle {
    perform Logger::Log("hi")
    7
  } with Console {
    Print(s) => resume(0)
  }
}
export let _start: () -> Int = () -> { greet() }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hdir/discharge.vibe" "$hdir/discharge.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$hdir/discharge.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: handle did not discharge its own effect (#626 criterion 2 over-rejects)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hdir/leak.vibe" "$hdir/leak.wasm" _start >/dev/null 2>&1 || true
if [ -s "$hdir/leak.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: a different undeclared effect leaked through a handle (#626 criterion 2 regressed)" >&2; exit 1
fi
rm -rf "$hdir"
echo "[selfhost-only-gate] handle effect discharge ok"

# 28. argument type checking: the checker used to SWALLOW argument unification
#     failures (`unify_call_args` did `None => out`), so an ill-typed call like
#     `f("x")` for `f: (Int) -> Int` was silently accepted. It now reports a
#     STRUCTURAL argument mismatch (effect-only differences and the polymorphic
#     `__to_string` interpolation stringifier are still tolerated, since effect
#     inference on function values is imprecise). The mismatch must be REJECTED;
#     a correct call must still compile.
echo "[selfhost-only-gate] 28/28 argument type checking"
adir="_build/_gate_argcheck"
rm -rf "$adir"; mkdir -p "$adir"
cat > "$adir/wrong.vibe" <<'EOF'
let f: (Int) -> Int = (x) -> { x + 1 }
export let _start: () -> Int = () -> { f("hello") }
EOF
cat > "$adir/right.vibe" <<'EOF'
let f: (Int) -> Int = (x) -> { x + 1 }
export let _start: () -> Int = () -> { f(41) + 1 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$adir/right.vibe" "$adir/right.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$adir/right.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: a correctly-typed call did not compile (arg-check over-rejects)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$adir/wrong.vibe" "$adir/wrong.wasm" _start >/dev/null 2>&1 || true
if [ -s "$adir/wrong.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: an ill-typed argument (Int <- String) compiled (arg-check regressed)" >&2; exit 1
fi
rm -rf "$adir"
echo "[selfhost-only-gate] argument type checking ok"

# 29. assignment / typed-binding / if-branch type checking: more positions the
#     checker used to leave unchecked. A typed `let x: Int = "s"`, an assignment
#     `y = "s"` (for `let mut y = 1`), and `if c { 1 } else { "x" }` must all be
#     REJECTED; their well-typed counterparts must compile. (Iterative
#     check_expr spine — check_seq_spine — gives the stack headroom for these
#     extra checks during self-compile.)
echo "[selfhost-only-gate] 29/29 assignment / binding / if-branch / struct-field / local-let type checking"
tdir="_build/_gate_typecheck"
rm -rf "$tdir"; mkdir -p "$tdir"
cat > "$tdir/ok.vibe" <<'EOF'
export let x: Int = 5
export let _start: () -> Int = () -> {
  let mut y = 1
  y = 7
  y + (if true { 1 } else { 2 }) + x
}
EOF
cat > "$tdir/bad_let.vibe" <<'EOF'
export let x: Int = "hello"
export let _start: () -> Int = () -> { x }
EOF
cat > "$tdir/bad_assign.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let mut y = 1
  y = "str"
  y
}
EOF
cat > "$tdir/bad_if.vibe" <<'EOF'
export let _start: () -> Int = () -> { if true { 1 } else { "x" } }
EOF
cat > "$tdir/bad_struct.vibe" <<'EOF'
struct P { x: Int }
export let _start: () -> Int = () -> {
  let p = P::{ x: "oops" }
  0
}
EOF
cat > "$tdir/bad_locallet.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let x: Int = "hello"
  0
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/ok.vibe" "$tdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdir/ok.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: well-typed binding/assign/if did not compile (over-rejects)" >&2; exit 1
fi
for bad in bad_let bad_assign bad_if bad_struct bad_locallet; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$tdir/$bad.vibe" "$tdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$tdir/$bad.wasm" ]; then
    echo "[selfhost-only-gate] FAIL: ill-typed $bad compiled (type-check regressed)" >&2; exit 1
  fi
done
rm -rf "$tdir"
echo "[selfhost-only-gate] assignment / binding / if-branch / struct-field / local-let type checking ok"

# 30. `mut`-field write escape analysis (#418): assigning `obj.field = x` (which
#     desugars to `__set_field(obj, "field", x)`) is only legal when `field` was
#     declared `mut` in its struct. A write to a non-`mut` field must be
#     REJECTED; a write to a `mut` field (and a same-typed value) must compile.
echo "[selfhost-only-gate] 30/30 mut-field write escape analysis"
mdir="_build/_gate_mutfield"
rm -rf "$mdir"; mkdir -p "$mdir"
cat > "$mdir/ok_mut.vibe" <<'EOF'
struct Cell { mut n: Int }
export let _start: () -> Int = () -> {
  let c = Cell::{ n: 0 }
  c.n = 5
  c.n
}
EOF
cat > "$mdir/bad_nonmut.vibe" <<'EOF'
struct Frozen { x: Int }
export let _start: () -> Int = () -> {
  let p = Frozen::{ x: 1 }
  p.x = 9
  p.x
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mdir/ok_mut.vibe" "$mdir/ok_mut.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$mdir/ok_mut.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: mut-field write did not compile (over-rejects)" >&2
  cat "$mdir/ok_mut.wasm.diag" 2>/dev/null >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mdir/bad_nonmut.vibe" "$mdir/bad_nonmut.wasm" _start >/dev/null 2>&1 || true
if [ -s "$mdir/bad_nonmut.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: non-mut field write compiled (mut escape check regressed)" >&2; exit 1
fi
rm -rf "$mdir"
echo "[selfhost-only-gate] mut-field write escape analysis ok"

# 31. value-soundness probes (each was previously accepted silently): value-
#     yielding `match` arms must agree; array literal elements must share a type;
#     calling a non-function value, `!` on a non-Bool, and `for x in <scalar>`
#     must all be rejected. A `CtUnit` arm (statement-position match) and the
#     well-typed positives must still compile.
echo "[selfhost-only-gate] 31/31 match-arm / array / non-fn-call / unary-not / for-iterable type checking"
cdir="_build/_gate_consistency"
rm -rf "$cdir"; mkdir -p "$cdir"
cat > "$cdir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let a = [1, 2, 3]
  let m = match a[0] { 0 => 10, _ => 20 }
  Array::length(a) + m
}
EOF
cat > "$cdir/bad_match.vibe" <<'EOF'
export let _start: () -> Int = () -> { match 1 { 0 => 1, _ => "x" } }
EOF
cat > "$cdir/bad_array.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, "x", 3]; 0 }
EOF
cat > "$cdir/bad_call.vibe" <<'EOF'
export let _start: () -> Int = () -> { let x = 5; x(3) }
EOF
cat > "$cdir/bad_not.vibe" <<'EOF'
export let _start: () -> Bool = () -> { !5 }
EOF
cat > "$cdir/bad_forint.vibe" <<'EOF'
export let _start: () -> Int = () -> { for x in 5 { let _ = x; () }; 0 }
EOF
cat > "$cdir/bad_tuparity.vibe" <<'EOF'
export let _start: () -> Int = () -> { let t = (1, 2); let (a, b, c) = t; a }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir/ok.vibe" "$cdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir/ok.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: well-typed match/array did not compile (over-rejects)" >&2
  cat "$cdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
for bad in bad_match bad_array bad_call bad_not bad_forint bad_tuparity; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$cdir/$bad.vibe" "$cdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$cdir/$bad.wasm" ]; then
    echo "[selfhost-only-gate] FAIL: ill-typed $bad compiled (consistency check regressed)" >&2; exit 1
  fi
done
rm -rf "$cdir"
echo "[selfhost-only-gate] match-arm / array / non-fn-call / unary-not / for-iterable type checking ok"

echo "[selfhost-only-gate] ok"
