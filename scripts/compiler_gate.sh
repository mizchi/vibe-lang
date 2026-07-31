#!/usr/bin/env bash
# Moon-free selfhost-only gate (#594 Stage 5): the post-`src/`-removal sign-off.
# Needs no MoonBit host — only the committed seed, the Rust runner, and the
# committed selfhost compiler source/bundles. Verifies:
#   1. committed bundles are in sync with the compiler source,
#   2. the committed flat module source is in sync (regenerated via the seed),
#   3. the selfhost compiler self-reproduces (seed -> stage1 -> stage2
#      -> stage3) with stage2 == stage3 (fixpoint) and each stage validates a
#      compiled sample (compile -> run smoke).
set -euo pipefail
: "${VIBE_RC:=0}"; export VIBE_RC  # cutover: pin the compiler self-build / gate baseline to bump (RC only when explicitly VIBE_RC=1)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

echo "[compiler-gate] 0/3 builtin parity (#415 B-3)"
bash scripts/check_builtin_parity.sh

echo "[compiler-gate] 1-2/3 bundle + module-source sync (via seed, combined)"
# One generate_bundle.sh pass checks both the three bundles and the flat
# module source (VIBE_CHECK_BUNDLES_TOO=1) — the previous separate
# check_bundle_sync.sh step re-ran the same ~25s generation a second time.
VIBE_CHECK_BUNDLES_TOO=1 bash scripts/check_module_source_sync.sh

echo "[compiler-gate] 3/3 selfbuild seed->stage1->stage2->stage3"
# The sync check above just proved the committed flat module source is
# byte-identical to what generate_bundle.sh would regenerate, so feed it to
# the selfbuild directly instead of paying a third ~25s regeneration.
VIBE_PREBUILT_MODULE_SOURCE="lib/@vibe/compiler/_cli_adapter_module_source.vibe" \
  bash scripts/generations.sh build --stage3

# Assert the stage2==stage3 fixpoint from the freshest generation manifest.
latest_gen="$(ls -dt _build/selfhost/generations/*/ 2>/dev/null | head -1 || true)"
if [ -z "$latest_gen" ] || [ ! -f "${latest_gen}generation.json" ]; then
  echo "[compiler-gate] FAIL: no generation manifest produced" >&2
  exit 1
fi
python3 - "${latest_gen}generation.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d.get("stages", {})
s2 = s.get("stage2", {}).get("sha256")
s3 = s.get("stage3", {}).get("sha256")
if not s2 or not s3:
    print("[compiler-gate] FAIL: missing stage2/stage3 sha", file=sys.stderr); sys.exit(1)
if s2 != s3:
    print(f"[compiler-gate] FAIL: stage2 != stage3 ({s2[:12]} != {s3[:12]})", file=sys.stderr); sys.exit(1)
print(f"[compiler-gate] fixpoint ok: stage2==stage3 ({s2[:12]})")
PY

# 3b. RC bootstrap gate (#556) -- CAVEAT: this reuses the manifest from the
# bump-pinned build above (VIBE_RC=0, line ~11), so it does NOT perform a
# fresh seed-compiles-stage1-under-RC build; it only re-checks that
# manifest's stage2==stage3 sha (already asserted just above).
# Status (#705/#715/#720, 2026-07-02): RC self-hosting is CORRECT end-to-end
# -- a bump stage2 compiling the flat source under VIBE_RC=1 yields a
# stage2_rc whose own re-compile (stage3_rc) is byte-identical, and the
# VIBE_RC=shadow instrumented build completes the same self-compile trap-
# free. The VIBE_RC=0 pin above is now a PERFORMANCE default only (RC binary
# ~1.7x wall, ~2.9x output size; see #705 final benchmark), not a
# correctness blocker. seed->stage1 must still run bump: the pinned seed
# predates RC ("not EFn" on VIBE_RC=1).
VIBE_RC_BOOTSTRAP_REUSE_GEN="${latest_gen}generation.json" \
  bash scripts/test_rc_bootstrap.sh

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
stage2_wasm="${latest_gen}stage2.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fsdir/main.vibe" "$fsdir/main.wasm" _start
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

let rec walk = (path: String, depth: Int) -> String with { FileIo } {
  let source = perform FileIo::ReadFile(path)
  if depth <= 0 {
    source
  } else {
    let s1 = walk("_build/_gate_deepresume/d/b.txt", depth - 1)
    let s2 = walk("_build/_gate_deepresume/d/c.txt", depth - 1)
    "\{source}|\{s1}|\{s2}"
  }
}

export let _start: () -> Int with { Fs } = () -> {
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
  "$drdir/main.vibe" "$drdir/main.wasm" _start >/dev/null 2>&1
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
  "$tdir/fail_test.vibe" "$tdir/fail_test.wasm" __no_entry__ >/dev/null 2>&1
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
  "$ndir/in.vibe" "$ndir/out.vibe" >/dev/null 2>&1
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
  "$ndir/keep_fn.vibe" "$ndir/keep_fn.out.vibe" >/dev/null 2>&1
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
  "$ndir/compile.vibe" "$ndir/out.wasm" _start >/dev/null 2>&1
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
printf 'struct Pair[T] {\n  a: T;\n  b: T\n}\n\nstruct Bag[T] {\n  xs: Array[T]\n}\n\nexport let _start: () -> Unit = () -> {\n  let p = Pair[Int]::{ a: 1, b: 2 }\n  assert_eq(p.a + p.b, 3)\n  let g = Bag[Int]::{ xs: [] }\n  Array::push(g.xs, 42)\n  assert_eq(Array::get(g.xs, 0), 42)\n  let n = Pair[Array[Int]]::{ a: [1, 2], b: [] }\n  assert_eq(Array::length(n.a), 2)\n}\n' > "$stdir/ok.vibe"
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
printf 'struct Pair[T] {\n  a: T;\n  b: T\n}\n\nexport let _start: () -> Unit = () -> {\n  let p = Pair[Int, String]::{ a: 1, b: 2 }\n  assert_eq(p.a, 1)\n}\n' > "$stdir/arity.vibe"
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
printf 'struct Pair[T] {\n  a: T;\n  b: T\n}\n\nexport let _start: () -> Unit = () -> {\n  let p = Pair[String]::{ a: 1, b: 2 }\n  assert_eq(p.a, "x")\n}\n' > "$stdir/pin.vibe"
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
  sha1, encode_uleb128, read_uleb128, list_of3, list_sum, from_array, contains
}
export let _start: () -> Int = () -> {
  assert(sha1("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d")
  let buf = encode_uleb128(624485)
  let (v, _) = read_uleb128(buf, 0)
  assert(eq(v, 624485))
  assert(eq(list_sum(list_of3(1, 2, 3)), 6))
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
  "$pdir/litpat.vibe" "$pdir/litpat.wasm" _start >/dev/null 2>&1
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
  "$ldir/in.vibe" "$ldir/out.vibe" >/dev/null 2>&1
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
  "$ndir/nested.vibe" "$ndir/nested.wasm" _start >/dev/null 2>&1
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
  "$wdir/fwd.vibe" "$wdir/fwd.wasm" _start >/dev/null 2>&1
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
  "$idir/interp.vibe" "$idir/interp.wasm" _start >/dev/null 2>&1
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
  "$cdir/cov_test.vibe" "$cdir/cov_test.wasm" __no_entry__ >/dev/null 2>&1
if [ ! -s "$cdir/cov_test.wasm" ]; then
  echo "[compiler-gate] FAIL: coverage build produced no wasm (#cov regressed)" >&2; exit 1
fi
VIBE_COV_OUT="$cdir/cov.json" VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$cdir/cov_test.wasm" >/dev/null 2>&1
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
  "$mbtdir/mbt.vibe" "$mbtdir/mbt.wasm" _start >/dev/null 2>&1
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
  "$mgdir/mg.vibe" "$mgdir/mg.wasm" _start >/dev/null 2>&1
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
sed '/^_start()$/d; /^__DATA__$/,$d' fixtures/trait_bound_ufcs_method.vibe > "$ufcsdir/ufcs.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ufcsdir/ufcs.vibe" "$ufcsdir/ufcs.wasm" _start >/dev/null 2>&1
if [ ! -s "$ufcsdir/ufcs.wasm" ]; then
  echo "[compiler-gate] FAIL: UFCS-on-bounded-tparam program did not compile" >&2
  cat "$ufcsdir/ufcs.wasm.diag" 2>/dev/null >&2; exit 1
fi
ufcs_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$ufcsdir/ufcs.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$ufcs_out" != "97097" ]; then
  echo "[compiler-gate] FAIL: UFCS-on-bounded-tparam mismatch (got '$ufcs_out', want 97097 -> #931 regressed)" >&2
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
  "$drvdir/drv.vibe" "$drvdir/drv.wasm" _start >/dev/null 2>&1
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

# 15b. extended derive(...) regression (#638): enum `derive(Ord/Show)`, struct +
#      enum `derive(Default)`, and `derive(Hash)` (Map-key usability). Each real
#      fixture is a `test "..."`-block suite; compile it through the fresh stage2
#      and run `_start` — every `assert` traps on failure, so a clean run == all
#      blocks passed. Covers multiple-derive (`derive(Eq, Ord, Show, Hash)`) too.
echo "[compiler-gate] 15b/15 extended derive (enum Ord/Show, Default, Hash)"
for fx in \
  fixtures/derive_ord_show_test.vibe \
  fixtures/derive_enum_ord_show_test.vibe \
  fixtures/derive_default_test.vibe \
  fixtures/derive_hash_test.vibe \
  fixtures/eq_array_option_fields.vibe; do
  fxout="_build/_gate_derive_ext_$(basename "${fx%.vibe}").wasm"
  rm -f "$fxout" "$fxout.diag"
  # ADR-0069: these are test-block suites with no `_start` of their own — the
  # test-runner `_start` synthesis needs the explicit `__no_entry__` sentinel
  # now (an unknown entry name is a compile error).
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$fx" "$fxout" __no_entry__ >/dev/null 2>&1
  if [ ! -s "$fxout" ]; then
    echo "[compiler-gate] FAIL: $fx did not compile" >&2
    cat "$fxout.diag" 2>/dev/null >&2; exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
      --invoke _start "$fxout" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: $fx has a failing test (assert trapped)" >&2
    exit 1
  fi
  rm -f "$fxout" "$fxout.diag" "$fxout.funcmap"
done
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
echo "[compiler-gate] extended derive (enum Ord/Show, Default, Hash) ok"

# 15c. railway `let*` / `?` generalized to Option (#635): the parser emits a
#      type-directed sentinel that the pre-check desugar lowers by the operand's
#      head type — `Option` (Some/None) or `Result` (Ok/Err, the default). The
#      fixtures are `test "..."`-block suites; compile each through the fresh
#      stage2 and run `_start` (a failing `assert` traps, so a clean run == all
#      blocks passed). Covers Option `let*`, Result `let*` unchanged, Option `?`
#      early-return-None, Result `?` early-return-Err, and the mixed-type type
#      error (a negative file that must NOT compile).
echo "[compiler-gate] 15c/15 railway let*/? Option generalization (#635)"
for fx in \
  fixtures/try_let_star_option_test.vibe \
  fixtures/try_question_option_test.vibe; do
  fxout="_build/_gate_railway_$(basename "${fx%.vibe}").wasm"
  rm -f "$fxout" "$fxout.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$fx" "$fxout" __no_entry__ >/dev/null 2>&1
  if [ ! -s "$fxout" ]; then
    echo "[compiler-gate] FAIL: $fx did not compile" >&2
    cat "$fxout.diag" 2>/dev/null >&2; exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
      --invoke _start "$fxout" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: $fx has a failing test (assert trapped)" >&2
    exit 1
  fi
  rm -f "$fxout" "$fxout.diag" "$fxout.funcmap"
done
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

# 15d. derive(Hash) transparent Map keys (#694): a `derive(Hash)` struct is
#      usable as a Map key through the method-bearing `Hash::hash_key` —
#      `map_key_to_string = [K: Hash](key) -> K::hash_key(key)` threads the
#      witness dict (#684) through the `[K: Hash]` `get_by`/`has_by`/`get_or_by`
#      generic->generic chain, and the derived structural `T::hash_key` (a
#      recursive `to_string`) is the key. INCLUDES a key with a nested aggregate
#      field (nested struct + Option + Array) to prove Layer-2 recursion. The
#      fixture is a `test "..."`-block suite; compile via the fresh stage2 and run
#      `_start` (a failing `assert` traps, so a clean run == all blocks passed).
echo "[compiler-gate] 15d/15 derive(Hash) transparent Map keys (#694)"
hkfx="fixtures/derive_hash_map_key_test.vibe"
hkout="_build/_gate_derive_hash_map_key.wasm"
rm -f "$hkout" "$hkout.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hkfx" "$hkout" __no_entry__ >/dev/null 2>&1
if [ ! -s "$hkout" ]; then
  echo "[compiler-gate] FAIL: $hkfx did not compile" >&2
  cat "$hkout.diag" 2>/dev/null >&2; exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$hkout" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: $hkfx has a failing test (assert trapped) -> #694 regressed" >&2
  exit 1
fi
rm -f "$hkout" "$hkout.diag" "$hkout.funcmap"
echo "[compiler-gate] derive(Hash) transparent Map keys ok"

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
  "$itdir/iter.vibe" "$itdir/iter.wasm" _start >/dev/null 2>&1
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
  "$lcdir/lc.vibe" "$lcdir/lc.wasm" _start >/dev/null 2>&1
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
  "$xidir/main.vibe" "$xidir/main.wasm" _start >/dev/null 2>&1
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
echo "[compiler-gate] 19/19 for-await unification regression"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fadir/fa.vibe" "$fadir/fa.wasm" _start >/dev/null 2>&1
if [ ! -s "$fadir/fa.wasm" ]; then
  echo "[compiler-gate] FAIL: for-await program did not compile" >&2
  cat "$fadir/fa.wasm.diag" 2>/dev/null >&2; exit 1
fi
fa_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$fadir/fa.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$fa_out" != "70" ]; then
  echo "[compiler-gate] FAIL: for-await unification mismatch (got '$fa_out', want 70 -> #636 regressed)" >&2
  exit 1
fi
rm -rf "$fadir"
echo "[compiler-gate] for-await unification regression ok"

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
  "$eidir/pos.vibe" "$eidir/pos.wasm" _start >/dev/null 2>&1
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
#     and the async `for await`-driven terminals) — these prelude tests are not
#     otherwise exercised by the gate.
echo "[compiler-gate] 21/21 prelude iterator combinator suites"
for suite in lib/@vibe/prelude/lazy_iter_test.vibe lib/@vibe/prelude/async_iter_test.vibe; do
  out="_build/_gate_prelude_iter_$(basename "${suite%.vibe}").wasm"
  # ADR-0069: test-block suites need the explicit `__no_entry__` sentinel for
  # the test-runner `_start` synthesis (unknown entry names are compile errors).
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$suite" "$out" __no_entry__ >/dev/null 2>&1
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
  "$gidir/pos.vibe" "$gidir/pos.wasm" _start >/dev/null 2>&1
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
  "$gjdir/pos.vibe" "$gjdir/pos.wasm" _start >/dev/null 2>&1
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
  "$nldir/nestedlit.vibe" "$nldir/nestedlit.wasm" _start >/dev/null 2>&1
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
#     `with { ... }` (or it is inside a `handle`). Declared variants must
#     compile; undeclared variants must be REJECTED. (`Error`/`Async` are out of
#     this slice; pure builtins like `Array::length` are never flagged.)
echo "[compiler-gate] 26/26 effect-call discipline (perform + builtin)"
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
export let _start: () -> Int with { Stdout } = () -> {
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
let leaf: (String) -> String with { Fs } = (p) -> {
  Fs::read_file(p)
}
let mid: (String) -> String = (p) -> {
  leaf(p)
}
export let _start: () -> Int with { Fs } = () -> {
  let _ = mid("x")
  42
}
EOF
# The same chain with `mid` correctly declaring Fs must compile.
cat > "$pfdir/good_transitive.vibe" <<'EOF'
let leaf: (String) -> String with { Fs } = (p) -> {
  Fs::read_file(p)
}
let mid: (String) -> String with { Fs } = (p) -> {
  leaf(p)
}
export let _start: () -> Int with { Fs } = () -> {
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
if ! grep -qF "hint: declare 'fn mid(...) -> T with { Fs }'" "$pfdir/bad_transitive.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: no-row reject lacks the declare-form fix-it hint (#639)" >&2
  cat "$pfdir/bad_transitive.wasm.diag" 2>/dev/null >&2; exit 1
fi
# #639: a caller that already declares a row gets the add-form hint carrying
# the sorted union (existing row preserved, missing effect appended).
cat > "$pfdir/bad_row_single.vibe" <<'EOF'
let leaf: (String) -> String with { Fs } = (p) -> {
  Fs::read_file(p)
}
let mid: (String) -> String with { Error } = (p) -> {
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
if ! grep -qF "effect row mismatch for 'mid': missing { Fs } (declared with { Error }, requires { Error, Fs })" "$pfdir/bad_row_single.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: partial-row reject lacks the declared-vs-required diff (#639)" >&2
  cat "$pfdir/bad_row_single.wasm.diag" 2>/dev/null >&2; exit 1
fi
if ! grep -qF "hint: add 'with { Error, Fs }' to 'mid'" "$pfdir/bad_row_single.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: partial-row reject lacks the add-form fix-it hint (#639)" >&2
  cat "$pfdir/bad_row_single.wasm.diag" 2>/dev/null >&2; exit 1
fi
# #639: multiple missing effects at one call site aggregate into ONE sorted
# set difference (leaf declares "Fs, Env" in reversed order; the diagnostic
# must render "{ Env, Fs }").
cat > "$pfdir/bad_row_multi.vibe" <<'EOF'
let leaf: (String) -> String with { Fs, Env } = (p) -> {
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
if ! grep -qF "hint: declare 'fn mid(...) -> T with { Env, Fs }'" "$pfdir/bad_row_multi.wasm.diag" 2>/dev/null; then
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
# caller invoking an imported `with { Fs }` function without declaring Fs used
# to compile (and reach the filesystem at runtime) while the same shape with a
# local callee was rejected. The env-seeded row closes the module boundary.
mkdir -p "$pfdir/sub"
cat > "$pfdir/sub/helper.vibe" <<'EOF'
export let read_it: (String) -> String with { Error, Fs } = (p) -> {
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

let g: (String) -> String with { Error, Fs } = (p) -> {
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

# 27d. `for await` classification (#827): a stream iterated through an
#      UNannotated lambda param gives the type-directed desugar no type head; it
#      used to fall back SILENTLY to the pull-closure lowering, which compiled
#      fine and then trapped at runtime (call_indirect on the stream's array
#      pointer). It must now be REJECTED at compile time; the annotated-param
#      equivalent (#822) must still compile and run to 42.
echo "[compiler-gate] 27d/27 for-await classification (#827)"
fadir="_build/_gate_forawait"
rm -rf "$fadir"; mkdir -p "$fadir"
cat > "$fadir/ok_annot.vibe" <<'EOF'
let consume: (Stream[Int]) -> Int = (s) -> {
  let mut sum = 0
  for await x in s {
    sum = sum + x
  }
  sum
}
export let _start: () -> Int = () -> { consume(Stream::once(42)) }
EOF
cat > "$fadir/bad_unannot.vibe" <<'EOF'
let consume = (s) -> Int {
  let mut sum = 0
  for await x in s {
    sum = sum + x
  }
  sum
}
export let _start: () -> Int = () -> { consume(Stream::once(42)) }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fadir/ok_annot.vibe" "$fadir/ok_annot.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$fadir/ok_annot.wasm" ]; then
  echo "[compiler-gate] FAIL: annotated-param for-await did not compile (#827 over-rejects)" >&2; exit 1
fi
fa_out="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$fadir/ok_annot.wasm" 2>/dev/null | tail -n 1)"
if [ "$fa_out" != "42" ]; then
  echo "[compiler-gate] FAIL: annotated-param for-await returned '$fa_out' (expected 42; #822 regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fadir/bad_unannot.vibe" "$fadir/bad_unannot.wasm" _start >/dev/null 2>&1 || true
if [ -s "$fadir/bad_unannot.wasm" ]; then
  echo "[compiler-gate] FAIL: unannotated-param for-await compiled (#827 regressed: pull-closure fallback trap)" >&2; exit 1
fi
rm -rf "$fadir"
echo "[compiler-gate] for-await classification ok"

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
let safe = () -> Int with { Error } {
  perform Error::Throw("fail")
  0
}
export let _start: () -> Int = () -> {
  handle { safe() } with Error { Throw(msg) => String::length(msg) }
}
EOF
cat > "$edir/via_throw.vibe" <<'EOF'
let safe = () -> Int with { Error } {
  throw("fail")
  0
}
export let _start: () -> Int = () -> {
  handle { safe() } with Error { Throw(msg) => String::length(msg) }
}
EOF
cat > "$edir/bad_resume_arm.vibe" <<'EOF'
let risky = () -> Int with { Error } {
  throw("boom")
  0
}
export let _start: () -> Int = () -> {
  handle { risky() } with Error { Throw(_m) => resume(0) }
}
EOF
# Codex P2 on #933: the rejection walk's catch-all used to end at EBreak /
# ELoop (and EMap/ESpread/ELabeledArg/EContinue/ERecord), so a resume tucked
# into `loop { break resume(0) }` reached codegen's meaningless tag-1 path.
cat > "$edir/bad_resume_loop.vibe" <<'EOF'
let risky = () -> Int with { Error } {
  throw("boom")
  0
}
export let _start: () -> Int = () -> {
  handle { risky() } with Error { Throw(_m) => loop { break resume(0) } }
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
fn main() -> Unit with { Stdout } {
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
cat > "$ppdir/shadow.vibe" <<'EOF'
fn println(s: String) -> Unit {
  print("S\n")
}

fn main() -> Unit {
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
export let _start: () -> Int = () -> { Array::length(Stream::once(41)) }
EOF
cat > "$tdir/bad_streamget.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::get(Stream::once(41), 0) }
EOF
cat > "$tdir/bad_streamset.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::set(Stream::once(41), 0, 1); 0 }
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

# 40. V128 SIMD intrinsics (#536): the first-class V128 type + 12 wasm-SIMD
#     intrinsics (v128_load/store/splat/eq/le_u/ge_u/and/or/not/bitmask/
#     any_true/all_true) must type-check, lower to valid v128 instructions, and
#     run correctly on the default non-RC linear backend. fixtures/
#     v128_intrinsics_test.vibe asserts lane-wise results via i8x16.bitmask; a
#     failing assert traps (`unreachable`), so a clean `_start` exit == pass.
echo "[compiler-gate] 40/40 V128 SIMD intrinsics compile+run"
vdir="_build/_gate_v128"
rm -rf "$vdir"; mkdir -p "$vdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/v128_intrinsics_test.vibe" "$vdir/v128.wasm" __no_entry__ >/dev/null 2>&1
if [ ! -s "$vdir/v128.wasm" ]; then
  echo "[compiler-gate] FAIL: v128 intrinsics test did not compile" >&2
  cat "$vdir/v128.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$vdir/v128.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: v128 intrinsics test trapped (assert failed)" >&2; exit 1
fi
rm -rf "$vdir"
echo "[compiler-gate] V128 SIMD intrinsics ok"

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
  "fixtures/simd_skip_ws_test.vibe" "$swdir/sw.wasm" __no_entry__ >/dev/null 2>&1
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
  "fixtures/region_capture_test.vibe" "$rcdir/rc.wasm" __no_entry__ >/dev/null 2>&1
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
echo "[compiler-gate] 40d/40 RC reclamation leak guard (tuple+cell+closure+enum+loop-consume)"
lkdir="_build/_gate_rc_leak"
rm -rf "$lkdir"; mkdir -p "$lkdir"
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/rc_reclaim_leak_test.vibe" "$lkdir/rc.wasm" main >/dev/null 2>&1
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
if [ "$lk_result" != "3200280000" ]; then
  echo "[compiler-gate] FAIL: rc_reclaim_leak wrong result $lk_result (want 3200280000)" >&2; exit 1
fi
if [ "$lk_used" -ge 2000 ]; then
  echo "[compiler-gate] FAIL: rc_reclaim_leak heap_used=$lk_used >= 2000 (RC reclamation regressed; ~800000 == full leak)" >&2; exit 1
fi
rm -rf "$lkdir"
echo "[compiler-gate] RC reclamation leak guard ok (heap_used=$lk_used B at N=20000)"

# 40e. V128 SIMD intrinsics under RC (#705 follow-up): step 40 only exercised
#      the bump backend. v128 boxes are tagged pointers with NO rc header, so
#      naively letting them flow through RC's dup/drop guards would misread
#      their payload bytes as a refcount and corrupt them; Perceus now treats
#      v128-producing let-bindings as scalar (never dup/drop'd), matching their
#      forward-only, never-freed lifetime under bump too. Also covers a distinct
#      RC-only bug where v128_load/store's byte offset and v128_splat_i8x16's
#      byte value were used raw instead of untagged (RC tags Int as n<<1),
#      silently computing the wrong SIMD lane bytes.
echo "[compiler-gate] 40e/40 V128 SIMD intrinsics compile+run under RC"
v2dir="_build/_gate_v128_rc"
rm -rf "$v2dir"; mkdir -p "$v2dir"
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/v128_intrinsics_test.vibe" "$v2dir/v128rc.wasm" __no_entry__ >/dev/null 2>&1
if [ ! -s "$v2dir/v128rc.wasm" ]; then
  echo "[compiler-gate] FAIL: v128 intrinsics test did not compile under RC" >&2
  cat "$v2dir/v128rc.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$v2dir/v128rc.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: v128 intrinsics test trapped under RC (assert failed)" >&2; exit 1
fi
rm -rf "$v2dir"
echo "[compiler-gate] V128 SIMD intrinsics under RC ok"

# 40f. RC shadow-liveness regression guard (#715 recurrence prevention).
#      Compiles the #715 shape corpus (every minimal shape that once produced
#      a use-after-free / double-free in the Perceus RC backend) with
#      VIBE_RC=shadow -- codegen that marks freed blocks in a shadow byte
#      table and executes `unreachable` on the FIRST dup-of-freed or
#      drop-of-freed -- and runs it. A regression in the RC dup/drop
#      accounting traps HERE, deterministically, at the faulting operation,
#      instead of corrupting the free list and crashing later at an
#      unrelated, binary-layout-dependent location ("moving target").
echo "[compiler-gate] 40f/40 RC shadow-liveness regression guard (#715 shapes)"
shdir="_build/_gate_rc_shadow"
rm -rf "$shdir"; mkdir -p "$shdir"
VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/rc_shadow_regression_test.vibe" "$shdir/shadow.wasm" main >/dev/null 2>&1
if [ ! -s "$shdir/shadow.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_shadow_regression fixture did not compile under VIBE_RC=shadow" >&2
  cat "$shdir/shadow.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
sh_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$shdir/shadow.wasm" 2>&1 | tail -1)"
if [ "$sh_out" != "122489" ]; then
  echo "[compiler-gate] FAIL: rc_shadow_regression got '$sh_out' (want 122489). A trap here means an RC dup/drop accounting regression touched a freed block -- see fixtures/rc_shadow_regression_test.vibe for which shapes are covered and issue #715 for the debugging methodology." >&2
  exit 1
fi
rm -rf "$shdir"
echo "[compiler-gate] RC shadow-liveness regression guard ok (122489)"

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
  "fixtures/gc_backend_smoke_test.vibe" "$gcdir/smoke.wasm" main >/dev/null 2>&1
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
  "fixtures/gc_backend_effect_evidence_dict.vibe" "$gcedir/out.wasm" main >/dev/null 2>&1
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
sed '/^__DATA__$/,$d' fixtures/effect_local_closure_by_value_wrapper.vibe > "$gcdeaddir/src.vibe"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gcdeaddir/src.vibe" "$gcdeaddir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$gcdeaddir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_wrapper.vibe did not compile under VIBE_BACKEND=gc" >&2
  cat "$gcdeaddir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
gcdead_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcdeaddir/out.wasm" 2>&1 | tail -1)"
if [ "$gcdead_out" != "105" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_wrapper.vibe under gc got '$gcdead_out' (want 105) -- dead-needing-function filtering regressed" >&2
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
#       fixtures/effect_effectset_expansion.vibe's `main` is exactly this
#       shape; confirmed via direct testing that it failed under
#       VIBE_BACKEND=gc with "only `with Error`..." before this change.
echo "[compiler-gate] 40h4/40 wasm-gc backend: self-discharging needing function no longer blocks effect migration (ADR-0076 gc follow-up)"
gcselfdir="_build/_gate_gc_self_discharge"
rm -rf "$gcselfdir"; mkdir -p "$gcselfdir"
sed '/^__DATA__$/,$d' fixtures/effect_effectset_expansion.vibe > "$gcselfdir/src.vibe"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gcselfdir/src.vibe" "$gcselfdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$gcselfdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_effectset_expansion.vibe did not compile under VIBE_BACKEND=gc" >&2
  cat "$gcselfdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
gcself_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcselfdir/out.wasm" 2>&1 | tail -1)"
if [ "$gcself_out" != "42" ]; then
  echo "[compiler-gate] FAIL: effect_effectset_expansion.vibe under gc got '$gcself_out' (want 42) -- self-discharging needing function filtering regressed" >&2
  exit 1
fi
rm -rf "$gcselfdir"
echo "[compiler-gate] wasm-gc backend self-discharging needing function filtering ok (42)"

# 40h5. ADR-0076 (#817) gc-backend follow-up: a local closure literal with
#       NO explicit `with {...}` annotation (its `eff` field is blank in the
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
sed '/^__DATA__$/,$d' fixtures/effect_handle_call_evidence_closure_literal.vibe > "$gcclosdir/src.vibe"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gcclosdir/src.vibe" "$gcclosdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$gcclosdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_closure_literal.vibe did not compile under VIBE_BACKEND=gc" >&2
  cat "$gcclosdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
gcclos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcclosdir/out.wasm" 2>&1 | tail -1)"
if [ "$gcclos_out" != "6" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_closure_literal.vibe under gc got '$gcclos_out' (want 6) -- hoisted closure row backfill or try-full-before-dropping-dead regressed" >&2
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
sed '/^__DATA__$/,$d' fixtures/gc_backend_effect_pure_builtin_index.vibe > "$gcidxdir/src.vibe"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gcidxdir/src.vibe" "$gcidxdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$gcidxdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: gc_backend_effect_pure_builtin_index.vibe did not compile under VIBE_BACKEND=gc" >&2
  cat "$gcidxdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
gcidx_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcidxdir/out.wasm" 2>&1 | tail -1)"
if [ "$gcidx_out" != "3" ]; then
  echo "[compiler-gate] FAIL: gc_backend_effect_pure_builtin_index.vibe under gc got '$gcidx_out' (want 3) -- pure-builtin allowlist regressed" >&2
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
sed '/^__DATA__$/,$d' fixtures/gc_backend_suberror_ctor.vibe > "$gcsuberrdir/src.vibe"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gcsuberrdir/src.vibe" "$gcsuberrdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$gcsuberrdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: gc_backend_suberror_ctor.vibe did not compile under VIBE_BACKEND=gc" >&2
  cat "$gcsuberrdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
gcsuberr_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcsuberrdir/out.wasm" 2>&1 | tail -1)"
if [ "$gcsuberr_out" != "4200" ]; then
  echo "[compiler-gate] FAIL: gc_backend_suberror_ctor.vibe under gc got '$gcsuberr_out' (want 4200) -- suberror ctor registration regressed" >&2
  exit 1
fi
rm -rf "$gcsuberrdir"
echo "[compiler-gate] wasm-gc backend suberror constructor registration ok (4200)"

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
  "fixtures/wit_gen_http.vibe" "$witdir/out.wit" main >/dev/null 2>&1
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
  "fixtures/serve_handler_smoke.vibe" "$svdir/handler.component.wasm" main >/dev/null 2>&1
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
echo "[compiler-gate] 40k/40 gc-lane to_string(Bool) regressions (#1015)"
gcbdir="_build/_gate_gc_to_string_bool"
rm -rf "$gcbdir"; mkdir -p "$gcbdir"
for gcb_fixture in to_string_bool_gc_test to_string_shadow_gc_test to_string_bool_scope_gc_test to_string_float_scope_gc_test; do
  VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/${gcb_fixture}.vibe" "$gcbdir/${gcb_fixture}.wasm" __no_entry__ >/dev/null 2>&1
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
echo "[compiler-gate] gc-lane to_string(Bool) regressions ok"

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
sed '/^__DATA__$/,$d' fixtures/effect_handle_replay_corruption.vibe > "$m2dir/m2_src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$m2dir/m2_src.vibe" "$m2dir/m2.wasm" main >/dev/null 2>&1
if [ ! -s "$m2dir/m2.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_replay_corruption.vibe did not compile" >&2
  cat "$m2dir/m2.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
m2_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$m2dir/m2.wasm" 2>&1 | tail -1)"
if [ "$m2_out" != "3013" ]; then
  echo "[compiler-gate] FAIL: effect_handle_replay_corruption got '$m2_out' (want 3013, the ADR-0076 Phase 2 direct-perform-inlining fixed value). This means the fix regressed -- e.g. inline_direct_performs stopped firing for this fixture's shape and it fell back to buggy replay (6016)." >&2
  exit 1
fi
rm -rf "$m2dir"
echo "[compiler-gate] handle-replay side-effect corruption regression guard ok (3013, ADR-0076 Phase 2 fix verified)"

# 40m. ADR-0071 step 1 (#755, docs/effectset.md): a `with { ... }` row item
#      may now name a single qualified operation (`Effect::op`), not just a
#      whole effect name -- collect_effect_names in
#      lib/@vibe/parser/parser_base.vibe. Parser-only slice: the row stays
#      an opaque comma-joined String (no new AST shape), so round-trip is
#      automatic; this gate just pins that the new grammar actually parses
#      and compiles/runs end to end. Operation-level CHECKING (rejecting a
#      perform of a DIFFERENT operation of the same effect when only one is
#      named) is a separate, larger change (step 3), not covered here.
echo "[compiler-gate] 40m/40 effect row operation-item grammar (ADR-0071 step 1/#755)"
a71dir="_build/_gate_effectset_row_item"
rm -rf "$a71dir"; mkdir -p "$a71dir"
sed '/^__DATA__$/,$d' fixtures/effect_row_operation_item.vibe > "$a71dir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a71dir/src.vibe" "$a71dir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$a71dir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_row_operation_item.vibe did not compile (with { Effect::op } row-item grammar regressed)" >&2
  cat "$a71dir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
a71_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$a71dir/out.wasm" 2>&1 | tail -1)"
if [ "$a71_out" != "42" ]; then
  echo "[compiler-gate] FAIL: effect_row_operation_item got '$a71_out' (want 42)" >&2
  exit 1
fi
rm -rf "$a71dir"
echo "[compiler-gate] effect row operation-item grammar ok"

# 40n. ADR-0071 step 3 (#755, docs/effectset.md): a VALID `effectset` (no
#      cycle, no operation-name collision) is now ACCEPTED and its members
#      are expanded into any `with { EffectsetName }` row item that
#      references it (checker_stmt.vibe's es_expand_stmts_effect_rows),
#      before the existing string-label containment machinery
#      (decl_authorizes_effect et al., unmodified) runs. This gate compiles
#      fixtures/effect_effectset_expansion.vibe, where a function's OWN
#      declared row is JUST an effectset name (`with { AskAll }`) and that
#      alone must authorize a transitively-called function requiring the
#      operation the effectset expands to (`Ask::Get`) -- proving expansion
#      is actually wired in, not just that the effectset parses. (Step 2's
#      prior behavior -- rejecting EVERY effectset declaration regardless of
#      validity -- is superseded by this step; see gate 40o below for what
#      STILL gets rejected.)
echo "[compiler-gate] 40n/40 effectset row expansion authorizes a transitive call (ADR-0071 step 3/#755)"
a71bdir="_build/_gate_effectset_expand"
rm -rf "$a71bdir"; mkdir -p "$a71bdir"
sed '/^__DATA__$/,$d' fixtures/effect_effectset_expansion.vibe > "$a71bdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a71bdir/src.vibe" "$a71bdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$a71bdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_effectset_expansion.vibe did not compile -- effectset row expansion regressed" >&2
  cat "$a71bdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
a71b_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$a71bdir/out.wasm" 2>&1 | tail -1)"
if [ "$a71b_out" != "42" ]; then
  echo "[compiler-gate] FAIL: effect_effectset_expansion got '$a71b_out' (want 42)" >&2
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
sed '/^__DATA__$/,$d' fixtures/err_effectset_cycle.vibe > "$a71cdir/cycle.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a71cdir/cycle.vibe" "$a71cdir/cycle.wasm" main >/dev/null 2>&1 || true
if [ -s "$a71cdir/cycle.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effectset_cycle.vibe compiled successfully -- circular effectset references must be rejected" >&2
  exit 1
fi
if ! grep -q "effectset cycle: A -> B -> A" "$a71cdir/cycle.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effectset_cycle.vibe did not produce the expected cycle diagnostic" >&2
  cat "$a71cdir/cycle.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
sed '/^__DATA__$/,$d' fixtures/err_effectset_operation_collision.vibe > "$a71cdir/collision.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a71cdir/collision.vibe" "$a71cdir/collision.wasm" main >/dev/null 2>&1 || true
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
a71ddir="_build/_gate_effectset_param_expand"
rm -rf "$a71ddir"; mkdir -p "$a71ddir"
sed '/^__DATA__$/,$d' fixtures/effect_effectset_param_expansion.vibe > "$a71ddir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a71ddir/src.vibe" "$a71ddir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$a71ddir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_effectset_param_expansion.vibe did not compile -- parameter-type effectset expansion regressed" >&2
  cat "$a71ddir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
a71d_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$a71ddir/out.wasm" 2>&1 | tail -1)"
if [ "$a71d_out" != "42" ]; then
  echo "[compiler-gate] FAIL: effect_effectset_param_expansion got '$a71d_out' (want 42)" >&2
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
#      (`with { Ask::Get }`, not the bare effect `Ask`) was incorrectly
#      rejected as still missing that requirement even though the handle
#      plainly covers it. This gate compiles
#      fixtures/effect_handle_operation_level_discharge.vibe, which has
#      exactly that shape and NO with-clause of its own on main.
echo "[compiler-gate] 40q/40 handler operation-level discharge (ADR-0071 step 4/#755)"
a71edir="_build/_gate_effectset_handle_discharge"
rm -rf "$a71edir"; mkdir -p "$a71edir"
sed '/^__DATA__$/,$d' fixtures/effect_handle_operation_level_discharge.vibe > "$a71edir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a71edir/src.vibe" "$a71edir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$a71edir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_operation_level_discharge.vibe did not compile -- handler operation-level discharge regressed" >&2
  cat "$a71edir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
a71e_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$a71edir/out.wasm" 2>&1 | tail -1)"
if [ "$a71e_out" != "42" ]; then
  echo "[compiler-gate] FAIL: effect_handle_operation_level_discharge got '$a71e_out' (want 42)" >&2
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
  "fixtures/contract_effectset_vpkg_main.vibe" "$a71fdir/out.wasm" main >/dev/null 2>&1
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
#      effectset alias (`fn f() -> T with { AskAll }`) reported a false
#      "signature mismatch" against an implementation spelled with the
#      literal operations it expands to (`with { Ask::Get }`), even though
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
  "fixtures/contract_effectset_signature_alias_main.vibe" "$a71gdir/out.wasm" main >/dev/null 2>&1
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
#      so an `effectset` alias (`with { AskAll }`) or a bare qualified
#      operation item with no accompanying plain effect-name item
#      (`with { Ask::Get }`) never matched `Ask`'s definition and fell
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
  "fixtures/wit_gen_effectset.vibe" "$witesdir/out.wit" main >/dev/null 2>&1
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
sed '/^__DATA__$/,$d' fixtures/effect_handle_call_evidence.vibe > "$edpdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edpdir/src.vibe" "$edpdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edpdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence.vibe did not compile" >&2
  cat "$edpdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edp_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edpdir/out.wasm" 2>&1 | tail -1)"
if [ "$edp_out" != "3013" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence.vibe got '$edp_out' (want 3013) -- evidence-dict threading through a helper call regressed" >&2
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
sed '/^__DATA__$/,$d' fixtures/effect_handle_call_evidence_branch.vibe > "$edpbdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edpbdir/src.vibe" "$edpbdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edpbdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_branch.vibe did not compile" >&2
  cat "$edpbdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edpb_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edpbdir/out.wasm" 2>&1 | tail -1)"
if [ "$edpb_out" != "2007" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_branch.vibe got '$edpb_out' (want 2007) -- either the invalid-wasm crash regressed, or the evidence-dict rewrite for branching bodies regressed" >&2
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
sed '/^__DATA__$/,$d' fixtures/effect_handle_call_evidence_error_mix.vibe > "$edpemdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edpemdir/src.vibe" "$edpemdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edpemdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_error_mix.vibe did not compile" >&2
  cat "$edpemdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edpem_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edpemdir/out.wasm" 2>&1 | tail -1)"
if [ "$edpem_out" != "5" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_error_mix.vibe got '$edpem_out' (want 5)" >&2
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
sed '/^__DATA__$/,$d' fixtures/effect_handle_multi_effect_row_nested.vibe > "$edpmedir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edpmedir/src.vibe" "$edpmedir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edpmedir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_multi_effect_row_nested.vibe did not compile" >&2
  cat "$edpmedir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edpme_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edpmedir/out.wasm" 2>&1 | tail -1)"
if [ "$edpme_out" != "2017" ]; then
  echo "[compiler-gate] FAIL: effect_handle_multi_effect_row_nested.vibe got '$edpme_out' (want 2017) -- multi-effect nested-handle migration regressed" >&2
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
sed '/^__DATA__$/,$d' fixtures/effect_handle_multi_effect_nested_handles.vibe > "$edpnhdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edpnhdir/src.vibe" "$edpnhdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edpnhdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_multi_effect_nested_handles.vibe did not compile" >&2
  cat "$edpnhdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edpnh_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edpnhdir/out.wasm" 2>&1 | tail -1)"
if [ "$edpnh_out" != "7" ]; then
  echo "[compiler-gate] FAIL: effect_handle_multi_effect_nested_handles.vibe got '$edpnh_out' (want 7) -- directly-nested handle pair migration regressed" >&2
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
sed '/^__DATA__$/,$d' fixtures/effect_handle_call_evidence_let_bound.vibe > "$edpletdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edpletdir/src.vibe" "$edpletdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edpletdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_let_bound.vibe did not compile" >&2
  cat "$edpletdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edplet_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edpletdir/out.wasm" 2>&1 | tail -1)"
if [ "$edplet_out" != "6" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_let_bound.vibe got '$edplet_out' (want 6) -- let-bound perform inside a needing function's body regressed (either an uncaught-exception crash or a wrong value)" >&2
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
sed '/^__DATA__$/,$d' fixtures/effect_handle_call_evidence_pure_helper.vibe > "$edppurdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edppurdir/src.vibe" "$edppurdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edppurdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_pure_helper.vibe did not compile" >&2
  cat "$edppurdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edppur_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edppurdir/out.wasm" 2>&1 | tail -1)"
if [ "$edppur_out" != "11" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_pure_helper.vibe got '$edppur_out' (want 11) -- pure-helper-call eligibility regressed" >&2
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
sed '/^__DATA__$/,$d' fixtures/effect_handle_call_evidence_struct_field.vibe > "$edpdotdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edpdotdir/src.vibe" "$edpdotdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edpdotdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_struct_field.vibe did not compile" >&2
  cat "$edpdotdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edpdot_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edpdotdir/out.wasm" 2>&1 | tail -1)"
if [ "$edpdot_out" != "6" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_struct_field.vibe got '$edpdot_out' (want 6) -- EDot eligibility regressed" >&2
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
sed '/^__DATA__$/,$d' fixtures/effect_handle_call_evidence_closure_literal.vibe > "$edpclodir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edpclodir/src.vibe" "$edpclodir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edpclodir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_closure_literal.vibe did not compile" >&2
  cat "$edpclodir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edpclo_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edpclodir/out.wasm" 2>&1 | tail -1)"
if [ "$edpclo_out" != "6" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_closure_literal.vibe got '$edpclo_out' (want 6) -- closure-literal eligibility regressed" >&2
  exit 1
fi
rm -rf "$edpclodir"
echo "[compiler-gate] evidence-dict pass closure literal ok"

# 40ad. ADR-0076 Phase 3 (#817): a needing function's row is spelled with an
#       `effectset` alias (`with { AskAll }` where `effectset AskAll = {
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
sed '/^__DATA__$/,$d' fixtures/effect_handle_call_evidence_effectset_alias.vibe > "$edpesdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edpesdir/src.vibe" "$edpesdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edpesdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_effectset_alias.vibe did not compile" >&2
  cat "$edpesdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edpes_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edpesdir/out.wasm" 2>&1 | tail -1)"
if [ "$edpes_out" != "2007" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_effectset_alias.vibe got '$edpes_out' (want 2007) -- either effectset-alias row recognition regressed, or it regressed back to the replay-inflated value" >&2
  exit 1
fi
rm -rf "$edpesdir"
echo "[compiler-gate] evidence-dict pass effectset alias ok"

# 40ae. ADR-0076 Phase 3 (#817): a needing function's row directly
#       enumerates a QUALIFIED operation (`with { Ask::Get }`) instead of
#       the bare effect name -- no `effectset` alias involved, exercising
#       edp_effect_name_of's `::`-prefix stripping directly rather than
#       effectset-table expansion (gate 40ad's own code path). Completeness
#       check written alongside the effectset-alias fix.
echo "[compiler-gate] 40ae/40 evidence-dict pass: needing function's row is a directly-qualified operation (ADR-0076 Phase 3/#817)"
edpqodir="_build/_gate_evidence_dict_qualified_op"
rm -rf "$edpqodir"; mkdir -p "$edpqodir"
sed '/^__DATA__$/,$d' fixtures/effect_handle_call_evidence_qualified_op.vibe > "$edpqodir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edpqodir/src.vibe" "$edpqodir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edpqodir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_qualified_op.vibe did not compile" >&2
  cat "$edpqodir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edpqo_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edpqodir/out.wasm" 2>&1 | tail -1)"
if [ "$edpqo_out" != "2007" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_qualified_op.vibe got '$edpqo_out' (want 2007) -- qualified-operation row recognition regressed, or it regressed back to the replay-inflated value" >&2
  exit 1
fi
rm -rf "$edpqodir"
echo "[compiler-gate] evidence-dict pass qualified-operation row ok"

# 40af. ADR-0076 Phase 3 (#817): a needing function's row combines a
#       concrete effect with an open row-variable TAIL (`with { Ask, e }`).
#       Initially assumed a genuine limitation alongside the
#       fully-row-polymorphic case; verified directly instead of continuing
#       to assume -- this already migrates its concrete effect via the same
#       row-containment mechanism as any other multi-effect row, since the
#       row-variable token never matches a real declared effect name and
#       is therefore inert to this pass's own matching logic.
echo "[compiler-gate] 40af/40 evidence-dict pass: row combines a concrete effect with an open row-variable tail (ADR-0076 Phase 3/#817)"
edprvdir="_build/_gate_evidence_dict_row_variable_tail"
rm -rf "$edprvdir"; mkdir -p "$edprvdir"
sed '/^__DATA__$/,$d' fixtures/effect_handle_call_evidence_row_variable_tail.vibe > "$edprvdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edprvdir/src.vibe" "$edprvdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edprvdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_row_variable_tail.vibe did not compile" >&2
  cat "$edprvdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edprv_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edprvdir/out.wasm" 2>&1 | tail -1)"
if [ "$edprv_out" != "2007" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_row_variable_tail.vibe got '$edprv_out' (want 2007) -- row-variable-tail row recognition regressed, or it regressed back to the replay-inflated value" >&2
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
sed '/^__DATA__$/,$d' fixtures/effect_handle_call_evidence_local_closure_capture_free.vibe > "$edplccfdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edplccfdir/src.vibe" "$edplccfdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edplccfdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_local_closure_capture_free.vibe did not compile" >&2
  cat "$edplccfdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edplccf_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edplccfdir/out.wasm" 2>&1 | tail -1)"
if [ "$edplccf_out" != "2007" ]; then
  echo "[compiler-gate] FAIL: effect_handle_call_evidence_local_closure_capture_free.vibe got '$edplccf_out' (want 2007) -- either #786's hoist regressed or evidence_dict_pass no longer forwards to the hoisted top-level name" >&2
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
sed '/^__DATA__$/,$d' fixtures/effect_local_closure_capture_conversion.vibe > "$lcccdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$lcccdir/src.vibe" "$lcccdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$lcccdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_capture_conversion.vibe did not compile" >&2
  cat "$lcccdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
lccc_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$lcccdir/out.wasm" 2>&1 | tail -1)"
if [ "$lccc_out" != "1015" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_capture_conversion.vibe got '$lccc_out' (want 1015) -- #1069's closure conversion regressed" >&2
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
sed '/^__DATA__$/,$d' fixtures/effect_local_closure_by_value_wrapper.vibe > "$lcbvwdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$lcbvwdir/src.vibe" "$lcbvwdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$lcbvwdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_wrapper.vibe did not compile" >&2
  cat "$lcbvwdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
lcbvw_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$lcbvwdir/out.wasm" 2>&1 | tail -1)"
if [ "$lcbvw_out" != "105" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_wrapper.vibe got '$lcbvw_out' (want 105) -- #1070's trivial-wrapper inlining regressed" >&2
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
sed '/^__DATA__$/,$d' fixtures/effect_local_closure_wrapper_referenced_as_value.vibe > "$lcwrvdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$lcwrvdir/src.vibe" "$lcwrvdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$lcwrvdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_wrapper_referenced_as_value.vibe did not compile" >&2
  cat "$lcwrvdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
lcwrv_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$lcwrvdir/out.wasm" 2>&1 | tail -1)"
if [ "$lcwrv_out" != "30" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_wrapper_referenced_as_value.vibe got '$lcwrv_out' (want 30) -- trivial-wrapper inlining broke a wrapper-as-value reference" >&2
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
sed '/^__DATA__$/,$d' fixtures/local_closure_wrapper_wrong_arity_not_inlined.vibe > "$lcwadir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$lcwadir/src.vibe" "$lcwadir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$lcwadir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: local_closure_wrapper_wrong_arity_not_inlined.vibe did not compile" >&2
  cat "$lcwadir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
lcwa_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$lcwadir/out.wasm" 2>&1 | tail -1)"
if [ "$lcwa_out" != "6" ]; then
  echo "[compiler-gate] FAIL: local_closure_wrapper_wrong_arity_not_inlined.vibe got '$lcwa_out' (want 6) -- trivial-wrapper pattern misfired on a wrong-arity call" >&2
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
sed '/^__DATA__$/,$d' fixtures/effect_inline_lambda_literal_hof_arg.vibe > "$illhadir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$illhadir/src.vibe" "$illhadir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$illhadir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_inline_lambda_literal_hof_arg.vibe did not compile" >&2
  cat "$illhadir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
illha_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$illhadir/out.wasm" 2>&1 | tail -1)"
if [ "$illha_out" != "10" ]; then
  echo "[compiler-gate] FAIL: effect_inline_lambda_literal_hof_arg.vibe got '$illha_out' (want 10) -- inline lambda literal IIFE/HOF-arg fix regressed" >&2
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
sed '/^__DATA__$/,$d' fixtures/effect_inline_lambda_literal_labeled_arg.vibe > "$illladir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$illladir/src.vibe" "$illladir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$illladir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_inline_lambda_literal_labeled_arg.vibe did not compile" >&2
  cat "$illladir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
illla_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$illladir/out.wasm" 2>&1 | tail -1)"
if [ "$illla_out" != "5" ]; then
  echo "[compiler-gate] FAIL: effect_inline_lambda_literal_labeled_arg.vibe got '$illla_out' (want 5) -- labeled-arg literal fix regressed" >&2
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
sed '/^__DATA__$/,$d' fixtures/dtpw_wrapper_shadowed_by_parameter.vibe > "$dtpwsdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$dtpwsdir/src.vibe" "$dtpwsdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$dtpwsdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: dtpw_wrapper_shadowed_by_parameter.vibe did not compile" >&2
  cat "$dtpwsdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
dtpws_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$dtpwsdir/out.wasm" 2>&1 | tail -1)"
if [ "$dtpws_out" != "99" ]; then
  echo "[compiler-gate] FAIL: dtpw_wrapper_shadowed_by_parameter.vibe got '$dtpws_out' (want 99) -- trivial-wrapper shadowing fix regressed" >&2
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
sed '/^__DATA__$/,$d' fixtures/evidence_dict_needing_shadowed_by_local.vibe > "$edpsdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edpsdir/src.vibe" "$edpsdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edpsdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: evidence_dict_needing_shadowed_by_local.vibe did not compile" >&2
  cat "$edpsdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edps_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edpsdir/out.wasm" 2>&1 | tail -1)"
if [ "$edps_out" != "47" ]; then
  echo "[compiler-gate] FAIL: evidence_dict_needing_shadowed_by_local.vibe got '$edps_out' (want 47) -- evidence-dict needing-forwarding shadowing fix regressed" >&2
  exit 1
fi
rm -rf "$edpsdir"
echo "[compiler-gate] evidence-dict needing-forwarding shadowing fix ok (47)"

# 40ap. #1070 (general case): a needing function calling its OWN
#       closure-typed parameter (not another named needing function) --
#       `apply_twice`'s body calls `f` (a `with { Ask }`-typed parameter)
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
sed '/^__DATA__$/,$d' fixtures/effect_local_closure_by_value_hof_general.vibe > "$edpgdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edpgdir/src.vibe" "$edpgdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edpgdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_hof_general.vibe did not compile" >&2
  cat "$edpgdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edpg_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edpgdir/out.wasm" 2>&1 | tail -1)"
if [ "$edpg_out" != "210" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_hof_general.vibe got '$edpg_out' (want 210) -- #1070 general-case closure-HOF-parameter fix regressed" >&2
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
sed '/^__DATA__$/,$d' fixtures/effect_local_closure_by_value_hof_escaping.vibe > "$edpedir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edpedir/src.vibe" "$edpedir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edpedir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_hof_escaping.vibe did not compile" >&2
  cat "$edpedir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edpe_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edpedir/out.wasm" 2>&1 | tail -1)"
if [ "$edpe_out" != "206" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_by_value_hof_escaping.vibe got '$edpe_out' (want 206) -- #1070 closure-HOF-parameter safety boundary regressed" >&2
  exit 1
fi
rm -rf "$edpedir"
echo "[compiler-gate] closure-typed HOF parameter safety boundary ok (206)"

# 40ar. #1070 (general case, second slice -- docs/effect-evidence-passing.md
#       追記25): a SELF-DISCHARGING owner -- a function with NO `with { Ask }`
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
sed '/^__DATA__$/,$d' fixtures/effect_local_closure_handle_owner_param.vibe > "$edphdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edphdir/src.vibe" "$edphdir/out.wasm" main >/dev/null 2>&1
if [ ! -s "$edphdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_handle_owner_param.vibe did not compile" >&2
  cat "$edphdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
edph_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$edphdir/out.wasm" 2>&1 | tail -1)"
if [ "$edph_out" != "285" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_handle_owner_param.vibe got '$edph_out' (want 285) -- #1070 self-discharging-owner closure-param fix regressed" >&2
  exit 1
fi
rm -rf "$edphdir"
echo "[compiler-gate] self-discharging owner's closure-typed parameter ok (285)"

# 41. ADR-0069 Phase 1: `fn main {}` sugar + entry/top-level hardening.
#     (a) ok_fnmain: the paren-less/annotation-less `fn main with { Stdout } { .. }`
#         special form compiles as `let main: () -> Unit with { Stdout }` and the
#         synthesized `_start` runs it (output contains 42).
#     (b) bad_entry_typo: a nonexistent entry name is a COMPILE ERROR (it used
#         to silently fall through to an empty test-runner `_start`); only the
#         explicit `__no_entry__` sentinel builds a test runner (exercised all
#         over this gate, e.g. step 15c).
#     (c) bad_toplevel_expr / bad_toplevel_mut: top level is declarations only —
#         a top-level expression statement / `let mut` is rejected by the checker.
echo "[compiler-gate] 41/41 ADR-0069 fn main sugar + entry/top-level hardening"
a69dir="_build/_gate_adr69"
rm -rf "$a69dir"; mkdir -p "$a69dir"
cat > "$a69dir/ok_fnmain.vibe" <<'EOF'
fn main with { Stdout } {
  Stdout::write_stream("42\n")
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a69dir/ok_fnmain.vibe" "$a69dir/ok_fnmain.wasm" main >/dev/null 2>&1
if [ ! -s "$a69dir/ok_fnmain.wasm" ]; then
  echo "[compiler-gate] FAIL: fn main {} sugar did not compile" >&2
  cat "$a69dir/ok_fnmain.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
a69_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$a69dir/ok_fnmain.wasm" 2>&1 || true)"
# `fn main` is `() -> Unit`: the program's own output must appear and the
# `_start` synthesis must NOT print the entry's return (a Unit entry used to
# get a stray trailing `0` line from the Int-return print_int convention,
# PR #834 review). Int-returning entries keep the print (see below).
if [ "$a69_out" != "42" ]; then
  echo "[compiler-gate] FAIL: fn main {} run output '$a69_out' (want exactly '42'; a trailing 0 line means the Unit entry hit print_int)" >&2
  exit 1
fi
# Int-returning `let main` keeps the historical return-print convention.
cat > "$a69dir/int_main.vibe" <<'EOF'
let main: () -> Int = () -> { 41 + 1 }
EOF
rm -f "$a69dir/int_main.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a69dir/int_main.vibe" "$a69dir/int_main.wasm" main >/dev/null 2>&1
if [ ! -s "$a69dir/int_main.wasm" ]; then
  echo "[compiler-gate] FAIL: Int-returning let main did not compile" >&2
  cat "$a69dir/int_main.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
a69_int_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$a69dir/int_main.wasm" 2>&1 || true)"
if [ "$a69_int_out" != "42" ]; then
  echo "[compiler-gate] FAIL: Int-returning main output '$a69_int_out' (want '42' — the return-print convention must survive for Int entries)" >&2
  exit 1
fi
cat > "$a69dir/typo.vibe" <<'EOF'
let main: () -> Int = () -> { 42 }
EOF
rm -f "$a69dir/typo.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a69dir/typo.vibe" "$a69dir/typo.wasm" mian >/dev/null 2>&1 || true
if [ -s "$a69dir/typo.wasm" ]; then
  echo "[compiler-gate] FAIL: entry typo 'mian' compiled to a module (should be 'entry not found' error)" >&2
  exit 1
fi
if ! grep -q "not found" "$a69dir/typo.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: entry typo diag missing 'not found' message" >&2
  cat "$a69dir/typo.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
cat > "$a69dir/toplevel_expr.vibe" <<'EOF'
let f = (n: Int) -> Int { n + 1 }
f(41)
export let _start: () -> Int = () -> { f(41) }
EOF
rm -f "$a69dir/toplevel_expr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a69dir/toplevel_expr.vibe" "$a69dir/toplevel_expr.wasm" _start >/dev/null 2>&1 || true
if [ -s "$a69dir/toplevel_expr.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level expression statement compiled (should be rejected, ADR-0069)" >&2
  exit 1
fi
cat > "$a69dir/toplevel_mut.vibe" <<'EOF'
let mut counter = 0
export let _start: () -> Int = () -> { counter }
EOF
rm -f "$a69dir/toplevel_mut.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$a69dir/toplevel_mut.vibe" "$a69dir/toplevel_mut.wasm" _start >/dev/null 2>&1 || true
if [ -s "$a69dir/toplevel_mut.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level let mut compiled (should be rejected, ADR-0069)" >&2
  exit 1
fi
rm -rf "$a69dir"
echo "[compiler-gate] ADR-0069 fn main sugar + entry/top-level hardening ok"

# 42. #830 regression: `let record { .. } = <expr>` (record-pattern
# destructuring, #760) parsed fine as a *local* `let` but hit a confusing raw
# "expected = but got {" parse error at the top level (the top-level `let`
# parser only special-cased `Name::{ .. }` struct-destructure and plain
# bindings, not the `record { .. }` sugar). Top-level statements don't go
# through the block-step desugar that makes the local form work (each
# top-level `let` is its own independent global binding, not one big
# continuation to expand into), so accepting the grammar there needs a real
# multi-statement expansion -- not a local change. Fixed by rejecting it at
# parse time with a clear, LOCATED, actionable error instead (docs/adr.md
# option (b) fallback) while leaving the working function-body form alone.
echo "[compiler-gate] 42/42 top-level record-pattern let rejection (#830)"
g830dir="_build/_gate_830"
rm -rf "$g830dir"; mkdir -p "$g830dir"
cat > "$g830dir/toplevel_record_destr.vibe" <<'EOF'
let r = record { name: "vibe", ver: 1 }
let record { name: n, ver: v } = r
export let _start: () -> Int = () -> { n; v; 0 }
EOF
rm -f "$g830dir/toplevel_record_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g830dir/toplevel_record_destr.vibe" "$g830dir/toplevel_record_destr.wasm" _start >/dev/null 2>&1 || true
if [ -s "$g830dir/toplevel_record_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level 'let record { .. } = ..' compiled (should be rejected, #830)" >&2
  exit 1
fi
if ! grep -q "top-level 'let record" "$g830dir/toplevel_record_destr.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: top-level record-pattern let diag missing the clear #830 message (still the raw 'expected = but got {' error?)" >&2
  cat "$g830dir/toplevel_record_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# The function-body form (the one #830 says already worked) must keep
# compiling AND running to the correct values -- this is the regression net
# for the working case, so a future change to the block-step record-destr
# desugar (parser_expr_dispatch.vibe StepRecordDestr/apply_record_destr)
# that breaks it fails here too, not just silently at the top level.
cat > "$g830dir/fnbody_record_destr.vibe" <<'EOF'
struct Rec { name: String; ver: Int }
fn describe(r: Rec) -> Int {
  let record { name: n, ver: v } = r
  String::length(n) * 100 + v
}
export let _start: () -> Int = () -> { describe(Rec::{ name: "vibe", ver: 7 }) }
EOF
rm -f "$g830dir/fnbody_record_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g830dir/fnbody_record_destr.vibe" "$g830dir/fnbody_record_destr.wasm" _start >/dev/null 2>&1
if [ ! -s "$g830dir/fnbody_record_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: function-body 'let record { .. } = ..' did not compile" >&2
  cat "$g830dir/fnbody_record_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g830_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g830dir/fnbody_record_destr.wasm" 2>&1 || true)"
if [ "$g830_out" != "407" ]; then
  echo "[compiler-gate] FAIL: function-body record-pattern destructure output '$g830_out' (want '407' = length(\"vibe\")*100 + 7)" >&2
  exit 1
fi
rm -rf "$g830dir"
echo "[compiler-gate] top-level record-pattern let rejection (#830) ok"

# 43. #844 regression: a `let`-style annotation used to be able to LAUNDER a
#     generic struct's real type arguments. `resolve_type_expr` types a bare
#     (unparameterized) reference to a generic struct annotation as bare
#     `CtStruct(name)`, discarding #829's real instantiated args; `unify`'s
#     `CtStruct`/`CtNamed` bridge (core/types.vibe, needed for the LEGITIMATE
#     case guarded by gate sections 18/20 above -- a bare-`S`-typed trait
#     return accepting a freshly `S::{...}`-constructed `S[X]`) then re-unifies
#     that bare annotation with ANY later, unrelated instantiation by name
#     alone. `let x: Box = Box::{v:1}; let y: Box[String] = x; y.v` used to
#     compile clean and read a stored `Int` as a `String` at runtime.
#     `check_assignable`'s `type_is_ground`/`type_no_named` heuristic
#     (deliberately lenient for a still-rigid/uninstantiated type parameter,
#     e.g. the very `LazyIter`/`Option[(T, Int)]` shape sections 18/20 guard)
#     ALSO independently swallows this specific mismatch even once the real
#     type args are preserved, since it treats every `CtNamed` as non-ground
#     regardless of how concrete its arguments are -- so the fix has two
#     additive parts (checker.vibe: `preserve_generic_instantiation` +
#     `detect_narrowed_generic_mismatch`, applied at both the top-level `SLet`
#     path (checker_stmt.vibe) and the local-`let` ascription-lambda call
#     shape) instead of touching `resolve_type_expr`'s ~20 call sites or the
#     shared `type_is_ground` (both judged too wide-blast-radius to land in
#     one pass, and the latter is exactly what sections 18/20 above exist to
#     protect).
echo "[compiler-gate] 43/43 generic-struct annotation re-narrowing regression (#844)"
g844dir="_build/_gate_844"
rm -rf "$g844dir"; mkdir -p "$g844dir"
cat > "$g844dir/toplevel_narrow.vibe" <<'EOF'
struct Box[T] { v: T }
let x: Box = Box::{ v: 1 }
let y: Box[String] = x
export let _start: () -> Int = () -> { String::length(y.v) }
EOF
rm -f "$g844dir/toplevel_narrow.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g844dir/toplevel_narrow.vibe" "$g844dir/toplevel_narrow.wasm" _start >/dev/null 2>&1 || true
if [ -s "$g844dir/toplevel_narrow.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level annotation-laundered generic-struct re-narrowing compiled (#844 regressed)" >&2
  exit 1
fi
if ! grep -q "binding type mismatch" "$g844dir/toplevel_narrow.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: top-level #844 rejection lacks the expected diagnostic" >&2
  cat "$g844dir/toplevel_narrow.wasm.diag" 2>/dev/null >&2; exit 1
fi
cat > "$g844dir/local_narrow.vibe" <<'EOF'
struct Box[T] { v: T }
fn bad() -> Int {
  let x: Box = Box::{ v: 1 }
  let y: Box[String] = x
  String::length(y.v)
}
export let _start: () -> Int = () -> { bad() }
EOF
rm -f "$g844dir/local_narrow.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g844dir/local_narrow.vibe" "$g844dir/local_narrow.wasm" _start >/dev/null 2>&1 || true
if [ -s "$g844dir/local_narrow.wasm" ]; then
  echo "[compiler-gate] FAIL: local-let annotation-laundered generic-struct re-narrowing compiled (#844 regressed)" >&2
  exit 1
fi
if ! grep -q "binding type mismatch" "$g844dir/local_narrow.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: local-let #844 rejection lacks the expected diagnostic" >&2
  cat "$g844dir/local_narrow.wasm.diag" 2>/dev/null >&2; exit 1
fi
# Positive controls: legitimate bare/explicit generic-struct annotation uses
# that must NOT be over-rejected by the #844 fix.
cat > "$g844dir/ok_bare_roundtrip.vibe" <<'EOF'
struct Box[T] { v: T }
let x: Box = Box::{ v: 1 }
let y: Box = x
export let _start: () -> Int = () -> { y.v }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g844dir/ok_bare_roundtrip.vibe" "$g844dir/ok_bare_roundtrip.wasm" _start >/dev/null 2>&1
if [ ! -s "$g844dir/ok_bare_roundtrip.wasm" ]; then
  echo "[compiler-gate] FAIL: bare-to-bare generic-struct annotation round-trip over-rejected (#844 fix too aggressive)" >&2
  cat "$g844dir/ok_bare_roundtrip.wasm.diag" 2>/dev/null >&2; exit 1
fi
g844_ok_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g844dir/ok_bare_roundtrip.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g844_ok_out" != "1" ]; then
  echo "[compiler-gate] FAIL: bare-to-bare generic-struct round-trip returned '$g844_ok_out' (want 1)" >&2
  exit 1
fi
cat > "$g844dir/ok_matching.vibe" <<'EOF'
struct Box[T] { v: T }
let x: Box[Int] = Box::{ v: 41 }
let y: Box[Int] = x
export let _start: () -> Int = () -> { y.v + 1 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g844dir/ok_matching.vibe" "$g844dir/ok_matching.wasm" _start >/dev/null 2>&1
if [ ! -s "$g844dir/ok_matching.wasm" ]; then
  echo "[compiler-gate] FAIL: explicit matching generic-struct instantiation over-rejected (#844 fix too aggressive)" >&2
  cat "$g844dir/ok_matching.wasm.diag" 2>/dev/null >&2; exit 1
fi
g844_ok2_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g844dir/ok_matching.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g844_ok2_out" != "42" ]; then
  echo "[compiler-gate] FAIL: explicit matching generic-struct instantiation returned '$g844_ok2_out' (want 42)" >&2
  exit 1
fi
rm -rf "$g844dir"
echo "[compiler-gate] generic-struct annotation re-narrowing regression (#844) ok"

# 44. #859 regression: top-level pattern `let` (tuple destructure
#     `let (a, b) = pair`, named-struct destructure `let Name::{ x, y } = v`)
#     parsed AND type-checked cleanly but codegen had no case for a
#     top-level `SLetPat` at all -- ANY pattern shape crashed with a raw
#     "undefined variable" instead of either working or producing a proper
#     diagnostic (pattern-let lowering only exists as a block-level
#     mechanism with an enclosing expression continuation to desugar into;
#     top-level statements have no such continuation). Same treatment #830
#     already gave the `record { .. }` form: reject with a clear, LOCATED
#     error instead of the misleading internal crash.
# 43b. #1078: two enums declaring a same-named variant in one compiled unit
#      is a hard, descriptive error naming both enums -- previously the
#      flat name-keyed env silently resolved every bare construction to the
#      LAST-registered signature, producing an arity/argument-type mismatch
#      pointing at the WRONG declaration (or a silent wrong-tag miscompile
#      when signatures matched). Unrelated packages meet in one unit via
#      the merge/flatten lane, which is how #1078 was originally hit.
echo "[compiler-gate] 43b/43 enum constructor name collision rejection (#1078)"
g1078dir="_build/_gate_1078"
rm -rf "$g1078dir"; mkdir -p "$g1078dir"
cat > "$g1078dir/ctor_collision.vibe" <<'EOF'
enum AEnum {
  Mk(Int)
}

enum BEnum {
  Mk(String, String)
}

fn use_a() -> AEnum {
  Mk(1)
}

export let main = () -> Int {
  let a = use_a()
  1
}
EOF
rm -f "$g1078dir/ctor_collision.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g1078dir/ctor_collision.vibe" "$g1078dir/ctor_collision.wasm" main >/dev/null 2>&1 || true
if [ -s "$g1078dir/ctor_collision.wasm" ]; then
  echo "[compiler-gate] FAIL: same-named variant across two enums compiled (should be rejected, #1078)" >&2
  exit 1
fi
if ! grep -q "constructor name collision" "$g1078dir/ctor_collision.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: ctor-collision diag missing the descriptive #1078 message (still the misleading wrong-declaration mismatch?)" >&2
  cat "$g1078dir/ctor_collision.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$g1078dir"
echo "[compiler-gate] enum constructor name collision rejection ok (#1078)"

echo "[compiler-gate] 44/44 top-level pattern let rejection (#859)"
g859dir="_build/_gate_859"
rm -rf "$g859dir"; mkdir -p "$g859dir"
cat > "$g859dir/toplevel_tuple_destr.vibe" <<'EOF'
let (a, b) = (10, 32)
export let _start: () -> Int = () -> { a + b }
EOF
rm -f "$g859dir/toplevel_tuple_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g859dir/toplevel_tuple_destr.vibe" "$g859dir/toplevel_tuple_destr.wasm" _start >/dev/null 2>&1 || true
if [ -s "$g859dir/toplevel_tuple_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level 'let (a, b) = ..' compiled (should be rejected, #859)" >&2
  exit 1
fi
if ! grep -q "top-level 'let (\.\.)" "$g859dir/toplevel_tuple_destr.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: top-level tuple-pattern let diag missing the clear #859 message (still the raw 'undefined variable' crash?)" >&2
  cat "$g859dir/toplevel_tuple_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
cat > "$g859dir/toplevel_struct_destr.vibe" <<'EOF'
struct Pair { x: Int; y: Int }
let Pair::{ x, y } = Pair::{ x: 10, y: 32 }
export let _start: () -> Int = () -> { x + y }
EOF
rm -f "$g859dir/toplevel_struct_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g859dir/toplevel_struct_destr.vibe" "$g859dir/toplevel_struct_destr.wasm" _start >/dev/null 2>&1 || true
if [ -s "$g859dir/toplevel_struct_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level 'let Name::{ .. } = ..' compiled (should be rejected, #859)" >&2
  exit 1
fi
if ! grep -q "top-level 'let Name::{ \.\. }" "$g859dir/toplevel_struct_destr.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: top-level struct-pattern let diag missing the clear #859 message (still the raw 'undefined variable' crash?)" >&2
  cat "$g859dir/toplevel_struct_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# The function-body forms (which already worked, per the #859 writeup) must
# keep compiling AND running to the correct values -- the regression net for
# the working case, so a future change to the block-step destructure desugar
# (parser_expr_dispatch.vibe apply_record_destr/apply_struct_destr) that
# breaks it fails here too, not just silently at the top level.
cat > "$g859dir/fnbody_tuple_destr.vibe" <<'EOF'
fn compute() -> Int {
  let (a, b) = (10, 32)
  a + b
}
export let _start: () -> Int = () -> { compute() }
EOF
rm -f "$g859dir/fnbody_tuple_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g859dir/fnbody_tuple_destr.vibe" "$g859dir/fnbody_tuple_destr.wasm" _start >/dev/null 2>&1
if [ ! -s "$g859dir/fnbody_tuple_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: function-body 'let (a, b) = ..' did not compile" >&2
  cat "$g859dir/fnbody_tuple_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g859_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g859dir/fnbody_tuple_destr.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g859_out" != "42" ]; then
  echo "[compiler-gate] FAIL: function-body tuple-pattern destructure output '$g859_out' (want 42)" >&2
  exit 1
fi
rm -rf "$g859dir"
echo "[compiler-gate] top-level pattern let rejection (#859) ok"

# 45/45 (#897 Phase 4, ADR-0070): every directory in the repo must have
# migrated off the old index.vibei/bare-index.vibe facade to a proper
# index.vpkg contract. This is the CI-required half of the diagnostic
# implemented in loader/loader.vibe's find_missing_vpkg_dirs (Phase 1) --
# a passive `vibe check` command is easy to forget to run by hand, so once
# Phase 3 finished migrating all 76 directories this became a required gate
# to prevent a future PR from silently reintroducing a plain index.vibe dir.
# 44b. #944 (ADR-0073 stage B): checked-Error row discipline is ON by
#      default -- a row-less caller of a `with { Error }` function is
#      rejected with the row-mismatch diagnostic; VIBE_CHECK_ERROR_ROW=0
#      is the opt-out escape hatch that restores the old exemption; a
#      caller that discharges via `handle .. with Error` compiles and
#      runs under the default.
echo "[compiler-gate] 44b/44 checked-Error row discipline default-on (#944 stage B)"
g944dir="_build/_gate_944"
rm -rf "$g944dir"; mkdir -p "$g944dir"
cat > "$g944dir/leak.vibe" <<'EOF'
fn boom(x: Int) -> Int with { Error } {
  if x == 0 {
    throw("zero")
  }
  x
}

fn pure_caller(x: Int) -> Int {
  boom(x)
}

export let main = () -> Int {
  pure_caller(1)
}
EOF
cat > "$g944dir/discharged.vibe" <<'EOF'
fn boom(x: Int) -> Int with { Error } {
  if x == 0 {
    throw("zero")
  }
  x
}

export let main = () -> Int {
  handle {
    boom(1)
  } with Error {
    Throw(_) => 0
  }
}
EOF
rm -f "$g944dir/leak_off.wasm"
VIBE_CHECK_ERROR_ROW=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g944dir/leak.vibe" "$g944dir/leak_off.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$g944dir/leak_off.wasm" ]; then
  echo "[compiler-gate] FAIL: VIBE_CHECK_ERROR_ROW=0 opt-out did not restore the old exemption (#944)" >&2
  cat "$g944dir/leak_off.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -f "$g944dir/leak_on.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g944dir/leak.vibe" "$g944dir/leak_on.wasm" main >/dev/null 2>&1 || true
if [ -s "$g944dir/leak_on.wasm" ]; then
  echo "[compiler-gate] FAIL: default-on checked-Error mode did not reject the row-less caller (#944)" >&2
  exit 1
fi
if ! grep -q "missing { Error }" "$g944dir/leak_on.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: checked-Error rejection diag missing the row-mismatch message (#944)" >&2
  cat "$g944dir/leak_on.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -f "$g944dir/discharged.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g944dir/discharged.vibe" "$g944dir/discharged.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$g944dir/discharged.wasm" ]; then
  echo "[compiler-gate] FAIL: checked-Error mode rejected a handle-with-Error discharge (over-strict, #944)" >&2
  cat "$g944dir/discharged.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g944_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$g944dir/discharged.wasm" 2>&1 | tail -1)"
if [ "$g944_out" != "1" ]; then
  echo "[compiler-gate] FAIL: checked-Error discharged sample got '$g944_out' (want 1)" >&2
  exit 1
fi
rm -rf "$g944dir"
echo "[compiler-gate] opt-in checked-Error row discipline ok (#944 stage A)"

# 44c. #944 (ADR-0073 stage C, "entry boundary A"): an entry declared
#      `with { Error }` whose Throw escapes must produce the stderr
#      diagnostic and evaluate to 1 (unsuccessful outcome) instead of
#      leaking a raw WebAssembly.Exception out of the entry.
echo "[compiler-gate] 44c/44 entry-boundary Error handler (#944 stage C)"
g944cdir="_build/_gate_944c"
rm -rf "$g944cdir"; mkdir -p "$g944cdir"
sed '/^__DATA__$/,$d' fixtures/entry_error_boundary.vibe > "$g944cdir/src.vibe"
rm -f "$g944cdir/out.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g944cdir/src.vibe" "$g944cdir/out.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$g944cdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: entry_error_boundary.vibe did not compile (#944 stage C)" >&2
  cat "$g944cdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g944c_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$g944cdir/out.wasm" 2>"$g944cdir/stderr.txt" | tail -1)"
if [ "$g944c_out" != "1" ]; then
  echo "[compiler-gate] FAIL: entry_error_boundary got '$g944c_out' (want 1) -- boundary handler value regressed (#944 stage C)" >&2
  exit 1
fi
if ! grep -q "vibe: uncaught error: boom" "$g944cdir/stderr.txt"; then
  echo "[compiler-gate] FAIL: entry_error_boundary stderr missing the boundary diagnostic (#944 stage C)" >&2
  cat "$g944cdir/stderr.txt" >&2 || true
  exit 1
fi
rm -rf "$g944cdir"
echo "[compiler-gate] entry-boundary Error handler ok (#944 stage C)"

# 44d. #1087: a NON-tail `throw` inline in a `handle .. with Error` body
#      must abort the body -- the arm's value (1) is the handle's result,
#      not the body's continuation value (41). The ADR-0076 Phase 2 inliner
#      used to splice the arm in place of the perform (resumptive
#      semantics), running the arm but discarding its value; Error arms are
#      now excluded from that pass (idp_arms_discharge_error).
echo "[compiler-gate] 44d/44 with-Error non-tail throw abort (#1087)"
g1087dir="_build/_gate_1087"
rm -rf "$g1087dir"; mkdir -p "$g1087dir"
sed '/^__DATA__$/,$d' fixtures/effect_handle_error_nontail.vibe > "$g1087dir/src.vibe"
rm -f "$g1087dir/out.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g1087dir/src.vibe" "$g1087dir/out.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$g1087dir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_error_nontail.vibe did not compile (#1087)" >&2
  exit 1
fi
g1087_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$g1087dir/out.wasm" 2>/dev/null | tail -1)"
if [ "$g1087_out" != "1" ]; then
  echo "[compiler-gate] FAIL: effect_handle_error_nontail got '$g1087_out' (want 1, NOT 41) -- a non-tail throw in a with-Error handle body ran the body's continuation instead of aborting to the arm's value (#1087; check idp_arms_discharge_error in inline_direct_perform.vibe)" >&2
  exit 1
fi
rm -rf "$g1087dir"
echo "[compiler-gate] with-Error non-tail throw abort ok (#1087)"

# 44e. #1092: `vibe diagnostics` on a file whose FIRST error sits past a
#      multi-KB prefix must report it, not blow the wasm call stack. The
#      prelude's String::index_of (and its sibling scanners) used to recurse
#      once per scanned character via a local `let rec` closure -- a
#      call_indirect self-call the top-level-only TCO pass never loop-ifies
#      -- so the located-error path (which searches the whole source text)
#      crashed with "RangeError: Maximum call stack size exceeded" at a
#      ~4-5KB error offset (lsp_server.vibe was undiagnosable). The prelude
#      scanners are iterative now; this pins that.
echo "[compiler-gate] 44e/44 diagnostics on multi-KB source with a late error (#1092)"
g1092dir="_build/_gate_1092"
rm -rf "$g1092dir"; mkdir -p "$g1092dir"
{
  i=0
  while [ $i -lt 300 ]; do
    printf 'fn f%d(x: Int) -> Int {\n  x + %d\n}\n\n' "$i" "$i"
    i=$((i + 1))
  done
  printf 'fn g(n: Int) -> Int {\n  unknown_name_xyz(n)\n}\n'
} > "$g1092dir/src.vibe"
rm -f "$g1092dir/diag.txt"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g1092dir/src.vibe" "$g1092dir/diag.txt" >/dev/null 2>&1 || true
if [ ! -f "$g1092dir/diag.txt" ]; then
  echo "[compiler-gate] FAIL: diagnostics crashed on a ~11KB source with a late error (#1092 regressed -- check the prelude string scanners for reintroduced per-char recursion)" >&2
  exit 1
fi
if ! grep -q "unknown name: unknown_name_xyz" "$g1092dir/diag.txt"; then
  echo "[compiler-gate] FAIL: diagnostics on the late-error source missed the error (#1092)" >&2
  cat "$g1092dir/diag.txt" >&2 || true
  exit 1
fi
rm -rf "$g1092dir"
echo "[compiler-gate] diagnostics on multi-KB source ok (#1092)"

echo "[compiler-gate] 45/45 missing index.vpkg scan (#897 Phase 4)"
vpkgdir="_build/_gate_vpkg_scan"
rm -rf "$vpkgdir"; mkdir -p "$vpkgdir"
VIBE_MISSING_VPKG_SCAN=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ROOT_DIR" "$vpkgdir/scan.out" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$vpkgdir/scan.out" ]; then
  echo "[compiler-gate] FAIL: missing-vpkg scan produced no output" >&2
  cat "$vpkgdir/scan.out.diag" 2>/dev/null >&2
  exit 1
fi
if ! grep -q "^ok: no directories missing index.vpkg" "$vpkgdir/scan.out"; then
  echo "[compiler-gate] FAIL: directories still missing index.vpkg (#897 Phase 4):" >&2
  cat "$vpkgdir/scan.out" >&2
  exit 1
fi
rm -rf "$vpkgdir"
echo "[compiler-gate] missing index.vpkg scan (#897 Phase 4) ok"

# 46/46. Ctor Double-field match binding under RC (#1062; reverted attempt
#        PR #1068 / commit 0269998). A pattern-bound constructor field
#        (`Circle(r) => r * r`) was never registered into the float-local-slot
#        tracking `let`-bound floats get, so a Double-typed field fell through
#        to the integer-multiply path -- under RC that multiplies two boxed-
#        float POINTERS together, producing a bogus pointer that traps with
#        "memory access out of bounds" when dereferenced. The first fix
#        attempt (PR #1068) added CompileCtx.ctor_float_fields +
#        bind_match_pat's ctor_field_is_float consumer and correctly fixed
#        this repro, but was reverted: the broader
#        "scripts/unit_test_runner.sh" allowlist (462 files) showed ~37-39
#        unrelated failures in parser/checker/printer tests that this gate's
#        OWN narrower checks never exercised. Root cause of THAT regression:
#        float_local_slots was never pruned at match-arm / if-else boundaries
#        the way int_local_slots / agg_local_slots already are, so a sibling
#        arm's non-float field reusing the same local slot number as an
#        earlier arm's Double-typed bind inherited a stale "floatish" mark and
#        took the f64 path for ordinary integer arithmetic (see
#        float_log_reset_above in codegen/common_base/common_base.vibe, and
#        fixtures/ctor_float_sibling_arm_slot_test.vibe which pins that class
#        of bug directly, RC-independent). This gate compiles+runs the
#        original #1062 repro under VIBE_RC=1 -- the OOB-trap-specific
#        manifestation the issue was filed for.
echo "[compiler-gate] 46/46 ctor Double-field match binding under RC (#1062)"
c1062dir="_build/_gate_ctor_double_field_rc"
rm -rf "$c1062dir"; mkdir -p "$c1062dir"
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/rc_ctor_double_field_match_test.vibe" "$c1062dir/c1062.wasm" __no_entry__ >/dev/null 2>&1
if [ ! -s "$c1062dir/c1062.wasm" ]; then
  echo "[compiler-gate] FAIL: ctor Double-field match fixture did not compile under RC" >&2
  cat "$c1062dir/c1062.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$c1062dir/c1062.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: ctor Double-field match fixture trapped under RC (#1062 regressed)" >&2; exit 1
fi
rm -rf "$c1062dir"
echo "[compiler-gate] ctor Double-field match binding under RC (#1062) ok"

# 47/47. Self-hosted `vibe lsp` (lib/@vibe/lsp/lsp_server.vibe,
#        #lsp-selfhost): a full JSON-RPC 2.0 / Content-Length-framed
#        initialize -> didOpen -> hover -> shutdown -> exit round trip,
#        driven via scripts/wasm_vibe_host_runner.js's VIBE_STDIN_BYTES
#        batch-feed (the same "vibe.*" linear-backend stdin host imports a
#        real editor's live pipe exercises under viberun -- this gate proves
#        the wasm-level protocol/dispatch logic; it doesn't need viberun
#        itself, which compiler_gate.sh has no other dependency on and
#        this sandbox doesn't have installed). Checks the hover response
#        contains the correct inferred type for a simple two-arg function --
#        this specific assertion is also a regression lock for the
#        closure-crossing-a-HOF-parameter trap fixed while landing this
#        feature (lsp_run_with_handler dispatches via a plain Int tag, not
#        an effectful closure VALUE passed through a HOF parameter -- see
#        that function's own doc comment for why: the closure-value form
#        compiled fine and even ran fine under this same Node dev-runner,
#        but trapped ("indirect call type mismatch") under real wasmtime,
#        the still-open GENERAL case issue #1070 describes).
echo "[compiler-gate] 47/47 self-hosted vibe lsp: initialize/didOpen/hover/shutdown/exit round trip"
lspgatedir="_build/_gate_lsp_selfhost"
rm -rf "$lspgatedir"; mkdir -p "$lspgatedir"
python3 - "$lspgatedir/input.bin" <<'PYEOF'
import json, sys

def frame(obj):
    body = json.dumps(obj)
    b = body.encode("utf-8")
    return f"Content-Length: {len(b)}\r\n\r\n".encode("ascii") + b

sample_source = "let add = (a: Int, b: Int) -> Int { a + b }\n\nexport let main = () -> Int { add(1, 2) }\n"
msgs = [
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": "file:///gate.vibe", "languageId": "vibe", "version": 1, "text": sample_source}
    }}),
    frame({"jsonrpc": "2.0", "id": 2, "method": "textDocument/hover", "params": {
        "textDocument": {"uri": "file:///gate.vibe"}, "position": {"line": 0, "character": 5}
    }}),
    # parity slice 2: completion / signatureHelp / workspace-symbol.
    # signatureHelp position: line 2 "export let main = () -> Int { add(1, 2) }",
    # character 34 = just after "add(" -- callee backscan must find `add` and
    # ask the checker for its type.
    frame({"jsonrpc": "2.0", "id": 4, "method": "textDocument/completion", "params": {
        "textDocument": {"uri": "file:///gate.vibe"}, "position": {"line": 2, "character": 0}
    }}),
    frame({"jsonrpc": "2.0", "id": 5, "method": "textDocument/signatureHelp", "params": {
        "textDocument": {"uri": "file:///gate.vibe"}, "position": {"line": 2, "character": 34}
    }}),
    frame({"jsonrpc": "2.0", "id": 6, "method": "workspace/symbol", "params": {"query": "ad"}}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]
with open(sys.argv[1], "wb") as f:
    f.write(b"".join(msgs))
PYEOF
lsp_out="$lspgatedir/output.bin"
VIBE_STDIN_BYTES="$(cat "$lspgatedir/input.bin")" \
  VIBE_LSP=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" > "$lsp_out" 2>"$lspgatedir/stderr.log"
if ! grep -q '"id":1,"result"' "$lsp_out" 2>/dev/null && ! grep -q '"id": 1, "result"' "$lsp_out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: self-hosted vibe lsp did not answer initialize" >&2
  cat "$lspgatedir/stderr.log" 2>/dev/null >&2 || true
  exit 1
fi
if ! grep -q '(Int, Int) -> Int' "$lsp_out"; then
  echo "[compiler-gate] FAIL: self-hosted vibe lsp hover response missing/wrong (want '(Int, Int) -> Int')" >&2
  cat "$lsp_out" >&2
  exit 1
fi
# parity slice 2 assertions: completion offers the document's own `add`
# declaration AND a language keyword; signatureHelp resolves the callee and
# renders "add: (Int, Int) -> Int"; workspace/symbol finds `add` in the open
# doc with its location.
if ! grep -Eq '"label": ?"add"' "$lsp_out"; then
  echo "[compiler-gate] FAIL: self-hosted vibe lsp completion missing document symbol 'add'" >&2
  cat "$lsp_out" >&2
  exit 1
fi
if ! grep -Eq '"label": ?"handle"' "$lsp_out"; then
  echo "[compiler-gate] FAIL: self-hosted vibe lsp completion missing keyword item 'handle'" >&2
  cat "$lsp_out" >&2
  exit 1
fi
if ! grep -Eq '"label": ?"add: \(Int, Int\) -> Int"' "$lsp_out"; then
  echo "[compiler-gate] FAIL: self-hosted vibe lsp signatureHelp missing 'add: (Int, Int) -> Int' (callee backscan or type_at regressed)" >&2
  cat "$lsp_out" >&2
  exit 1
fi
if ! grep -Eq '"name": ?"add"' "$lsp_out"; then
  echo "[compiler-gate] FAIL: self-hosted vibe lsp workspace/symbol missing 'add'" >&2
  cat "$lsp_out" >&2
  exit 1
fi
rm -rf "$lspgatedir"
echo "[compiler-gate] self-hosted vibe lsp round trip ok (incl. completion/signatureHelp/workspace-symbol)"

# 48/48. ADR-0068 `Send` marker (docs/concurrency.md "`Send` と capture
#        safety"): compiler-judged structural marker for task/channel
#        message safety. Positive: primitives, tuples, Option/Result, and
#        immutable structs/enums (incl. generic instantiation + recursive
#        enum) satisfy `[T: Send]` (fixtures/send_bound_structural.vibe,
#        compiled AND run: 42). Negative: Array (mutable interior),
#        mut-field struct, and closure are rejected with the standard
#        `no impl `Send` for `...`` diagnostic; a user `impl Send` is
#        rejected as such (Send cannot be user-implemented). Judgment is
#        type_send_ok in checker/checker_trait.vibe, wired into
#        check_program_bounds (checker_stmt.vibe).
echo "[compiler-gate] 48/48 ADR-0068 Send marker (structural judgment + rejections)"
senddir="_build/_gate_send_marker"
rm -rf "$senddir"; mkdir -p "$senddir"
sed '/^_start()$/d; /^__DATA__$/,$d' fixtures/send_bound_structural.vibe > "$senddir/pos.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$senddir/pos.vibe" "$senddir/pos.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$senddir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: send_bound_structural.vibe did not compile -- structural Send acceptance regressed" >&2
  cat "$senddir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
send_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$senddir/pos.wasm" 2>/dev/null | tail -1)"
if [ "$send_pos_out" != "42" ]; then
  echo "[compiler-gate] FAIL: send_bound_structural got '$send_pos_out' (want 42)" >&2
  exit 1
fi
send_check_reject() {
  local fixture="$1" needle="$2" tag="$3"
  sed '/^__DATA__$/,$d' "fixtures/$fixture" > "$senddir/$tag.vibe"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$senddir/$tag.vibe" "$senddir/$tag.wasm" main >/dev/null 2>&1 || true
  if [ -s "$senddir/$tag.wasm" ]; then
    echo "[compiler-gate] FAIL: $fixture compiled successfully -- must be rejected" >&2
    exit 1
  fi
  if ! grep -qF "$needle" "$senddir/$tag.wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $fixture did not produce the expected diagnostic ($needle)" >&2
    cat "$senddir/$tag.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
}
send_check_reject "err_type_send_array_bound.vibe" 'no impl `Send` for `Array[Int]`' "arr"
send_check_reject "err_type_send_mut_struct_bound.vibe" 'no impl `Send` for `Counter`' "mut"
send_check_reject "err_type_send_closure_bound.vibe" 'no impl `Send` for `' "clos"
send_check_reject "err_type_send_user_impl.vibe" '`Send` is a compiler-judged structural marker' "impl"
# #1090 review: the coinductive guard keys on constructor + ARGS — a
# recursive occurrence with different arguments must still be checked.
send_check_reject "err_type_send_nonregular_recursion.vibe" 'no impl `Send` for `LoopT[Int]`' "nonreg"
# #1090 review: bounds are enforced on the IMPORT (check_program_with_env /
# FS) path too — a consumer importing a [T: Send] fn must not bypass it.
cat > "$senddir/send_dep.vibe" <<'SENDDEP'
export let want_send = [T: Send](x: T) -> T { x }
SENDDEP
cat > "$senddir/send_use.vibe" <<'SENDUSE'
import ./send_dep.vibe { want_send }

fn main {
  let _ = want_send([1, 2, 3])
  ()
}
SENDUSE
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$senddir/send_use.vibe" "$senddir/send_use.wasm" main >/dev/null 2>&1 || true
if [ -s "$senddir/send_use.wasm" ]; then
  echo "[compiler-gate] FAIL: Send bound bypassed on the import path (send_use.vibe compiled)" >&2
  exit 1
fi
if ! grep -qF 'no impl `Send` for `Array[Int]`' "$senddir/send_use.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: import-path Send violation did not produce the expected diagnostic" >&2
  cat "$senddir/send_use.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$senddir"
echo "[compiler-gate] ADR-0068 Send marker ok"

# 49/49. #1085: RC over-drop for a param with a real consume (Array::set)
#        in one branch and a #706 loop-borrow site (while + push) in the
#        sibling branch of an append helper. The #725 epilogue emitted its
#        "one unconditional drop" on every path, over-releasing the store
#        on real-consume executions (use-after-free from the 3rd element,
#        else arm not even executed). Fixed by lc_has_nonloop_consume
#        (codegen/wasi/linked_compile.vibe) suppressing the loop-count
#        drop in the mixed case. Runs under the default RC test lane and
#        checks both the struct shape (silent corruption) and the closure
#        shape (call_indirect trap): want 123123.
echo "[compiler-gate] 49/49 RC branch+loop mixed-consume over-drop (#1085)"
rc1085dir="_build/_gate_rc_branch_loop"
rm -rf "$rc1085dir"; mkdir -p "$rc1085dir"
sed '/^_start()$/d; /^__DATA__$/,$d' fixtures/rc_branch_loop_mixed_consume_test.vibe > "$rc1085dir/src.vibe"
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$rc1085dir/src.vibe" "$rc1085dir/src.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$rc1085dir/src.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_branch_loop_mixed_consume fixture did not compile" >&2
  cat "$rc1085dir/src.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rc1085_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$rc1085dir/src.wasm" 2>/dev/null | tail -1)"
if [ "$rc1085_out" != "123123" ]; then
  echo "[compiler-gate] FAIL: rc_branch_loop_mixed_consume got '$rc1085_out' (want 123123) -- #1085 over-drop regressed" >&2
  exit 1
fi
rm -rf "$rc1085dir"
echo "[compiler-gate] RC branch+loop mixed-consume over-drop (#1085) ok"

# 50/50. ADR-0076 Phase 3a (#817, docs/effect-evidence-passing.md 追記27):
#        first-class `resume` (suspend handler class) via the depth-0
#        suspend CPS lowering (suspend_cps_pass in codegen/common_base/
#        inline_direct_perform.vibe + the checker's arm-scope `resume`
#        binding). Positive: the scheduler shape -- an arm STORES resume,
#        the handle returns the suspension value, and the stored one-shot
#        continuations drive the remaining body suspend-by-suspend
#        (want 10230); post-processing through the value form
#        (`let k = resume  let r = k(v)  r + 7`, want 1017). Runtime: the
#        second call of the same continuation writes the one-shot message
#        to stderr and traps. Phase 3b (yield bubbling): a suspend body
#        may call concrete-row functions carrying the effect -- CPS
#        clones + per-effect bubble combinator (want 3131365). #1230: a
#        plain `while` + `let mut` spine is eligible too -- the loop
#        becomes a recursive step-returning closure and each `let mut` a
#        1-element cell, so state survives every suspend (want 101020383).
#        Negative: a non-tail DIRECT resume(...) call stays rejected (#942
#        unchanged); a row-variable callee and a loop carrying
#        break/continue/return are HARD compile errors, never a silent
#        replay fallback.
echo "[compiler-gate] 50/50 ADR-0076 Phase 3a first-class resume (suspend CPS)"
scpsdir="_build/_gate_scps"
rm -rf "$scpsdir"; mkdir -p "$scpsdir"
scps_run_expect() {
  local fixture="$1" want="$2" tag="$3"
  sed '/^_start()$/d; /^__DATA__$/,$d' "fixtures/$fixture" > "$scpsdir/$tag.vibe"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$scpsdir/$tag.vibe" "$scpsdir/$tag.wasm" _start >/dev/null 2>&1 || true
  if [ ! -s "$scpsdir/$tag.wasm" ]; then
    echo "[compiler-gate] FAIL: $fixture did not compile -- Phase 3a suspend lowering regressed" >&2
    cat "$scpsdir/$tag.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  local out
  out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$scpsdir/$tag.wasm" 2>/dev/null | tail -1)"
  if [ "$out" != "$want" ]; then
    echo "[compiler-gate] FAIL: $fixture got '$out' (want $want)" >&2
    exit 1
  fi
}
scps_run_expect "effect_resume_store_scheduler.vibe" "10230" "sched"
scps_run_expect "effect_resume_value_postprocess.vibe" "1017" "post"
# Phase 3b yield bubbling: a suspend-class handle body calling row-carrying
# helpers (incl. a recursive one) -- CPS clones + per-effect bubble
# combinator, two sites sharing one step enum (want 3131365).
scps_run_expect "effect_resume_call_bubbling.vibe" "3131365" "bubble"
# trivial row-var wrapper + capture-free closure: normalized upstream
# (#786 hoist + trivial-wrapper inlining) into a plain needing call the
# clone/bubble machinery handles (want -95).
scps_run_expect "effect_resume_rowvar_wrapper_normalized.vibe" "-95" "norm"
# #1230 loop widening: `while` + `let mut` on the spine. 101020383 decodes
# as r0=100/r1=101/r2=102/r3=183 -- the 183 is the pin that both `acc` and
# `i` survived every suspend/resume round trip through their cells.
scps_run_expect "effect_resume_store_loop.vibe" "101020383" "loop"
# #1263 Codex P1: a non-suspending loop AHEAD of a suspending one must stay
# iterative. The 200000-iteration prefix would blow the wasm call stack if it
# were converted to the recursive lp() shape (rewrite_self_tail_calls runs
# before suspend_cps_pass, so nothing flattens it back).
scps_run_expect "effect_resume_store_loop_prefix.vibe" "20000112" "loopprefix"
# #1263 Codex P2: a nested closure is a control-flow boundary -- its `return`
# targets the closure, not the loop being converted, so it must not reject.
scps_run_expect "effect_resume_store_loop_nested_return.vibe" "112" "loopnestedret"
# one-shot violation: must NOT produce a value; the failure output carries
# the one-shot stderr diagnostic before the assert trap.
sed '/^_start()$/d' fixtures/effect_resume_one_shot_trap.vibe > "$scpsdir/once.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$scpsdir/once.vibe" "$scpsdir/once.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$scpsdir/once.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_resume_one_shot_trap.vibe did not compile" >&2
  cat "$scpsdir/once.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
scps_once_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$scpsdir/once.wasm" 2>&1 || true)"
if ! printf '%s' "$scps_once_out" | grep -q "one-shot continuation called twice"; then
  echo "[compiler-gate] FAIL: double resume did not trap with the one-shot message; output was:" >&2
  printf '%s\n' "$scps_once_out" >&2
  exit 1
fi
scps_check_reject() {
  local fixture="$1" needle="$2" tag="$3"
  sed '/^_start()$/d; /^__DATA__$/,$d' "fixtures/$fixture" > "$scpsdir/$tag.vibe"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$scpsdir/$tag.vibe" "$scpsdir/$tag.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$scpsdir/$tag.wasm" ]; then
    echo "[compiler-gate] FAIL: $fixture compiled successfully -- must be rejected" >&2
    exit 1
  fi
  if ! grep -qF "$needle" "$scpsdir/$tag.wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $fixture did not produce the expected diagnostic ($needle)" >&2
    cat "$scpsdir/$tag.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
}
scps_check_reject "err_resume_non_tail.vibe" "must be the last expression of the handler arm" "nontail"
scps_check_reject "err_effect_resume_store_ineligible.vibe" "cannot see through" "inelig"
scps_check_reject "err_effect_resume_store_loop.vibe" "let/seq/tail/branch-tail spine" "loopbreak"
# #1261: an unannotated performing closure is row-backfilled by
# dlh_hoist_expr and so gets the evidence dict prepended; handing that value
# to a row-FREE fn-typed slot used to compile clean and trap at runtime with
# a wasm signature mismatch. Reject it, and keep the annotated form working.
scps_check_reject "err_effect_needing_value_escape.vibe" "passed as a VALUE into a slot whose type does not carry that row" "valesc"
scps_run_expect "effect_needing_value_annotated.vibe" "42" "valann"
rm -rf "$scpsdir"
echo "[compiler-gate] ADR-0076 Phase 3a first-class resume ok"

# 51/51. #1097: a closure literal capturing a MATCH-BOUND payload used to
#        hold it as an unowned env borrow; when the wrapper escaped and
#        the scrutinee died with its lambda frame, a second suspend-shaped
#        site reused the freed block and the stored wrapper trapped.
#        compile_match now backs each capturing literal with one payload
#        dup (md_capturing_fn_count). Runs under the RC lane; want 38013
#        (r's + resumed values + the log digits — silent-corruption pin,
#        not just no-trap).
echo "[compiler-gate] 51/51 RC match-payload closure capture (#1097)"
rc1097dir="_build/_gate_rc_payload_capture"
rm -rf "$rc1097dir"; mkdir -p "$rc1097dir"
sed '/^_start()$/d; /^__DATA__$/,$d' fixtures/rc_match_payload_closure_capture_test.vibe > "$rc1097dir/src.vibe"
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$rc1097dir/src.vibe" "$rc1097dir/src.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$rc1097dir/src.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_match_payload_closure_capture fixture did not compile" >&2
  cat "$rc1097dir/src.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rc1097_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$rc1097dir/src.wasm" 2>/dev/null | tail -1)"
if [ "$rc1097_out" != "38013" ]; then
  echo "[compiler-gate] FAIL: rc_match_payload_closure_capture got '$rc1097_out' (want 38013) -- #1097 regressed" >&2
  exit 1
fi
rm -rf "$rc1097dir"
echo "[compiler-gate] RC match-payload closure capture (#1097) ok"

# 52/52. owned-captures ABI (ADR-0076 追記31 Vertical A): a closure env OWNS
#        its heap captures — creation-site dup + class-7 recursive drop.
#        The fixture generalizes #1097 beyond match payloads: a borrowed
#        view (Array::get) captured by an escaping closure survives the
#        owner's scope-end recursive drop. Under the old borrow model the
#        freed element block was reused by churn() and the escaped closure
#        read the reused contents (got 50067, silent corruption).
echo "[compiler-gate] 52/52 RC owned-captures escape (ADR-0076 追記31)"
rcocdir="_build/_gate_rc_owned_capture"
rm -rf "$rcocdir"; mkdir -p "$rcocdir"
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/rc_closure_owned_capture_escape.vibe "$rcocdir/esc.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$rcocdir/esc.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_closure_owned_capture_escape fixture did not compile" >&2
  cat "$rcocdir/esc.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rcoc_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$rcocdir/esc.wasm" 2>/dev/null | tail -1)"
if [ "$rcoc_out" != "4067" ]; then
  echo "[compiler-gate] FAIL: rc_closure_owned_capture_escape got '$rcoc_out' (want 4067) -- owned-captures regressed" >&2
  exit 1
fi
rm -rf "$rcocdir"
echo "[compiler-gate] RC owned-captures escape ok"

# 53/53. closure-CPS ABI (ADR-0076 追記31 Vertical B): a suspending body
#        passed as a plain closure ARGUMENT into a library-side handle.
#        The literal is step-compiled at the call site and the handle body
#        bubbles the steps returned through its closure param (α-seeded
#        cps local). Positive pin 2130 (two-yield resume-value trace) +
#        the v1 convention guard (an untriggered handle for a
#        step-compiled effect is a hard error).
echo "[compiler-gate] 53/53 closure-CPS param suspend (ADR-0076 追記31)"
ccpsdir="_build/_gate_closure_cps"
rm -rf "$ccpsdir"; mkdir -p "$ccpsdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_closure_cps_param.vibe "$ccpsdir/param.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$ccpsdir/param.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_closure_cps_param fixture did not compile" >&2
  cat "$ccpsdir/param.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
ccps_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$ccpsdir/param.wasm" 2>/dev/null | tail -1)"
if [ "$ccps_out" != "2130" ]; then
  echo "[compiler-gate] FAIL: effect_closure_cps_param got '$ccps_out' (want 2130) -- closure-CPS regressed" >&2
  exit 1
fi
rm -f "$ccpsdir/mixed.wasm"
cp fixtures/err_effect_closure_cps_mixed_convention.vibe "$ccpsdir/mixed.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ccpsdir/mixed.vibe" "$ccpsdir/mixed.wasm" _start >/dev/null 2>&1 || true
if [ -s "$ccpsdir/mixed.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effect_closure_cps_mixed_convention compiled (must be a hard error)" >&2
  exit 1
fi
if ! grep -qF "mixing the step convention" "$ccpsdir/mixed.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: mixed-convention fixture did not produce the expected diagnostic" >&2
  cat "$ccpsdir/mixed.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$ccpsdir"
echo "[compiler-gate] closure-CPS param suspend ok"

# 54/54. type-directed closure evidence (ADR-0076 追記34 V1): the
#        hof_escaping shape (closure used as direct call AND by-value HOF
#        arg) migrates to evidence — the replay M2 side-effect duplication
#        is gone (hits 4 → 2, pinned via a row-free bump helper). The
#        guard makes an ineligible closure-value program a hard error
#        instead of a silent replay fallback.
echo "[compiler-gate] 54/54 type-directed closure evidence (ADR-0076 追記34)"
tdevdir="_build/_gate_td_evidence"
rm -rf "$tdevdir"; mkdir -p "$tdevdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_closure_value_evidence_m2.vibe "$tdevdir/m2.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdevdir/m2.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_closure_value_evidence_m2 fixture did not compile" >&2
  cat "$tdevdir/m2.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
tdev_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$tdevdir/m2.wasm" 2>/dev/null | tail -1)"
if [ "$tdev_out" != "2062" ]; then
  echo "[compiler-gate] FAIL: effect_closure_value_evidence_m2 got '$tdev_out' (want 2062; 2064 = replay M2 duplication returned)" >&2
  exit 1
fi
rm -f "$tdevdir/inelig.wasm"
cp fixtures/err_closure_value_evidence_ineligible.vibe "$tdevdir/inelig.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdevdir/inelig.vibe" "$tdevdir/inelig.wasm" _start >/dev/null 2>&1 || true
if [ -s "$tdevdir/inelig.wasm" ]; then
  echo "[compiler-gate] FAIL: err_closure_value_evidence_ineligible compiled (must be a hard error)" >&2
  exit 1
fi
if ! grep -qF "type-directed evidence" "$tdevdir/inelig.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: ineligible closure-value fixture did not produce the expected diagnostic" >&2
  cat "$tdevdir/inelig.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -f "$tdevdir/multi.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_closure_value_evidence_multi.vibe "$tdevdir/multi.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdevdir/multi.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_closure_value_evidence_multi fixture did not compile" >&2
  cat "$tdevdir/multi.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
multi_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$tdevdir/multi.wasm" 2>/dev/null | tail -1)"
if [ "$multi_out" != "33" ]; then
  echo "[compiler-gate] FAIL: effect_closure_value_evidence_multi got '$multi_out' (want 33; a blanket __ev_ guard drops __ev_B and the raw B perform escapes -- #1116 Codex P1)" >&2
  exit 1
fi
rm -f "$tdevdir/shadow.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_closure_value_evidence_shadow.vibe "$tdevdir/shadow.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdevdir/shadow.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_closure_value_evidence_shadow fixture did not compile" >&2
  cat "$tdevdir/shadow.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
shadow_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$tdevdir/shadow.wasm" 2>/dev/null | tail -1)"
if [ "$shadow_out" != "42" ]; then
  echo "[compiler-gate] FAIL: effect_closure_value_evidence_shadow got '$shadow_out' (want 42; a top-level pure fn sharing a name with a nested row-E closure must not get a stray evidence arg -- #1117 Codex P1)" >&2
  exit 1
fi
rm -rf "$tdevdir"
echo "[compiler-gate] type-directed closure evidence ok"

# 55/55. replay frontier removal (ADR-0076 追記34 V2): the replay engine is
#        gone from codegen. (a) A handle whose effect is never user-performed
#        anywhere (the host-row label-pun shape: the body calls the Env::get
#        BUILTIN directly, so the arms are dead) is erased by the
#        vacuous-handle elimination and the program compiles + runs. (b) A
#        live non-Error handle the evidence migration cannot reach is a HARD
#        error, never a silent fallback. (c) The shadowed-needing class
#        (gate 40ao, 47) now migrates via the seed-scoped α-rename +
#        local-literal call safety instead of parking on replay -- its pin
#        already asserts the value; this section pins the two new behaviors.
echo "[compiler-gate] 55/55 replay frontier removal (ADR-0076 追記34 V2)"
v2dir="_build/_gate_replay_removed"
rm -rf "$v2dir"; mkdir -p "$v2dir"
sed '/^__DATA__$/,$d' fixtures/effect_vacuous_handle_erased.vibe > "$v2dir/vacuous.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$v2dir/vacuous.vibe" "$v2dir/vacuous.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$v2dir/vacuous.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_vacuous_handle_erased fixture did not compile" >&2
  cat "$v2dir/vacuous.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
v2_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$v2dir/vacuous.wasm" 2>/dev/null | tail -1)"
if [ "$v2_out" != "46" ]; then
  echo "[compiler-gate] FAIL: effect_vacuous_handle_erased got '$v2_out' (want 46) -- vacuous-handle elimination regressed" >&2
  exit 1
fi
rm -f "$v2dir/reject.wasm"
cp fixtures/err_effect_handle_replay_removed.vibe "$v2dir/reject.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$v2dir/reject.vibe" "$v2dir/reject.wasm" _start >/dev/null 2>&1 || true
if [ -s "$v2dir/reject.wasm" ]; then
  echo "[compiler-gate] FAIL: err_effect_handle_replay_removed compiled (a live unmigratable non-Error handle must be a hard error)" >&2
  exit 1
fi
if ! grep -qF "replay engine was removed" "$v2dir/reject.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: replay-removed reject fixture did not produce the expected diagnostic" >&2
  cat "$v2dir/reject.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$v2dir"
echo "[compiler-gate] replay frontier removal ok"

# 56/56. #1114: a nested closure calling a bare inlined-builtin name must
#        invoke an ENCLOSING local binding that shadows it, not the builtin.
#        The #773 skip only saw the innermost lambda's own binders + the
#        top-level fn table, so a parameter named `not`/`mul`/... was never
#        captured and the call silently produced the BUILTIN's value.
echo "[compiler-gate] 56/56 closure captures enclosing-scope shadow of an inlined builtin (#1114)"
csibdir="_build/_gate_closure_shadow_builtin"
rm -rf "$csibdir"; mkdir -p "$csibdir"
sed '/^__DATA__$/,$d' fixtures/closure_shadowed_inline_builtin.vibe > "$csibdir/src.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$csibdir/src.vibe" "$csibdir/out.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$csibdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: closure_shadowed_inline_builtin.vibe did not compile" >&2
  cat "$csibdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
csib_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$csibdir/out.wasm" 2>/dev/null | tail -1)"
if [ "$csib_out" != "28" ]; then
  echo "[compiler-gate] FAIL: closure_shadowed_inline_builtin got '$csib_out' (want 28) -- either a shadowed inline builtin fell back to the builtin instead of the captured closure (#1114), or a non-recursive let binder was treated as an enclosing shadow inside its own initializer (#1120 Codex P1)" >&2
  exit 1
fi
rm -rf "$csibdir"
echo "[compiler-gate] closure shadowed inline builtin ok (28)"

# 57/57. #1078: an enum CONSTRUCTOR and an effect OPERATION that share a bare
#        name, declared by two UNRELATED packages, must still resolve to the
#        right declaration once BOTH are reachable in one merged program.
#        The reported failure ("argument type mismatch for Request: expected
#        RpcId, got Map[String, Json]") was specific to the merge/flatten
#        whole-program view -- ordinary FS-mode compilation never reproduced
#        it -- so this gate drives the REAL merge lane
#        (VIBE_EMIT_MERGED_SOURCE=1, the same mode generate_bundle.sh uses)
#        and then compiles its output, rather than compiling the sources
#        directly. Note the merge STRIPS the qualification: `Msg::Request(..)`
#        in a pattern comes out as bare `Request(..)`, which is exactly the
#        state the bare-name resolution has to get right.
echo "[compiler-gate] 57/57 merged-program ctor/effect-op name collision across packages (#1078)"
c1078dir="_build/_gate_ctor_effect_collision"
rm -rf "$c1078dir"; mkdir -p "$c1078dir/pkga" "$c1078dir/pkgb"
cat > "$c1078dir/pkga/index.vibe" <<'VEOF'
export enum Msg {
  Request(String, Int, Bool);
  Reply(Int)
}

export fn make_req(m: String, id: Int) -> Msg {
  Msg::Request(m, id, true)
}

export fn req_id(r: Msg) -> Int {
  match r {
    Msg::Request(_m, id, _f) => id,
    Msg::Reply(id) => id
  }
}
VEOF
cat > "$c1078dir/pkgb/index.vibe" <<'VEOF'
export effect Net {
  Request(String, String, String, String) -> Int
}

export fn fetch(url: String) -> Int with { Net } {
  perform Net::Request("GET", url, "", "")
}
VEOF
cat > "$c1078dir/main.vibe" <<'VEOF'
import ./pkga/index.vibe { Msg, make_req, req_id }
import ./pkgb/index.vibe { Net, fetch }

// BOTH declarations reachable from the exported entry: the enum ctor via
// make_req/req_id, the effect op via the handled fetch call.
export let main = () -> Int {
  let n = req_id(make_req("hello", 40))
  let f = handle {
    fetch("http://127.0.0.1:1/x")
  } with Net {
    Request(_m, _u, _h, _b) => resume(2)
  }
  n + f
}
VEOF
rm -f "$c1078dir/merged.vibe" "$c1078dir/merged.vibe.diag"
VIBE_EMIT_MERGED_SOURCE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$c1078dir/main.vibe" "$c1078dir/merged.vibe" main >/dev/null 2>&1 || true
if [ ! -s "$c1078dir/merged.vibe" ]; then
  echo "[compiler-gate] FAIL: merge/flatten of the ctor/effect-op collision program failed (#1078)" >&2
  cat "$c1078dir/merged.vibe.diag" 2>/dev/null >&2 || true
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$c1078dir/merged.vibe" "$c1078dir/out.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$c1078dir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: merged ctor/effect-op collision program did not compile -- bare-name resolution picked the wrong declaration (#1078)" >&2
  cat "$c1078dir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
c1078_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$c1078dir/out.wasm" 2>&1 | tail -1)"
if [ "$c1078_out" != "42" ]; then
  echo "[compiler-gate] FAIL: merged ctor/effect-op collision program got '$c1078_out' (want 42) -- #1078 regressed" >&2
  exit 1
fi
rm -rf "$c1078dir"
echo "[compiler-gate] merged ctor/effect-op collision ok (42)"

# 58/58. #906 Phase 2: the worker transport. A worker gets a job directory
# as its entire filesystem sandbox and must be able to check a module WITH
# imports, using dependency environments handed to it as values. Delegated
# because the interesting part is the negative controls -- an unresolved
# import is lenient, so the assertion has to be that the dependency's
# SIGNATURE arrived, not just its name.
echo "[compiler-gate] 58/58 module job dir worker transport (#906 Phase 2)"
if ! bash "$ROOT_DIR/scripts/module_job_dir_test.sh" "$stage2_wasm"; then
  echo "[compiler-gate] FAIL: module job dir worker transport regressed (#906 Phase 2)" >&2
  exit 1
fi

# 59/59. #1081 step 3: ADR-0068 region generativity. `TaskGroup::run`
# mints a fresh, compiler-rigid region skolem (hardcoded to this qualified
# name -- no general rank-2/`Region`-bound mechanism, see docs/
# concurrency.md's dated 実装ノート) and rejects the call if the region
# escapes via the body's return value. Positive: a plain spawn+join inside
# one nursery keeps compiling and running (region_ok_basic.vibe, 42).
# Negative: returning a `TaskHandle` obtained inside the nursery is a
# STATIC error (err_region_escape_return.vibe). Known gap, documented
# rather than silently claimed: an outer-capture check also runs (scans
# every binding visible at the call site after the body is checked), but
# this checker generalizes `let`/`let mut` bindings, so a leak into an
# already-generalized local `let mut` cell is NOT caught by this slice --
# only the return-position escape is a hard guarantee here.
echo "[compiler-gate] 59/59 ADR-0068 region generativity (#1081 step 3)"
regiondir="_build/_gate_region"
rm -rf "$regiondir"; mkdir -p "$regiondir"
sed '/^_start()$/d; /^__DATA__$/,$d' fixtures/region_ok_basic.vibe > "$regiondir/pos.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$regiondir/pos.vibe" "$regiondir/pos.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$regiondir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_basic.vibe did not compile -- plain non-escaping nursery use regressed" >&2
  cat "$regiondir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
region_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$regiondir/pos.wasm" 2>/dev/null | tail -1)"
if [ "$region_pos_out" != "42" ]; then
  echo "[compiler-gate] FAIL: region_ok_basic.vibe got '$region_pos_out' (want 42)" >&2
  exit 1
fi
sed '/^__DATA__$/,$d' fixtures/err_region_escape_return.vibe > "$regiondir/neg.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$regiondir/neg.vibe" "$regiondir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$regiondir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_region_escape_return.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'region escapes its nursery scope' "$regiondir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_region_escape_return.vibe did not produce the expected diagnostic" >&2
  cat "$regiondir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$regiondir"
echo "[compiler-gate] ADR-0068 region generativity ok"

echo "[compiler-gate] 60/60 deps missing-for-imports scan (#1145 follow-up 2)"
depsdir="_build/_gate_deps_scan"
rm -rf "$depsdir"; mkdir -p "$depsdir"
VIBE_DEPS_MISSING_SCAN=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ROOT_DIR" "$depsdir/scan.out" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$depsdir/scan.out" ]; then
  echo "[compiler-gate] FAIL: deps-missing scan produced no output" >&2
  cat "$depsdir/scan.out.diag" 2>/dev/null >&2
  exit 1
fi
if ! grep -q "^ok: no missing deps declarations" "$depsdir/scan.out"; then
  echo "[compiler-gate] FAIL: index.vpkg packages with deps missing an import's package (#1128/#1145):" >&2
  cat "$depsdir/scan.out" >&2
  exit 1
fi
rm -rf "$depsdir"
echo "[compiler-gate] deps missing-for-imports scan (#1145 follow-up 2) ok"

# 61/61. #1081 step 3 Phase B: `Spawnable[r]` capture check for
# `TaskGroup::spawn`/`TaskGroup::spawn_suspend`. Like `TaskGroup::run`
# above, hardcoded by literal qualified name (same alias/rename bypass
# caveat, see checker.vibe/docs/concurrency.md). A captured free variable
# must be structurally `Send`, or a `TaskGroup`/`TaskHandle`/`Sender`/
# `Receiver` endpoint tagged with THIS spawn call's own region. Positive: a
# same-region `Sender` capture through `Channel::bounded` keeps compiling
# and running (region_ok_spawnable_capture.vibe, 42) -- the exact "capture
# an endpoint from THIS nursery" case the roadmap calls out as
# inexpressible without regions. Negative: a plain outer `Array` capture
# (err_spawnable_capture_array.vibe), a `Sender` captured from a
# DIFFERENT (outer) nursery (err_spawnable_capture_cross_region.vibe), and
# a captured `let mut` binding regardless of its (Send) type, whether
# declared inside the run body (err_spawnable_capture_letmut.vibe) or in
# the ENCLOSING scope before calling TaskGroup::run
# (err_spawnable_capture_letmut_outer_scope.vibe, Codex review PR #1151
# P1) are all STATIC errors.
echo "[compiler-gate] 61/61 ADR-0068 Spawnable[r] capture check (#1081 step 3 Phase B)"
spawnabledir="_build/_gate_spawnable"
rm -rf "$spawnabledir"; mkdir -p "$spawnabledir"
sed '/^_start()$/d; /^__DATA__$/,$d' fixtures/region_ok_spawnable_capture.vibe > "$spawnabledir/pos.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$spawnabledir/pos.vibe" "$spawnabledir/pos.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_capture.vibe did not compile -- same-region Sender capture regressed" >&2
  cat "$spawnabledir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
spawnable_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$spawnabledir/pos.wasm" 2>/dev/null | tail -1)"
if [ "$spawnable_pos_out" != "42" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_capture.vibe got '$spawnable_pos_out' (want 42)" >&2
  exit 1
fi
sed '/^__DATA__$/,$d' fixtures/err_spawnable_capture_array.vibe > "$spawnabledir/neg_array.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$spawnabledir/neg_array.vibe" "$spawnabledir/neg_array.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_array.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_array.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'no impl `Spawnable` for `Array[Int]`' "$spawnabledir/neg_array.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_array.vibe did not produce the expected diagnostic" >&2
  cat "$spawnabledir/neg_array.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
sed '/^__DATA__$/,$d' fixtures/err_spawnable_capture_cross_region.vibe > "$spawnabledir/neg_cross.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$spawnabledir/neg_cross.vibe" "$spawnabledir/neg_cross.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_cross.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_cross_region.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'no impl `Spawnable`' "$spawnabledir/neg_cross.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_cross_region.vibe did not produce the expected diagnostic" >&2
  cat "$spawnabledir/neg_cross.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
sed '/^__DATA__$/,$d' fixtures/err_spawnable_capture_letmut.vibe > "$spawnabledir/neg_letmut.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$spawnabledir/neg_letmut.vibe" "$spawnabledir/neg_letmut.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_letmut.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF "no impl \`Spawnable\` for a \`let mut\` binding" "$spawnabledir/neg_letmut.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut.vibe did not produce the expected diagnostic" >&2
  cat "$spawnabledir/neg_letmut.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
sed '/^__DATA__$/,$d' fixtures/err_spawnable_capture_letmut_outer_scope.vibe > "$spawnabledir/neg_letmut_outer.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$spawnabledir/neg_letmut_outer.vibe" "$spawnabledir/neg_letmut_outer.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_letmut_outer.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut_outer_scope.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF "no impl \`Spawnable\` for a \`let mut\` binding" "$spawnabledir/neg_letmut_outer.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut_outer_scope.vibe did not produce the expected diagnostic" >&2
  cat "$spawnabledir/neg_letmut_outer.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# Codex review (PR #1152, P1): the whole-program `let mut` capture pass
# used to collect every `let mut` name reachable ANYWHERE in a top-level
# declaration into one flat, scope-blind list and cross-match by name
# alone -- so an unrelated `let mut x` in a sibling closure made a
# lexically-distinct, genuinely-immutable `x` captured elsewhere look
# mutable too. Must compile and run cleanly.
sed '/^_start()$/d; /^__DATA__$/,$d' fixtures/region_ok_spawnable_capture_shadowed_letmut.vibe > "$spawnabledir/pos_shadow.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$spawnabledir/pos_shadow.vibe" "$spawnabledir/pos_shadow.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos_shadow.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_capture_shadowed_letmut.vibe did not compile -- scope-blind let-mut false positive regressed" >&2
  cat "$spawnabledir/pos_shadow.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
spawnable_shadow_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$spawnabledir/pos_shadow.wasm" 2>/dev/null | tail -1)"
if [ "$spawnable_shadow_out" != "42" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_capture_shadowed_letmut.vibe got '$spawnable_shadow_out' (want 42)" >&2
  exit 1
fi
# Codex review (PR #1152, P2): the whole-program `let mut` capture pass
# also used to lose the `[@off=...]` source-offset marker, degrading
# `vibe diagnostics`/LSP to an unlocated error. The located-diagnostics
# layer decodes `[@off=N:M]` into a `line L:C-C` range before writing the
# .diag file (confirmed empirically -- the raw `[@off=...]` marker itself
# never reaches this file), so check for THAT rendered form instead.
if ! grep -qE 'line [0-9]+:[0-9]+-[0-9]+' "$spawnabledir/neg_letmut_outer.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut_outer_scope.vibe diagnostic lost its located line:col-col source range" >&2
  cat "$spawnabledir/neg_letmut_outer.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$spawnabledir"
echo "[compiler-gate] ADR-0068 Spawnable[r] capture check ok"

# #1081 step 4 (surface polish): `taskgroup { g => body }` is pure parser
# sugar for `TaskGroup::run((g) -> { body })` -- no dedicated AST node, no
# desugar pass, no checker special-casing (docs/concurrency.md's naming
# note: the actually-implemented library type is `TaskGroup`, not the
# earlier illustrative `Nursery`/`Task`/`Spawn[r]` capability-effect
# design). Positive: the sugar compiles + runs identically to a
# hand-written `TaskGroup::run(...)` call. Negative: the EXISTING region-
# escape check (hardcoded by name on `TaskGroup::run`, unchanged by this
# sugar) still rejects a leaked `TaskHandle`.
echo "[compiler-gate] 62/67 ADR-0068 taskgroup { g => body } syntax sugar (#1081 step 4)"
taskgroupdir="_build/_gate_taskgroup_sugar"
rm -rf "$taskgroupdir"; mkdir -p "$taskgroupdir"
sed '/^_start()$/d; /^__DATA__$/,$d' fixtures/region_ok_taskgroup_sugar.vibe > "$taskgroupdir/pos.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$taskgroupdir/pos.vibe" "$taskgroupdir/pos.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$taskgroupdir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_taskgroup_sugar.vibe did not compile" >&2
  cat "$taskgroupdir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
taskgroup_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$taskgroupdir/pos.wasm" 2>/dev/null | tail -1)"
if [ "$taskgroup_pos_out" != "42" ]; then
  echo "[compiler-gate] FAIL: region_ok_taskgroup_sugar.vibe got '$taskgroup_pos_out' (want 42)" >&2
  exit 1
fi
sed '/^__DATA__$/,$d' fixtures/err_taskgroup_sugar_region_escape.vibe > "$taskgroupdir/neg.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$taskgroupdir/neg.vibe" "$taskgroupdir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$taskgroupdir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_taskgroup_sugar_region_escape.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'region escapes its nursery scope' "$taskgroupdir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_taskgroup_sugar_region_escape.vibe did not produce the expected diagnostic" >&2
  cat "$taskgroupdir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$taskgroupdir"
echo "[compiler-gate] taskgroup { g => body } syntax sugar ok"

# #906 (compiler self-parallelization prerequisite,
# docs/compiler-parallelism.md "FrozenArray"): FrozenArray[T] is a
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
sed '/^_start()$/d; /^__DATA__$/,$d' fixtures/region_ok_frozen_array_basic.vibe > "$frozenarrdir/basic.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$frozenarrdir/basic.vibe" "$frozenarrdir/basic.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$frozenarrdir/basic.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_frozen_array_basic.vibe did not compile" >&2
  cat "$frozenarrdir/basic.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
frozenarr_basic_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$frozenarrdir/basic.wasm" 2>/dev/null | tail -1)"
if [ "$frozenarr_basic_out" != "42" ]; then
  echo "[compiler-gate] FAIL: region_ok_frozen_array_basic.vibe got '$frozenarr_basic_out' (want 42)" >&2
  exit 1
fi
sed '/^_start()$/d; /^__DATA__$/,$d' fixtures/send_bound_frozen_array.vibe > "$frozenarrdir/send.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$frozenarrdir/send.vibe" "$frozenarrdir/send.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$frozenarrdir/send.wasm" ]; then
  echo "[compiler-gate] FAIL: send_bound_frozen_array.vibe did not compile -- FrozenArray[Int] Send acceptance regressed" >&2
  cat "$frozenarrdir/send.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
frozenarr_send_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$frozenarrdir/send.wasm" 2>/dev/null | tail -1)"
if [ "$frozenarr_send_out" != "42" ]; then
  echo "[compiler-gate] FAIL: send_bound_frozen_array.vibe got '$frozenarr_send_out' (want 42)" >&2
  exit 1
fi
sed '/^__DATA__$/,$d' fixtures/err_type_send_frozen_array_of_array_bound.vibe > "$frozenarrdir/neg.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$frozenarrdir/neg.vibe" "$frozenarrdir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$frozenarrdir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_type_send_frozen_array_of_array_bound.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'no impl `Send` for `FrozenArray[Array[Int]]`' "$frozenarrdir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_type_send_frozen_array_of_array_bound.vibe did not produce the expected diagnostic" >&2
  cat "$frozenarrdir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
sed '/^_start()$/d; /^__DATA__$/,$d' fixtures/region_ok_frozen_array_taskgroup_capture.vibe > "$frozenarrdir/capture.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$frozenarrdir/capture.vibe" "$frozenarrdir/capture.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$frozenarrdir/capture.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_frozen_array_taskgroup_capture.vibe did not compile -- FrozenArray Spawnable capture regressed" >&2
  cat "$frozenarrdir/capture.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
frozenarr_capture_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$frozenarrdir/capture.wasm" 2>/dev/null | tail -1)"
if [ "$frozenarr_capture_out" != "40" ]; then
  echo "[compiler-gate] FAIL: region_ok_frozen_array_taskgroup_capture.vibe got '$frozenarr_capture_out' (want 40)" >&2
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
#        "over-declared with{} is itself a hard error" reading was
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
  cat "$eff639dir/no_with.wasm.diag" 2>/dev/null >&2 || true
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
if ! grep -qF "missing { Fs } (declared with { Ask, Ask::Get }, requires { Ask, Ask::Get, Fs })" "$eff639dir/partial.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effect_handle_partial_discharge.vibe did not produce the expected diagnostic" >&2
  cat "$eff639dir/partial.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$eff1157dir/x.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$eff1157dir"
echo "[compiler-gate] zero-arg perform effect-row check ok"

# 66/66. #1161 (Codex review of #1157's fix): a DIRECT-discipline mismatch
#        must report the qualified operation, not the stripped base effect
#        name, when the enclosing function already declares a SIBLING
#        operation of the same effect at operation granularity -- otherwise
#        the generated fix-it would grant the whole effect and over-widen
#        the caller's capability surface (docs/effectset.md's operation-
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
if ! grep -qF "missing { Ask::Get } (declared with { Ask::Other }, requires { Ask::Get, Ask::Other })" "$eff1161dir/x.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effect_op_level_partial_row_bare_perform.vibe did not produce the expected diagnostic" >&2
  cat "$eff1161dir/x.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! grep -qF "hint: add 'with { Ask::Get, Ask::Other }' to 'asks'" "$eff1161dir/x.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effect_op_level_partial_row_bare_perform.vibe did not produce the expected operation-level fix-it hint" >&2
  cat "$eff1161dir/x.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$eff1161dir"
echo "[compiler-gate] operation-level fix-it precision ok"

# 67/67. #820 sub-item 3: `vibe context-pack` bundles docs/cheatsheet.md +
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
if ! bash eval/lang-review/run_golden.sh; then
  echo "[compiler-gate] FAIL: eval/lang-review/run_golden.sh -- the golden corpus context-pack bundles no longer compiles/runs as claimed" >&2
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
  cat "$c1203dir/out.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$c1203bdir/out.wasm.diag" 2>/dev/null >&2 || true
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
#        docs/adr.md #0087): scripts/vibe_inspect_update.sh reads a failing
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
#        upfront plan -- @vibe/graph's plan_module_order, wired into
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
  "$plandir/src/main.vibe" "$plandir/plan.txt" __no_entry__ >/dev/null 2>&1
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
  lib/@vibe/compiler/tests/codegen_lexer_test.vibe "$plandir/big.txt" __no_entry__ >/dev/null 2>&1
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
    "fixtures/gc_bytes_append_grow.vibe" "$bagdir/$bag_be.wasm" main >/dev/null 2>&1
  if [ ! -s "$bagdir/$bag_be.wasm" ]; then
    echo "[compiler-gate] FAIL: gc_bytes_append_grow.vibe did not compile on the $bag_be backend" >&2
    cat "$bagdir/$bag_be.wasm.diag" 2>/dev/null >&2 || true
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

echo "[compiler-gate] ok"
