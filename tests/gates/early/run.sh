#!/usr/bin/env bash
# compiler-gate lane: early (#1849 / #2001 Phase 1).
# Invoked by scripts/compiler_gate.sh or directly:
#   bash tests/gates/early/run.sh
set -euo pipefail
# shellcheck source=../lib.sh
GATES_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck disable=SC1090
source "$GATES_LIB"
gate_resolve_stage2


# 4. multi-file compile regression (#594): the selfhost compiler must resolve
#    imports from the filesystem. collect_import_path once built import paths via
#    string interpolation, which a selfhost codegen bug rendered as garbage (only
#    hit by real `import` statements, which the merged/bundle selfbuild source
#    strips — so the fixpoint above does not exercise it). Compile a 2-file
#    program via the fresh stage2 (VIBE_FS_COMPILE) and assert it runs to 42.
echo "[compiler-gate] 4/4 multi-file FS-compile regression"
fsdir="_build/_gate_fscompile"
rm -rf "$fsdir"; mkdir -p "$fsdir"
printf 'export let add = (a: Int, b: Int) -> Int { a + b }\n' > "$fsdir/helper.vibe"
printf 'import ./helper.vibe { add }\nexport let _start = () -> Int { add(40, 2) }\n' > "$fsdir/main.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fsdir/main.vibe" "$fsdir/main.wasm" _start || true
if [ ! -s "$fsdir/main.wasm" ]; then
  echo "[compiler-gate] FAIL: multi-file FS-compile produced no wasm" >&2
  exit 1
fi
fsres="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$fsdir/main.wasm" 2>/dev/null | tr -dc '0-9')"
rm -rf "$fsdir"
if [ "$fsres" != "42" ]; then
  echo "[compiler-gate] FAIL: multi-file FS-compile sample returned '$fsres' (expected 42)" >&2
  exit 1
fi
echo "[compiler-gate] multi-file FS-compile ok (42)"

# 4b. deep-recursion effect resume regression (#737): a perform issued from a
#     RECURSIVE frame, handled by an in-language handler OUTSIDE the recursion
#     that bridges to a host builtin, used to deliver the FIRST resume's value
#     as the SECOND op's argument (deep-continuation resume corruption). The
#     merge lane works around nothing anymore (merge_sources is back on
#     `perform Fs::ReadFile`), so this program is the canary.
echo "[compiler-gate] 4b deep-recursion effect resume regression (#737)"
drdir="_build/_gate_deepresume"
rm -rf "$drdir"; mkdir -p "$drdir/d"
printf 'AAA' > "$drdir/a.txt"
printf 'BBB' > "$drdir/d/b.txt"
printf 'CCC' > "$drdir/d/c.txt"
cat > "$drdir/main.vibe" <<'VEOF'
effect FileIo {
  ReadFile(String) -> String
}

let rec walk = (path: String, depth: Int) -> String with FileIo {
  let source = perform FileIo::ReadFile(path)
  if depth <= 0 {
    source
  } else {
    let s1 = walk("_build/_gate_deepresume/d/b.txt", depth - 1)
    let s2 = walk("_build/_gate_deepresume/d/c.txt", depth - 1)
    "\{source}|\{s1}|\{s2}"
  }
}

export let _start: () -> Int with Fs = () -> {
  let out = handle {
    walk("_build/_gate_deepresume/a.txt", 1)
  } with FileIo {
    ReadFile(p) => resume(Fs::read_file(p))
  }
  if out == "AAA|BBB|CCC" {
    42
  } else {
    1
  }
}
VEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$drdir/main.vibe" "$drdir/main.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$drdir/main.wasm" ]; then
  echo "[compiler-gate] FAIL: deep-resume regression program did not compile" >&2
  cat "$drdir/main.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
drres="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$drdir/main.wasm" 2>/dev/null | tr -dc '0-9')"
rm -rf "$drdir"
if [ "$drres" != "42" ]; then
  echo "[compiler-gate] FAIL: deep-resume regression returned '$drres' (expected 42) — #737-class resume corruption" >&2
  exit 1
fi
echo "[compiler-gate] deep-recursion effect resume ok (42)"

# 4c. missing-import diagnostic regression (#831): a file that imports a path
#     which does not exist on disk used to crash raw -- `collect_sources_rec`
#     called the host `Fs::read_file` primitive unguarded on the (silently
#     best-effort-resolved) missing path, and a host-level ENOENT there is a
#     JS exception that crosses the wasm/JS boundary uncaught (not a guest
#     `Error` effect), printing a "[crash debug]" memory dump and aborting
#     instead of reporting a diagnostic. Assert the compile now fails
#     gracefully with a located "cannot resolve import" diagnostic and never
#     reaches the raw crash dump / host exception text.
echo "[compiler-gate] 4c missing-import diagnostic regression (#831)"
midir="_build/_gate_missing_import"
rm -rf "$midir"; mkdir -p "$midir"
cat > "$midir/main.vibe" <<'VEOF'
import ./does_not_exist.vibe { helper }

export let _start = () -> Int { helper(1) }
VEOF
mi_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$midir/main.vibe" "$midir/main.wasm" _start 2>&1)" || true
mi_wasm_produced=0
if [ -s "$midir/main.wasm" ]; then
  mi_wasm_produced=1
fi
mi_diag="$(cat "$midir/main.wasm.diag" 2>/dev/null || true)"
rm -rf "$midir"
if [ "$mi_wasm_produced" = "1" ]; then
  echo "[compiler-gate] FAIL: missing-import program compiled successfully (expected a diagnostic failure)" >&2
  exit 1
fi
if echo "$mi_out" | grep -q "crash debug"; then
  echo "[compiler-gate] FAIL: missing-import compile hit the raw crash-debug dump instead of a diagnostic" >&2
  echo "$mi_out" >&2
  exit 1
fi
if echo "$mi_out" | grep -qi "fs_read_file failed"; then
  echo "[compiler-gate] FAIL: missing-import compile leaked the raw fs_read_file host error instead of a diagnostic" >&2
  echo "$mi_out" >&2
  exit 1
fi
if ! echo "$mi_diag" | grep -qE '^line [0-9]+:[0-9]+: cannot resolve import .*does_not_exist\.vibe'; then
  echo "[compiler-gate] FAIL: missing-import diagnostic did not look like a located 'cannot resolve import' message: '$mi_diag'" >&2
  exit 1
fi
echo "[compiler-gate] missing-import diagnostic ok: $mi_diag"

# 5. test-block regression (#594): a file with only `test {}` blocks (no entry)
#    must compile to a valid module whose `_start` runs every test; a passing
#    file exits clean and a failing assert traps. Guards the codegen fix that
#    stopped exporting a nonexistent entry function (call/export index -1).
echo "[compiler-gate] 5/5 test-block compile+run regression"
tdir="_build/_gate_testblock"
rm -rf "$tdir"; mkdir -p "$tdir"
printf 'test "ok" {\n  assert_eq(2 + 2, 4)\n}\n' > "$tdir/pass_test.vibe"
printf 'test "bad" {\n  assert_eq(2 + 2, 5)\n}\n' > "$tdir/fail_test.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/pass_test.vibe" "$tdir/pass_test.wasm" __no_entry__ >/dev/null 2>&1
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/fail_test.vibe" "$tdir/fail_test.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$tdir/pass_test.wasm" ] || [ ! -s "$tdir/fail_test.wasm" ]; then
  echo "[compiler-gate] FAIL: test-block compile produced no wasm" >&2; exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$tdir/pass_test.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: passing test file did not run clean" >&2; exit 1
fi
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$tdir/fail_test.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: failing test file did not trap" >&2; exit 1
fi
rm -rf "$tdir"
echo "[compiler-gate] test-block regression ok"

# 6. normalize regression (#594): `vibe normalize` (VIBE_NORMALIZE=1) canonicalizes
#    a source file — DCE from exported roots + section layout — via the
#    in-compiler engine. Guards that a future seed keeps it working and
#    idempotent. The flat selfbuild source strips imports, so the fixpoint
#    above does not exercise the normalize entry; assert it directly.
#    (Module blocks were removed in #728; flatten coverage retired with them.)
echo "[compiler-gate] 6/6 normalize compile+run regression"
ndir="_build/_gate_normalize"
rm -rf "$ndir"; mkdir -p "$ndir"
printf 'let dead: () -> Int = () -> { 0 }\nlet helper: () -> Int = () -> { 1 }\nexport let run: () -> Int = () -> { helper() }\n' > "$ndir/in.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/in.vibe" "$ndir/out.vibe" >/dev/null 2>&1 || true
if [ ! -s "$ndir/out.vibe" ]; then
  echo "[compiler-gate] FAIL: normalize produced no output" >&2; exit 1
fi
# `dead` must be eliminated; `helper` (reached from the exported `run`) kept.
if grep -q "dead" "$ndir/out.vibe" || ! grep -q "helper" "$ndir/out.vibe"; then
  echo "[compiler-gate] FAIL: normalize DCE incorrect" >&2
  cat "$ndir/out.vibe" >&2; exit 1
fi
# Removed/guarded syntax must be refused by the CURRENT stage2 (the committed
# seed lags until the next bump, so these checks live here, not in the
# seed-driven normalize smoke): module blocks are removed (#728).
printf 'module m {\n  export let run: () -> Int = () -> { 1 }\n}\n' > "$ndir/reject_module.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/reject_module.vibe" "$ndir/reject_module.out.vibe" >/dev/null 2>&1 \
  && [ -s "$ndir/reject_module.out.vibe" ]; then
  echo "[compiler-gate] FAIL: module-block source was not rejected (#728)" >&2; exit 1
fi
# fn round-trip (ADR-0064 #727): normalize must KEEP `fn` declarations —
# including the `where` contract — in fn form (SFnDecl + printer support),
# not rewrite them to `let rec` + inlined asserts; and stay idempotent.
printf 'fn checked_inc(x: Int) -> Int where { requires: x >= 0, ensures: result > x } { x + 1 }\nexport fn run() -> Int { checked_inc(41) }\nexport { run }\n' > "$ndir/keep_fn.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/keep_fn.vibe" "$ndir/keep_fn.out.vibe" >/dev/null 2>&1 || true
if [ ! -s "$ndir/keep_fn.out.vibe" ]; then
  echo "[compiler-gate] FAIL: fn-bearing source was not normalized (#727)" >&2; exit 1
fi
if ! grep -q "fn checked_inc" "$ndir/keep_fn.out.vibe" \
  || ! grep -q "fn run" "$ndir/keep_fn.out.vibe" \
  || ! grep -q "where { requires:" "$ndir/keep_fn.out.vibe" \
  || ! grep -q "ensures:" "$ndir/keep_fn.out.vibe" \
  || grep -q "let rec checked_inc" "$ndir/keep_fn.out.vibe"; then
  echo "[compiler-gate] FAIL: normalize did not keep the fn + where form (#727)" >&2
  cat "$ndir/keep_fn.out.vibe" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/keep_fn.out.vibe" "$ndir/keep_fn.out2.vibe" >/dev/null 2>&1
if ! cmp -s "$ndir/keep_fn.out.vibe" "$ndir/keep_fn.out2.vibe"; then
  echo "[compiler-gate] FAIL: fn normalize not idempotent (#727)" >&2
  diff "$ndir/keep_fn.out.vibe" "$ndir/keep_fn.out2.vibe" >&2 || true; exit 1
fi
# Idempotency: normalize(normalize(x)) == normalize(x).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/out.vibe" "$ndir/out2.vibe" >/dev/null 2>&1
if ! cmp -s "$ndir/out.vibe" "$ndir/out2.vibe"; then
  echo "[compiler-gate] FAIL: normalize not idempotent" >&2; exit 1
fi
# Normalized output must still typecheck: compiling a copy with an entry
# must succeed.
cp "$ndir/out.vibe" "$ndir/compile.vibe"
printf '\nexport let _start: () -> Int = () -> { run() }\n' >> "$ndir/compile.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/compile.vibe" "$ndir/out.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$ndir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: normalized output does not compile" >&2
  cat "$ndir/compile.vibe" >&2; exit 1
fi
rm -rf "$ndir"
echo "[compiler-gate] normalize regression ok"

# 6b. contract package regression (#729): an index.vibei contract package must
#     resolve via a bare directory import (conformance-check + facade desugar,
#     end to end through the current stage2), and its internals must NOT be
#     importable from a different nearest-owner package (#897 / ADR-0070).
echo "[compiler-gate] 6b contract package + boundary regression (#729)"
cdir="_build/_gate_contract"
rm -rf "$cdir"; mkdir -p "$cdir/pkg"
printf 'import ./impl.vibe {}\nfn add(x: Int, y: Int) -> Int\n' > "$cdir/pkg/index.vpkg"
printf 'export fn add(x: Int, y: Int) -> Int { x + y }\n' > "$cdir/pkg/impl.vibe"
printf 'import ./pkg { add }\nexport let _start: () -> Int = () -> { add(40, 2) }\n' > "$cdir/ok.vibe"
# #749 canary: run this compile with a COLD persistent cache. The runner's
# module-init _start executes the same pipeline once before the real cli_main
# invoke; a first-pass failure is masked in the exit code but leaves a .diag
# beside the (valid) wasm the second pass writes. Cold-only ingestion rot
# (#740/#749 class) surfaces exactly there, so assert "no sidecar" too.
find "$ROOT_DIR/_build" -maxdepth 1 -type f -name "vibe_*" -delete 2>/dev/null || true
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir/ok.vibe" "$cdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: contract package import did not compile (#729)" >&2
  cat "$cdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
if [ -s "$cdir/ok.wasm.diag" ]; then
  echo "[compiler-gate] FAIL: cold contract compile left a stale .diag beside a valid wasm (#749 first-pass ingestion failure)" >&2
  cat "$cdir/ok.wasm.diag" >&2; exit 1
fi
printf 'import ./pkg/impl.vibe { add }\nexport let _start: () -> Int = () -> { add(40, 2) }\n' > "$cdir/bad.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir/bad.vibe" "$cdir/bad.wasm" _start >/dev/null 2>&1 \
  && [ -s "$cdir/bad.wasm" ]; then
  echo "[compiler-gate] FAIL: package-internal import crossed the boundary (#729)" >&2; exit 1
fi
if ! grep -q "package boundary" "$cdir/bad.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: boundary rejection lacks the expected diagnostic (#729)" >&2
  cat "$cdir/bad.wasm.diag" 2>/dev/null >&2; exit 1
fi
rm -rf "$cdir"
echo "[compiler-gate] contract package + boundary regression ok"

# 6b2. generic-struct contract arity regression (#829/#841 follow-up):
#      collect_impl_type_defs used to hardcode a struct's type-parameter
#      arity as 0 regardless of its actual `[T]` header, so a package
#      exporting `struct Box[T] { ... }` had no arity-correct way to declare
#      `type Box[T]` in its own contract (multiple #841 packages worked
#      around this by writing a nullary `type Box`, which is now WRONG and
#      must itself be rejected — the under-declared arity 0 no longer
#      matches the impl's real arity 1).
echo "[compiler-gate] 6b2 generic-struct contract arity regression (#829/#841)"
gsdir="_build/_gate_genstruct_contract"
rm -rf "$gsdir"; mkdir -p "$gsdir/pkg"
printf 'export struct Box[T] {\n  v: T\n}\n\nexport fn Box::wrap[T](v: T) -> Box[T] {\n  Box::{ v: v }\n}\n' > "$gsdir/pkg/box.vibe"
printf 'version 0.0.1\nimport ./box.vibe {}\ntype Box[T]\nfn Box::wrap[T](v: T) -> Box[T]\n' > "$gsdir/pkg/index.vibei"
printf 'import ./pkg { Box::wrap }\nexport let _start: () -> Int = () -> { 0 }\n' > "$gsdir/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gsdir/ok.vibe" "$gsdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$gsdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: contract-correct 'type Box[T]' arity was rejected (over-reject)" >&2
  cat "$gsdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
printf 'version 0.0.1\nimport ./box.vibe {}\ntype Box\nfn Box::wrap[T](v: T) -> Box[T]\n' > "$gsdir/pkg/index.vibei"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gsdir/ok.vibe" "$gsdir/bad.wasm" _start >/dev/null 2>&1 \
  && [ -s "$gsdir/bad.wasm" ]; then
  echo "[compiler-gate] FAIL: nullary 'type Box' contract for a struct Box[T] impl compiled (arity under-declaration not caught)" >&2; exit 1
fi
if ! grep -q "arity mismatch" "$gsdir/bad.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: struct arity mismatch rejection lacks the expected diagnostic" >&2
  cat "$gsdir/bad.wasm.diag" 2>/dev/null >&2; exit 1
fi
rm -rf "$gsdir"
echo "[compiler-gate] generic-struct contract arity regression ok"

# 6b2b. explicit struct type arguments (#886): `Pair[Int]::{ .. }` pins the
#      instantiation (parse + arity check + checker pinning). Positive: the
#      explicit form compiles and runs, including a field inference alone
#      cannot decide (empty array). Negatives: a type-argument arity mismatch
#      and a field value conflicting with the pinned argument must both be
#      rejected with their dedicated diagnostics (not a generic parse error).
echo "[compiler-gate] 6b2b explicit struct type args (#886)"
stdir="_build/_gate_struct_targs"
rm -rf "$stdir"; mkdir -p "$stdir"
printf 'struct Pair[T] {\n  a: T;\n  b: T\n}\n\nstruct Bag[T] {\n  xs: Array[T]\n}\n\nexport let _start: () -> Unit with Stdout = () -> {\n  let p = Pair[Int]::{ a: 1, b: 2 }\n  assert_eq(p.a + p.b, 3)\n  let g = Bag[Int]::{ xs: [] }\n  Array::push(g.xs, 42)\n  assert_eq(Array::get(g.xs, 0), 42)\n  let n = Pair[Array[Int]]::{ a: [1, 2], b: [] }\n  assert_eq(Array::length(n.a), 2)\n}\n' > "$stdir/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$stdir/ok.vibe" "$stdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$stdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: explicit struct type args (#886) did not compile" >&2
  cat "$stdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$stdir/ok.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: explicit struct type args (#886) compiled but trapped at runtime" >&2; exit 1
fi
printf 'struct Pair[T] {\n  a: T;\n  b: T\n}\n\nexport let _start: () -> Unit with Stdout = () -> {\n  let p = Pair[Int, String]::{ a: 1, b: 2 }\n  assert_eq(p.a, 1)\n}\n' > "$stdir/arity.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$stdir/arity.vibe" "$stdir/arity.wasm" _start >/dev/null 2>&1 \
  && [ -s "$stdir/arity.wasm" ]; then
  echo "[compiler-gate] FAIL: struct type-arg arity mismatch (#886) was not rejected" >&2; exit 1
fi
if ! grep -q "expects 1 type argument(s), got 2" "$stdir/arity.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: type-arg arity rejection lacks the expected diagnostic (#886)" >&2
  cat "$stdir/arity.wasm.diag" 2>/dev/null >&2; exit 1
fi
printf 'struct Pair[T] {\n  a: T;\n  b: T\n}\n\nexport let _start: () -> Unit with Stdout = () -> {\n  let p = Pair[String]::{ a: 1, b: 2 }\n  assert_eq(p.a, "x")\n}\n' > "$stdir/pin.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$stdir/pin.vibe" "$stdir/pin.wasm" _start >/dev/null 2>&1 \
  && [ -s "$stdir/pin.wasm" ]; then
  echo "[compiler-gate] FAIL: field value conflicting with pinned type arg (#886) was not rejected" >&2; exit 1
fi
if ! grep -q "struct field type mismatch for a" "$stdir/pin.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: pinned-arg field mismatch rejection lacks the expected diagnostic (#886)" >&2
  cat "$stdir/pin.wasm.diag" 2>/dev/null >&2; exit 1
fi
rm -rf "$stdir"
echo "[compiler-gate] explicit struct type args (#886) ok"

# 6b3. cross-package contract import resolution regression (#842): a bare
#      directory-style import inside an index.vibei CONTRACT (not just an
#      implementation .vibe file) must resolve to the sibling package's own
#      index.vibei/index.vibe, the same directory-first order the regular
#      loader uses -- desugar_contract_source_fs used to skip straight to the
#      single-file form (`../pkgb.vibe`) and ENOENT. package A's contract
#      references package B's opaque type by NAME (`import ../pkgb { type X }`)
#      instead of the #841-era workaround (referencing the bare name with no
#      import at all); the cross-package .vibei target must also be routed
#      through the normal facade desugar (not parsed as raw contract grammar).
echo "[compiler-gate] 6b3 cross-package contract import resolution regression (#842)"
xpdir="_build/_gate_contract_crosspkg"
rm -rf "$xpdir"; mkdir -p "$xpdir/pkgb" "$xpdir/pkga"
printf 'import ./impl.vibe {}\nopaque type X\nfn make(v: Int) -> X\nfn value(x: X) -> Int\n' > "$xpdir/pkgb/index.vibei"
printf 'export struct X {\n  v: Int\n}\n\nexport fn make(v: Int) -> X {\n  X::{ v: v }\n}\n\nexport fn value(x: X) -> Int {\n  x.v\n}\n' > "$xpdir/pkgb/impl.vibe"
printf 'import ./impl.vibe {}\nimport ../pkgb { type X }\nfn wrap(v: Int) -> X\n' > "$xpdir/pkga/index.vibei"
printf 'import ../pkgb { X, make }\nexport fn wrap(v: Int) -> X {\n  make(v)\n}\n' > "$xpdir/pkga/impl.vibe"
printf 'import ./pkga { wrap }\nimport ./pkgb { value }\nexport let _start: () -> Int = () -> { value(wrap(42)) }\n' > "$xpdir/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xpdir/ok.vibe" "$xpdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xpdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: .vibei contract's cross-package directory import (../pkgb) did not resolve (#842)" >&2
  cat "$xpdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
xpres="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$xpdir/ok.wasm" 2>/dev/null | tr -dc '0-9')"
rm -rf "$xpdir"
if [ "$xpres" != "42" ]; then
  echo "[compiler-gate] FAIL: cross-package contract import sample returned '$xpres' (expected 42)" >&2
  exit 1
fi
echo "[compiler-gate] cross-package contract import resolution regression ok"

# 6c. content-addressed store regression (#730 D-2): `vibe hash` prints a
#     store package's pin; a require-pinned `import @scope/name` resolves
#     through .vibe/store/ with hash verification; a wrong pin is rejected.
echo "[compiler-gate] 6c content-addressed store regression (#730)"
sdir=".vibe/store/@gate/d2pkg"
rm -rf ".vibe/store/@gate"; mkdir -p "$sdir"
printf 'import ./impl.vibe {}\nfn triple(x: Int) -> Int\n' > "$sdir/index.vibei"
printf 'export fn triple(x: Int) -> Int { x * 3 }\n' > "$sdir/impl.vibe"
cdir2="_build/_gate_store"
rm -rf "$cdir2"; mkdir -p "$cdir2"
VIBE_HASH=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$sdir/index.vibei" "$cdir2/hash.out" __no_entry__ >/dev/null 2>&1 || true
pin="$(grep '^package ' "$cdir2/hash.out" 2>/dev/null | cut -d' ' -f2)"
if [ -z "$pin" ]; then
  echo "[compiler-gate] FAIL: vibe hash produced no package pin (#730)" >&2
  cat "$cdir2/hash.out.diag" 2>/dev/null >&2; exit 1
fi
printf 'require @gate/d2pkg 1.0.0 = %s\n\nimport @gate/d2pkg { triple }\nexport let _start: () -> Int = () -> { triple(14) }\n' "$pin" > "$cdir2/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/ok.vibe" "$cdir2/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir2/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: pinned store import did not compile (#730)" >&2
  cat "$cdir2/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
printf 'require @gate/d2pkg 1.0.0 = #pkg:sha1:0000000000000000000000000000000000000000\n\nimport @gate/d2pkg { triple }\nexport let _start: () -> Int = () -> { triple(14) }\n' > "$cdir2/bad.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/bad.vibe" "$cdir2/bad.wasm" _start >/dev/null 2>&1 \
  && [ -s "$cdir2/bad.wasm" ]; then
  echo "[compiler-gate] FAIL: wrong pin was not rejected (#730)" >&2; exit 1
fi
if ! grep -q "pin mismatch" "$cdir2/bad.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: pin rejection lacks the expected diagnostic (#730)" >&2
  cat "$cdir2/bad.wasm.diag" 2>/dev/null >&2; exit 1
fi
# D-3: an unpinned require refuses to build; VIBE_FILL_PINS completes it
# offline from the store; the filled source builds; the fill is idempotent.
printf 'require @gate/d2pkg 1.0.0\n\nimport @gate/d2pkg { triple }\nexport let _start: () -> Int = () -> { triple(14) }\n' > "$cdir2/unpinned.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/unpinned.vibe" "$cdir2/unpinned.wasm" _start >/dev/null 2>&1 \
  && [ -s "$cdir2/unpinned.wasm" ]; then
  echo "[compiler-gate] FAIL: unpinned require was not rejected (#730 D-3)" >&2; exit 1
fi
VIBE_FILL_PINS=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/unpinned.vibe" "$cdir2/filled.vibe" __no_entry__ >/dev/null 2>&1 || true
if ! grep -q "= #pkg:sha1:" "$cdir2/filled.vibe" 2>/dev/null; then
  echo "[compiler-gate] FAIL: VIBE_FILL_PINS did not insert the pin (#730 D-3)" >&2
  cat "$cdir2/filled.vibe.diag" 2>/dev/null >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/filled.vibe" "$cdir2/filled.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir2/filled.wasm" ]; then
  echo "[compiler-gate] FAIL: pin-filled source did not compile (#730 D-3)" >&2
  cat "$cdir2/filled.wasm.diag" 2>/dev/null >&2; exit 1
fi
VIBE_NORMALIZE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/filled.vibe" "$cdir2/norm.vibe" >/dev/null 2>&1 || true
if ! head -1 "$cdir2/norm.vibe" 2>/dev/null | grep -q "^require @gate/d2pkg 1.0.0 = #pkg:sha1:"; then
  echo "[compiler-gate] FAIL: normalize did not re-emit the require pin line (#730 D-3)" >&2
  head -3 "$cdir2/norm.vibe" 2>/dev/null >&2; exit 1
fi
rm -rf ".vibe/store/@gate" "$cdir2"
echo "[compiler-gate] content-addressed store regression ok"

# 6h. workspace lib/ package resolution (#751, ADR-0065): `@scope/name`
#     resolves through lib/@scope/name/index.vibei WITHOUT a require pin
#     (dev-mode lane; the pinned store stays first in candidate order). A pin,
#     when present, is still the truth: a wrong pin against the lib/ copy is
#     rejected. The package below declares no impl imports, so this also
#     exercises sibling auto-discovery (#730) through the lib/ path.
echo "[compiler-gate] 6h workspace lib/ package resolution (#751)"
lpkg="lib/@gate751/greet"
rm -rf "lib/@gate751"; mkdir -p "$lpkg"
printf 'fn greet_n(x: Int) -> Int\n' > "$lpkg/index.vibei"
printf 'export fn greet_n(x: Int) -> Int { x + 2 }\n' > "$lpkg/impl.vibe"
ldir="_build/_gate_lib751"
rm -rf "$ldir"; mkdir -p "$ldir"
printf 'import @gate751/greet { greet_n }\nexport let _start: () -> Int = () -> { greet_n(40) }\n' > "$ldir/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ldir/ok.vibe" "$ldir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$ldir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: unpinned lib/ package import did not compile (#751)" >&2
  cat "$ldir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
printf 'require @gate751/greet 1.0.0 = #pkg:sha1:0000000000000000000000000000000000000000\n\nimport @gate751/greet { greet_n }\nexport let _start: () -> Int = () -> { greet_n(40) }\n' > "$ldir/bad.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ldir/bad.vibe" "$ldir/bad.wasm" _start >/dev/null 2>&1 \
  && [ -s "$ldir/bad.wasm" ]; then
  echo "[compiler-gate] FAIL: wrong pin against a lib/ copy was not rejected (#751)" >&2; exit 1
fi
if ! grep -q "pin mismatch" "$ldir/bad.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: lib/ pin rejection lacks the expected diagnostic (#751)" >&2
  cat "$ldir/bad.wasm.diag" 2>/dev/null >&2; exit 1
fi
rm -rf "lib/@gate751" "$ldir"
echo "[compiler-gate] workspace lib/ package resolution ok"

# 6i. VIBE_LIB external roots + freeze (#751, ADR-0065): an @scope/name
#     package living OUTSIDE the workspace resolves through a VIBE_LIB root
#     (":"-separated list; missing roots are skipped in order). The
#     workspace lib/ copy wins over an external root when both exist, and
#     VIBE_REQUIRE_PINS=1 (the release/publish freeze switch) rejects any
#     pin-less dev-mode lib resolution. Each step uses a distinct consumer
#     file: the persistent header/dep caches key on content, and the SAME
#     content under a different VIBE_LIB would replay the previous
#     resolution.
echo "[compiler-gate] 6i VIBE_LIB external roots + freeze (#751)"
xroot="$(mktemp -d)"
xpkg="$xroot/@gate751x/echo"
mkdir -p "$xpkg"
printf 'fn echo_n(x: Int) -> Int\n' > "$xpkg/index.vibei"
printf 'export fn echo_n(x: Int) -> Int { x + 2 }\n' > "$xpkg/impl.vibe"
xdir="_build/_gate_lib751x"
rm -rf "$xdir" "lib/@gate751x"; mkdir -p "$xdir"
# (1) without a usable root the name must NOT resolve
printf 'import @gate751x/echo { echo_n }\nexport let _start: () -> Int = () -> { echo_n(40) }\n' > "$xdir/miss.vibe"
if VIBE_LIB="$xroot/does-not-exist" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/miss.vibe" "$xdir/miss.wasm" _start >/dev/null 2>&1 \
  && [ -s "$xdir/miss.wasm" ]; then
  echo "[compiler-gate] FAIL: external package resolved without a VIBE_LIB root (#751)" >&2; exit 1
fi
# (2) a ":"-separated VIBE_LIB resolves through the first root that has the
#     package (missing roots skipped); the compiled program runs.
printf 'import @gate751x/echo { echo_n }\nexport let _start: () -> Int = () -> { echo_n(40) + 0 }\n' > "$xdir/ext.vibe"
VIBE_LIB="$xroot/does-not-exist:$xroot" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/ext.vibe" "$xdir/ext.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xdir/ext.wasm" ]; then
  echo "[compiler-gate] FAIL: VIBE_LIB root resolution did not compile (#751)" >&2
  cat "$xdir/ext.wasm.diag" 2>/dev/null >&2; exit 1
fi
ext_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$xdir/ext.wasm" 2>/dev/null | tail -1)"
if [ "$ext_out" != "42" ]; then
  echo "[compiler-gate] FAIL: VIBE_LIB-resolved package returned '$ext_out' (want 42) (#751)" >&2; exit 1
fi
# (3) the workspace lib/ copy wins over the external root
mkdir -p "lib/@gate751x/echo"
printf 'fn echo_n(x: Int) -> Int\n' > "lib/@gate751x/echo/index.vibei"
printf 'export fn echo_n(x: Int) -> Int { x + 3 }\n' > "lib/@gate751x/echo/impl.vibe"
printf 'import @gate751x/echo { echo_n }\nexport let _start: () -> Int = () -> { echo_n(40) + 0 + 0 }\n' > "$xdir/ws.vibe"
VIBE_LIB="$xroot/does-not-exist:$xroot" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/ws.vibe" "$xdir/ws.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xdir/ws.wasm" ]; then
  echo "[compiler-gate] FAIL: workspace-precedence consumer did not compile (#751)" >&2
  cat "$xdir/ws.wasm.diag" 2>/dev/null >&2; exit 1
fi
ws_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$xdir/ws.wasm" 2>/dev/null | tail -1)"
if [ "$ws_out" != "43" ]; then
  echo "[compiler-gate] FAIL: workspace lib/ did not win over VIBE_LIB root (got '$ws_out', want 43) (#751)" >&2; exit 1
fi
# (4) freeze: VIBE_REQUIRE_PINS=1 demands a pin for any dev-mode lib lane
printf 'import @gate751x/echo { echo_n }\nexport let _start: () -> Int = () -> { echo_n(40) + 0 + 0 + 0 }\n' > "$xdir/frz.vibe"
if VIBE_REQUIRE_PINS=1 VIBE_LIB="$xroot" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/frz.vibe" "$xdir/frz.wasm" _start >/dev/null 2>&1 \
  && [ -s "$xdir/frz.wasm" ]; then
  echo "[compiler-gate] FAIL: pin-less lib resolution was allowed under VIBE_REQUIRE_PINS=1 (#751)" >&2; exit 1
fi
if ! grep -q "pin required" "$xdir/frz.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: freeze rejection lacks the expected diagnostic (#751)" >&2
  cat "$xdir/frz.wasm.diag" 2>/dev/null >&2; exit 1
fi
# (5) #758 review (P1): a resolved graph cached under one environment must
#     NOT replay under another — the SAME consumer content is compiled
#     across env changes (previously the persistent source/header caches
#     keyed on content only, so a pin-less graph warmed without freeze was
#     replayed under VIBE_REQUIRE_PINS=1, and a removed VIBE_LIB root kept
#     resolving).
rm -rf "lib/@gate751x"
printf 'import @gate751x/echo { echo_n }\nexport let _start: () -> Int = () -> { echo_n(38) }\n' > "$xdir/replay.vibe"
VIBE_LIB="$xroot" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/replay.vibe" "$xdir/replay1.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xdir/replay1.wasm" ]; then
  echo "[compiler-gate] FAIL: replay warm-up compile failed (#758)" >&2
  cat "$xdir/replay1.wasm.diag" 2>/dev/null >&2; exit 1
fi
if VIBE_LIB="$xroot/does-not-exist" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/replay.vibe" "$xdir/replay2.wasm" _start >/dev/null 2>&1 \
  && [ -s "$xdir/replay2.wasm" ]; then
  echo "[compiler-gate] FAIL: warm cache replayed a removed VIBE_LIB root (#758)" >&2; exit 1
fi
if VIBE_REQUIRE_PINS=1 VIBE_LIB="$xroot" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/replay.vibe" "$xdir/replay3.wasm" _start >/dev/null 2>&1 \
  && [ -s "$xdir/replay3.wasm" ]; then
  echo "[compiler-gate] FAIL: warm cache bypassed VIBE_REQUIRE_PINS=1 (#758)" >&2; exit 1
fi
if ! grep -q "pin required" "$xdir/replay3.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: freeze-under-warm-cache rejection lacks the expected diagnostic (#758)" >&2
  cat "$xdir/replay3.wasm.diag" 2>/dev/null >&2; exit 1
fi
rm -rf "$xdir" "$xroot"
echo "[compiler-gate] VIBE_LIB external roots + freeze ok"

# 6j. distribution pipeline (#754, ADR-0065 Phase 4): publish (version
#     directive + semver gate) -> fetch cache (CAS keyed by package hash +
#     versions.tsv) -> materialize into $VIBE_HOME/lib (the default VIBE_LIB
#     root) -> name resolution -> build&run; then the pinned store lane
#     under freeze; then the two rejections that make version->hash an
#     immutable mapping (same-version republish; dishonest semver claim).
echo "[compiler-gate] 6j distribution pipeline: publish/cache/materialize (#754)"
jhome="$(mktemp -d)"
jsrc="$jhome/src/@gate754/mathx"
mkdir -p "$jsrc"
printf 'version 1.0.0\n\nfn quad(x: Int) -> Int\n' > "$jsrc/index.vibei"
printf 'export fn quad(x: Int) -> Int { x * 4 }\n' > "$jsrc/impl.vibe"
jdir="_build/_gate_pkg754"
rm -rf "$jdir" ".vibe/store/@gate754"; mkdir -p "$jdir"
if ! VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$jsrc" > "$jdir/pub1.log" 2>&1; then
  echo "[compiler-gate] FAIL: publish of @gate754/mathx@1.0.0 failed (#754)" >&2
  cat "$jdir/pub1.log" >&2; exit 1
fi
if ! grep -q "@gate754/mathx@1.0.0" "$jhome/cache/versions.tsv" 2>/dev/null; then
  echo "[compiler-gate] FAIL: publish did not record the version mapping (#754)" >&2; exit 1
fi
if ! VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate754/mathx@1.0.0" > "$jdir/inst1.log" 2>&1; then
  echo "[compiler-gate] FAIL: install/materialize into VIBE_HOME/lib failed (#754)" >&2
  cat "$jdir/inst1.log" >&2; exit 1
fi
printf 'import @gate754/mathx { quad }\nexport let _start: () -> Int = () -> { quad(11) }\n' > "$jdir/use.vibe"
VIBE_HOME="$jhome" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$jdir/use.vibe" "$jdir/use.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$jdir/use.wasm" ]; then
  echo "[compiler-gate] FAIL: materialized package did not resolve via VIBE_HOME default root (#754)" >&2
  cat "$jdir/use.wasm.diag" 2>/dev/null >&2; exit 1
fi
juse_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$jdir/use.wasm" 2>/dev/null | tail -1)"
if [ "$juse_out" != "44" ]; then
  echo "[compiler-gate] FAIL: materialized package returned '$juse_out' (want 44) (#754)" >&2; exit 1
fi
# pinned store lane under freeze: install --store, consumer carries the pin
if ! VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate754/mathx@1.0.0" --store > "$jdir/inst2.log" 2>&1; then
  echo "[compiler-gate] FAIL: install --store failed (#754)" >&2
  cat "$jdir/inst2.log" >&2; exit 1
fi
jhash="$(awk -F'\t' '$1 == "@gate754/mathx@1.0.0" { print $2 }' "$jhome/cache/versions.tsv")"
printf 'require @gate754/mathx 1.0.0 = #%s\n\nimport @gate754/mathx { quad }\nexport let _start: () -> Int = () -> { quad(11) + 0 }\n' "$jhash" > "$jdir/pinned.vibe"
VIBE_REQUIRE_PINS=1 VIBE_HOME="$jhome" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$jdir/pinned.vibe" "$jdir/pinned.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$jdir/pinned.wasm" ]; then
  echo "[compiler-gate] FAIL: pinned store build under VIBE_REQUIRE_PINS=1 failed (#754)" >&2
  cat "$jdir/pinned.wasm.diag" 2>/dev/null >&2; exit 1
fi
# same-version republish with different content must be rejected
printf 'export fn quad(x: Int) -> Int { x * 5 }\n' > "$jsrc/impl.vibe"
if VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$jsrc" > "$jdir/pub2.log" 2>&1; then
  echo "[compiler-gate] FAIL: same-version republish was accepted (#754)" >&2; exit 1
fi
if ! grep -q "same-version republish rejected" "$jdir/pub2.log"; then
  echo "[compiler-gate] FAIL: republish rejection lacks the expected message (#754)" >&2
  cat "$jdir/pub2.log" >&2; exit 1
fi
# dishonest bump: surface grows but only the patch level is bumped
printf 'version 1.0.1\n\nfn quad(x: Int) -> Int\nfn oct(x: Int) -> Int\n' > "$jsrc/index.vibei"
printf 'export fn quad(x: Int) -> Int { x * 4 }\nexport fn oct(x: Int) -> Int { x * 8 }\n' > "$jsrc/impl.vibe"
if VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$jsrc" > "$jdir/pub3.log" 2>&1; then
  echo "[compiler-gate] FAIL: dishonest patch bump was accepted by publish (#754)" >&2; exit 1
fi
# honest minor bump passes (versions come from the directives, no env)
printf 'version 1.1.0\n\nfn quad(x: Int) -> Int\nfn oct(x: Int) -> Int\n' > "$jsrc/index.vibei"
if ! VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$jsrc" > "$jdir/pub4.log" 2>&1; then
  echo "[compiler-gate] FAIL: honest minor bump was rejected by publish (#754)" >&2
  cat "$jdir/pub4.log" >&2; exit 1
fi
rm -rf ".vibe/store/@gate754" "$jdir" "$jhome"
echo "[compiler-gate] distribution pipeline ok"

# 6k. registry-less git resolution (#755 Phase 0): `vibe_pkg.sh add` fetches
#     a package from a git source (github: is sugar over the same path),
#     resolves the ref to a COMMIT (provenance), hashes the fetched sources
#     LOCALLY, and installs only when the hash agrees with the expected pin
#     (or records it trust-on-first-use). A hermetic file:// repo stands in
#     for GitHub; the tamper step re-serves the same version with different
#     content and must be rejected by the version->hash record.
echo "[compiler-gate] 6k registry-less git resolution (#755 Phase 0)"
khome="$(mktemp -d)"
krepo="$(mktemp -d)"
kdir="_build/_gate_pkg755"
rm -rf "$kdir"; mkdir -p "$kdir"
mkdir -p "$krepo/packages/@gate755/hex"
printf 'version 1.0.0\n\nfn hex_n(x: Int) -> Int\n' > "$krepo/packages/@gate755/hex/index.vibei"
printf 'export fn hex_n(x: Int) -> Int { x + 6 }\n' > "$krepo/packages/@gate755/hex/impl.vibe"
git -C "$krepo" init -q
git -C "$krepo" add -A
git -C "$krepo" -c user.email=gate@vibe -c user.name=gate commit -qm pkg
git -C "$krepo" branch -m main
kspec="git:file://$krepo@main#packages/@gate755/hex"
# (1) TOFU add: fetch, record, materialize into $VIBE_HOME/lib; consumer runs
if ! VIBE_HOME="$khome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh add "$kspec" > "$kdir/add1.log" 2>&1; then
  echo "[compiler-gate] FAIL: git add (TOFU) failed (#755)" >&2
  cat "$kdir/add1.log" >&2; exit 1
fi
khash="$(awk -F'\t' '$1 == "@gate755/hex@1.0.0" { print $2 }' "$khome/cache/versions.tsv")"
if [ -z "$khash" ]; then
  echo "[compiler-gate] FAIL: git add did not record the version mapping (#755)" >&2; exit 1
fi
if ! grep -q "@gate755/hex@1.0.0" "$khome/cache/provenance.tsv" 2>/dev/null; then
  echo "[compiler-gate] FAIL: git add did not record provenance (#755)" >&2; exit 1
fi
printf 'import @gate755/hex { hex_n }\nexport let _start: () -> Int = () -> { hex_n(36) }\n' > "$kdir/use.vibe"
VIBE_HOME="$khome" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$kdir/use.vibe" "$kdir/use.wasm" _start >/dev/null 2>&1 || true
kuse_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$kdir/use.wasm" 2>/dev/null | tail -1)"
if [ "$kuse_out" != "42" ]; then
  echo "[compiler-gate] FAIL: git-added package returned '$kuse_out' (want 42) (#755)" >&2; exit 1
fi
# (2) wrong expected pin rejects BEFORE any side effect (fresh home)
khome2="$(mktemp -d)"
if VIBE_HOME="$khome2" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh add "$kspec" "#pkg:sha1:0000000000000000000000000000000000000000" > "$kdir/add2.log" 2>&1; then
  echo "[compiler-gate] FAIL: wrong expected pin was accepted (#755)" >&2; exit 1
fi
if ! grep -q "hash mismatch" "$kdir/add2.log" || [ -f "$khome2/cache/versions.tsv" ]; then
  echo "[compiler-gate] FAIL: pin rejection is wrong or left side effects (#755)" >&2
  cat "$kdir/add2.log" >&2; exit 1
fi
# (3) correct expected pin verifies a fresh fetch
if ! VIBE_HOME="$khome2" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh add "$kspec" "#$khash" > "$kdir/add3.log" 2>&1; then
  echo "[compiler-gate] FAIL: correct expected pin was rejected (#755)" >&2
  cat "$kdir/add3.log" >&2; exit 1
fi
# (4) upstream tampers: same version, different content -> rejected by the
#     local version->hash record
printf 'export fn hex_n(x: Int) -> Int { x + 7 }\n' > "$krepo/packages/@gate755/hex/impl.vibe"
git -C "$krepo" add -A
git -C "$krepo" -c user.email=gate@vibe -c user.name=gate commit -qm tamper
if VIBE_HOME="$khome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh add "$kspec" > "$kdir/add4.log" 2>&1; then
  echo "[compiler-gate] FAIL: tampered same-version fetch was accepted (#755)" >&2; exit 1
fi
if ! grep -q "version->hash is immutable" "$kdir/add4.log"; then
  echo "[compiler-gate] FAIL: tamper rejection lacks the expected message (#755)" >&2
  cat "$kdir/add4.log" >&2; exit 1
fi
rm -rf "$kdir" "$khome" "$khome2" "$krepo"
echo "[compiler-gate] registry-less git resolution ok"

# 6l. registry transparency log + yank (#805, ADR-0065 Phase 5 minimal
#     slice): publish appends an ordinal record to $VIBE_HOME/log/records.tsv
#     and maintains a Merkle head; install verifies (a) the served head
#     commits to the served records (tamper check), (b) prefix consistency
#     against the last head this client saw (the log may only ever extend),
#     and (c) an inclusion proof for the claimed name@version -> hash record
#     against the head root. yank is an append-only marking that install
#     refuses without --allow-yanked while versions.tsv (the immutable
#     version->hash mapping) stays untouched. The log dir is static files:
#     VIBE_REGISTRY_LOG_DIR points a client at a served copy.
echo "[compiler-gate] 6l registry transparency log + yank (#805)"
lhome805="$(mktemp -d)"
lsrc805="$lhome805/src/@gate805/logx"
mkdir -p "$lsrc805"
printf 'version 1.0.0\n\nfn triple(x: Int) -> Int\n' > "$lsrc805/index.vibei"
printf 'export fn triple(x: Int) -> Int { x * 3 }\n' > "$lsrc805/impl.vibe"
ldir805="_build/_gate_pkg805"
rm -rf "$ldir805"; mkdir -p "$ldir805"
# (1) publish appends a publish record and writes a merkle head
if ! VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$lsrc805" > "$ldir805/pub1.log" 2>&1; then
  echo "[compiler-gate] FAIL: publish of @gate805/logx@1.0.0 failed (#805)" >&2
  cat "$ldir805/pub1.log" >&2; exit 1
fi
if ! awk -F'\t' '$1 == "0" && $2 == "publish" && $3 == "@gate805/logx@1.0.0"' "$lhome805/log/records.tsv" 2>/dev/null | grep -q .; then
  echo "[compiler-gate] FAIL: publish did not append a transparency-log record (#805)" >&2
  cat "$lhome805/log/records.tsv" 2>/dev/null >&2; exit 1
fi
if [ ! -s "$lhome805/log/head" ]; then
  echo "[compiler-gate] FAIL: publish did not write a merkle head (#805)" >&2; exit 1
fi
cp "$lhome805/log/records.tsv" "$ldir805/log1.records"
cp "$lhome805/log/head" "$ldir805/log1.head"
# (2) a second publish extends the log; install verifies an inclusion proof
printf 'version 1.1.0\n\nfn triple(x: Int) -> Int\nfn nona(x: Int) -> Int\n' > "$lsrc805/index.vibei"
printf 'export fn triple(x: Int) -> Int { x * 3 }\nexport fn nona(x: Int) -> Int { x * 9 }\n' > "$lsrc805/impl.vibe"
if ! VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$lsrc805" > "$ldir805/pub2.log" 2>&1; then
  echo "[compiler-gate] FAIL: publish of @gate805/logx@1.1.0 failed (#805)" >&2
  cat "$ldir805/pub2.log" >&2; exit 1
fi
if [ "$(wc -l < "$lhome805/log/records.tsv" | tr -d '[:space:]')" != "2" ]; then
  echo "[compiler-gate] FAIL: second publish did not extend the log to 2 records (#805)" >&2
  cat "$lhome805/log/records.tsv" >&2; exit 1
fi
if ! VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate805/logx@1.0.0" > "$ldir805/inst1.log" 2>&1; then
  echo "[compiler-gate] FAIL: install of a logged version failed (#805)" >&2
  cat "$ldir805/inst1.log" >&2; exit 1
fi
if ! grep -q "inclusion verified for @gate805/logx@1.0.0" "$ldir805/inst1.log"; then
  echo "[compiler-gate] FAIL: install did not verify the log inclusion proof (#805)" >&2
  cat "$ldir805/inst1.log" >&2; exit 1
fi
cp "$lhome805/log/records.tsv" "$ldir805/log2.records"
cp "$lhome805/log/head" "$ldir805/log2.head"
# (3) same-version republish with different content is still rejected — and
#     the rejected publish must NOT grow the log
printf 'export fn triple(x: Int) -> Int { x * 3 + 1 }\nexport fn nona(x: Int) -> Int { x * 9 }\n' > "$lsrc805/impl.vibe"
if VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$lsrc805" > "$ldir805/pub3.log" 2>&1; then
  echo "[compiler-gate] FAIL: same-version republish was accepted (#805)" >&2; exit 1
fi
if ! grep -q "same-version republish rejected" "$ldir805/pub3.log"; then
  echo "[compiler-gate] FAIL: republish rejection lacks the expected message (#805)" >&2
  cat "$ldir805/pub3.log" >&2; exit 1
fi
if [ "$(wc -l < "$lhome805/log/records.tsv" | tr -d '[:space:]')" != "2" ]; then
  echo "[compiler-gate] FAIL: a rejected republish grew the transparency log (#805)" >&2; exit 1
fi
# (4) a tampered log head is detected before anything installs
sed 's/\t/\tf00dfeed/' "$ldir805/log2.head" > "$lhome805/log/head"
if VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate805/logx@1.1.0" > "$ldir805/inst2.log" 2>&1; then
  echo "[compiler-gate] FAIL: install accepted a tampered log head (#805)" >&2; exit 1
fi
if ! grep -q "tampered log head" "$ldir805/inst2.log"; then
  echo "[compiler-gate] FAIL: tampered-head rejection lacks the expected message (#805)" >&2
  cat "$ldir805/inst2.log" >&2; exit 1
fi
cp "$ldir805/log2.head" "$lhome805/log/head"
# (5) append-only consistency: rolling the log back to its (self-consistent)
#     1-record state must be refused by a client that already saw 2 records
cp "$ldir805/log1.records" "$lhome805/log/records.tsv"
cp "$ldir805/log1.head" "$lhome805/log/head"
if VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate805/logx@1.0.0" > "$ldir805/inst3.log" 2>&1; then
  echo "[compiler-gate] FAIL: install accepted a truncated (rolled-back) log (#805)" >&2; exit 1
fi
if ! grep -q "log consistency violation" "$ldir805/inst3.log"; then
  echo "[compiler-gate] FAIL: truncation rejection lacks the expected message (#805)" >&2
  cat "$ldir805/inst3.log" >&2; exit 1
fi
cp "$ldir805/log2.records" "$lhome805/log/records.tsv"
cp "$ldir805/log2.head" "$lhome805/log/head"
# (6) yank: an append-only marking; install refuses it without --allow-yanked;
#     the version->hash mapping stays immutable
if ! VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh yank "@gate805/logx@1.1.0" > "$ldir805/yank.log" 2>&1; then
  echo "[compiler-gate] FAIL: yank failed (#805)" >&2
  cat "$ldir805/yank.log" >&2; exit 1
fi
if [ "$(wc -l < "$lhome805/log/records.tsv" | tr -d '[:space:]')" != "3" ]; then
  echo "[compiler-gate] FAIL: yank did not append a log record (#805)" >&2; exit 1
fi
if VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate805/logx@1.1.0" > "$ldir805/inst4.log" 2>&1; then
  echo "[compiler-gate] FAIL: install accepted a yanked version without --allow-yanked (#805)" >&2; exit 1
fi
if ! grep -q "yanked in the registry log" "$ldir805/inst4.log"; then
  echo "[compiler-gate] FAIL: yank rejection lacks the expected message (#805)" >&2
  cat "$ldir805/inst4.log" >&2; exit 1
fi
if ! VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate805/logx@1.1.0" --allow-yanked > "$ldir805/inst5.log" 2>&1; then
  echo "[compiler-gate] FAIL: --allow-yanked did not override the yank refusal (#805)" >&2
  cat "$ldir805/inst5.log" >&2; exit 1
fi
if ! awk -F'\t' '$1 == "@gate805/logx@1.1.0"' "$lhome805/cache/versions.tsv" | grep -q "pkg:sha1:"; then
  echo "[compiler-gate] FAIL: yank disturbed the immutable version->hash mapping (#805)" >&2; exit 1
fi
# (7) the log dir is a servable static artifact: a copied dir passed via
#     VIBE_REGISTRY_LOG_DIR verifies the same way
rm -rf "$ldir805/served"
cp -R "$lhome805/log" "$ldir805/served"
if ! VIBE_HOME="$lhome805" VIBE_REGISTRY_LOG_DIR="$ldir805/served" VIBE_PKG_CLI_WASM="$stage2_wasm" \
  bash scripts/vibe_pkg.sh install "@gate805/logx@1.0.0" > "$ldir805/inst6.log" 2>&1; then
  echo "[compiler-gate] FAIL: install against a served log copy failed (#805)" >&2
  cat "$ldir805/inst6.log" >&2; exit 1
fi
if ! grep -q "inclusion verified for @gate805/logx@1.0.0" "$ldir805/inst6.log"; then
  echo "[compiler-gate] FAIL: served-copy install did not verify inclusion (#805)" >&2
  cat "$ldir805/inst6.log" >&2; exit 1
fi
rm -rf "$ldir805" "$lhome805"
echo "[compiler-gate] registry transparency log + yank ok"

# 6d. where-contract + publish-gate regression (#731 / #732): a violated
#     requires clause traps at runtime; the publish semver gate accepts an
#     honest bump and rejects a dishonest one.
echo "[compiler-gate] 6d where-contract + publish gate regression (#731/#732)"
edir="_build/_gate_ef"
rm -rf "$edir"; mkdir -p "$edir"
# (a) satisfied contract: requires + ensures hold, the call returns 42.
printf 'fn checked_add(x: Int, y: Int) -> Int where { requires: x >= 0, requires: y >= 0, ensures: result >= x } { x + y }\nexport let _start: () -> Int = () -> { checked_add(40, 2) }\n' > "$edir/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/ok.vibe" "$edir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$edir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: satisfied where-contract program did not compile (#731)" >&2
  cat "$edir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
ok_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edir/ok.wasm" 2>/dev/null | tail -1)"
if [ "$ok_out" != "42" ]; then
  echo "[compiler-gate] FAIL: satisfied where-contract returned '$ok_out' (want 42) (#731)" >&2; exit 1
fi
# (b) violated requires: entry assert traps.
printf 'fn half_pos(x: Int) -> Int where { requires: x > 0 } { x / 2 }\nexport let _start: () -> Int = () -> { half_pos(0 - 4) }\n' > "$edir/viol.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/viol.vibe" "$edir/viol.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$edir/viol.wasm" ]; then
  echo "[compiler-gate] FAIL: where-contract program did not compile (#731)" >&2
  cat "$edir/viol.wasm.diag" 2>/dev/null >&2; exit 1
fi
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edir/viol.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: violated requires clause did not trap (#731)" >&2; exit 1
fi
# (c) violated ensures: exit assert (over the `result` binding) traps.
printf 'fn bad_dec(x: Int) -> Int where { ensures: result > x } { x - 1 }\nexport let _start: () -> Int = () -> { bad_dec(7) }\n' > "$edir/viol_ens.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/viol_ens.vibe" "$edir/viol_ens.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$edir/viol_ens.wasm" ]; then
  echo "[compiler-gate] FAIL: ensures-contract program did not compile (#731)" >&2
  cat "$edir/viol_ens.wasm.diag" 2>/dev/null >&2; exit 1
fi
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edir/viol_ens.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: violated ensures clause did not trap (#731)" >&2; exit 1
fi
printf 'fn a(x: Int) -> Int\n' > "$edir/prev.vibei"
printf 'fn a(x: Int) -> Int\nfn b(x: Int) -> Int\n' > "$edir/next.vibei"
VIBE_PUBLISH_CHECK=1 VIBE_PUBLISH_PREV="$edir/prev.vibei" VIBE_PUBLISH_PREV_VERSION=1.0.0 VIBE_PUBLISH_VERSION=1.1.0 \
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/next.vibei" "$edir/pub.out" __no_entry__ >/dev/null 2>&1 || true
if ! grep -q "^ok" "$edir/pub.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: honest minor bump was rejected (#732)" >&2
  cat "$edir/pub.out.diag" 2>/dev/null >&2; exit 1
fi
VIBE_PUBLISH_CHECK=1 VIBE_PUBLISH_PREV="$edir/prev.vibei" VIBE_PUBLISH_PREV_VERSION=1.0.0 VIBE_PUBLISH_VERSION=1.0.1 \
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/next.vibei" "$edir/pub2.out" __no_entry__ >/dev/null 2>&1 || true
if ! grep -q "requires minor" "$edir/pub2.out.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: dishonest patch claim was not rejected (#732)" >&2
  cat "$edir/pub2.out" "$edir/pub2.out.diag" 2>/dev/null >&2; exit 1
fi
rm -rf "$edir"
echo "[compiler-gate] where-contract + publish gate regression ok"

# (6e retired by #741: the vendored lib/@vibe/compiler/cache/sha1.vibe twin was
# deleted — the compiler consumes lib/@vibe/core through the contract import,
# so there is nothing left to drift-check.)

# 6f. @vibe/core store-install E2E: install the REAL in-repo package into
#     .vibe/store via scripts/vibe_core_install.sh, then compile AND RUN a
#     require-pinned consumer against it. The pin is taken from the install
#     output, so core source changes never stale this step. Complements 6c
#     (synthetic packages) with the shipped package: 82-decl contract,
#     bodyless `type` re-exports, multi-impl any-match conformance.
echo "[compiler-gate] 6f @vibe/core store-install E2E"
cdir6f="_build/_gate_core_store"
rm -rf "$cdir6f" ".vibe/store/@vibe/core"; mkdir -p "$cdir6f"
if ! VIBE_CORE_CLI_WASM="$stage2_wasm" bash scripts/vibe_core_install.sh > "$cdir6f/install.out" 2>&1; then
  echo "[compiler-gate] FAIL: vibe_core_install.sh failed" >&2
  cat "$cdir6f/install.out" >&2; exit 1
fi
core_pin="$(grep '^package ' "$cdir6f/install.out" | cut -d' ' -f2)"
if [ -z "$core_pin" ]; then
  echo "[compiler-gate] FAIL: install printed no package pin" >&2
  cat "$cdir6f/install.out" >&2; exit 1
fi
cat > "$cdir6f/consumer.vibe" <<EOF
require @vibe/core 0.2.0 = $core_pin

import @vibe/core {
  sha1, encode_uleb128, read_uleb128, type List, from_array, contains
}
export let _start: () -> Int = () -> {
  assert(sha1("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d")
  let buf = encode_uleb128(624485)
  let (v, _) = read_uleb128(buf, 0)
  assert(eq(v, 624485))
  assert(eq(List::sum(List::of3(1, 2, 3)), 6))
  let s = from_array(["a", "b"])
  assert(contains(s, "a"))
  assert(not(contains(s, "z")))
  0
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir6f/consumer.vibe" "$cdir6f/consumer.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir6f/consumer.wasm" ]; then
  echo "[compiler-gate] FAIL: pinned @vibe/core consumer did not compile" >&2
  cat "$cdir6f/consumer.wasm.diag" 2>/dev/null >&2; exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$cdir6f/consumer.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: @vibe/core consumer trapped at runtime" >&2; exit 1
fi
rm -rf "$cdir6f" ".vibe/store/@vibe/core"
echo "[compiler-gate] @vibe/core store-install E2E ok"

# 7. literal sub-pattern regression (#603): a literal (PInt/PString) argument of a
#    constructor pattern must be tested, not just the tag — `I("x")` must not
#    match `I("y")`, `I(1)` must not match `I(2)`. Guards the match-codegen fix.
echo "[compiler-gate] 7/7 literal sub-pattern regression"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pdir/litpat.vibe" "$pdir/litpat.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$pdir/litpat.wasm" ]; then
  echo "[compiler-gate] FAIL: literal sub-pattern program did not compile" >&2; exit 1
fi
litpat_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$pdir/litpat.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$litpat_out" != "62" ]; then
  echo "[compiler-gate] FAIL: literal sub-pattern mismatch (got '$litpat_out', want 62 -> #603 regressed)" >&2
  exit 1
fi
rm -rf "$pdir"
echo "[compiler-gate] literal sub-pattern regression ok"

# 8. labeled-param round-trip regression (#604/#606): normalizing a function
#    with labeled (`x~`) / optional (`x?`) parameters must preserve the parameter
#    names. `parse_one_param` builds the names with string interpolation
#    (`"\{name}~"`); before the #606 `__to_string` root fix this leaked a heap
#    pointer (`(1285664100319233~)`), and the #604 mitigation routed around it
#    with `String::concat`. With the root fix the interpolation form is correct,
#    so this guards the root fix directly. The result must still compile + run.
echo "[compiler-gate] 8/8 labeled-param round-trip regression"
ldir="_build/_gate_labeled"
rm -rf "$ldir"; mkdir -p "$ldir"
printf 'let sum: (x~: Int, y~: Int) -> Int = (x~, y~) -> { x + y }\nexport let run: () -> Int = () -> { sum(x=1, y=2) }\nexport { run }\n' > "$ldir/in.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ldir/in.vibe" "$ldir/out.vibe" >/dev/null 2>&1 || true
if [ ! -s "$ldir/out.vibe" ]; then
  echo "[compiler-gate] FAIL: labeled-param normalize produced no output" >&2; exit 1
fi
# Param names must survive verbatim; a digit before `~` means the gensym bug is back.
if ! grep -q "(x~, y~)" "$ldir/out.vibe" || grep -Eq "[0-9]+~" "$ldir/out.vibe"; then
  echo "[compiler-gate] FAIL: labeled param names mangled (#604 regressed)" >&2
  cat "$ldir/out.vibe" >&2; exit 1
fi
# The normalized output must still compile + run.
cp "$ldir/out.vibe" "$ldir/compile.vibe"
printf '\nexport let _start: () -> Int = () -> { run() }\n' >> "$ldir/compile.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ldir/compile.vibe" "$ldir/out.wasm" _start >/dev/null 2>&1
labeled_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$ldir/out.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$labeled_out" != "3" ]; then
  echo "[compiler-gate] FAIL: normalized labeled-param output did not compile/run to 3 (got '$labeled_out')" >&2
  cat "$ldir/compile.vibe" >&2; exit 1
fi
rm -rf "$ldir"
echo "[compiler-gate] labeled-param round-trip regression ok"

# 9. constant-folding regression (#594): `vibe normalize` folds `+ - *` over int
#    literals. The folded value must replace the expression and the result must
#    compile + run unchanged.
echo "[compiler-gate] 9/9 constant-folding regression"
fdir="_build/_gate_fold"
rm -rf "$fdir"; mkdir -p "$fdir"
printf 'let x = 40 + 2 * 10\nexport let run: () -> Int = () -> { x }\nexport { run }\n' > "$fdir/in.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fdir/in.vibe" "$fdir/out.vibe" >/dev/null 2>&1
# 40 + 2*10 = 60; the arithmetic must be gone and `60` present.
if ! grep -q "let x: Int = 60" "$fdir/out.vibe" || grep -q "40 + 2" "$fdir/out.vibe"; then
  echo "[compiler-gate] FAIL: constant folding incorrect" >&2
  cat "$fdir/out.vibe" >&2; exit 1
fi
cp "$fdir/out.vibe" "$fdir/compile.vibe"
printf '\nexport let _start: () -> Int = () -> { run() }\n' >> "$fdir/compile.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fdir/compile.vibe" "$fdir/out.wasm" _start >/dev/null 2>&1
fold_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$fdir/out.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$fold_out" != "60" ]; then
  echo "[compiler-gate] FAIL: folded program did not run to 60 (got '$fold_out')" >&2; exit 1
fi
rm -rf "$fdir"
echo "[compiler-gate] constant-folding regression ok"

# 10. nested constructor sub-pattern regression (#608): a constructor pattern
#     whose argument is itself a constructor (`SL(_, None, _)` vs
#     `SL(_, Some(x), _)`) must (a) discriminate on the nested tag — arms sharing
#     the outer tag must route distinctly — and (b) bind the nested fields, so
#     using `x` in the arm body compiles instead of trapping codegen. Adjacent to
#     #603 (literal sub-patterns); both live in the single-condition PCtor path.
echo "[compiler-gate] 10/10 nested ctor sub-pattern regression"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/nested.vibe" "$ndir/nested.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$ndir/nested.wasm" ]; then
  echo "[compiler-gate] FAIL: nested ctor sub-pattern program did not compile (#608 regressed: codegen trap)" >&2; exit 1
fi
nested_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$ndir/nested.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$nested_out" != "27" ]; then
  echo "[compiler-gate] FAIL: nested ctor sub-pattern mismatch (got '$nested_out', want 27 -> #608 regressed)" >&2
  exit 1
fi
rm -rf "$ndir"
echo "[compiler-gate] nested ctor sub-pattern regression ok"

# 11. forward-reference regression (#602): a top-level `let` may reference another
#     top-level `let` defined later in the same file. The checker now hoists
#     top-level binding signatures, so this compiles instead of aborting with an
#     opaque trap. A genuinely-undefined name must still error (no over-permit).
echo "[compiler-gate] 11/11 forward-reference regression"
wdir="_build/_gate_fwdref"
rm -rf "$wdir"; mkdir -p "$wdir"
cat > "$wdir/fwd.vibe" <<'EOF'
let early: () -> Int = () -> { late() }
let late: () -> Int = () -> { 41 }
export let _start: () -> Int = () -> { early() + 1 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$wdir/fwd.vibe" "$wdir/fwd.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$wdir/fwd.wasm" ]; then
  echo "[compiler-gate] FAIL: forward-reference program did not compile (#602 regressed: checker trap)" >&2; exit 1
fi
fwd_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$wdir/fwd.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$fwd_out" != "42" ]; then
  echo "[compiler-gate] FAIL: forward-reference mismatch (got '$fwd_out', want 42 -> #602 regressed)" >&2
  exit 1
fi
# Guard: a genuinely-undefined name must still be rejected (hoist only adds names
# that are actually defined later).
printf 'export let _start: () -> Int = () -> { genuinely_undefined_name() }\n' > "$wdir/undef.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$wdir/undef.vibe" "$wdir/undef.wasm" _start >/dev/null 2>&1 || true
if [ -s "$wdir/undef.wasm" ]; then
  echo "[compiler-gate] FAIL: undefined name compiled (#602 hoist over-permitted)" >&2; exit 1
fi
rm -rf "$wdir"
echo "[compiler-gate] forward-reference regression ok"

# 12. string-interpolation conversion regression (#606): `"\{e}"` lowers to
#     `__to_string(e)`, which was an `identity` stub (so interpolating an int
#     yielded garbage) reachable only via a dead inline path. The root fix makes
#     `__to_string` always use the real conversion (int -> decimal, string ->
#     passthrough with an in-bounds pointer check). Assert an int interpolates to
#     its digits and a string interpolates verbatim.
echo "[compiler-gate] 12/12 string-interpolation conversion regression"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$idir/interp.vibe" "$idir/interp.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$idir/interp.wasm" ]; then
  echo "[compiler-gate] FAIL: interpolation program did not compile" >&2; exit 1
fi
interp_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$idir/interp.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$interp_out" != "8230" ]; then
  echo "[compiler-gate] FAIL: interpolation mismatch (got '$interp_out', want 8230 -> #606 regressed)" >&2
  exit 1
fi
rm -rf "$idir"
echo "[compiler-gate] string-interpolation conversion regression ok"

# 13. coverage instrumentation regression (#cov): VIBE_COVERAGE=1 must produce an
#     instrumented build whose vibe_cov / vibe_cov_branch sections the runner can
#     read. A test that exercises only the then-branch of an `if` must report
#     both functions hit and exactly one of the two branches taken — the signal
#     that powers `vibe test --coverage`.
echo "[compiler-gate] 13/13 coverage instrumentation regression"
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
VIBE_COVERAGE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir/cov_test.vibe" "$cdir/cov_test.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$cdir/cov_test.wasm" ]; then
  echo "[compiler-gate] FAIL: coverage build produced no wasm (#cov regressed)" >&2; exit 1
fi
VIBE_COV_OUT="$cdir/cov.json" VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$cdir/cov_test.wasm" >/dev/null 2>&1 || true
if [ ! -s "$cdir/cov.json" ]; then
  echo "[compiler-gate] FAIL: no coverage report produced (vibe_cov section missing?)" >&2; exit 1
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
  echo "[compiler-gate] FAIL: coverage report wrong ($cov_check -> #cov regressed)" >&2; exit 1
fi
rm -rf "$cdir"
echo "[compiler-gate] coverage instrumentation regression ok"

# 14. method-bearing-trait dictionary passing regression (#641 PR-3): a
#     `[T: Trait]` generic calling `T::method(x)` must dispatch to the concrete
#     impl via a synthesized witness dictionary (desugar_trait_dict.vibe). Covers
#     a primitive impl, a struct impl, multiple methods (incl. `Self`-returning
#     `scale`), literal and let-bound receivers, generic->generic dict
#     forwarding, and supertrait method inheritance (flattened witness).
echo "[compiler-gate] 14/14 method-bearing-trait dict-passing regression"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mbtdir/mbt.vibe" "$mbtdir/mbt.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$mbtdir/mbt.wasm" ]; then
  echo "[compiler-gate] FAIL: trait dict-passing program did not compile" >&2
  cat "$mbtdir/mbt.wasm.diag" 2>/dev/null >&2; exit 1
fi
mbt_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$mbtdir/mbt.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$mbt_out" != "340" ]; then
  echo "[compiler-gate] FAIL: trait dict-passing mismatch (got '$mbt_out', want 340 -> #641 PR-3 regressed)" >&2
  exit 1
fi
rm -rf "$mbtdir"
echo "[compiler-gate] method-bearing-trait dict-passing regression ok"

# 14b. rank-1 method-level generics on trait methods (#684): a trait method may
#      declare its OWN bounded type parameter `m: [X: Show](Self, X) -> R`. The
#      binder lives on the TRAIT method only; the impl does NOT repeat it. At a
#      qualified call `C::m(recv, arg)` the `Show` witness for `X = type(arg)`
#      must be resolved/threaded so the body's `X::show(arg)` dispatches to the
#      concrete impl. Covers an Int and a String argument (witness per type).
echo "[compiler-gate] 14b/14 rank-1 trait-method generics regression (#684)"
mgdir="_build/_gate_methodgen"
rm -rf "$mgdir"; mkdir -p "$mgdir"
cat > "$mgdir/mg.vibe" <<'EOF'
trait Show { show(Self) -> String }
trait Logger { write_object: [X: Show](Self, X) -> String }
struct SB { prefix: String }
impl Show for Int { show(self) -> String { __to_string(self) } }
impl Show for String { show(self) -> String { self } }
impl Logger for SB {
  write_object(self, x) -> String { String::concat(self.prefix, X::show(x)) }
}
export let _start: () -> Int = () -> {
  let sb = SB::{ prefix: "n=" }
  let a = SB::write_object(sb, 42)
  let sb2 = SB::{ prefix: "s=" }
  let b = SB::write_object(sb2, "hi")
  if a == "n=42" && b == "s=hi" { 84 } else { 0 }
}
EOF
# Expected: 84 (both Int and String witnesses resolved -> correct shown strings)
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mgdir/mg.vibe" "$mgdir/mg.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$mgdir/mg.wasm" ]; then
  echo "[compiler-gate] FAIL: rank-1 trait-method generic program did not compile" >&2
  cat "$mgdir/mg.wasm.diag" 2>/dev/null >&2; exit 1
fi
mg_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$mgdir/mg.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$mg_out" != "84" ]; then
  echo "[compiler-gate] FAIL: rank-1 trait-method generic mismatch (got '$mg_out', want 84 -> #684 regressed)" >&2
  exit 1
fi
rm -rf "$mgdir"
echo "[compiler-gate] rank-1 trait-method generics regression ok"

# 14c. UFCS method call on a trait-bounded type parameter (#931): inside a
#      `[K: Hash]` generic, the UFCS spelling `k.probe_key()` must dispatch
#      through the SAME threaded witness dict as the qualified spelling
#      `K::probe_key(k)`. Before the fix the UFCS call stayed a bare EDot,
#      which codegen compiled as a struct-field read — a silent null-function
#      call at runtime. Uses the committed fixture (expected value pinned in
#      its __DATA__ block: 97097 = qualified 97 * 1000 + UFCS 97); the
#      fixture's top-level `_start()` echo line and __DATA__ tail are stripped
#      for the ADR-0069 entry-based compile.
echo "[compiler-gate] 14c/14 UFCS-on-bounded-tparam dict dispatch (#931)"
ufcsdir="_build/_gate_ufcs_tparam"
rm -rf "$ufcsdir"; mkdir -p "$ufcsdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/trait_bound_ufcs_method.vibe "$ufcsdir/ufcs.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$ufcsdir/ufcs.wasm" ]; then
  echo "[compiler-gate] FAIL: UFCS-on-bounded-tparam program did not compile" >&2
  cat "$ufcsdir/ufcs.wasm.diag" 2>/dev/null >&2; exit 1
fi
if ! ufcs_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$ufcsdir/ufcs.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: UFCS-on-bounded-tparam mismatch (want 97097 -> #931 regressed)" >&2
  echo "$ufcs_out" >&2
  exit 1
fi
rm -rf "$ufcsdir"
echo "[compiler-gate] UFCS-on-bounded-tparam dict dispatch ok (97097)"

# 15. derive(...) structural generation regression (#638): `derive(Ord)` and
#     `derive(Show)` on a struct must generate working `Type::compare` (-1/0/1
#     lexicographic over fields) and `Type::to_string` free functions. Also
#     covers multiple-derive and `Eq` accepted as a no-op marker.
echo "[compiler-gate] 15/15 derive(Ord/Show) structural-generation regression"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$drvdir/drv.vibe" "$drvdir/drv.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$drvdir/drv.wasm" ]; then
  echo "[compiler-gate] FAIL: derive program did not compile" >&2
  cat "$drvdir/drv.wasm.diag" 2>/dev/null >&2; exit 1
fi
drv_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$drvdir/drv.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$drv_out" != "16" ]; then
  echo "[compiler-gate] FAIL: derive mismatch (got '$drv_out', want 16 -> #638 regressed)" >&2
  exit 1
fi
rm -rf "$drvdir"
echo "[compiler-gate] derive(Ord/Show) structural-generation regression ok"

# Runs each given fixture as a test-block suite through the fresh stage2:
# compile with the `__no_entry__` sentinel (ADR-0069 — these files have no
# `_start` of their own, and the test-runner `_start` synthesis needs the
# explicit sentinel now that an unknown entry name is a compile error), then
# run `_start`. Every `assert` traps on failure, so a clean run == all blocks
# in the file passed.
#
# #1587: callers pass a GLOB, never a hand-written list. Three sections below
# used to carry byte-identical copies of this loop over enumerations that every
# fixture-adding PR appended to — so queued PRs collided on the same line, and
# a fixture committed without the gate edit was silently never executed. With a
# glob, a fixture that matches the convention runs the moment it lands, and
# scripts/check_fixture_execution.sh fails the gate if some test-block fixture
# is picked up by no lane at all.
run_test_block_fixtures() {
  local label="$1"; shift
  local fx fxout
  [ "$#" -gt 0 ] || { echo "[compiler-gate] FAIL: $label matched no fixtures" >&2; exit 1; }
  for fx in "$@"; do
    # An unmatched glob comes through literally (nullglob is off); catch that
    # here rather than reporting it as a compile failure of a missing file.
    [ -f "$fx" ] || { echo "[compiler-gate] FAIL: $label: no such fixture '$fx'" >&2; exit 1; }
    fxout="_build/_gate_tbf_$(basename "${fx%.vibe}").wasm"
    rm -f "$fxout" "$fxout.diag"
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      "$fx" "$fxout" __no_entry__ >/dev/null 2>&1 || true
    if [ ! -s "$fxout" ]; then
      echo "[compiler-gate] FAIL: $fx did not compile ($label)" >&2
      cat "$fxout.diag" 2>/dev/null >&2; exit 1
    fi
    if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
        --invoke _start "$fxout" >/dev/null 2>&1; then
      echo "[compiler-gate] FAIL: $fx has a failing test (assert trapped) ($label)" >&2
      exit 1
    fi
    rm -f "$fxout" "$fxout.diag" "$fxout.funcmap"
  done
}

# 15b. extended derive(...) regression (#638 / #694): enum `derive(Ord/Show)`,
#      struct + enum `derive(Default)`, `derive(Eq)`, and `derive(Hash)`
#      including transparent Map keys — `map_key_to_string = [K: Hash](key) ->
#      K::hash_key(key)` threads the witness dict (#684) through the `[K: Hash]`
#      `get_by`/`has_by`/`get_or_by` chain, with a nested-aggregate key proving
#      Layer-2 recursion. Covers multiple-derive (`derive(Eq, Ord, Show, Hash)`).
#
#      The set is `fixtures/derive_*_test.vibe`, not a list: a new derive
#      fixture that follows the convention is covered without touching this
#      file. (Three fixtures unrelated to derive — eq_array_option_fields,
#      bool_interp_test, shadow_scope_test — used to ride along here because
#      this list was the nearest place to append; they are `*_test.vibe` under
#      fixtures/, so scripts/unit_test_runner.sh runs them through this exact
#      same harness and nothing is lost by dropping them from the gate copy.)
echo "[compiler-gate] 15b/15 extended derive (enum Ord/Show, Default, Eq, Hash + Map keys)"
run_test_block_fixtures "extended derive" fixtures/derive_*_test.vibe
# Unknown-derive negative check: `derive(Foo)` for an unknown trait must error
# (`unknown trait: Foo`, no wasm emitted), keeping genuinely-unknown derive names
# rejected while Eq/Ord/Show/Hash/Default are accepted.
undir="_build/_gate_derive_unknown"
rm -rf "$undir"; mkdir -p "$undir"
cat > "$undir/u.vibe" <<'EOF'
struct P { x: Int } derive(Foo)
export let _start: () -> Int = () -> { P::{ x: 1 }.x }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$undir/u.vibe" "$undir/u.wasm" _start >/dev/null 2>&1 || true
if [ -s "$undir/u.wasm" ]; then
  echo "[compiler-gate] FAIL: derive(Foo) unknown trait was accepted (should error)" >&2
  exit 1
fi
rm -rf "$undir"
echo "[compiler-gate] extended derive (enum Ord/Show, Default, Eq, Hash + Map keys) ok"

# #1681 / ADR-0097: an unannotated empty-array binding has no element type to
# select a structural comparator. Empty values compare exactly by length, but
# after mutation to non-empty the compiler must fail closed at runtime rather
# than silently falling back to reference/length equality. Pin both spellings:
# `!=` is lowered through the same guarded equality and then negated.
echo "[compiler-gate] structural equality untyped-empty mutation fail-closed (#1681)"
eqtrapdir="_build/_gate_eq_untyped_empty"
rm -rf "$eqtrapdir"; mkdir -p "$eqtrapdir"
for eqtrap_src in fixtures/structural_eq_untyped_empty_*_trap.vibe; do
  eqtrap_name="$(basename "${eqtrap_src%.vibe}")"
  eqtrap_wasm="$eqtrapdir/$eqtrap_name.wasm"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$eqtrap_src" "$eqtrap_wasm" _start >/dev/null 2>&1 || true
  if [ ! -s "$eqtrap_wasm" ]; then
    echo "[compiler-gate] FAIL: $eqtrap_src did not compile" >&2
    cat "$eqtrap_wasm.diag" 2>/dev/null >&2
    exit 1
  fi
  if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
      --invoke _start "$eqtrap_wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: $eqtrap_src returned normally; expected fail-closed trap" >&2
    exit 1
  fi
done
rm -rf "$eqtrapdir"
echo "[compiler-gate] structural equality untyped-empty mutation fail-closed ok (== + !=)"

# 15c. railway `let*` / `?` generalized to Option (#635): the parser emits a
#      type-directed sentinel that the pre-check desugar lowers by the operand's
#      head type — `Option` (Some/None) or `Result` (Ok/Err, the default). The
#      fixtures are `test "..."`-block suites; compile each through the fresh
#      stage2 and run `_start` (a failing `assert` traps, so a clean run == all
#      blocks passed). Covers Option `let*`, Result `let*` unchanged, Option `?`
#      early-return-None, Result `?` early-return-Err, and the mixed-type type
#      error (a negative file that must NOT compile).
echo "[compiler-gate] 15c/15 railway let*/? Option generalization (#635)"
run_test_block_fixtures "railway let*/?" fixtures/try_*_option_test.vibe
# Mixed Result/Option in one `let*` chain must be a type error (NO implicit
# conversion): a block returns one type, so a `Result` rest under an `Option`
# `let*` (or vice-versa) fails the checker. The file must NOT compile.
mixdir="_build/_gate_railway_mixed"
rm -rf "$mixdir"; mkdir -p "$mixdir"
cat > "$mixdir/m.vibe" <<'EOF'
enum Result[T, E] { Ok(T); Err(E) }
let opt = (n: Int) -> Option[Int] { if n > 0 { Some(n) } else { None } }
let res = (n: Int) -> Result[Int, String] { if n > 0 { Ok(n) } else { Err("x") } }
// `let* x = opt(..)` lowers the block to Option; returning a Result `rest`
// (and an `Err` ctor as the None/short-circuit value) is a type clash.
export let _start: () -> Int = () -> {
  let r = (a: Int) -> Option[Int] {
    let* x = opt(a)
    res(x)
  }
  match r(1) { Some(v) => v, None => 0 }
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mixdir/m.vibe" "$mixdir/m.wasm" _start >/dev/null 2>&1 || true
if [ -s "$mixdir/m.wasm" ]; then
  echo "[compiler-gate] FAIL: mixed Result/Option let* chain compiled (should be a type error)" >&2
  exit 1
fi
rm -rf "$mixdir"
echo "[compiler-gate] railway let*/? Option generalization ok"

# 15d was a third byte-identical copy of the test-block-suite loop, for the
# single fixture `fixtures/derive_hash_map_key_test.vibe` (#694). That name
# matches 15b's `fixtures/derive_*_test.vibe` glob, so it runs there now and
# the standalone copy is gone (#1587); 15b's comment carries the #694 rationale.

# 16. trait type parameters / Iterator regression (#636): a method-bearing trait
#     with a type parameter (`Iterator[T] { next(Self) -> Option[T] }`) must be
#     declarable, and a `[I: Iterator]` generic must dispatch `I::next` through
#     the witness dictionary — driving a stateful, functional iterator
#     (`next(Self) -> Option[(T, Self)]`) to completion.
echo "[compiler-gate] 16/16 trait-type-parameter / Iterator regression"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$itdir/iter.vibe" "$itdir/iter.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$itdir/iter.wasm" ]; then
  echo "[compiler-gate] FAIL: Iterator trait program did not compile" >&2
  cat "$itdir/iter.wasm.diag" 2>/dev/null >&2; exit 1
fi
it_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$itdir/iter.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$it_out" != "30" ]; then
  echo "[compiler-gate] FAIL: Iterator dispatch mismatch (got '$it_out', want 30 -> #636 regressed)" >&2
  exit 1
fi
rm -rf "$itdir"
echo "[compiler-gate] trait-type-parameter / Iterator regression ok"

# 17. lazy iterator combinators regression (#636): a lazy `Stream` (a struct
#     holding a `pull` closure) with `impl Iter for Stream` supports lazy
#     `map`/`filter` and eager `fold`/`sum`/`count` consumers (driven by the
#     `for` desugar) — the trait-based replacement for prelude/lazy_iter.vibe's
#     `() -> Option[T]` function iterator. All library code, no compiler support
#     beyond the trait machinery.
echo "[compiler-gate] 17/17 lazy iterator combinators regression"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$lcdir/lc.vibe" "$lcdir/lc.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$lcdir/lc.wasm" ]; then
  echo "[compiler-gate] FAIL: lazy combinators program did not compile" >&2
  cat "$lcdir/lc.wasm.diag" 2>/dev/null >&2; exit 1
fi
lc_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$lcdir/lc.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$lc_out" != "47" ]; then
  echo "[compiler-gate] FAIL: lazy combinators mismatch (got '$lc_out', want 47 -> #636 regressed)" >&2
  exit 1
fi
rm -rf "$lcdir"
echo "[compiler-gate] lazy iterator combinators regression ok"

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
echo "[compiler-gate] 18/18 cross-import trait-iterator regression"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xidir/main.vibe" "$xidir/main.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xidir/main.wasm" ]; then
  echo "[compiler-gate] FAIL: cross-import trait-iterator program did not compile" >&2
  exit 1
fi
xi_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$xidir/main.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$xi_out" != "5" ]; then
  echo "[compiler-gate] FAIL: cross-import trait-iterator mismatch (got '$xi_out', want 5 -> import method namespacing regressed)" >&2
  exit 1
fi
rm -rf "$xidir"
echo "[compiler-gate] cross-import trait-iterator regression ok"

# 19. async for-loop unification regression (#636 / #1350): `for x in s` is ONE
#     type-directed desugar covering the sync and async shapes. #1350 removed
#     the `for await` spelling and its `__await_iter` marker; the loop shape is
#     picked from the iterand's TYPE alone:
#       - a struct `C` with `C::next -> Future[Option[..]]` (an AsyncIterator /
#         `Stream[T]`) drives an `await`-wrapped next loop (`await` unwraps the
#         ready future on the synchronous backend), and
#       - any other iterable (a pull closure `() -> Option[T]`, the pre-existing
#         M2c-3 model) drives the pull-to-`None` loop.
#     Guards that the async shapes still classify with no syntax marker and with
#     no declared trait (the always-run desugar pass).
echo "[compiler-gate] 19/19 async for-loop unification regression"
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
export let _start: () -> Int with Async = () -> {
  let mut t = 0
  for x in mkstream([10, 20, 30]) { t = t + x }
  for y in counter_stream() { t = t + y }
  t
}
EOF
# Expected: async iterator 10+20+30 = 60, pull closure 1+2+3+4 = 10 -> 70.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fadir/fa.vibe" "$fadir/fa.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$fadir/fa.wasm" ]; then
  echo "[compiler-gate] FAIL: async for-loop program did not compile" >&2
  cat "$fadir/fa.wasm.diag" 2>/dev/null >&2; exit 1
fi
fa_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$fadir/fa.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$fa_out" != "70" ]; then
  echo "[compiler-gate] FAIL: async for-loop unification mismatch (got '$fa_out', want 70 -> #636/#1350 regressed)" >&2
  exit 1
fi
rm -rf "$fadir"
echo "[compiler-gate] async for-loop unification regression ok"

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
echo "[compiler-gate] 20/20 cross-import trait-iterator element-type regression"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eidir/pos.vibe" "$eidir/pos.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$eidir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: element-type positive program did not compile" >&2
  cat "$eidir/pos.wasm.diag" 2>/dev/null >&2; exit 1
fi
ei_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$eidir/pos.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$ei_out" != "100" ]; then
  echo "[compiler-gate] FAIL: element-type positive mismatch (got '$ei_out', want 100)" >&2
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eidir/neg.vibe" "$eidir/neg.wasm" _start >/dev/null 2>&1 || true
if [ -s "$eidir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: element-type negative program compiled (element typed CtUnknown, not String -> element-type safety regressed)" >&2
  exit 1
fi
if ! grep -q "type mismatch in '+'" "$eidir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: element-type negative rejected for the wrong reason" >&2
  cat "$eidir/neg.wasm.diag" 2>/dev/null >&2; exit 1
fi
rm -rf "$eidir"
echo "[compiler-gate] cross-import trait-iterator element-type regression ok"

# 21. prelude iterator combinator suites: compile + run the real prelude test
#     files through the fresh stage2 and assert every `test "..."` block passes
#     (each `assert` traps on failure, so a clean `_start` run == all passed).
#     Covers the sync `lazy_iter` and async `async_iter` combinator libraries
#     (take / drop / take_while / enumerate / zip / flat_map / find / any / all,
#     and the async `for`-driven terminals) — these prelude tests are not
#     otherwise exercised by the gate.
echo "[compiler-gate] 21/21 prelude iterator combinator suites"
for suite in lib/@vibe/prelude/lazy_iter_test.vibe lib/@vibe/prelude/async_iter_test.vibe; do
  out="_build/_gate_prelude_iter_$(basename "${suite%.vibe}").wasm"
  # ADR-0069: test-block suites need the explicit `__no_entry__` sentinel for
  # the test-runner `_start` synthesis (unknown entry names are compile errors).
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$suite" "$out" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$out" ]; then
    echo "[compiler-gate] FAIL: $suite did not compile" >&2
    cat "$out.diag" 2>/dev/null >&2; exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
      --invoke _start "$out" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: $suite has a failing test (assert trapped)" >&2
    exit 1
  fi
  rm -f "$out" "$out.diag" "$out.funcmap"
done
echo "[compiler-gate] prelude iterator combinator suites ok"

# 22. generic trait impls — Increment A (#5): an UNbounded, method-bearing
#     `impl [T] Trait for C` makes `C[K]` satisfy a `[U: Trait]` bound for any K,
#     and the witness dict (`{ method: C::method }`) dispatches through the
#     existing dict-passing desugar — so a generic function called with an array
#     runs the array impl. Two assertions:
#       (a) POSITIVE: `impl [T] Len2 for Array` + `[U: Len2] total(x)` runs.
#       (b) SOUNDNESS: a marker-trait generic impl (`impl [T: Eq] Eq for
#           Option[T]`, Eq has no methods) must STILL be rejected — matching it
#           would let `==` (which is not structural on Option) silently misbehave.
echo "[compiler-gate] 22/22 generic trait impl (Increment A)"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gidir/pos.vibe" "$gidir/pos.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$gidir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: generic-impl positive program did not compile" >&2
  cat "$gidir/pos.wasm.diag" 2>/dev/null >&2; exit 1
fi
gi_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$gidir/pos.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$gi_out" != "5" ]; then
  echo "[compiler-gate] FAIL: generic-impl positive mismatch (got '$gi_out', want 5)" >&2
  exit 1
fi
# Soundness: a marker-trait generic impl must NOT satisfy the bound.
cat > "$gidir/neg.vibe" <<'EOF'
trait Marky[T]
impl [T] Marky for Array
let needs = [U: Marky](x: U) -> Int { 1 }
export let _start: () -> Int = () -> { needs([1, 2, 3]) }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gidir/neg.vibe" "$gidir/neg.wasm" _start >/dev/null 2>&1 || true
if [ -s "$gidir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: marker-trait generic impl was accepted (unsound — should be rejected)" >&2
  exit 1
fi
rm -rf "$gidir"
echo "[compiler-gate] generic trait impl (Increment A) ok"

# 23. generic trait impls — Increment B (#5): a BOUNDED generic impl
#     `impl [T: Bound] Trait for C` whose body dispatches `T`'s methods on the
#     elements. The witness for `C[K]` is a nested dictionary-of-dictionaries:
#     `{ method: (w) -> C::method(<K's Bound dict>, w) }`. Assertions:
#       (a) `impl [T: Show2] Show2 for Array` summing `T::show2` over elements
#           runs for `Array[Box]` (→60) and nests for `Array[Array[Box]]` (→6).
#       (b) SOUNDNESS: an element type with no impl must NOT silently dispatch —
#           the witness refuses to build, so the program fails to produce a
#           runnable module (never returns a wrong number).
echo "[compiler-gate] 23/23 generic trait impl (Increment B, dict-of-dict)"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gjdir/pos.vibe" "$gjdir/pos.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$gjdir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: dict-of-dict positive program did not compile" >&2
  cat "$gjdir/pos.wasm.diag" 2>/dev/null >&2; exit 1
fi
gj_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$gjdir/pos.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$gj_out" != "66" ]; then
  echo "[compiler-gate] FAIL: dict-of-dict mismatch (got '$gj_out', want 66 = 60 + 6)" >&2
  exit 1
fi
# Soundness: an element type with no Show2 impl must not silently dispatch.
{ printf '%s\n' "$gj_prelude"
  printf 'struct Qux[T] { w: T }\n'
  printf 'export let _start: () -> Int = () -> { use_it([Qux::{ w: 5 }]) }\n'
} > "$gjdir/neg.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gjdir/neg.vibe" "$gjdir/neg.wasm" _start >/dev/null 2>&1 || true
neg_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$gjdir/neg.wasm" 2>/dev/null | tr -dc '0-9-' || true)"
if [ "$neg_out" = "5" ]; then
  echo "[compiler-gate] FAIL: element without an impl silently dispatched (miscompile — returned 5)" >&2
  exit 1
fi
rm -rf "$gjdir"
echo "[compiler-gate] generic trait impl (Increment B, dict-of-dict) ok"

# 24. async-lifted component EXECUTION on wasmtime (docs/spec/wasi-p3-async.md
#     §3.1). The async-lift codegen (`comp_emit_component_wasm_async*` — task.return
#     canon + async functype + async lift) is byte-tested on node, but the emitted
#     component had no EXECUTION check (the only runner was the retired
#     host `vibe.exe`). `fixtures/async_lift_run42.component.wasm` is a committed
#     async component (its `run()` returns 42) emitted by the selfhost codegen;
#     here wasmtime runs it with the async-stackful flags and we assert 42 — so
#     the async runtime path is proven to EXECUTE on wasmtime 45 (no wasmtime 46
#     needed). SKIPs cleanly when wasmtime / the async flags are unavailable.
#     Regenerate the fixture with: scripts/emit_async_lift_fixture.sh
echo "[compiler-gate] 24/24 async-lifted component execution (wasmtime)"
WT_BIN="$(command -v wasmtime || "$ROOT_DIR/scripts/wasmtime_bin.sh" 2>/dev/null || true)"
ac_fixture="$ROOT_DIR/fixtures/async_lift_run42.component.wasm"
if [ -z "${WT_BIN:-}" ] || ! "$WT_BIN" --version >/dev/null 2>&1; then
  echo "[compiler-gate] SKIP: wasmtime not available"
elif ! "$WT_BIN" -W help 2>&1 | grep -q "component-model-async-stackful"; then
  echo "[compiler-gate] SKIP: wasmtime lacks component-model-async-stackful"
elif [ ! -s "$ac_fixture" ]; then
  echo "[compiler-gate] SKIP: async-lift fixture missing (run scripts/emit_async_lift_fixture.sh)"
else
  ac_out="$(VIBE_WASMTIME_WASM_FLAGS="component-model-async=y concurrency-support=y component-model-async-stackful=y" \
    bash scripts/wasmtime_run.sh --invoke 'run()' "$ac_fixture" 2>/dev/null | tr -dc '0-9-' || true)"
  if [ "$ac_out" != "42" ]; then
    echo "[compiler-gate] FAIL: async component did not execute to 42 (got '$ac_out')" >&2; exit 1
  fi
  echo "[compiler-gate] async-lifted component execution (wasmtime $("$WT_BIN" --version | awk '{print $2}')) -> 42 ok"
fi

# 25. nested literal sub-pattern discrimination (#613 follow-up): a boolean (or
#     any) literal nested INSIDE a constructor argument that is itself a
#     constructor (`N(W(false), n)`) or a tuple (`T((false, n))`) must be
#     discriminated — the prior codegen only tag-tested nested ctors and did not
#     test tuple sub-patterns at all, silently routing `W(true)`/`(true, _)` to
#     the `false` arm (wrong result, not a trap). compile_match now emits the
#     literal test recursively at every nesting level.
echo "[compiler-gate] 25/25 nested literal sub-pattern discrimination"
nldir="_build/_gate_nestedlit"
rm -rf "$nldir"; mkdir -p "$nldir"
cat > "$nldir/nestedlit.vibe" <<'EOF'
enum W { W(Bool) }
enum N { N(W, Int) }
enum T { T((Bool, Int)) }
enum I { I(Int) }
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
// Bare top-level tuple pattern with a literal element: previously the cond was
// unconditionally true (matched any tuple) AND the binding of `n` was dropped
// (codegen trap). `cb` exercises both over a local tuple; discrimination must
// route by the bool. (Written with a local `let` tuple rather than a tuple
// function parameter, since `((Bool, Int)) -> Int` annotations are mis-parsed
// as two-parameter, a separate type-annotation bug.)
let cb: (Bool, Int) -> Int = (flag, v) -> {
  let e = (flag, v)
  match e {
    (false, n) => n,
    (true, n) => n + 1000
  }
}
export let _start: () -> Int = () -> {
  // Or-pattern discrimination: a string / tuple branch of `a | b` previously
  // fell through to an always-true test, so a non-matching scrutinee silently
  // took the first arm (`"z"` matched `"a" | "b"`, `(9, 0)` matched
  // `(1, _) | (2, _)`). Both must route to the catch-all here.
  let s = "z"
  let sor = match s { "a" | "b" => 100, _ => 7 }
  let t = (9, 0)
  let tor = match t { (1, _) | (2, _) => 100, (_, _) => 11 }
  // Or-pattern nested inside a constructor arg / tuple element (`W(1 | 2)`,
  // `(1 | 2, _)`): emit_sub_tests previously had no POr case, so the literal
  // test was skipped and any value matched. `W(9)` / `(9, _)` must miss here.
  let nor = match I(9) { I(1 | 2) => 100, I(_) => 13 }
  let ntor = match (9, 0) { (1 | 2, _) => 100, (_, _) => 17 }
  cn(N(W(true), 7)) + cn(N(W(false), 3)) + ct(T((true, 5))) + ct(T((false, 1)))
    + cb(true, 9) + cb(false, 2) + sor + tor + nor + ntor
}
EOF
# Expected: 1007+3+1005+1+1009+2 + 7+11 + 13+17 = 3075. A regressed compiler
# ignores the nested/bare-tuple/or literal tests and returns a smaller sum (or
# fails to compile the bare-tuple binding).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$nldir/nestedlit.vibe" "$nldir/nestedlit.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$nldir/nestedlit.wasm" ]; then
  echo "[compiler-gate] FAIL: nested literal sub-pattern program did not compile" >&2; exit 1
fi
nestedlit_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$nldir/nestedlit.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$nestedlit_out" != "3075" ]; then
  echo "[compiler-gate] FAIL: nested literal sub-pattern mismatch (got '$nestedlit_out', want 3075 -> #613 regressed)" >&2
  exit 1
fi
rm -rf "$nldir"
echo "[compiler-gate] nested literal sub-pattern discrimination ok"

# 26. effect-call discipline (#626 criteria 1 & 3-builtin-slice): both
#     `perform EffName::Op` and a call to an effectful BUILTIN (`Fs::read_file`,
#     ...) are type errors unless the enclosing function declares that effect in
#     a `with` row (or it is inside a `handle`). Declared variants must
#     compile; undeclared variants must be REJECTED. (`Error`/`Async` are out of
#     this slice; pure builtins like `Array::length` are never flagged.)
echo "[compiler-gate] 26/26 effect-call discipline (perform + builtin)"
pfdir="_build/_gate_perform"
rm -rf "$pfdir"; mkdir -p "$pfdir"
cat > "$pfdir/good.vibe" <<'EOF'
let emit: () -> Unit with Stdout = () -> {
  perform Stdout::WriteStream("hi")
}
let load: (String) -> String with Fs = (p) -> {
  Fs::read_file(p)
}
let pure_use: (Array[Int]) -> Int = (xs) -> {
  Array::length(xs)
}
export let _start: () -> Int with Stdout = () -> {
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
# Transitive (#626): a function calling an Fs-declaring helper must itself
# declare Fs (or handle it). `mid` leaks Fs from `leaf` without declaring it.
cat > "$pfdir/bad_transitive.vibe" <<'EOF'
let leaf: (String) -> String with Fs = (p) -> {
  Fs::read_file(p)
}
let mid: (String) -> String = (p) -> {
  leaf(p)
}
export let _start: () -> Int with Fs = () -> {
  let _ = mid("x")
  42
}
EOF
# The same chain with `mid` correctly declaring Fs must compile.
cat > "$pfdir/good_transitive.vibe" <<'EOF'
let leaf: (String) -> String with Fs = (p) -> {
  Fs::read_file(p)
}
let mid: (String) -> String with Fs = (p) -> {
  leaf(p)
}
export let _start: () -> Int with Fs = () -> {
  let _ = mid("x")
  42
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/good.vibe" "$pfdir/good.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$pfdir/good.wasm" ]; then
  echo "[compiler-gate] FAIL: declared effect calls did not compile (#626 over-rejects)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_perform.vibe" "$pfdir/bad_perform.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_perform.wasm" ]; then
  echo "[compiler-gate] FAIL: undeclared perform compiled (#626 criterion 1 regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_builtin.vibe" "$pfdir/bad_builtin.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_builtin.wasm" ]; then
  echo "[compiler-gate] FAIL: undeclared effectful builtin call compiled (#626 builtin slice regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_transitive.vibe" "$pfdir/bad_transitive.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_transitive.wasm" ]; then
  echo "[compiler-gate] FAIL: undeclared transitive effect call compiled (#626 transitive enforcement regressed)" >&2; exit 1
fi
# #639: effect-row diagnostics — the transitive reject above must print the
# EXPECTED vs ACTUAL rows as a set difference, and (since `mid` has no `with`
# clause at all) a declare-form fix-it hint that blames the CALLER `mid`,
# not the callee `leaf`.
if ! grep -qF "effect row mismatch for 'mid': missing { Fs }" "$pfdir/bad_transitive.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: transitive reject lacks the effect-row set-difference diagnostic (#639)" >&2
  cat "$pfdir/bad_transitive.wasm.diag" 2>/dev/null >&2; exit 1
fi
if ! grep -qF "hint: declare 'fn mid(...) -> T with Fs'" "$pfdir/bad_transitive.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: no-row reject lacks the declare-form fix-it hint (#639)" >&2
  cat "$pfdir/bad_transitive.wasm.diag" 2>/dev/null >&2; exit 1
fi
# #639: a caller that already declares a row gets the add-form hint carrying
# the sorted union (existing row preserved, missing effect appended).
cat > "$pfdir/bad_row_single.vibe" <<'EOF'
let leaf: (String) -> String with Fs = (p) -> {
  Fs::read_file(p)
}
let mid: (String) -> String with Exception = (p) -> {
  leaf(p)
}
export let _start: () -> Int = () -> { 42 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_row_single.vibe" "$pfdir/bad_row_single.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_row_single.wasm" ]; then
  echo "[compiler-gate] FAIL: partially-declared transitive effect call compiled (#639)" >&2; exit 1
fi
# #1461: the fixture used to DECLARE `with Error` while the diagnostic reported
# the canonical `Exception` -- an asymmetry that was the point of Step 1's flip,
# and what this assertion pinned. The final stage retired the alias as a
# spelling, so the fixture now declares `Exception` too and the asymmetry is
# gone. The assertion text is unchanged: it always read `declared { Exception }`,
# because the canonical name is what gets printed either way.
if ! grep -qF "effect row mismatch for 'mid': missing { Fs } (declared { Exception }, requires { Exception, Fs })" "$pfdir/bad_row_single.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: partial-row reject lacks the declared-vs-required diff (#639)" >&2
  cat "$pfdir/bad_row_single.wasm.diag" 2>/dev/null >&2; exit 1
fi
if ! grep -qF "hint: add 'with Exception + Fs' to 'mid'" "$pfdir/bad_row_single.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: partial-row reject lacks the add-form fix-it hint (#639)" >&2
  cat "$pfdir/bad_row_single.wasm.diag" 2>/dev/null >&2; exit 1
fi
# #639: multiple missing effects at one call site aggregate into ONE sorted
# set difference (leaf declares "Fs, Env" in reversed order; the diagnostic
# must render "{ Env, Fs }").
cat > "$pfdir/bad_row_multi.vibe" <<'EOF'
let leaf: (String) -> String with Fs + Env = (p) -> {
  Fs::read_file(p)
}
let mid: (String) -> String = (p) -> {
  leaf(p)
}
export let _start: () -> Int = () -> { 42 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_row_multi.vibe" "$pfdir/bad_row_multi.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_row_multi.wasm" ]; then
  echo "[compiler-gate] FAIL: multi-effect transitive call compiled (#639)" >&2; exit 1
fi
if ! grep -qF "effect row mismatch for 'mid': missing { Env, Fs }" "$pfdir/bad_row_multi.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: multi-effect reject is not an aggregated sorted set difference (#639)" >&2
  cat "$pfdir/bad_row_multi.wasm.diag" 2>/dev/null >&2; exit 1
fi
if ! grep -qF "hint: declare 'fn mid(...) -> T with Env + Fs'" "$pfdir/bad_row_multi.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: multi-effect reject lacks the sorted fix-it hint (#639)" >&2
  cat "$pfdir/bad_row_multi.wasm.diag" 2>/dev/null >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/good_transitive.vibe" "$pfdir/good_transitive.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$pfdir/good_transitive.wasm" ]; then
  echo "[compiler-gate] FAIL: correctly-declared transitive effect chain did not compile (#626 over-rejects)" >&2; exit 1
fi
# #812: the transitive map must also cover IMPORTED effectful functions — a
# caller invoking an imported `with Fs` function without declaring Fs used
# to compile (and reach the filesystem at runtime) while the same shape with a
# local callee was rejected. The env-seeded row closes the module boundary.
mkdir -p "$pfdir/sub"
cat > "$pfdir/sub/helper.vibe" <<'EOF'
export let read_it: (String) -> String with Exception + Fs = (p) -> {
  Fs::read_file(p)
}
EOF
cat > "$pfdir/bad_import_transitive.vibe" <<'EOF'
import ./sub/helper.vibe { read_it }

let f: (Int) -> Int = (n) -> {
  let _ = read_it("x")
  n
}
export let _start: () -> Int = () -> { f(1) }
EOF
cat > "$pfdir/good_import_transitive.vibe" <<'EOF'
import ./sub/helper.vibe { read_it }

let g: (String) -> String with Exception + Fs = (p) -> {
  read_it(p)
}
export let _start: () -> Int = () -> { 42 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_import_transitive.vibe" "$pfdir/bad_import_transitive.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_import_transitive.wasm" ]; then
  echo "[compiler-gate] FAIL: undeclared call of IMPORTED effectful function compiled (#812 regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/good_import_transitive.vibe" "$pfdir/good_import_transitive.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$pfdir/good_import_transitive.wasm" ]; then
  echo "[compiler-gate] FAIL: correctly-declared imported effect call did not compile (#812 over-rejects)" >&2; exit 1
fi
rm -rf "$pfdir"
echo "[compiler-gate] effect-call discipline ok"

# 27. handle effect discharge (#626 criterion 2): `handle ... with E` discharges
#     E for its body (a perform of E inside need not be declared), but ONLY E —
#     a perform of a DIFFERENT undeclared effect inside the same handle still
#     leaks and is a type error. The parser qualifies arm patterns as `E::Op`, so
#     the discharged effect is recovered from the handler arms.
echo "[compiler-gate] 27/27 handle effect discharge"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hdir/discharge.vibe" "$hdir/discharge.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$hdir/discharge.wasm" ]; then
  echo "[compiler-gate] FAIL: handle did not discharge its own effect (#626 criterion 2 over-rejects)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hdir/leak.vibe" "$hdir/leak.wasm" _start >/dev/null 2>&1 || true
if [ -s "$hdir/leak.wasm" ]; then
  echo "[compiler-gate] FAIL: a different undeclared effect leaked through a handle (#626 criterion 2 regressed)" >&2; exit 1
fi
# Multi-operation handler dispatch (#665): the perform/handler ABI records the
# operation index (g_op_index) so a handler over a multi-operation effect routes
# each performed operation to the matching arm (previously every operation
# silently ran arms[0]). Verify correct routing AND that the original positional
# bug (perform order != arm order) and cross-handler corruption are gone.
cat > "$hdir/multiop.vibe" <<'EOF'
effect Calc {
  Add(Int) -> Int
  Mul(Int) -> Int
}
export let _start: () -> Int = () -> {
  let a = handle { perform Calc::Mul(3) } with Calc {
    Add(n) => resume(n + 100);
    Mul(n) => resume(n * 1000)
  }
  let b = handle {
    let x = perform Calc::Mul(3)
    let y = perform Calc::Add(5)
    x + y
  } with Calc {
    Add(n) => resume(n + 10);
    Mul(n) => resume(n * 10)
  }
  a + b
}
EOF
cat > "$hdir/singleop.vibe" <<'EOF'
effect Logger { Log(String) -> Unit }
export let _start: () -> Int = () -> {
  handle { perform Logger::Log("hi"); 42 } with Logger {
    Log(s) => resume(())
  }
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hdir/multiop.vibe" "$hdir/multiop.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$hdir/multiop.wasm" ]; then
  echo "[compiler-gate] FAIL: multi-operation effect handler did not compile (#665 dispatch regressed)" >&2; exit 1
fi
# a = Mul(3)*1000 = 3000 ; b = Mul(3)*10 + Add(5)+10 = 30+15 = 45 ; total 3045
multiop_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$hdir/multiop.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$multiop_out" != "3045" ]; then
  echo "[compiler-gate] FAIL: multi-operation dispatch wrong (got '$multiop_out', want 3045 -> #665 regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hdir/singleop.vibe" "$hdir/singleop.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$hdir/singleop.wasm" ]; then
  echo "[compiler-gate] FAIL: single-operation effect handler did not compile (#665 over-rejects)" >&2; exit 1
fi
rm -rf "$hdir"
echo "[compiler-gate] handle effect discharge ok"

# 27b. effect op signatures (#813): perform arguments, handler arm names and
#      payload types, and resume values are validated against the DECLARED
#      effect's op signatures. Each was previously unchecked (silent garbage).
echo "[compiler-gate] 27b/27 effect op signature checking (#813)"
odir="_build/_gate_effopsig"
rm -rf "$odir"; mkdir -p "$odir"
cat > "$odir/ok_op.vibe" <<'EOF'
effect R { Take(Int) -> Int }
export let _start: () -> Int = () -> {
  handle {
    perform R::Take(41)
  } with R {
    Take(n) => resume(n + 1)
  }
}
EOF
cat > "$odir/bad_performarg.vibe" <<'EOF'
effect R { Take(Int) -> Int }
export let _start: () -> Int = () -> {
  handle { perform R::Take("str") } with R { Take(n) => resume(n + 1) }
}
EOF
cat > "$odir/bad_performarity.vibe" <<'EOF'
effect R { Take(Int) -> Int }
export let _start: () -> Int = () -> {
  handle { perform R::Take(1, 2) } with R { Take(n) => resume(n + 1) }
}
EOF
cat > "$odir/bad_armname.vibe" <<'EOF'
effect Ask { Get() -> Int }
export let _start: () -> Int = () -> {
  handle { perform Ask::Get() } with Ask { Wrong(x) => resume(1) }
}
EOF
cat > "$odir/bad_armpayload.vibe" <<'EOF'
effect G { Give(Int) -> Int }
export let _start: () -> Int = () -> {
  handle { perform G::Give(7) } with G { Give(s) => resume(String::length(s)) }
}
EOF
cat > "$odir/bad_resumeval.vibe" <<'EOF'
effect Q { Get() -> Int }
export let _start: () -> Int = () -> {
  handle { perform Q::Get() } with Q { Get() => resume("oops") }
}
EOF
cat > "$odir/bad_kconv.vibe" <<'EOF'
effect E { Emit(Int) -> Int }
export let _start: () -> Int = () -> {
  handle { perform E::Emit(20) } with E { Emit(v, k) => v + k(0) }
}
EOF
cat > "$odir/bad_missingarm.vibe" <<'EOF'
effect Duo { A() -> Int; B() -> Int }
export let _start: () -> Int = () -> {
  handle { perform Duo::B() } with Duo { A() => resume(1) }
}
EOF
cat > "$odir/bad_resume0.vibe" <<'EOF'
effect Q { Get() -> Int }
export let _start: () -> Int = () -> {
  handle { perform Q::Get() } with Q { Get() => resume() }
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$odir/ok_op.vibe" "$odir/ok_op.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$odir/ok_op.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed effect op program did not compile (#813 over-rejects)" >&2; exit 1
fi
op_out="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$odir/ok_op.wasm" 2>/dev/null | tail -n 1)"
if [ "$op_out" != "42" ]; then
  echo "[compiler-gate] FAIL: effect op control returned '$op_out' (expected 42)" >&2; exit 1
fi
for bad in bad_performarg bad_performarity bad_armname bad_armpayload bad_resumeval bad_kconv bad_missingarm bad_resume0; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$odir/$bad.vibe" "$odir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$odir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: ill-typed $bad compiled (#813 regressed)" >&2; exit 1
  fi
done
rm -rf "$odir"
echo "[compiler-gate] effect op signature checking ok"

# 27c. index bounds checks (#811): OOB / negative Array and Bytes access must
#      TRAP (unreachable) instead of silently reading/writing adjacent memory;
#      in-bounds access is unchanged.
echo "[compiler-gate] 27c/27 index bounds checks (#811)"
bdir="_build/_gate_bounds"
rm -rf "$bdir"; mkdir -p "$bdir"
cat > "$bdir/inbounds.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let a = [40, 2, 7]
  // Bytes::new(n) is a length-n zero-filled buffer (MoonBit semantics);
  // exercise in-len set/get plus push growth past the initial length.
  let b = Bytes::new(3)
  Bytes::set(b, 0, 2)
  Bytes::push(b, 9)
  let s = "abc"
  Array::get(a, 0) + Bytes::get(b, 0) + Bytes::get(b, 3) - 9 + s[1] - String::char_code_at(s, 1)
}
EOF
cat > "$bdir/oob_get.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::get([1, 2, 3], 5) }
EOF
cat > "$bdir/oob_neg.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::get([1, 2, 3], -1) }
EOF
cat > "$bdir/oob_bytes.vibe" <<'EOF'
export let _start: () -> Int = () -> { let b = Bytes::new(2); Bytes::get(b, 9) }
EOF
cat > "$bdir/oob_str.vibe" <<'EOF'
export let _start: () -> Int = () -> { String::char_code_at("abc", 7) }
EOF
cat > "$bdir/oob_str_neg.vibe" <<'EOF'
export let _start: () -> Int = () -> { let s = "abc"; s[-1] }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$bdir/inbounds.vibe" "$bdir/inbounds.wasm" _start >/dev/null 2>&1 || true
bounds_out="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$bdir/inbounds.wasm" 2>/dev/null | tail -n 1 || true)"
if [ "$bounds_out" != "42" ]; then
  echo "[compiler-gate] FAIL: in-bounds access returned '$bounds_out' (expected 42; #811 over-traps)" >&2; exit 1
fi
for oob in oob_get oob_neg oob_bytes oob_str oob_str_neg; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$bdir/$oob.vibe" "$bdir/$oob.wasm" _start >/dev/null 2>&1 || true
  if bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$bdir/$oob.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: $oob ran without trapping (#811 regressed)" >&2; exit 1
  fi
done
rm -rf "$bdir"
echo "[compiler-gate] index bounds checks ok"

# 27d. async for-loop classification (#827 / #1350): the pull-closure lowering
#      must fire only on a POSITIVELY function-shaped source. It used to be
#      reachable by a silent fallback, which compiled fine and then trapped at
#      runtime (call_indirect on the stream's array pointer). #1350 removed the
#      `for await` syntax and made the UNCLASSIFIED fallback the plain array
#      loop -- which is the correct lowering for the eager Array-backed
#      `Stream` (ADR-0012) -- so the hazard is now structural rather than
#      diagnostic: BOTH the annotated and the unannotated param must compile
#      and run to 42.
echo "[compiler-gate] 27d/27 async for-loop classification (#827/#1350)"
fadir="_build/_gate_forawait"
rm -rf "$fadir"; mkdir -p "$fadir"
cat > "$fadir/ok_annot.vibe" <<'EOF'
let consume: (Stream[Int]) -> Int = (s) -> {
  let mut sum = 0
  for x in s {
    sum = sum + x
  }
  sum
}
export let _start: () -> Int = () -> { consume(String::to_bytes("*")) }
EOF
cat > "$fadir/ok_unannot.vibe" <<'EOF'
let consume = (s) -> Int {
  let mut sum = 0
  for x in s {
    sum = sum + x
  }
  sum
}
export let _start: () -> Int = () -> { consume(String::to_bytes("*")) }
EOF
# #1350 (Codex P1): the pull-closure loop must fire only when the source
# POSITIVELY returns a function. A call to a function whose return annotation
# was merely OMITTED records the same empty head as a closure-returning one
# did before the fix, and its array was then called as a closure
# (call_indirect trap). Reproduced on the pre-fix stage2; 42 = 40 + 2.
cat > "$fadir/ok_unannot_factory.vibe" <<'EOF'
let values = () -> {
  [40, 2]
}
export let _start: () -> Int = () -> {
  let mut sum = 0
  for x in values() {
    sum = sum + x
  }
  sum
}
EOF
# #1350 (Codex P1, second round): the same ambiguity in the OTHER direction --
# an unannotated factory that really DOES return a pull closure must keep its
# pull loop. Tightening the annotated case alone moved the trap here (the
# closure was iterated as an array). The head is inferred from the body's tail
# expression, so both unannotated shapes classify correctly. 42 = 14 * 3.
cat > "$fadir/ok_unannot_closure_factory.vibe" <<'EOF'
let make_pull = () -> {
  let mut n = 0
  () -> {
    if n >= 3 {
      None
    } else {
      n = n + 1
      Some(14)
    }
  }
}
export let _start: () -> Int = () -> {
  let mut sum = 0
  for x in make_pull() {
    sum = sum + x
  }
  sum
}
EOF
for fa_case in ok_annot ok_unannot ok_unannot_factory ok_unannot_closure_factory; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$fadir/$fa_case.vibe" "$fadir/$fa_case.wasm" _start >/dev/null 2>&1 || true
  if [ ! -s "$fadir/$fa_case.wasm" ]; then
    echo "[compiler-gate] FAIL: $fa_case for-loop over a Stream did not compile" >&2; exit 1
  fi
  fa_out="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$fadir/$fa_case.wasm" 2>/dev/null | tail -n 1)"
  if [ "$fa_out" != "42" ]; then
    echo "[compiler-gate] FAIL: $fa_case returned '$fa_out' (expected 42 -- the array loop is the right lowering for an eager Stream; a pull-closure fallback would trap)" >&2; exit 1
  fi
done
rm -rf "$fadir"
echo "[compiler-gate] async for-loop classification ok"

# 27e. Error-as-perform equivalence (#640 Stage 1): `perform Error::Throw(x)`
#      must be indistinguishable from `throw(x)` — both emit the EThrow wasm
#      exception (tag 2), so the same `with Error` handler catches both.
#      Previously the perform spelling was lowered with the out-of-range
#      fallback effect tag (Error is never in effect_names) and ESCAPED the
#      handler as an uncaught exception. Also pins #640's checker rule:
#      Error is non-resumable, so resume(...) inside a with-Error arm is a
#      compile error (the arm's value IS the handle result).
echo "[compiler-gate] 27e/27 Error-as-perform equivalence + non-resumability (#640)"
edir="_build/_gate_error_perform"
rm -rf "$edir"; mkdir -p "$edir"
cat > "$edir/via_perform.vibe" <<'EOF'
let safe = () -> Int with Exception {
  perform Error::Throw("fail")
  0
}
export let _start: () -> Int = () -> {
  handle { safe() } with Exception { Throw(msg) => String::length(msg) }
}
EOF
cat > "$edir/via_throw.vibe" <<'EOF'
let safe = () -> Int with Exception {
  throw("fail")
  0
}
export let _start: () -> Int = () -> {
  handle { safe() } with Exception { Throw(msg) => String::length(msg) }
}
EOF
cat > "$edir/bad_resume_arm.vibe" <<'EOF'
let risky = () -> Int with Exception {
  throw("boom")
  0
}
export let _start: () -> Int = () -> {
  handle { risky() } with Exception { Throw(_m) => resume(0) }
}
EOF
# Codex P2 on #933: the rejection walk's catch-all used to end at EBreak /
# ELoop (and EMap/ESpread/ELabeledArg/EContinue/ERecord), so a resume tucked
# into `loop { break resume(0) }` reached codegen's meaningless tag-1 path.
cat > "$edir/bad_resume_loop.vibe" <<'EOF'
let risky = () -> Int with Exception {
  throw("boom")
  0
}
export let _start: () -> Int = () -> {
  handle { risky() } with Exception { Throw(_m) => loop { break resume(0) } }
}
EOF
for v in via_perform via_throw; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$edir/$v.vibe" "$edir/$v.wasm" _start >/dev/null 2>&1 || true
  if [ ! -s "$edir/$v.wasm" ]; then
    echo "[compiler-gate] FAIL: $v did not compile (#640)" >&2; exit 1
  fi
done
perf_out="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edir/via_perform.wasm" 2>/dev/null | tail -n 1 || true)"
throw_out="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edir/via_throw.wasm" 2>/dev/null | tail -n 1 || true)"
if [ "$throw_out" != "4" ]; then
  echo "[compiler-gate] FAIL: throw spelling returned '$throw_out' (expected 4)" >&2; exit 1
fi
if [ "$perf_out" != "$throw_out" ]; then
  echo "[compiler-gate] FAIL: perform Error::Throw diverged from throw ('$perf_out' vs '$throw_out'; #640 regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/bad_resume_arm.vibe" "$edir/bad_resume_arm.wasm" _start >/dev/null 2>&1 || true
if [ -s "$edir/bad_resume_arm.wasm" ]; then
  echo "[compiler-gate] FAIL: resume(...) in a with-Error arm compiled (#640 regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/bad_resume_loop.vibe" "$edir/bad_resume_loop.wasm" _start >/dev/null 2>&1 || true
if [ -s "$edir/bad_resume_loop.wasm" ]; then
  echo "[compiler-gate] FAIL: resume(...) nested in loop/break inside a with-Error arm compiled (walk gap; Codex P2 on #933)" >&2; exit 1
fi
# 27e2 (#640 Stage 2): `throw(x)` desugars at PARSE time to the exact
# `perform Error::Throw(x)` AST (single internal form), so the two spellings
# must produce BYTE-IDENTICAL wasm — a much stronger pin than the equal-output
# check above. If this ever diverges, the single-form invariant regressed
# (e.g. one spelling grew its own lowering again).
if ! cmp -s "$edir/via_perform.wasm" "$edir/via_throw.wasm"; then
  echo "[compiler-gate] FAIL: throw vs perform Error::Throw wasm bytes differ (#640 Stage 2 single-form regressed)" >&2; exit 1
fi
rm -rf "$edir"
echo "[compiler-gate] Error-as-perform equivalence ok (4, byte-identical)"

# 27f. print primitives on the bare FS lane (#929/#930): the println/print
#      checker builtins had no linear-lane lowering (any program not importing
#      @vibe/io died with "undefined variable (local): println @call"), and the
#      Stdout::write_char / Stderr::write_char / Stdin::read_stream host
#      imports were called with guest-TAGGED ints (write_char(65) wrote byte
#      130 — "42" printed as "hd"). println/print must compile standalone and
#      print exact text; write_char must print the untagged byte; a source-
#      provided println (shadow) must still win over the builtin lowering.
echo "[compiler-gate] 27f/27 print primitives on the FS lane (#929/#930)"
ppdir="_build/_gate_print_prims"
rm -rf "$ppdir"; mkdir -p "$ppdir"
cat > "$ppdir/prints.vibe" <<'EOF'
fn main() -> Unit with Stdout {
  println("hello gate")
  print("forty")
  print("two")
  println("")
  println("\{40 + 2}")
  Stdout::write_char(String::char_code_at("A", 0))
  Stdout::write_char(10)
}
EOF
# The lowering must hold on BOTH linear lanes: the RC-canonical lane (raw
# host ABI, #930 untag shims) and the non-RC lane this gate's global
# VIBE_RC=0 pin compiles under (its generic call path untags import args
# itself). Compile and run the same program once per lane.
for pp_rc in 0 1; do
  rm -f "$ppdir/prints.wasm" "$ppdir/prints.wasm.diag"
  VIBE_RC="$pp_rc" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$ppdir/prints.vibe" "$ppdir/prints.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$ppdir/prints.wasm" ]; then
    echo "[compiler-gate] FAIL: println/print program did not compile on the FS lane under VIBE_RC=$pp_rc (#929 regressed)" >&2
    cat "$ppdir/prints.wasm.diag" 2>/dev/null >&2; exit 1
  fi
  pp_out="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$ppdir/prints.wasm" 2>/dev/null | head -n 4 | tr '\n' '|')"
  if [ "$pp_out" != "hello gate|fortytwo|42|A|" ]; then
    echo "[compiler-gate] FAIL: print primitives output '$pp_out' under VIBE_RC=$pp_rc (expected 'hello gate|fortytwo|42|A|'; #929/#930 regressed)" >&2; exit 1
  fi
done
# #2107: both rows are declared because both functions really do print --
# `print` carries `Stdout` now that the checker holds the print builtins to
# the row discipline. What this fixture pins is unchanged: the SOURCE
# definition of `println` wins over the builtin lowering, so the program
# prints "S" rather than "ignored".
cat > "$ppdir/shadow.vibe" <<'EOF'
fn println(s: String) -> Unit with Stdout {
  print("S\n")
}

fn main() -> Unit with Stdout {
  println("ignored")
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ppdir/shadow.vibe" "$ppdir/shadow.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$ppdir/shadow.wasm" ]; then
  echo "[compiler-gate] FAIL: source-shadowed println did not compile (#929 shadow guard broke shadowing)" >&2; exit 1
fi
pp_shadow="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$ppdir/shadow.wasm" 2>/dev/null | head -n 1)"
if [ "$pp_shadow" != "S" ]; then
  echo "[compiler-gate] FAIL: source-shadowed println printed '$pp_shadow' (expected 'S'; builtin lowering must yield to source defs)" >&2; exit 1
fi
rm -rf "$ppdir"
echo "[compiler-gate] print primitives ok"

# 28. argument type checking: the checker used to SWALLOW argument unification
#     failures (`unify_call_args` did `None => out`), so an ill-typed call like
#     `f("x")` for `f: (Int) -> Int` was silently accepted. It now reports a
#     STRUCTURAL argument mismatch (effect-only differences and the polymorphic
#     `__to_string` interpolation stringifier are still tolerated, since effect
#     inference on function values is imprecise). The mismatch must be REJECTED;
#     a correct call must still compile.
echo "[compiler-gate] 28/28 argument type checking"
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
# Field-stored-function call `b.f(args)`: when no method `T::f` exists but the
# struct field `f` holds a function, the args must be checked against the
# field's parameter types (this `b.f("s")` was previously unchecked).
cat > "$adir/ffwrong.vibe" <<'EOF'
struct B { f: (Int) -> Int }
export let _start: () -> Int = () -> { let b = B::{ f: (x) -> { x + 1 } }; (b.f)("s") }
EOF
cat > "$adir/ffright.vibe" <<'EOF'
struct B { f: (Int) -> Int }
export let _start: () -> Int = () -> { let b = B::{ f: (x) -> { x + 1 } }; (b.f)(3) }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$adir/right.vibe" "$adir/right.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$adir/right.wasm" ]; then
  echo "[compiler-gate] FAIL: a correctly-typed call did not compile (arg-check over-rejects)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$adir/ffright.vibe" "$adir/ffright.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$adir/ffright.wasm" ]; then
  echo "[compiler-gate] FAIL: a correct field-stored-function call did not compile (over-rejects)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$adir/wrong.vibe" "$adir/wrong.wasm" _start >/dev/null 2>&1 || true
if [ -s "$adir/wrong.wasm" ]; then
  echo "[compiler-gate] FAIL: an ill-typed argument (Int <- String) compiled (arg-check regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$adir/ffwrong.vibe" "$adir/ffwrong.wasm" _start >/dev/null 2>&1 || true
if [ -s "$adir/ffwrong.wasm" ]; then
  echo "[compiler-gate] FAIL: ill-typed field-stored-function call (Int <- String) compiled" >&2; exit 1
fi
rm -rf "$adir"
echo "[compiler-gate] argument type checking ok"

# 29. assignment / typed-binding / if-branch type checking: more positions the
#     checker used to leave unchecked. A typed `let x: Int = "s"`, an assignment
#     `y = "s"` (for `let mut y = 1`), and `if c { 1 } else { "x" }` must all be
#     REJECTED; their well-typed counterparts must compile. (Iterative
#     check_expr spine — check_seq_spine — gives the stack headroom for these
#     extra checks during self-compile.)
echo "[compiler-gate] 29/29 assignment / binding / if-branch / struct-field / local-let type checking"
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
cat > "$tdir/bad_ifnoelse.vibe" <<'EOF'
export let _start: () -> Int = () -> { let x: Int = if true { 1 }; x }
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
cat > "$tdir/bad_missingfield.vibe" <<'EOF'
struct Pt { x: Int; y: Int }
export let _start: () -> Int = () -> {
  let p = Pt::{ x: 1 }
  p.x
}
EOF
cat > "$tdir/bad_fnannot.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let g: (Int) -> String = (n) -> { n }
  0
}
EOF
cat > "$tdir/bad_return.vibe" <<'EOF'
export let f: () -> Int = () -> { return "x" }
export let _start: () -> Int = () -> { f() }
EOF
cat > "$tdir/bad_retviaannot.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let g: (Int) -> String = (n) -> { return n }
  0
}
EOF
cat > "$tdir/bad_genhead.vibe" <<'EOF'
let f = [T](a: Array[T]) -> Int { 0 }
export let _start: () -> Int = () -> { f(5) }
EOF
cat > "$tdir/bad_builtinarg.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::length(5) }
EOF
cat > "$tdir/bad_dupfield.vibe" <<'EOF'
struct P { x: Int }
export let _start: () -> Int = () -> { let p = P::{ x: 1, x: 2 }; p.x }
EOF
cat > "$tdir/bad_some2.vibe" <<'EOF'
export let _start: () -> Int = () -> { match Some(1, 2) { Some(a) => a, None => 0 } }
EOF
cat > "$tdir/bad_optfield.vibe" <<'EOF'
struct P { x: Int }
export let _start: () -> Int = () -> { let o: Option[P] = None; o.x }
EOF
cat > "$tdir/bad_concatarg.vibe" <<'EOF'
export let _start: () -> Int = () -> { let s = String::concat("a", 1); 0 }
EOF
cat > "$tdir/bad_concatarg0.vibe" <<'EOF'
export let _start: () -> Int = () -> { let s = String::concat(1, "a"); 0 }
EOF
cat > "$tdir/bad_substrarg.vibe" <<'EOF'
export let _start: () -> Int = () -> { let s = String::substring("abc", "x", 2); 0 }
EOF
cat > "$tdir/bad_unknownfield.vibe" <<'EOF'
struct P { x: Int; y: Int }
export let _start: () -> Int = () -> { let p = P::{ x: 1, z: 2 }; p.y }
EOF
cat > "$tdir/bad_guardonly.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  match 0 {
    v if v > 0 => 1,
    v if v < 0 => -1
  }
}
EOF
cat > "$tdir/bad_arity_get.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::get([1, 2, 3]) }
EOF
cat > "$tdir/bad_mutann.vibe" <<'EOF'
export let _start: () -> Int = () -> { let mut x: Bool = 5; 0 }
EOF
cat > "$tdir/bad_agrecv.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::get("str", 0) }
EOF
cat > "$tdir/bad_agidx.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::get([1, 2, 3], "x") }
EOF
cat > "$tdir/bad_asrecv.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::set("str", 0, 1); 0 }
EOF
cat > "$tdir/bad_arity_bytesnew.vibe" <<'EOF'
export let _start: () -> Int = () -> { let b = Bytes::new(1, 2); Bytes::length(b) }
EOF
# #827: Stream[T] is CtNamed (head 0 = tolerated), so the eager Array-backed
# representation leaked through the Array builtins — these compiled AND ran.
cat > "$tdir/bad_streamlen.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::length(String::to_bytes("*")) }
EOF
cat > "$tdir/bad_streamget.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::get(String::to_bytes("*"), 0) }
EOF
cat > "$tdir/bad_streamset.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::set(String::to_bytes("*"), 0, 1); 0 }
EOF
# #805 (0.3.0 redundant-syntax removal): the `\(expr)` string-interpolation
# spelling was removed — only `\{expr}` remains. A source using the old form
# must be a (located) compile error. The ok side is covered by the existing
# tests' pervasive `\{...}` usage.
cat > "$tdir/bad_interp_paren.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let x = 41
  let s = "\(x)"
  String::length(s)
}
EOF
# 0.3.0 redundant-syntax removal (2nd batch): ',' as the separator inside type
# declaration bodies (enum variants / struct fields) was removed — only ';'
# separates members. Sources using the old comma form must be (located) parse
# errors. The ok side is covered by the compiler tree's pervasive ';' decls
# (and $tdir/ok.vibe compiles above).
cat > "$tdir/bad_declcomma.vibe" <<'EOF'
enum Color { Red, Green, Blue }
export let _start: () -> Int = () -> { match Red { Red => 42, _ => 0 } }
EOF
cat > "$tdir/bad_structcomma.vibe" <<'EOF'
struct Pt { x: Int, y: Int }
export let _start: () -> Int = () -> { let p = Pt::{ x: 40, y: 2 }; p.x + p.y }
EOF
# #829 (lang-review r2 M7): a GENERIC struct literal must instantiate its type
# params from the field values, so a field read consumed at the wrong concrete
# type is a compile error (it used to compile and return silent garbage).
cat > "$tdir/bad_genfield.vibe" <<'EOF'
struct Box[T] { v: T }
export let _start: () -> Int = () -> {
  let b = Box::{ v: 1 }
  String::length(b.v)
}
EOF
# The well-typed counterpart: the instantiated field read consumed at its own
# concrete type must still compile (no over-reject).
cat > "$tdir/ok_genfield.vibe" <<'EOF'
struct Box[T] { v: T }
fn unbox[T](b: Box[T]) -> T { b.v }
export let _start: () -> Int = () -> {
  let b = Box::{ v: 41 }
  let s = Box::{ v: "x" }
  b.v + String::length(s.v) + unbox(b)
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/ok.vibe" "$tdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed binding/assign/if did not compile (over-rejects)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/ok_genfield.vibe" "$tdir/ok_genfield.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdir/ok_genfield.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed generic-struct field reads did not compile (over-rejects, #829)" >&2; exit 1
fi
for bad in bad_let bad_assign bad_if bad_ifnoelse bad_struct bad_locallet bad_missingfield bad_fnannot bad_return bad_retviaannot bad_genhead bad_builtinarg bad_dupfield bad_some2 bad_optfield bad_concatarg bad_concatarg0 bad_substrarg bad_unknownfield bad_guardonly bad_arity_get bad_arity_bytesnew bad_mutann bad_agrecv bad_agidx bad_asrecv bad_streamlen bad_streamget bad_streamset bad_interp_paren bad_declcomma bad_structcomma bad_genfield; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$tdir/$bad.vibe" "$tdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$tdir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: ill-typed $bad compiled (type-check regressed)" >&2; exit 1
  fi
done
rm -rf "$tdir"
echo "[compiler-gate] assignment / binding / if-branch / struct-field / local-let type checking ok"

# 30. `mut`-field write escape analysis (#418): assigning `obj.field = x` (which
#     desugars to `__set_field(obj, "field", x)`) is only legal when `field` was
#     declared `mut` in its struct. A write to a non-`mut` field must be
#     REJECTED; a write to a `mut` field (and a same-typed value) must compile.
echo "[compiler-gate] 30/30 mut-field write escape analysis"
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
cat > "$mdir/bad_valty.vibe" <<'EOF'
struct Cell2 { mut n: Int }
export let _start: () -> Int = () -> {
  let c = Cell2::{ n: 0 }
  c.n = "str"
  c.n
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mdir/ok_mut.vibe" "$mdir/ok_mut.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$mdir/ok_mut.wasm" ]; then
  echo "[compiler-gate] FAIL: mut-field write did not compile (over-rejects)" >&2
  cat "$mdir/ok_mut.wasm.diag" 2>/dev/null >&2; exit 1
fi
for bad in bad_nonmut bad_valty; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$mdir/$bad.vibe" "$mdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$mdir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: $bad field write compiled (mut/value-type check regressed)" >&2; exit 1
  fi
done
rm -rf "$mdir"
echo "[compiler-gate] mut-field write escape analysis ok"

# 31. value-soundness probes (each was previously accepted silently): value-
#     yielding `match` arms must agree; array literal elements must share a type;
#     calling a non-function value, `!` on a non-Bool, and `for x in <scalar>`
#     must all be rejected. A `CtUnit` arm (statement-position match) and the
#     well-typed positives must still compile.
echo "[compiler-gate] 31/31 match-arm / array / non-fn-call / unary-not / for-iterable type checking"
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
cat > "$cdir/bad_arraynest.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [[1], ["x"]]; 0 }
EOF
cat > "$cdir/bad_call.vibe" <<'EOF'
export let _start: () -> Int = () -> { let x = 5; x(3) }
EOF
cat > "$cdir/bad_calloption.vibe" <<'EOF'
export let _start: () -> Int = () -> { let o = Some(1); o(2) }
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir/ok.vibe" "$cdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed match/array did not compile (over-rejects)" >&2
  cat "$cdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
for bad in bad_match bad_array bad_arraynest bad_call bad_calloption bad_not bad_forint bad_tuparity; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$cdir/$bad.vibe" "$cdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$cdir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: ill-typed $bad compiled (consistency check regressed)" >&2; exit 1
  fi
done
rm -rf "$cdir"
echo "[compiler-gate] match-arm / array / non-fn-call / unary-not / for-iterable type checking ok"

# 32. mutability discipline: reassigning a plain (immutable) `let` is rejected;
#     a `let mut` binding, an accumulator updated in a loop, and a closure-local
#     `let mut` must still compile.
echo "[compiler-gate] 32/32 mutability discipline (immutable let reassignment)"
mudir="_build/_gate_mutability"
rm -rf "$mudir"; mkdir -p "$mudir"
cat > "$mudir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let mut x = 1
  x = 2
  let mut s = 0
  for i in [1, 2, 3] { s = s + i }
  x + s
}
EOF
cat > "$mudir/bad.vibe" <<'EOF'
export let _start: () -> Int = () -> { let x = 1; x = 2; x }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mudir/ok.vibe" "$mudir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$mudir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed mut/accumulator did not compile (over-rejects)" >&2
  cat "$mudir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mudir/bad.vibe" "$mudir/bad.wasm" _start >/dev/null 2>&1 || true
if [ -s "$mudir/bad.wasm" ]; then
  echo "[compiler-gate] FAIL: immutable-let reassignment compiled (mutability check regressed)" >&2; exit 1
fi
rm -rf "$mudir"
echo "[compiler-gate] mutability discipline ok"

# 32b. mutability discipline completeness (#629 step 3-2): an illegal reassignment
#      of an immutable `let` must be flagged even when it sits inside a Map::from_pairs value
#      (and likewise labeled arg / spread / break / continue — check_mutability_expr
#      previously dropped these Expr forms to `_ => errors`, missing the violation).
#      A `let mut` reassignment inside the same form must still compile (no over-reject).
echo "[compiler-gate] 32b/32 mutability discipline completeness (nested forms)"
mu2dir="_build/_gate_mutability_nested"
rm -rf "$mu2dir"; mkdir -p "$mu2dir"
cat > "$mu2dir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let mut x = 1
  let m = Map::from_pairs([("a", { x = 2; x })])
  m["a"]
}
EOF
cat > "$mu2dir/bad.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let x = 1
  let m = Map::from_pairs([("a", { x = 2; x })])
  m["a"]
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mu2dir/ok.vibe" "$mu2dir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$mu2dir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: legal mut reassignment inside Map::from_pairs value did not compile (over-rejects)" >&2
  cat "$mu2dir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mu2dir/bad.vibe" "$mu2dir/bad.wasm" _start >/dev/null 2>&1 || true
if [ -s "$mu2dir/bad.wasm" ]; then
  echo "[compiler-gate] FAIL: immutable-let reassignment inside map literal compiled (completeness regressed)" >&2; exit 1
fi
rm -rf "$mu2dir"
echo "[compiler-gate] mutability discipline completeness ok"

# 33. pattern-soundness: a constructor pattern must bind its variant's exact
#     payload arity, and cannot match a scalar scrutinee. Binding the right
#     arity, a nullary variant, and the builtin Option ctors must still compile.
echo "[compiler-gate] 33/33 constructor-pattern arity / scrutinee type checking"
pdir="_build/_gate_patsound"
rm -rf "$pdir"; mkdir -p "$pdir"
cat > "$pdir/ok.vibe" <<'EOF'
enum E { Pair(Int, Int) }
export let _start: () -> Int = () -> {
  let m = match Pair(1, 2) { Pair(a, b) => a + b }
  let o = match Some(5) { Some(v) => v, None => 0 }
  m + o
}
EOF
cat > "$pdir/bad_arity.vibe" <<'EOF'
enum E { Pair(Int, Int) }
export let _start: () -> Int = () -> { match Pair(1, 2) { Pair(a) => a, _ => 0 } }
EOF
cat > "$pdir/bad_scalar.vibe" <<'EOF'
enum Color { Red; Green }
export let _start: () -> Int = () -> { match 5 { Red => 1, _ => 0 } }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pdir/ok.vibe" "$pdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$pdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed ctor patterns did not compile (over-rejects)" >&2
  cat "$pdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
for bad in bad_arity bad_scalar; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$pdir/$bad.vibe" "$pdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$pdir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: ill-typed pattern $bad compiled (pattern check regressed)" >&2; exit 1
  fi
done
rm -rf "$pdir"
echo "[compiler-gate] constructor-pattern arity / scrutinee type checking ok"

# 34. indexing / tuple-projection soundness: `obj[i]` on a non-indexable scalar
#     and `t.N` past a tuple's arity must be rejected; indexing an Array/String
#     and an in-range tuple projection must still compile.
echo "[compiler-gate] 34/34 indexing / tuple-projection type checking"
idir="_build/_gate_index"
rm -rf "$idir"; mkdir -p "$idir"
cat > "$idir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let a = [10, 20, 30]
  let t = (1, 2)
  a[1] + t.0 + t.1
}
EOF
cat > "$idir/bad_index.vibe" <<'EOF'
export let _start: () -> Int = () -> { let n = 5; n[0] }
EOF
cat > "$idir/bad_tuple.vibe" <<'EOF'
export let _start: () -> Int = () -> { let t = (1, 2); t.5 }
EOF
cat > "$idir/bad_idxtype.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; a["x"] }
EOF
cat > "$idir/bad_idxelem.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; let s: String = a[0]; 0 }
EOF
cat > "$idir/bad_stridx.vibe" <<'EOF'
export let _start: () -> Int = () -> { let s: String = "abc"[0]; 0 }
EOF
cat > "$idir/bad_arrget.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; let s: String = Array::get(a, 0); 0 }
EOF
cat > "$idir/bad_arrpush.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; Array::push(a, "x"); 0 }
EOF
cat > "$idir/bad_arrset.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; Array::set(a, 0, "x"); 0 }
EOF
cat > "$idir/bad_arrmap.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; let b = Array::map(a, (x) -> { x + 1 }); let s: String = Array::get(b, 0); 0 }
EOF
cat > "$idir/bad_arrfold.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; let s: String = Array::fold(a, 0, (acc, x) -> { acc + x }); 0 }
EOF
cat > "$idir/bad_mapparam.vibe" <<'EOF'
export let _start: () -> Int = () -> { let b = Array::map([1, 2], (s: String) -> { s }); 0 }
EOF
cat > "$idir/bad_foldparam.vibe" <<'EOF'
export let _start: () -> Int = () -> { let r = Array::fold([1, 2], 0, (acc: String, x) -> { acc }); 0 }
EOF
cat > "$idir/bad_arrslice.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2, 3]; let b = Array::slice(a, 0, 2); let s: String = Array::get(b, 0); 0 }
EOF
cat > "$idir/bad_arrconcat.vibe" <<'EOF'
export let _start: () -> Int = () -> { let c = Array::concat([1, 2], [3, 4]); let s: String = Array::get(c, 0); 0 }
EOF
cat > "$idir/bad_arrconcatmix.vibe" <<'EOF'
export let _start: () -> Int = () -> { let c = Array::concat([1, 2], ["x"]); 0 }
EOF
cat > "$idir/bad_arrpushallmix.vibe" <<'EOF'
export let _start: () -> Int = () -> { let a = [1, 2]; Array::push_all(a, ["x"]); 0 }
EOF
cat > "$idir/bad_arrrev.vibe" <<'EOF'
export let _start: () -> Int = () -> { let b = Array::reverse([1, 2]); let s: String = Array::get(b, 0); 0 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$idir/ok.vibe" "$idir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$idir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed index/tuple did not compile (over-rejects)" >&2
  cat "$idir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
for bad in bad_index bad_tuple bad_idxtype bad_idxelem bad_stridx bad_arrget bad_arrpush bad_arrset bad_arrmap bad_arrfold bad_mapparam bad_foldparam bad_arrslice bad_arrconcat bad_arrconcatmix bad_arrpushallmix bad_arrrev; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$idir/$bad.vibe" "$idir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$idir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: ill-typed $bad compiled (index/tuple check regressed)" >&2; exit 1
  fi
done
rm -rf "$idir"
echo "[compiler-gate] indexing / tuple-projection type checking ok"

# 34b. match-arm guards (#666): `pat if cond => body` must DISPATCH on the guard.
#     Guards were previously parsed and silently DISCARDED — the arm was taken
#     unconditionally (`match 5 { n if n > 100 => 999, _ => 0 }` wrongly => 999).
#     Now desugared at parse time into nested EIf/EMatch over a bound scrutinee,
#     so a failed guard falls through to later arms, and pattern bindings (with
#     re-binding in the fall-through arm) stay in scope for the guard. Verify
#     the runtime answer, not just that it compiles.
echo "[compiler-gate] 34b/35 match-arm guard dispatch (#666)"
gdir="_build/_gate_guard"
rm -rf "$gdir"; mkdir -p "$gdir"
cat > "$gdir/guard.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let miss = match 5 { n if n > 100 => 999, _ => 7 }
  let hit = match 5 { n if n > 3 => 11, _ => 0 }
  let fall = match 5 { n if n > 100 => 1, n if n > 4 => 2, _ => 3 }
  let o = Some(2)
  let bind = match o { Some(x) if x > 5 => x, Some(y) => y + 100, _ => 0 }
  miss + hit + fall + bind
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gdir/guard.vibe" "$gdir/guard.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$gdir/guard.wasm" ]; then
  echo "[compiler-gate] FAIL: guarded match did not compile" >&2
  cat "$gdir/guard.wasm.diag" 2>/dev/null >&2; exit 1
fi
gres="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$gdir/guard.wasm" 2>/dev/null | tr -dc '0-9-')"
rm -rf "$gdir"
# 7 (guard misses -> wildcard) + 11 (guard hits) + 2 (second guard) + 102 (bind fall-through) = 122
if [ "$gres" != "122" ]; then
  echo "[compiler-gate] FAIL: guarded match returned '$gres' (expected 122 — guard dispatch wrong)" >&2; exit 1
fi
echo "[compiler-gate] match-arm guard dispatch ok (122)"

# 35. match exhaustiveness: a match on a concrete user enum must cover every
#     variant or carry a catch-all; a non-exhaustive match must be rejected.
#     Wildcard, full-coverage, and or-pattern coverage must still compile.
echo "[compiler-gate] 35/35 match exhaustiveness (enum variant coverage)"
xdir="_build/_gate_exhaust"
rm -rf "$xdir"; mkdir -p "$xdir"
cat > "$xdir/ok.vibe" <<'EOF'
enum Color { Red; Green; Blue }
export let _start: () -> Int = () -> {
  let a = match Red { Red => 1, Green => 2, Blue => 3 }
  let b = match Green { Red => 1, _ => 0 }
  let c = match Blue { Red | Green => 1, Blue => 3 }
  a + b + c
}
EOF
cat > "$xdir/bad.vibe" <<'EOF'
enum Color { Red; Green; Blue }
export let _start: () -> Int = () -> { match Red { Red => 1 } }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/ok.vibe" "$xdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: exhaustive matches did not compile (over-rejects)" >&2
  cat "$xdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/bad.vibe" "$xdir/bad.wasm" _start >/dev/null 2>&1 || true
if [ -s "$xdir/bad.wasm" ]; then
  echo "[compiler-gate] FAIL: non-exhaustive match compiled (exhaustiveness check regressed)" >&2; exit 1
fi
rm -rf "$xdir"
echo "[compiler-gate] match exhaustiveness ok"

# 36. literal-pattern type checking: an integer/string/boolean literal pattern
#     can only match a scrutinee of its own type — `match 5 { "x" => .. }` and a
#     nested `Some(true)` over `Option[Int]` must be rejected; matching literals
#     of the right type (incl. nested) must compile.
echo "[compiler-gate] 36/36 literal-pattern type checking"
ldir="_build/_gate_litpat"
rm -rf "$ldir"; mkdir -p "$ldir"
cat > "$ldir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let a = match 5 { 0 => 1, 5 => 2, _ => 0 }
  let o: Option[Int] = Some(1)
  let b = match o { Some(3) => 1, Some(_) => 9, None => 0 }
  a + b
}
EOF
cat > "$ldir/bad_lit.vibe" <<'EOF'
export let _start: () -> Int = () -> { match 5 { "x" => 1, _ => 0 } }
EOF
cat > "$ldir/bad_nested.vibe" <<'EOF'
export let _start: () -> Int = () -> { let o: Option[Int] = Some(1); match o { Some(true) => 1, _ => 0 } }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ldir/ok.vibe" "$ldir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$ldir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed literal patterns did not compile (over-rejects)" >&2
  cat "$ldir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
for bad in bad_lit bad_nested; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$ldir/$bad.vibe" "$ldir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$ldir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: ill-typed literal pattern $bad compiled (check regressed)" >&2; exit 1
  fi
done
rm -rf "$ldir"
echo "[compiler-gate] literal-pattern type checking ok"

# 37. unary `-` on a non-number and `break`/`continue` outside a loop must be
#     rejected; numeric negation and in-loop break/continue must compile.
echo "[compiler-gate] 37/37 unary-minus / break-outside-loop checking"
bdir="_build/_gate_breakneg"
rm -rf "$bdir"; mkdir -p "$bdir"
cat > "$bdir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let mut i = 0
  let mut s = 0
  while i < 10 { if i == 5 { break }; i = i + 1 }
  for x in [1, 2, 3] { if x == 2 { continue }; s = s + x }
  let neg = -i
  neg + s
}
EOF
cat > "$bdir/bad_neg.vibe" <<'EOF'
export let _start: () -> Int = () -> { let x = -"hi"; 0 }
EOF
cat > "$bdir/bad_break.vibe" <<'EOF'
export let _start: () -> Int = () -> { break; 0 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$bdir/ok.vibe" "$bdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$bdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed negation/break/continue did not compile (over-rejects)" >&2
  cat "$bdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
for bad in bad_neg bad_break; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$bdir/$bad.vibe" "$bdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$bdir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: ill-formed $bad compiled (unary-minus/break check regressed)" >&2; exit 1
  fi
done
rm -rf "$bdir"
echo "[compiler-gate] unary-minus / break-outside-loop checking ok"

# 38. tuple-pattern destructuring soundness: `let (a, b) = v` may only
#     destructure a tuple value; binding a tuple pattern over a concrete
#     non-tuple (`let (a, b) = 5`) must be rejected, while a genuine tuple
#     destructure must still compile.
echo "[compiler-gate] 38/38 tuple-pattern destructuring type checking"
tdir="_build/_gate_tupledestr"
rm -rf "$tdir"; mkdir -p "$tdir"
cat > "$tdir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> { let (a, b) = (1, 2); a + b }
EOF
cat > "$tdir/bad_nontuple.vibe" <<'EOF'
export let _start: () -> Int = () -> { let (a, b) = 5; a + b }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/ok.vibe" "$tdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed tuple destructure did not compile (over-rejects)" >&2
  cat "$tdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/bad_nontuple.vibe" "$tdir/bad_nontuple.wasm" _start >/dev/null 2>&1 || true
if [ -s "$tdir/bad_nontuple.wasm" ]; then
  echo "[compiler-gate] FAIL: ill-typed tuple destructure compiled (tuple-pattern check regressed)" >&2; exit 1
fi
rm -rf "$tdir"
echo "[compiler-gate] tuple-pattern destructuring type checking ok"

# 39. multi-feature end-to-end smoke: real programs that combine several language
#     features must compile through the fresh stage2 AND run to a known value —
#     a codegen/runtime regression net broader than the single-feature checks
#     above. `eff` deliberately exercises this session's work together: multi-
#     operation effect dispatch (#665), a match guard inside a handler arm
#     (#666), and the effect-call discipline (#626) in one program.
echo "[compiler-gate] 39/39 multi-feature end-to-end smoke"
sdir="_build/_gate_smoke"
rm -rf "$sdir"; mkdir -p "$sdir"
cat > "$sdir/clos.vibe" <<'EOF'
let rec fold: (Array[Int], Int, (Int, Int) -> Int) -> Int = (a, acc, f) -> {
  if Array::length(a) == 0 { acc }
  else { let h = Array::get(a, 0); fold(Array::slice(a, 1, Array::length(a)), f(acc, h), f) }
}
export let _start: () -> Int = () -> { let add = (x: Int, y: Int) -> { x + y }; fold([1, 2, 3, 4], 0, add) }
EOF
cat > "$sdir/eff.vibe" <<'EOF'
effect Calc { Add(Int) -> Int; Mul(Int) -> Int }
export let _start: () -> Int = () -> {
  handle {
    let a = perform Calc::Add(5)
    let b = perform Calc::Mul(3)
    a + b
  } with Calc {
    Add(n) => resume(match n { x if x > 3 => x * 10, _ => n });
    Mul(n) => resume(n + 100)
  }
}
EOF
cat > "$sdir/gen.vibe" <<'EOF'
enum Tree { Leaf(Int); Node(Tree, Tree) }
let rec sum: (Tree) -> Int = (t) -> { match t { Leaf(n) => n, Node(l, r) => sum(l) + sum(r) } }
export let _start: () -> Int = () -> { sum(Node(Node(Leaf(1), Leaf(2)), Leaf(3))) }
EOF
cat > "$sdir/teq.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let e1 = (1, "b") == (1, "b")
  let e2 = (1, 2, 3) == (1, 2, 3)
  let n1 = (1, "b") != (1, "c")
  let bad = (1, 2) == (1, 9)
  let v = if e1 { 1 } else { 0 }
  let v2 = if e2 { 10 } else { 0 }
  let v3 = if n1 { 100 } else { 0 }
  let v4 = if bad { 1000 } else { 0 }
  v + v2 + v3 + v4
}
EOF
cat > "$sdir/eeq.vibe" <<'EOF'
enum Sh { Circle(Int); Rect(Int, Int); Pt }
export let _start: () -> Int = () -> {
  let c = Circle(5)
  let v1 = if c == Circle(5) { 1 } else { 0 }
  let v2 = if Circle(5) != Circle(9) { 10 } else { 0 }
  let v3 = if Rect(3, 4) == Rect(3, 4) { 100 } else { 0 }
  let v4 = if Pt == Pt { 1000 } else { 0 }
  let v5 = if Circle(5) != Pt { 10000 } else { 0 }
  v1 + v2 + v3 + v4 + v5
}
EOF
cat > "$sdir/seq.vibe" <<'EOF'
struct V { x: Int; y: Int } derive(Eq)
struct N { name: String; value: Int } derive(Eq)
export let _start: () -> Int = () -> {
  let a = V::{ x: 1, y: 2 }
  let b = V::{ x: 1, y: 2 }
  let c = V::{ x: 3, y: 4 }
  let na = N::{ name: "foo", value: 1 }
  let nb = N::{ name: "foo", value: 1 }
  let v1 = if a == b { 1 } else { 0 }
  let v2 = if a != c { 20 } else { 0 }
  let v3 = if na == nb { 300 } else { 0 }
  let v4 = if a == c { 5000 } else { 0 }
  v1 + v2 + v3 + v4
}
EOF
cat > "$sdir/eveq.vibe" <<'EOF'
enum Color { Red; Green; Blue }
enum Sh { Circle(Int); Rect(Int, Int); Pt }
export let _start: () -> Int = () -> {
  let a = Green
  let b = Green
  let c = Red
  let s1 = Circle(5)
  let s2 = Circle(5)
  let v1 = if a == b { 1 } else { 0 }
  let v2 = if a != c { 20 } else { 0 }
  let v3 = if s1 == s2 { 3000 } else { 0 }
  let v4 = if s1 == Circle(9) { 40000 } else { 0 }
  v1 + v2 + v3 + v4
}
EOF
# qctor: qualified constructor references `Enum::Variant` (`Color::Green`,
# `Sh::Circle(5)`) resolve at check time and dispatch `==` structurally, both as
# direct literals and through qualified-ctor-bound variables. (#672 qualified
# ctors: checker resolve_qualified_ctor_ident + desugar unqualify + infer.)
cat > "$sdir/qctor.vibe" <<'EOF'
enum Color { Red; Green; Blue }
enum Sh { Circle(Int); Rect(Int, Int); Pt }
export let _start: () -> Int = () -> {
  let a = Color::Green
  let b: Color = Green
  let v1 = if a == b { 1 } else { 0 }
  let c = Sh::Circle(5)
  let d: Sh = Circle(5)
  let v2 = if c == d { 10 } else { 0 }
  let v3 = if Color::Red == Color::Red { 100 } else { 0 }
  let v4 = if Sh::Circle(5) == Sh::Circle(5) { 1000 } else { 0 }
  let v5 = if Sh::Circle(5) != Sh::Rect(1, 2) { 10000 } else { 0 }
  v1 + v2 + v3 + v4 + v5
}
EOF
# rec: recursive enum (`Tree`) and nested struct (`Outer { Inner }`) compare
# structurally — the generated comparators emit DIRECT `T::equals` calls for
# aggregate field/variant-arg types, so recursion closes without relying on
# operand type inference. (#672 recursion close: eq_for_typed.)
cat > "$sdir/rec.vibe" <<'EOF'
enum Tree { Leaf(Int); Node(Tree, Tree) } derive(Eq)
struct Inner { v: Int } derive(Eq)
struct Outer { a: Inner; b: Int } derive(Eq)
export let _start: () -> Int = () -> {
  let t1 = Node(Leaf(1), Leaf(2))
  let t2 = Node(Leaf(1), Leaf(2))
  let t3 = Node(Leaf(1), Leaf(3))
  let x = Outer::{ a: Inner::{ v: 1 }, b: 2 }
  let y = Outer::{ a: Inner::{ v: 1 }, b: 2 }
  let z = Outer::{ a: Inner::{ v: 9 }, b: 2 }
  let v1 = if t1 == t2 { 1 } else { 0 }
  let v2 = if t1 != t3 { 20 } else { 0 }
  let v3 = if x == y { 300 } else { 0 }
  let v4 = if x != z { 4000 } else { 0 }
  v1 + v2 + v3 + v4
}
EOF
# beq: builtin Option/Result and tuples with AGGREGATE payloads compare
# structurally (#825). Before the fix the bare-`==` dispatch only recovered the
# head name ("Option"/"Result") and word-compared payloads, so `Some([1,2]) ==
# Some([1,2])` was silently false (heap pointers differ); tuples containing
# arrays likewise. The dispatch now infers the full static shape from literal
# syntax and routes through eq_for_typed. v7 guards the #815 follow-up: the
# lowered match interpolates as true/false, not raw 1/0 (the boolish
# classifier sees through the lift_match_scrutinees `let __m_scrut_N` wrap).
cat > "$sdir/beq.vibe" <<'EOF'
enum Res[T, E] {
  Ok(T);
  Err(E)
}
export let _start: () -> Int = () -> {
  let v1 = if Some([1, 2]) == Some([1, 2]) { 1 } else { 0 }
  let v2 = if Some((1, 2)) == Some((1, 2)) { 20 } else { 0 }
  let v3 = if Some(Some(1)) == Some(Some(1)) { 300 } else { 0 }
  let v4 = if Ok([1, 2]) == Ok([1, 2]) { 4000 } else { 0 }
  let v5 = if ([1, 2], 0) == ([1, 2], 0) { 50000 } else { 0 }
  let v6 = if Some([1, 2]) != Some([1, 3]) { 600000 } else { 0 }
  let v7 = if "\{Some(1) == Some(1)}" == "true" { 7000000 } else { 0 }
  v1 + v2 + v3 + v4 + v5 + v6 + v7
}
EOF
# tann: function-type annotation arity. A parenthesized tuple parameter
# `((A, B)) -> R` is ONE tuple param, distinct from `(A, B) -> R`'s two params —
# previously both flattened to a two-param list and the tuple-param form failed
# to typecheck (`expected (Bool,Int)->Int, got (?t0)->Int`). Covers 0/1/2-param,
# a function-typed param (HOF), the tuple param, and tuple-param-plus-scalar.
# (parser_base.vibe parse_type_impl arity-preserving paren group.)
# tostr: `__to_string` of large integers (via interpolation) stringifies the
# DECIMAL value instead of misreading the i64 as a string handle. #664 root
# cause: a value whose high 32 bits fall below memory_size was treated as a
# string pointer, so its low 32 bits became a bogus length — a multi-gigabyte
# one crashed the persistent-sources-cache `String::concat` ("memory access out
# of bounds"), a `0` low word produced an empty string. The `64 <= ptr` and
# `ptr + len <= memory_size` bounds keep genuine strings on the identity path
# while routing large integers to decimal stringify.
# (compile_call.vibe __to_string heuristic.)
cat > "$sdir/tostr.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let v1 = if "\{4294967296}" == "4294967296" { 1 } else { 0 }
  let v2 = if "\{8294967296}" == "8294967296" { 20 } else { 0 }
  let v3 = if "\{1000000000000000000}" == "1000000000000000000" { 300 } else { 0 }
  let v4 = if "\{42}" == "42" { 4000 } else { 0 }
  v1 + v2 + v3 + v4
}
EOF
# ieq: integer `==` is sound for values >= 2^32 and large integer literals
# compile without truncation/trap. Root cause: the generic `eq` fell back to
# `str_eq` for bit-different operands, which reads an Int as a string fat-pointer
# `(ptr<<32)|len` — two unequal ints with a zero low word compared EQUAL, and a
# large low word made `str_eq`'s byte loop read OOB. The latter also surfaced as
# a compile trap for literals >= 2^39 (leb128's loop terminates on `v == 0`).
# Guards the `str_eq` fallback on both operands looking like real strings.
# (bodies_core_a1a1_eq.vibe emit_looks_like_string.)
#
# #678: v1/v2 use BARE integer VARIABLES (`let a = 1<<40; a == b`) — the residual
# the shape-only path could not classify. A bare ident now takes the direct
# i64.eq when its slot is int-tracked (compile_expr_tail expr_is_intish +
# int_local_slots, pruned at branch/arm boundaries). v5 is the regression guard:
# a bare String variable must still compare by CONTENT (a heap-built "abc" at a
# different offset than the interned literal), proving the int-tracking never
# misclassifies a string slot as int.
cat > "$sdir/ieq.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let a = 1 << 40
  let b = 1 << 41
  let v1 = if a == b { 0 } else { 1 }
  let c = 1 << 50
  let v2 = if c == c { 20 } else { 0 }
  let v3 = if "\{1 << 40}" == "1099511627776" { 300 } else { 0 }
  let v4 = if 2305843009213693951 > 1000000000 { 4000 } else { 0 }
  let s = String::concat("ab", "c")
  let v5 = if s == "abc" { 0 } else { 9000 }
  v1 + v2 + v3 + v4 + v5
}
EOF
# pstruct: struct field patterns in `match` (`S::{ x, y }`) bind fields by NAME
# (offset from the struct field-name table, so pattern field order is
# independent of declaration order) — previously fields were never bound
# (`undefined variable: x`). Covers full / reordered / partial field binds.
# (compile_match.vibe bind_struct_pat + is_catchall_pat PStruct.)
cat > "$sdir/pstruct.vibe" <<'EOF'
struct P { x: Int; y: Int }
struct N { a: Int; b: Int; c: Int }
export let _start: () -> Int = () -> {
  let p = P::{ x: 3, y: 5 }
  let n = N::{ a: 2, b: 4, c: 6 }
  let v1 = match p { P::{ x, y } => x * 10 + y }
  let v2 = match p { P::{ y, x } => x * 10 + y }
  let v3 = match n { N::{ a, c } => a + c }
  v1 + v2 + v3
}
EOF
# pneg: negative integer literal patterns `-5` (bare, in a constructor arg, and
# in a tuple element) — previously `unexpected in pattern: -`.
# (parser_base.vibe parse_pattern TMinus arm.)
cat > "$sdir/pneg.vibe" <<'EOF'
enum E { N(Int) }
export let _start: () -> Int = () -> {
  let v1 = match (0 - 5) { -5 => 1, _ => 0 }
  let v2 = match 5 { -5 => 0, _ => 20 }
  let v3 = match N(0 - 3) { N(-3) => 300, N(_) => 0 }
  let v4 = match (0 - 1, 2) { (-1, 2) => 4000, _ => 0 }
  v1 + v2 + v3 + v4
}
EOF
# interp: string interpolation `\{expr}` parses an arbitrary EXPRESSION
# (arithmetic, call, field access, multiple holes), not just a bare
# identifier — previously the embedded source was treated as an identifier name
# (`undefined variable: 1+1`). (parser_expr_primary.vibe build_interp_expr.)
# The `\(expr)` spelling was removed in 0.3.0 (#805; see bad_interp_paren in
# section 29 for the reject side).
cat > "$sdir/interp.vibe" <<'EOF'
struct P { x: Int }
let inc: (Int) -> Int = (n) -> { n + 1 }
export let _start: () -> Int = () -> {
  let a = 2
  let p = P::{ x: 7 }
  let v1 = if "\{a + 3}" == "5" { 1 } else { 0 }
  let v2 = if "\{inc(a)}" == "3" { 20 } else { 0 }
  let v3 = if "\{p.x}" == "7" { 300 } else { 0 }
  let v4 = if "\{a}-\{p.x}" == "2-7" { 4000 } else { 0 }
  v1 + v2 + v3 + v4
}
EOF
cat > "$sdir/tann.vibe" <<'EOF'
let two: (Int, Int) -> Int = (a, b) -> { a + b }
let one: (Int) -> Int = (x) -> { x + 1 }
let zero: () -> Int = () -> { 5 }
let hof: ((Int) -> Int, Int) -> Int = (f, x) -> { f(x) }
let tup1: ((Int, Int)) -> Int = (p) -> { let (a, b) = p; a + b }
let mix: ((Int, Int), Int) -> Int = (p, c) -> { let (a, b) = p; a + b + c }
export let _start: () -> Int = () -> {
  two(3, 4) + one(9) + zero() + hof((n) -> { n * 2 }, 10) + tup1((1, 2)) + mix((1, 2), 100)
}
EOF
smoke_check() {
  local nm="$1" want="$2"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$sdir/$nm.vibe" "$sdir/$nm.wasm" _start >/dev/null 2>&1 || true
  if [ ! -s "$sdir/$nm.wasm" ]; then
    echo "[compiler-gate] FAIL: smoke '$nm' did not compile (codegen regression)" >&2
    cat "$sdir/$nm.wasm.diag" 2>/dev/null >&2; exit 1
  fi
  local got
  got="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$sdir/$nm.wasm" 2>/dev/null | tr -dc '0-9-')"
  if [ "$got" != "$want" ]; then
    echo "[compiler-gate] FAIL: smoke '$nm' ran to '$got' (expected $want)" >&2; exit 1
  fi
}
smoke_check clos 10
smoke_check eff 153
smoke_check gen 6
smoke_check teq 111
smoke_check eeq 11111
smoke_check seq 321
smoke_check eveq 3021
smoke_check qctor 11111
smoke_check rec 4321
smoke_check beq 7654321
smoke_check tann 148
smoke_check interp 4321
smoke_check pneg 4321
smoke_check pstruct 78
smoke_check tostr 4321
smoke_check ieq 4321
rm -rf "$sdir"
echo "[compiler-gate] multi-feature end-to-end smoke ok (10/153/6/111/11111/321/3021/11111/4321/7654321/148/4321/4321/78/4321/4321)"
