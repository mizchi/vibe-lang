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

echo "[selfhost-only-gate] ok"
