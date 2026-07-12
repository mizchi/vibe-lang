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
: "${VIBE_RC:=0}"; export VIBE_RC  # cutover: pin the compiler self-build / gate baseline to bump (RC only when explicitly VIBE_RC=1)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

echo "[selfhost-only-gate] 0/3 builtin parity (#415 B-3)"
bash scripts/check_builtin_parity.sh

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
VIBE_SELFHOST_RC_BOOTSTRAP_REUSE_GEN="${latest_gen}generation.json" \
  bash scripts/test_selfhost_rc_bootstrap.sh

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

# 4b. deep-recursion effect resume regression (#737): a perform issued from a
#     RECURSIVE frame, handled by an in-language handler OUTSIDE the recursion
#     that bridges to a host builtin, used to deliver the FIRST resume's value
#     as the SECOND op's argument (deep-continuation resume corruption). The
#     merge lane works around nothing anymore (merge_sources is back on
#     `perform Fs::ReadFile`), so this program is the canary.
echo "[selfhost-only-gate] 4b deep-recursion effect resume regression (#737)"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$drdir/main.vibe" "$drdir/main.wasm" _start >/dev/null 2>&1
if [ ! -s "$drdir/main.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: deep-resume regression program did not compile" >&2
  cat "$drdir/main.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
drres="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$drdir/main.wasm" 2>/dev/null | tr -dc '0-9')"
rm -rf "$drdir"
if [ "$drres" != "42" ]; then
  echo "[selfhost-only-gate] FAIL: deep-resume regression returned '$drres' (expected 42) — #737-class resume corruption" >&2
  exit 1
fi
echo "[selfhost-only-gate] deep-recursion effect resume ok (42)"

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
#    a source file — DCE from exported roots + section layout — via the
#    in-compiler engine. Guards that a future seed keeps it working and
#    idempotent. The flat selfbuild source strips imports, so the fixpoint
#    above does not exercise the normalize entry; assert it directly.
#    (Module blocks were removed in #728; flatten coverage retired with them.)
echo "[selfhost-only-gate] 6/6 normalize compile+run regression"
ndir="_build/_gate_normalize"
rm -rf "$ndir"; mkdir -p "$ndir"
printf 'let dead: () -> Int = () -> { 0 }\nlet helper: () -> Int = () -> { 1 }\nexport let run: () -> Int = () -> { helper() }\n' > "$ndir/in.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/in.vibe" "$ndir/out.vibe" >/dev/null 2>&1
if [ ! -s "$ndir/out.vibe" ]; then
  echo "[selfhost-only-gate] FAIL: normalize produced no output" >&2; exit 1
fi
# `dead` must be eliminated; `helper` (reached from the exported `run`) kept.
if grep -q "dead" "$ndir/out.vibe" || ! grep -q "helper" "$ndir/out.vibe"; then
  echo "[selfhost-only-gate] FAIL: normalize DCE incorrect" >&2
  cat "$ndir/out.vibe" >&2; exit 1
fi
# Removed/guarded syntax must be refused by the CURRENT stage2 (the committed
# seed lags until the next bump, so these checks live here, not in the
# seed-driven normalize smoke): module blocks are removed (#728); fn
# statements re-print as let-form until the printer lands (#727).
printf 'module m {\n  export let run: () -> Int = () -> { 1 }\n}\n' > "$ndir/reject_module.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/reject_module.vibe" "$ndir/reject_module.out.vibe" >/dev/null 2>&1 \
  && [ -s "$ndir/reject_module.out.vibe" ]; then
  echo "[selfhost-only-gate] FAIL: module-block source was not rejected (#728)" >&2; exit 1
fi
printf 'fn run() -> Int { 1 }\nexport { run }\n' > "$ndir/reject_fn.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/reject_fn.vibe" "$ndir/reject_fn.out.vibe" >/dev/null 2>&1 \
  && [ -s "$ndir/reject_fn.out.vibe" ]; then
  echo "[selfhost-only-gate] FAIL: fn-bearing source was not rejected by normalize (#727)" >&2; exit 1
fi
# Idempotency: normalize(normalize(x)) == normalize(x).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/out.vibe" "$ndir/out2.vibe" >/dev/null 2>&1
if ! cmp -s "$ndir/out.vibe" "$ndir/out2.vibe"; then
  echo "[selfhost-only-gate] FAIL: normalize not idempotent" >&2; exit 1
fi
# Normalized output must still typecheck: compiling a copy with an entry
# must succeed.
cp "$ndir/out.vibe" "$ndir/compile.vibe"
printf '\nexport let _start: () -> Int = () -> { run() }\n' >> "$ndir/compile.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/compile.vibe" "$ndir/out.wasm" _start >/dev/null 2>&1
if [ ! -s "$ndir/out.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: normalized output does not compile" >&2
  cat "$ndir/compile.vibe" >&2; exit 1
fi
rm -rf "$ndir"
echo "[selfhost-only-gate] normalize regression ok"

# 6b. contract package regression (#729): an index.vibei contract package must
#     resolve via a bare directory import (conformance-check + facade desugar,
#     end to end through the current stage2), and its internals must NOT be
#     importable from outside the boundary (incoming enforcement, Phase C-3).
echo "[selfhost-only-gate] 6b contract package + boundary regression (#729)"
cdir="_build/_gate_contract"
rm -rf "$cdir"; mkdir -p "$cdir/pkg"
printf 'import ./impl.vibe {}\nfn add(x: Int, y: Int) -> Int\n' > "$cdir/pkg/index.vibei"
printf 'export fn add(x: Int, y: Int) -> Int { x + y }\n' > "$cdir/pkg/impl.vibe"
printf 'import ./pkg { add }\nexport let _start: () -> Int = () -> { add(40, 2) }\n' > "$cdir/ok.vibe"
# #749 canary: run this compile with a COLD persistent cache. The runner's
# module-init _start executes the same pipeline once before the real cli_main
# invoke; a first-pass failure is masked in the exit code but leaves a .diag
# beside the (valid) wasm the second pass writes. Cold-only ingestion rot
# (#740/#749 class) surfaces exactly there, so assert "no sidecar" too.
find "$ROOT_DIR/_build" -maxdepth 1 -type f -name "vibe_*" -delete 2>/dev/null || true
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir/ok.vibe" "$cdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir/ok.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: contract package import did not compile (#729)" >&2
  cat "$cdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
if [ -s "$cdir/ok.wasm.diag" ]; then
  echo "[selfhost-only-gate] FAIL: cold contract compile left a stale .diag beside a valid wasm (#749 first-pass ingestion failure)" >&2
  cat "$cdir/ok.wasm.diag" >&2; exit 1
fi
printf 'import ./pkg/impl.vibe { add }\nexport let _start: () -> Int = () -> { add(40, 2) }\n' > "$cdir/bad.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir/bad.vibe" "$cdir/bad.wasm" _start >/dev/null 2>&1 \
  && [ -s "$cdir/bad.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: package-internal import crossed the boundary (#729)" >&2; exit 1
fi
if ! grep -q "package boundary" "$cdir/bad.wasm.diag" 2>/dev/null; then
  echo "[selfhost-only-gate] FAIL: boundary rejection lacks the expected diagnostic (#729)" >&2
  cat "$cdir/bad.wasm.diag" 2>/dev/null >&2; exit 1
fi
rm -rf "$cdir"
echo "[selfhost-only-gate] contract package + boundary regression ok"

# 6c. content-addressed store regression (#730 D-2): `vibe hash` prints a
#     store package's pin; a require-pinned `import @scope/name` resolves
#     through .vibe/store/ with hash verification; a wrong pin is rejected.
echo "[selfhost-only-gate] 6c content-addressed store regression (#730)"
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
  echo "[selfhost-only-gate] FAIL: vibe hash produced no package pin (#730)" >&2
  cat "$cdir2/hash.out.diag" 2>/dev/null >&2; exit 1
fi
printf 'require @gate/d2pkg 1.0.0 = %s\n\nimport @gate/d2pkg { triple }\nexport let _start: () -> Int = () -> { triple(14) }\n' "$pin" > "$cdir2/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/ok.vibe" "$cdir2/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir2/ok.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: pinned store import did not compile (#730)" >&2
  cat "$cdir2/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
printf 'require @gate/d2pkg 1.0.0 = #pkg:sha1:0000000000000000000000000000000000000000\n\nimport @gate/d2pkg { triple }\nexport let _start: () -> Int = () -> { triple(14) }\n' > "$cdir2/bad.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/bad.vibe" "$cdir2/bad.wasm" _start >/dev/null 2>&1 \
  && [ -s "$cdir2/bad.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: wrong pin was not rejected (#730)" >&2; exit 1
fi
if ! grep -q "pin mismatch" "$cdir2/bad.wasm.diag" 2>/dev/null; then
  echo "[selfhost-only-gate] FAIL: pin rejection lacks the expected diagnostic (#730)" >&2
  cat "$cdir2/bad.wasm.diag" 2>/dev/null >&2; exit 1
fi
# D-3: an unpinned require refuses to build; VIBE_FILL_PINS completes it
# offline from the store; the filled source builds; the fill is idempotent.
printf 'require @gate/d2pkg 1.0.0\n\nimport @gate/d2pkg { triple }\nexport let _start: () -> Int = () -> { triple(14) }\n' > "$cdir2/unpinned.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/unpinned.vibe" "$cdir2/unpinned.wasm" _start >/dev/null 2>&1 \
  && [ -s "$cdir2/unpinned.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: unpinned require was not rejected (#730 D-3)" >&2; exit 1
fi
VIBE_FILL_PINS=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/unpinned.vibe" "$cdir2/filled.vibe" __no_entry__ >/dev/null 2>&1 || true
if ! grep -q "= #pkg:sha1:" "$cdir2/filled.vibe" 2>/dev/null; then
  echo "[selfhost-only-gate] FAIL: VIBE_FILL_PINS did not insert the pin (#730 D-3)" >&2
  cat "$cdir2/filled.vibe.diag" 2>/dev/null >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/filled.vibe" "$cdir2/filled.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir2/filled.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: pin-filled source did not compile (#730 D-3)" >&2
  cat "$cdir2/filled.wasm.diag" 2>/dev/null >&2; exit 1
fi
VIBE_NORMALIZE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/filled.vibe" "$cdir2/norm.vibe" >/dev/null 2>&1 || true
if ! head -1 "$cdir2/norm.vibe" 2>/dev/null | grep -q "^require @gate/d2pkg 1.0.0 = #pkg:sha1:"; then
  echo "[selfhost-only-gate] FAIL: normalize did not re-emit the require pin line (#730 D-3)" >&2
  head -3 "$cdir2/norm.vibe" 2>/dev/null >&2; exit 1
fi
rm -rf ".vibe/store/@gate" "$cdir2"
echo "[selfhost-only-gate] content-addressed store regression ok"

# 6h. workspace lib/ package resolution (#751, ADR-0065): `@scope/name`
#     resolves through lib/@scope/name/index.vibei WITHOUT a require pin
#     (dev-mode lane; the pinned store stays first in candidate order). A pin,
#     when present, is still the truth: a wrong pin against the lib/ copy is
#     rejected. The package below declares no impl imports, so this also
#     exercises sibling auto-discovery (#730) through the lib/ path.
echo "[selfhost-only-gate] 6h workspace lib/ package resolution (#751)"
lpkg="lib/@gate751/greet"
rm -rf "lib/@gate751"; mkdir -p "$lpkg"
printf 'fn greet_n(x: Int) -> Int\n' > "$lpkg/index.vibei"
printf 'export fn greet_n(x: Int) -> Int { x + 2 }\n' > "$lpkg/impl.vibe"
ldir="_build/_gate_lib751"
rm -rf "$ldir"; mkdir -p "$ldir"
printf 'import @gate751/greet { greet_n }\nexport let _start: () -> Int = () -> { greet_n(40) }\n' > "$ldir/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ldir/ok.vibe" "$ldir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$ldir/ok.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: unpinned lib/ package import did not compile (#751)" >&2
  cat "$ldir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
printf 'require @gate751/greet 1.0.0 = #pkg:sha1:0000000000000000000000000000000000000000\n\nimport @gate751/greet { greet_n }\nexport let _start: () -> Int = () -> { greet_n(40) }\n' > "$ldir/bad.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ldir/bad.vibe" "$ldir/bad.wasm" _start >/dev/null 2>&1 \
  && [ -s "$ldir/bad.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: wrong pin against a lib/ copy was not rejected (#751)" >&2; exit 1
fi
if ! grep -q "pin mismatch" "$ldir/bad.wasm.diag" 2>/dev/null; then
  echo "[selfhost-only-gate] FAIL: lib/ pin rejection lacks the expected diagnostic (#751)" >&2
  cat "$ldir/bad.wasm.diag" 2>/dev/null >&2; exit 1
fi
rm -rf "lib/@gate751" "$ldir"
echo "[selfhost-only-gate] workspace lib/ package resolution ok"

# 6i. VIBE_LIB external roots + freeze (#751, ADR-0065): an @scope/name
#     package living OUTSIDE the workspace resolves through a VIBE_LIB root
#     (":"-separated list; missing roots are skipped in order). The
#     workspace lib/ copy wins over an external root when both exist, and
#     VIBE_REQUIRE_PINS=1 (the release/publish freeze switch) rejects any
#     pin-less dev-mode lib resolution. Each step uses a distinct consumer
#     file: the persistent header/dep caches key on content, and the SAME
#     content under a different VIBE_LIB would replay the previous
#     resolution.
echo "[selfhost-only-gate] 6i VIBE_LIB external roots + freeze (#751)"
xroot="$(mktemp -d)"
xpkg="$xroot/@gate751x/echo"
mkdir -p "$xpkg"
printf 'fn echo_n(x: Int) -> Int\n' > "$xpkg/index.vibei"
printf 'export fn echo_n(x: Int) -> Int { x + 2 }\n' > "$xpkg/impl.vibe"
xdir="_build/_gate_lib751x"
rm -rf "$xdir" "lib/@gate751x"; mkdir -p "$xdir"
# (1) without a usable root the name must NOT resolve
printf 'import @gate751x/echo { echo_n }\nexport let _start: () -> Int = () -> { echo_n(40) }\n' > "$xdir/miss.vibe"
if VIBE_LIB="$xroot/does-not-exist" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/miss.vibe" "$xdir/miss.wasm" _start >/dev/null 2>&1 \
  && [ -s "$xdir/miss.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: external package resolved without a VIBE_LIB root (#751)" >&2; exit 1
fi
# (2) a ":"-separated VIBE_LIB resolves through the first root that has the
#     package (missing roots skipped); the compiled program runs.
printf 'import @gate751x/echo { echo_n }\nexport let _start: () -> Int = () -> { echo_n(40) + 0 }\n' > "$xdir/ext.vibe"
VIBE_LIB="$xroot/does-not-exist:$xroot" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/ext.vibe" "$xdir/ext.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xdir/ext.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: VIBE_LIB root resolution did not compile (#751)" >&2
  cat "$xdir/ext.wasm.diag" 2>/dev/null >&2; exit 1
fi
ext_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$xdir/ext.wasm" 2>/dev/null | tail -1)"
if [ "$ext_out" != "42" ]; then
  echo "[selfhost-only-gate] FAIL: VIBE_LIB-resolved package returned '$ext_out' (want 42) (#751)" >&2; exit 1
fi
# (3) the workspace lib/ copy wins over the external root
mkdir -p "lib/@gate751x/echo"
printf 'fn echo_n(x: Int) -> Int\n' > "lib/@gate751x/echo/index.vibei"
printf 'export fn echo_n(x: Int) -> Int { x + 3 }\n' > "lib/@gate751x/echo/impl.vibe"
printf 'import @gate751x/echo { echo_n }\nexport let _start: () -> Int = () -> { echo_n(40) + 0 + 0 }\n' > "$xdir/ws.vibe"
VIBE_LIB="$xroot/does-not-exist:$xroot" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/ws.vibe" "$xdir/ws.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xdir/ws.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: workspace-precedence consumer did not compile (#751)" >&2
  cat "$xdir/ws.wasm.diag" 2>/dev/null >&2; exit 1
fi
ws_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$xdir/ws.wasm" 2>/dev/null | tail -1)"
if [ "$ws_out" != "43" ]; then
  echo "[selfhost-only-gate] FAIL: workspace lib/ did not win over VIBE_LIB root (got '$ws_out', want 43) (#751)" >&2; exit 1
fi
# (4) freeze: VIBE_REQUIRE_PINS=1 demands a pin for any dev-mode lib lane
printf 'import @gate751x/echo { echo_n }\nexport let _start: () -> Int = () -> { echo_n(40) + 0 + 0 + 0 }\n' > "$xdir/frz.vibe"
if VIBE_REQUIRE_PINS=1 VIBE_LIB="$xroot" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/frz.vibe" "$xdir/frz.wasm" _start >/dev/null 2>&1 \
  && [ -s "$xdir/frz.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: pin-less lib resolution was allowed under VIBE_REQUIRE_PINS=1 (#751)" >&2; exit 1
fi
if ! grep -q "pin required" "$xdir/frz.wasm.diag" 2>/dev/null; then
  echo "[selfhost-only-gate] FAIL: freeze rejection lacks the expected diagnostic (#751)" >&2
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
VIBE_LIB="$xroot" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/replay.vibe" "$xdir/replay1.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xdir/replay1.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: replay warm-up compile failed (#758)" >&2
  cat "$xdir/replay1.wasm.diag" 2>/dev/null >&2; exit 1
fi
if VIBE_LIB="$xroot/does-not-exist" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/replay.vibe" "$xdir/replay2.wasm" _start >/dev/null 2>&1 \
  && [ -s "$xdir/replay2.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: warm cache replayed a removed VIBE_LIB root (#758)" >&2; exit 1
fi
if VIBE_REQUIRE_PINS=1 VIBE_LIB="$xroot" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/replay.vibe" "$xdir/replay3.wasm" _start >/dev/null 2>&1 \
  && [ -s "$xdir/replay3.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: warm cache bypassed VIBE_REQUIRE_PINS=1 (#758)" >&2; exit 1
fi
if ! grep -q "pin required" "$xdir/replay3.wasm.diag" 2>/dev/null; then
  echo "[selfhost-only-gate] FAIL: freeze-under-warm-cache rejection lacks the expected diagnostic (#758)" >&2
  cat "$xdir/replay3.wasm.diag" 2>/dev/null >&2; exit 1
fi
rm -rf "$xdir" "$xroot"
echo "[selfhost-only-gate] VIBE_LIB external roots + freeze ok"

# 6j. distribution pipeline (#754, ADR-0065 Phase 4): publish (version
#     directive + semver gate) -> fetch cache (CAS keyed by package hash +
#     versions.tsv) -> materialize into $VIBE_HOME/lib (the default VIBE_LIB
#     root) -> name resolution -> build&run; then the pinned store lane
#     under freeze; then the two rejections that make version->hash an
#     immutable mapping (same-version republish; dishonest semver claim).
echo "[selfhost-only-gate] 6j distribution pipeline: publish/cache/materialize (#754)"
jhome="$(mktemp -d)"
jsrc="$jhome/src/@gate754/mathx"
mkdir -p "$jsrc"
printf 'version 1.0.0\n\nfn quad(x: Int) -> Int\n' > "$jsrc/index.vibei"
printf 'export fn quad(x: Int) -> Int { x * 4 }\n' > "$jsrc/impl.vibe"
jdir="_build/_gate_pkg754"
rm -rf "$jdir" ".vibe/store/@gate754"; mkdir -p "$jdir"
if ! VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$jsrc" > "$jdir/pub1.log" 2>&1; then
  echo "[selfhost-only-gate] FAIL: publish of @gate754/mathx@1.0.0 failed (#754)" >&2
  cat "$jdir/pub1.log" >&2; exit 1
fi
if ! grep -q "@gate754/mathx@1.0.0" "$jhome/cache/versions.tsv" 2>/dev/null; then
  echo "[selfhost-only-gate] FAIL: publish did not record the version mapping (#754)" >&2; exit 1
fi
if ! VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate754/mathx@1.0.0" > "$jdir/inst1.log" 2>&1; then
  echo "[selfhost-only-gate] FAIL: install/materialize into VIBE_HOME/lib failed (#754)" >&2
  cat "$jdir/inst1.log" >&2; exit 1
fi
printf 'import @gate754/mathx { quad }\nexport let _start: () -> Int = () -> { quad(11) }\n' > "$jdir/use.vibe"
VIBE_HOME="$jhome" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$jdir/use.vibe" "$jdir/use.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$jdir/use.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: materialized package did not resolve via VIBE_HOME default root (#754)" >&2
  cat "$jdir/use.wasm.diag" 2>/dev/null >&2; exit 1
fi
juse_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$jdir/use.wasm" 2>/dev/null | tail -1)"
if [ "$juse_out" != "44" ]; then
  echo "[selfhost-only-gate] FAIL: materialized package returned '$juse_out' (want 44) (#754)" >&2; exit 1
fi
# pinned store lane under freeze: install --store, consumer carries the pin
if ! VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate754/mathx@1.0.0" --store > "$jdir/inst2.log" 2>&1; then
  echo "[selfhost-only-gate] FAIL: install --store failed (#754)" >&2
  cat "$jdir/inst2.log" >&2; exit 1
fi
jhash="$(awk -F'\t' '$1 == "@gate754/mathx@1.0.0" { print $2 }' "$jhome/cache/versions.tsv")"
printf 'require @gate754/mathx 1.0.0 = #%s\n\nimport @gate754/mathx { quad }\nexport let _start: () -> Int = () -> { quad(11) + 0 }\n' "$jhash" > "$jdir/pinned.vibe"
VIBE_REQUIRE_PINS=1 VIBE_HOME="$jhome" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$jdir/pinned.vibe" "$jdir/pinned.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$jdir/pinned.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: pinned store build under VIBE_REQUIRE_PINS=1 failed (#754)" >&2
  cat "$jdir/pinned.wasm.diag" 2>/dev/null >&2; exit 1
fi
# same-version republish with different content must be rejected
printf 'export fn quad(x: Int) -> Int { x * 5 }\n' > "$jsrc/impl.vibe"
if VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$jsrc" > "$jdir/pub2.log" 2>&1; then
  echo "[selfhost-only-gate] FAIL: same-version republish was accepted (#754)" >&2; exit 1
fi
if ! grep -q "same-version republish rejected" "$jdir/pub2.log"; then
  echo "[selfhost-only-gate] FAIL: republish rejection lacks the expected message (#754)" >&2
  cat "$jdir/pub2.log" >&2; exit 1
fi
# dishonest bump: surface grows but only the patch level is bumped
printf 'version 1.0.1\n\nfn quad(x: Int) -> Int\nfn oct(x: Int) -> Int\n' > "$jsrc/index.vibei"
printf 'export fn quad(x: Int) -> Int { x * 4 }\nexport fn oct(x: Int) -> Int { x * 8 }\n' > "$jsrc/impl.vibe"
if VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$jsrc" > "$jdir/pub3.log" 2>&1; then
  echo "[selfhost-only-gate] FAIL: dishonest patch bump was accepted by publish (#754)" >&2; exit 1
fi
# honest minor bump passes (versions come from the directives, no env)
printf 'version 1.1.0\n\nfn quad(x: Int) -> Int\nfn oct(x: Int) -> Int\n' > "$jsrc/index.vibei"
if ! VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$jsrc" > "$jdir/pub4.log" 2>&1; then
  echo "[selfhost-only-gate] FAIL: honest minor bump was rejected by publish (#754)" >&2
  cat "$jdir/pub4.log" >&2; exit 1
fi
rm -rf ".vibe/store/@gate754" "$jdir" "$jhome"
echo "[selfhost-only-gate] distribution pipeline ok"

# 6k. registry-less git resolution (#755 Phase 0): `vibe_pkg.sh add` fetches
#     a package from a git source (github: is sugar over the same path),
#     resolves the ref to a COMMIT (provenance), hashes the fetched sources
#     LOCALLY, and installs only when the hash agrees with the expected pin
#     (or records it trust-on-first-use). A hermetic file:// repo stands in
#     for GitHub; the tamper step re-serves the same version with different
#     content and must be rejected by the version->hash record.
echo "[selfhost-only-gate] 6k registry-less git resolution (#755 Phase 0)"
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
  echo "[selfhost-only-gate] FAIL: git add (TOFU) failed (#755)" >&2
  cat "$kdir/add1.log" >&2; exit 1
fi
khash="$(awk -F'\t' '$1 == "@gate755/hex@1.0.0" { print $2 }' "$khome/cache/versions.tsv")"
if [ -z "$khash" ]; then
  echo "[selfhost-only-gate] FAIL: git add did not record the version mapping (#755)" >&2; exit 1
fi
if ! grep -q "@gate755/hex@1.0.0" "$khome/cache/provenance.tsv" 2>/dev/null; then
  echo "[selfhost-only-gate] FAIL: git add did not record provenance (#755)" >&2; exit 1
fi
printf 'import @gate755/hex { hex_n }\nexport let _start: () -> Int = () -> { hex_n(36) }\n' > "$kdir/use.vibe"
VIBE_HOME="$khome" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$kdir/use.vibe" "$kdir/use.wasm" _start >/dev/null 2>&1 || true
kuse_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$kdir/use.wasm" 2>/dev/null | tail -1)"
if [ "$kuse_out" != "42" ]; then
  echo "[selfhost-only-gate] FAIL: git-added package returned '$kuse_out' (want 42) (#755)" >&2; exit 1
fi
# (2) wrong expected pin rejects BEFORE any side effect (fresh home)
khome2="$(mktemp -d)"
if VIBE_HOME="$khome2" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh add "$kspec" "#pkg:sha1:0000000000000000000000000000000000000000" > "$kdir/add2.log" 2>&1; then
  echo "[selfhost-only-gate] FAIL: wrong expected pin was accepted (#755)" >&2; exit 1
fi
if ! grep -q "hash mismatch" "$kdir/add2.log" || [ -f "$khome2/cache/versions.tsv" ]; then
  echo "[selfhost-only-gate] FAIL: pin rejection is wrong or left side effects (#755)" >&2
  cat "$kdir/add2.log" >&2; exit 1
fi
# (3) correct expected pin verifies a fresh fetch
if ! VIBE_HOME="$khome2" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh add "$kspec" "#$khash" > "$kdir/add3.log" 2>&1; then
  echo "[selfhost-only-gate] FAIL: correct expected pin was rejected (#755)" >&2
  cat "$kdir/add3.log" >&2; exit 1
fi
# (4) upstream tampers: same version, different content -> rejected by the
#     local version->hash record
printf 'export fn hex_n(x: Int) -> Int { x + 7 }\n' > "$krepo/packages/@gate755/hex/impl.vibe"
git -C "$krepo" add -A
git -C "$krepo" -c user.email=gate@vibe -c user.name=gate commit -qm tamper
if VIBE_HOME="$khome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh add "$kspec" > "$kdir/add4.log" 2>&1; then
  echo "[selfhost-only-gate] FAIL: tampered same-version fetch was accepted (#755)" >&2; exit 1
fi
if ! grep -q "version->hash is immutable" "$kdir/add4.log"; then
  echo "[selfhost-only-gate] FAIL: tamper rejection lacks the expected message (#755)" >&2
  cat "$kdir/add4.log" >&2; exit 1
fi
rm -rf "$kdir" "$khome" "$khome2" "$krepo"
echo "[selfhost-only-gate] registry-less git resolution ok"

# 6d. where-contract + publish-gate regression (#731 / #732): a violated
#     requires clause traps at runtime; the publish semver gate accepts an
#     honest bump and rejects a dishonest one.
echo "[selfhost-only-gate] 6d where-contract + publish gate regression (#731/#732)"
edir="_build/_gate_ef"
rm -rf "$edir"; mkdir -p "$edir"
printf 'fn half_pos(x: Int) -> Int where { requires: x > 0 } { x / 2 }\nexport let _start: () -> Int = () -> { half_pos(0 - 4) }\n' > "$edir/viol.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/viol.vibe" "$edir/viol.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$edir/viol.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: where-contract program did not compile (#731)" >&2
  cat "$edir/viol.wasm.diag" 2>/dev/null >&2; exit 1
fi
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edir/viol.wasm" >/dev/null 2>&1; then
  echo "[selfhost-only-gate] FAIL: violated requires clause did not trap (#731)" >&2; exit 1
fi
printf 'fn a(x: Int) -> Int\n' > "$edir/prev.vibei"
printf 'fn a(x: Int) -> Int\nfn b(x: Int) -> Int\n' > "$edir/next.vibei"
VIBE_PUBLISH_CHECK=1 VIBE_PUBLISH_PREV="$edir/prev.vibei" VIBE_PUBLISH_PREV_VERSION=1.0.0 VIBE_PUBLISH_VERSION=1.1.0 \
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/next.vibei" "$edir/pub.out" __no_entry__ >/dev/null 2>&1 || true
if ! grep -q "^ok" "$edir/pub.out" 2>/dev/null; then
  echo "[selfhost-only-gate] FAIL: honest minor bump was rejected (#732)" >&2
  cat "$edir/pub.out.diag" 2>/dev/null >&2; exit 1
fi
VIBE_PUBLISH_CHECK=1 VIBE_PUBLISH_PREV="$edir/prev.vibei" VIBE_PUBLISH_PREV_VERSION=1.0.0 VIBE_PUBLISH_VERSION=1.0.1 \
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/next.vibei" "$edir/pub2.out" __no_entry__ >/dev/null 2>&1 || true
if ! grep -q "requires minor" "$edir/pub2.out.diag" 2>/dev/null; then
  echo "[selfhost-only-gate] FAIL: dishonest patch claim was not rejected (#732)" >&2
  cat "$edir/pub2.out" "$edir/pub2.out.diag" 2>/dev/null >&2; exit 1
fi
rm -rf "$edir"
echo "[selfhost-only-gate] where-contract + publish gate regression ok"

# (6e retired by #741: the vendored lib/@vibe/compiler/cache/sha1.vibe twin was
# deleted — the compiler consumes lib/@vibe/core through the contract import,
# so there is nothing left to drift-check.)

# 6f. @vibe/core store-install E2E: install the REAL in-repo package into
#     .vibe/store via scripts/vibe_core_install.sh, then compile AND RUN a
#     require-pinned consumer against it. The pin is taken from the install
#     output, so core source changes never stale this step. Complements 6c
#     (synthetic packages) with the shipped package: 82-decl contract,
#     bodyless `type` re-exports, multi-impl any-match conformance.
echo "[selfhost-only-gate] 6f @vibe/core store-install E2E"
cdir6f="_build/_gate_core_store"
rm -rf "$cdir6f" ".vibe/store/@vibe/core"; mkdir -p "$cdir6f"
if ! VIBE_CORE_CLI_WASM="$stage2_wasm" bash scripts/vibe_core_install.sh > "$cdir6f/install.out" 2>&1; then
  echo "[selfhost-only-gate] FAIL: vibe_core_install.sh failed" >&2
  cat "$cdir6f/install.out" >&2; exit 1
fi
core_pin="$(grep '^package ' "$cdir6f/install.out" | cut -d' ' -f2)"
if [ -z "$core_pin" ]; then
  echo "[selfhost-only-gate] FAIL: install printed no package pin" >&2
  cat "$cdir6f/install.out" >&2; exit 1
fi
cat > "$cdir6f/consumer.vibe" <<EOF
require @vibe/core 0.1.0 = $core_pin

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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir6f/consumer.vibe" "$cdir6f/consumer.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir6f/consumer.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: pinned @vibe/core consumer did not compile" >&2
  cat "$cdir6f/consumer.wasm.diag" 2>/dev/null >&2; exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$cdir6f/consumer.wasm" >/dev/null 2>&1; then
  echo "[selfhost-only-gate] FAIL: @vibe/core consumer trapped at runtime" >&2; exit 1
fi
rm -rf "$cdir6f" ".vibe/store/@vibe/core"
echo "[selfhost-only-gate] @vibe/core store-install E2E ok"

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

# 14b. rank-1 method-level generics on trait methods (#684): a trait method may
#      declare its OWN bounded type parameter `m: [X: Show](Self, X) -> R`. The
#      binder lives on the TRAIT method only; the impl does NOT repeat it. At a
#      qualified call `C::m(recv, arg)` the `Show` witness for `X = type(arg)`
#      must be resolved/threaded so the body's `X::show(arg)` dispatches to the
#      concrete impl. Covers an Int and a String argument (witness per type).
echo "[selfhost-only-gate] 14b/14 rank-1 trait-method generics regression (#684)"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mgdir/mg.vibe" "$mgdir/mg.wasm" _start >/dev/null 2>&1
if [ ! -s "$mgdir/mg.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: rank-1 trait-method generic program did not compile" >&2
  cat "$mgdir/mg.wasm.diag" 2>/dev/null >&2; exit 1
fi
mg_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$mgdir/mg.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$mg_out" != "84" ]; then
  echo "[selfhost-only-gate] FAIL: rank-1 trait-method generic mismatch (got '$mg_out', want 84 -> #684 regressed)" >&2
  exit 1
fi
rm -rf "$mgdir"
echo "[selfhost-only-gate] rank-1 trait-method generics regression ok"

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

# 15b. extended derive(...) regression (#638): enum `derive(Ord/Show)`, struct +
#      enum `derive(Default)`, and `derive(Hash)` (Map-key usability). Each real
#      fixture is a `test "..."`-block suite; compile it through the fresh stage2
#      and run `_start` — every `assert` traps on failure, so a clean run == all
#      blocks passed. Covers multiple-derive (`derive(Eq, Ord, Show, Hash)`) too.
echo "[selfhost-only-gate] 15b/15 extended derive (enum Ord/Show, Default, Hash)"
for fx in \
  fixtures/derive_ord_show_test.vibe \
  fixtures/derive_enum_ord_show_test.vibe \
  fixtures/derive_default_test.vibe \
  fixtures/derive_hash_test.vibe \
  fixtures/eq_array_option_fields.vibe; do
  fxout="_build/_gate_derive_ext_$(basename "${fx%.vibe}").wasm"
  rm -f "$fxout" "$fxout.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$fx" "$fxout" _start >/dev/null 2>&1
  if [ ! -s "$fxout" ]; then
    echo "[selfhost-only-gate] FAIL: $fx did not compile" >&2
    cat "$fxout.diag" 2>/dev/null >&2; exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
      --invoke _start "$fxout" >/dev/null 2>&1; then
    echo "[selfhost-only-gate] FAIL: $fx has a failing test (assert trapped)" >&2
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$undir/u.vibe" "$undir/u.wasm" _start >/dev/null 2>&1 || true
if [ -s "$undir/u.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: derive(Foo) unknown trait was accepted (should error)" >&2
  exit 1
fi
rm -rf "$undir"
echo "[selfhost-only-gate] extended derive (enum Ord/Show, Default, Hash) ok"

# 15c. railway `let*` / `?` generalized to Option (#635): the parser emits a
#      type-directed sentinel that the pre-check desugar lowers by the operand's
#      head type — `Option` (Some/None) or `Result` (Ok/Err, the default). The
#      fixtures are `test "..."`-block suites; compile each through the fresh
#      stage2 and run `_start` (a failing `assert` traps, so a clean run == all
#      blocks passed). Covers Option `let*`, Result `let*` unchanged, Option `?`
#      early-return-None, Result `?` early-return-Err, and the mixed-type type
#      error (a negative file that must NOT compile).
echo "[selfhost-only-gate] 15c/15 railway let*/? Option generalization (#635)"
for fx in \
  fixtures/try_let_star_option_test.vibe \
  fixtures/try_question_option_test.vibe; do
  fxout="_build/_gate_railway_$(basename "${fx%.vibe}").wasm"
  rm -f "$fxout" "$fxout.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$fx" "$fxout" __no_entry__ >/dev/null 2>&1
  if [ ! -s "$fxout" ]; then
    echo "[selfhost-only-gate] FAIL: $fx did not compile" >&2
    cat "$fxout.diag" 2>/dev/null >&2; exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
      --invoke _start "$fxout" >/dev/null 2>&1; then
    echo "[selfhost-only-gate] FAIL: $fx has a failing test (assert trapped)" >&2
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mixdir/m.vibe" "$mixdir/m.wasm" _start >/dev/null 2>&1 || true
if [ -s "$mixdir/m.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: mixed Result/Option let* chain compiled (should be a type error)" >&2
  exit 1
fi
rm -rf "$mixdir"
echo "[selfhost-only-gate] railway let*/? Option generalization ok"

# 15d. derive(Hash) transparent Map keys (#694): a `derive(Hash)` struct is
#      usable as a Map key through the method-bearing `Hash::hash_key` —
#      `map_key_to_string = [K: Hash](key) -> K::hash_key(key)` threads the
#      witness dict (#684) through the `[K: Hash]` `get_by`/`has_by`/`get_or_by`
#      generic->generic chain, and the derived structural `T::hash_key` (a
#      recursive `to_string`) is the key. INCLUDES a key with a nested aggregate
#      field (nested struct + Option + Array) to prove Layer-2 recursion. The
#      fixture is a `test "..."`-block suite; compile via the fresh stage2 and run
#      `_start` (a failing `assert` traps, so a clean run == all blocks passed).
echo "[selfhost-only-gate] 15d/15 derive(Hash) transparent Map keys (#694)"
hkfx="fixtures/derive_hash_map_key_test.vibe"
hkout="_build/_gate_derive_hash_map_key.wasm"
rm -f "$hkout" "$hkout.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hkfx" "$hkout" __no_entry__ >/dev/null 2>&1
if [ ! -s "$hkout" ]; then
  echo "[selfhost-only-gate] FAIL: $hkfx did not compile" >&2
  cat "$hkout.diag" 2>/dev/null >&2; exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$hkout" >/dev/null 2>&1; then
  echo "[selfhost-only-gate] FAIL: $hkfx has a failing test (assert trapped) -> #694 regressed" >&2
  exit 1
fi
rm -f "$hkout" "$hkout.diag" "$hkout.funcmap"
echo "[selfhost-only-gate] derive(Hash) transparent Map keys ok"

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
for suite in lib/@vibe/prelude/lazy_iter_test.vibe lib/@vibe/prelude/async_iter_test.vibe; do
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$nldir/nestedlit.vibe" "$nldir/nestedlit.wasm" _start >/dev/null 2>&1
if [ ! -s "$nldir/nestedlit.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: nested literal sub-pattern program did not compile" >&2; exit 1
fi
nestedlit_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$nldir/nestedlit.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$nestedlit_out" != "3075" ]; then
  echo "[selfhost-only-gate] FAIL: nested literal sub-pattern mismatch (got '$nestedlit_out', want 3075 -> #613 regressed)" >&2
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_transitive.vibe" "$pfdir/bad_transitive.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_transitive.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: undeclared transitive effect call compiled (#626 transitive enforcement regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/good_transitive.vibe" "$pfdir/good_transitive.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$pfdir/good_transitive.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: correctly-declared transitive effect chain did not compile (#626 over-rejects)" >&2; exit 1
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_import_transitive.vibe" "$pfdir/bad_import_transitive.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_import_transitive.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: undeclared call of IMPORTED effectful function compiled (#812 regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/good_import_transitive.vibe" "$pfdir/good_import_transitive.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$pfdir/good_import_transitive.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: correctly-declared imported effect call did not compile (#812 over-rejects)" >&2; exit 1
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hdir/multiop.vibe" "$hdir/multiop.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$hdir/multiop.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: multi-operation effect handler did not compile (#665 dispatch regressed)" >&2; exit 1
fi
# a = Mul(3)*1000 = 3000 ; b = Mul(3)*10 + Add(5)+10 = 30+15 = 45 ; total 3045
multiop_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$hdir/multiop.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$multiop_out" != "3045" ]; then
  echo "[selfhost-only-gate] FAIL: multi-operation dispatch wrong (got '$multiop_out', want 3045 -> #665 regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hdir/singleop.vibe" "$hdir/singleop.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$hdir/singleop.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: single-operation effect handler did not compile (#665 over-rejects)" >&2; exit 1
fi
rm -rf "$hdir"
echo "[selfhost-only-gate] handle effect discharge ok"

# 27b. effect op signatures (#813): perform arguments, handler arm names and
#      payload types, and resume values are validated against the DECLARED
#      effect's op signatures. Each was previously unchecked (silent garbage).
echo "[selfhost-only-gate] 27b/27 effect op signature checking (#813)"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$odir/ok_op.vibe" "$odir/ok_op.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$odir/ok_op.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: well-typed effect op program did not compile (#813 over-rejects)" >&2; exit 1
fi
op_out="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$odir/ok_op.wasm" 2>/dev/null | tail -n 1)"
if [ "$op_out" != "42" ]; then
  echo "[selfhost-only-gate] FAIL: effect op control returned '$op_out' (expected 42)" >&2; exit 1
fi
for bad in bad_performarg bad_performarity bad_armname bad_armpayload bad_resumeval; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$odir/$bad.vibe" "$odir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$odir/$bad.wasm" ]; then
    echo "[selfhost-only-gate] FAIL: ill-typed $bad compiled (#813 regressed)" >&2; exit 1
  fi
done
rm -rf "$odir"
echo "[selfhost-only-gate] effect op signature checking ok"

# 27c. index bounds checks (#811): OOB / negative Array and Bytes access must
#      TRAP (unreachable) instead of silently reading/writing adjacent memory;
#      in-bounds access is unchanged.
echo "[selfhost-only-gate] 27c/27 index bounds checks (#811)"
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
  Array::get(a, 0) + Bytes::get(b, 0) + Bytes::get(b, 3) - 9
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$bdir/inbounds.vibe" "$bdir/inbounds.wasm" _start >/dev/null 2>&1 || true
bounds_out="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$bdir/inbounds.wasm" 2>/dev/null | tail -n 1 || true)"
if [ "$bounds_out" != "42" ]; then
  echo "[selfhost-only-gate] FAIL: in-bounds access returned '$bounds_out' (expected 42; #811 over-traps)" >&2; exit 1
fi
for oob in oob_get oob_neg oob_bytes; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$bdir/$oob.vibe" "$bdir/$oob.wasm" _start >/dev/null 2>&1 || true
  if bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$bdir/$oob.wasm" >/dev/null 2>&1; then
    echo "[selfhost-only-gate] FAIL: $oob ran without trapping (#811 regressed)" >&2; exit 1
  fi
done
rm -rf "$bdir"
echo "[selfhost-only-gate] index bounds checks ok"

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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$adir/right.vibe" "$adir/right.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$adir/right.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: a correctly-typed call did not compile (arg-check over-rejects)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$adir/ffright.vibe" "$adir/ffright.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$adir/ffright.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: a correct field-stored-function call did not compile (over-rejects)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$adir/wrong.vibe" "$adir/wrong.wasm" _start >/dev/null 2>&1 || true
if [ -s "$adir/wrong.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: an ill-typed argument (Int <- String) compiled (arg-check regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$adir/ffwrong.vibe" "$adir/ffwrong.wasm" _start >/dev/null 2>&1 || true
if [ -s "$adir/ffwrong.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: ill-typed field-stored-function call (Int <- String) compiled" >&2; exit 1
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
cat > "$tdir/bad_arity_bytesnew.vibe" <<'EOF'
export let _start: () -> Int = () -> { let b = Bytes::new(1, 2); Bytes::length(b) }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/ok.vibe" "$tdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdir/ok.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: well-typed binding/assign/if did not compile (over-rejects)" >&2; exit 1
fi
for bad in bad_let bad_assign bad_if bad_ifnoelse bad_struct bad_locallet bad_missingfield bad_fnannot bad_return bad_retviaannot bad_genhead bad_builtinarg bad_dupfield bad_some2 bad_optfield bad_concatarg bad_concatarg0 bad_substrarg bad_unknownfield bad_guardonly bad_arity_get bad_arity_bytesnew; do
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
cat > "$mdir/bad_valty.vibe" <<'EOF'
struct Cell2 { mut n: Int }
export let _start: () -> Int = () -> {
  let c = Cell2::{ n: 0 }
  c.n = "str"
  c.n
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mdir/ok_mut.vibe" "$mdir/ok_mut.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$mdir/ok_mut.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: mut-field write did not compile (over-rejects)" >&2
  cat "$mdir/ok_mut.wasm.diag" 2>/dev/null >&2; exit 1
fi
for bad in bad_nonmut bad_valty; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$mdir/$bad.vibe" "$mdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$mdir/$bad.wasm" ]; then
    echo "[selfhost-only-gate] FAIL: $bad field write compiled (mut/value-type check regressed)" >&2; exit 1
  fi
done
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir/ok.vibe" "$cdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir/ok.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: well-typed match/array did not compile (over-rejects)" >&2
  cat "$cdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
for bad in bad_match bad_array bad_arraynest bad_call bad_calloption bad_not bad_forint bad_tuparity; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$cdir/$bad.vibe" "$cdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$cdir/$bad.wasm" ]; then
    echo "[selfhost-only-gate] FAIL: ill-typed $bad compiled (consistency check regressed)" >&2; exit 1
  fi
done
rm -rf "$cdir"
echo "[selfhost-only-gate] match-arm / array / non-fn-call / unary-not / for-iterable type checking ok"

# 32. mutability discipline: reassigning a plain (immutable) `let` is rejected;
#     a `let mut` binding, an accumulator updated in a loop, and a closure-local
#     `let mut` must still compile.
echo "[selfhost-only-gate] 32/32 mutability discipline (immutable let reassignment)"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mudir/ok.vibe" "$mudir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$mudir/ok.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: well-typed mut/accumulator did not compile (over-rejects)" >&2
  cat "$mudir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mudir/bad.vibe" "$mudir/bad.wasm" _start >/dev/null 2>&1 || true
if [ -s "$mudir/bad.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: immutable-let reassignment compiled (mutability check regressed)" >&2; exit 1
fi
rm -rf "$mudir"
echo "[selfhost-only-gate] mutability discipline ok"

# 32b. mutability discipline completeness (#629 step 3-2): an illegal reassignment
#      of an immutable `let` must be flagged even when it sits inside a map literal
#      (and likewise labeled arg / spread / break / continue — check_mutability_expr
#      previously dropped these Expr forms to `_ => errors`, missing the violation).
#      A `let mut` reassignment inside the same form must still compile (no over-reject).
echo "[selfhost-only-gate] 32b/32 mutability discipline completeness (nested forms)"
mu2dir="_build/_gate_mutability_nested"
rm -rf "$mu2dir"; mkdir -p "$mu2dir"
cat > "$mu2dir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let mut x = 1
  let m = map { "a": { x = 2; x } }
  m["a"]
}
EOF
cat > "$mu2dir/bad.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let x = 1
  let m = map { "a": { x = 2; x } }
  m["a"]
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mu2dir/ok.vibe" "$mu2dir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$mu2dir/ok.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: legal mut reassignment inside map literal did not compile (over-rejects)" >&2
  cat "$mu2dir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mu2dir/bad.vibe" "$mu2dir/bad.wasm" _start >/dev/null 2>&1 || true
if [ -s "$mu2dir/bad.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: immutable-let reassignment inside map literal compiled (completeness regressed)" >&2; exit 1
fi
rm -rf "$mu2dir"
echo "[selfhost-only-gate] mutability discipline completeness ok"

# 33. pattern-soundness: a constructor pattern must bind its variant's exact
#     payload arity, and cannot match a scalar scrutinee. Binding the right
#     arity, a nullary variant, and the builtin Option ctors must still compile.
echo "[selfhost-only-gate] 33/33 constructor-pattern arity / scrutinee type checking"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pdir/ok.vibe" "$pdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$pdir/ok.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: well-typed ctor patterns did not compile (over-rejects)" >&2
  cat "$pdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
for bad in bad_arity bad_scalar; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$pdir/$bad.vibe" "$pdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$pdir/$bad.wasm" ]; then
    echo "[selfhost-only-gate] FAIL: ill-typed pattern $bad compiled (pattern check regressed)" >&2; exit 1
  fi
done
rm -rf "$pdir"
echo "[selfhost-only-gate] constructor-pattern arity / scrutinee type checking ok"

# 34. indexing / tuple-projection soundness: `obj[i]` on a non-indexable scalar
#     and `t.N` past a tuple's arity must be rejected; indexing an Array/String
#     and an in-range tuple projection must still compile.
echo "[selfhost-only-gate] 34/34 indexing / tuple-projection type checking"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$idir/ok.vibe" "$idir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$idir/ok.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: well-typed index/tuple did not compile (over-rejects)" >&2
  cat "$idir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
for bad in bad_index bad_tuple bad_idxtype bad_idxelem bad_stridx bad_arrget bad_arrpush bad_arrset bad_arrmap bad_arrfold bad_mapparam bad_foldparam bad_arrslice bad_arrconcat bad_arrconcatmix bad_arrpushallmix bad_arrrev; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$idir/$bad.vibe" "$idir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$idir/$bad.wasm" ]; then
    echo "[selfhost-only-gate] FAIL: ill-typed $bad compiled (index/tuple check regressed)" >&2; exit 1
  fi
done
rm -rf "$idir"
echo "[selfhost-only-gate] indexing / tuple-projection type checking ok"

# 34b. match-arm guards (#666): `pat if cond => body` must DISPATCH on the guard.
#     Guards were previously parsed and silently DISCARDED — the arm was taken
#     unconditionally (`match 5 { n if n > 100 => 999, _ => 0 }` wrongly => 999).
#     Now desugared at parse time into nested EIf/EMatch over a bound scrutinee,
#     so a failed guard falls through to later arms, and pattern bindings (with
#     re-binding in the fall-through arm) stay in scope for the guard. Verify
#     the runtime answer, not just that it compiles.
echo "[selfhost-only-gate] 34b/35 match-arm guard dispatch (#666)"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gdir/guard.vibe" "$gdir/guard.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$gdir/guard.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: guarded match did not compile" >&2
  cat "$gdir/guard.wasm.diag" 2>/dev/null >&2; exit 1
fi
gres="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$gdir/guard.wasm" 2>/dev/null | tr -dc '0-9-')"
rm -rf "$gdir"
# 7 (guard misses -> wildcard) + 11 (guard hits) + 2 (second guard) + 102 (bind fall-through) = 122
if [ "$gres" != "122" ]; then
  echo "[selfhost-only-gate] FAIL: guarded match returned '$gres' (expected 122 — guard dispatch wrong)" >&2; exit 1
fi
echo "[selfhost-only-gate] match-arm guard dispatch ok (122)"

# 35. match exhaustiveness: a match on a concrete user enum must cover every
#     variant or carry a catch-all; a non-exhaustive match must be rejected.
#     Wildcard, full-coverage, and or-pattern coverage must still compile.
echo "[selfhost-only-gate] 35/35 match exhaustiveness (enum variant coverage)"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/ok.vibe" "$xdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xdir/ok.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: exhaustive matches did not compile (over-rejects)" >&2
  cat "$xdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/bad.vibe" "$xdir/bad.wasm" _start >/dev/null 2>&1 || true
if [ -s "$xdir/bad.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: non-exhaustive match compiled (exhaustiveness check regressed)" >&2; exit 1
fi
rm -rf "$xdir"
echo "[selfhost-only-gate] match exhaustiveness ok"

# 36. literal-pattern type checking: an integer/string/boolean literal pattern
#     can only match a scrutinee of its own type — `match 5 { "x" => .. }` and a
#     nested `Some(true)` over `Option[Int]` must be rejected; matching literals
#     of the right type (incl. nested) must compile.
echo "[selfhost-only-gate] 36/36 literal-pattern type checking"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ldir/ok.vibe" "$ldir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$ldir/ok.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: well-typed literal patterns did not compile (over-rejects)" >&2
  cat "$ldir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
for bad in bad_lit bad_nested; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$ldir/$bad.vibe" "$ldir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$ldir/$bad.wasm" ]; then
    echo "[selfhost-only-gate] FAIL: ill-typed literal pattern $bad compiled (check regressed)" >&2; exit 1
  fi
done
rm -rf "$ldir"
echo "[selfhost-only-gate] literal-pattern type checking ok"

# 37. unary `-` on a non-number and `break`/`continue` outside a loop must be
#     rejected; numeric negation and in-loop break/continue must compile.
echo "[selfhost-only-gate] 37/37 unary-minus / break-outside-loop checking"
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$bdir/ok.vibe" "$bdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$bdir/ok.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: well-typed negation/break/continue did not compile (over-rejects)" >&2
  cat "$bdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
for bad in bad_neg bad_break; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$bdir/$bad.vibe" "$bdir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$bdir/$bad.wasm" ]; then
    echo "[selfhost-only-gate] FAIL: ill-formed $bad compiled (unary-minus/break check regressed)" >&2; exit 1
  fi
done
rm -rf "$bdir"
echo "[selfhost-only-gate] unary-minus / break-outside-loop checking ok"

# 38. tuple-pattern destructuring soundness: `let (a, b) = v` may only
#     destructure a tuple value; binding a tuple pattern over a concrete
#     non-tuple (`let (a, b) = 5`) must be rejected, while a genuine tuple
#     destructure must still compile.
echo "[selfhost-only-gate] 38/38 tuple-pattern destructuring type checking"
tdir="_build/_gate_tupledestr"
rm -rf "$tdir"; mkdir -p "$tdir"
cat > "$tdir/ok.vibe" <<'EOF'
export let _start: () -> Int = () -> { let (a, b) = (1, 2); a + b }
EOF
cat > "$tdir/bad_nontuple.vibe" <<'EOF'
export let _start: () -> Int = () -> { let (a, b) = 5; a + b }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/ok.vibe" "$tdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tdir/ok.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: well-typed tuple destructure did not compile (over-rejects)" >&2
  cat "$tdir/ok.wasm.diag" 2>/dev/null >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/bad_nontuple.vibe" "$tdir/bad_nontuple.wasm" _start >/dev/null 2>&1 || true
if [ -s "$tdir/bad_nontuple.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: ill-typed tuple destructure compiled (tuple-pattern check regressed)" >&2; exit 1
fi
rm -rf "$tdir"
echo "[selfhost-only-gate] tuple-pattern destructuring type checking ok"

# 39. multi-feature end-to-end smoke: real programs that combine several language
#     features must compile through the fresh stage2 AND run to a known value —
#     a codegen/runtime regression net broader than the single-feature checks
#     above. `eff` deliberately exercises this session's work together: multi-
#     operation effect dispatch (#665), a match guard inside a handler arm
#     (#666), and the effect-call discipline (#626) in one program.
echo "[selfhost-only-gate] 39/39 multi-feature end-to-end smoke"
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
# interp: string interpolation `\{expr}` / `\(expr)` parses an arbitrary
# EXPRESSION (arithmetic, call, field access, multiple holes), not just a bare
# identifier — previously the embedded source was treated as an identifier name
# (`undefined variable: 1+1`). (parser_expr_primary.vibe build_interp_expr.)
cat > "$sdir/interp.vibe" <<'EOF'
struct P { x: Int }
let inc: (Int) -> Int = (n) -> { n + 1 }
export let _start: () -> Int = () -> {
  let a = 2
  let p = P::{ x: 7 }
  let v1 = if "\{a + 3}" == "5" { 1 } else { 0 }
  let v2 = if "\{inc(a)}" == "3" { 20 } else { 0 }
  let v3 = if "\{p.x}" == "7" { 300 } else { 0 }
  let v4 = if "\{a}-\(p.x)" == "2-7" { 4000 } else { 0 }
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
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$sdir/$nm.vibe" "$sdir/$nm.wasm" _start >/dev/null 2>&1 || true
  if [ ! -s "$sdir/$nm.wasm" ]; then
    echo "[selfhost-only-gate] FAIL: smoke '$nm' did not compile (codegen regression)" >&2
    cat "$sdir/$nm.wasm.diag" 2>/dev/null >&2; exit 1
  fi
  local got
  got="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$sdir/$nm.wasm" 2>/dev/null | tr -dc '0-9-')"
  if [ "$got" != "$want" ]; then
    echo "[selfhost-only-gate] FAIL: smoke '$nm' ran to '$got' (expected $want)" >&2; exit 1
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
smoke_check tann 148
smoke_check interp 4321
smoke_check pneg 4321
smoke_check pstruct 78
smoke_check tostr 4321
smoke_check ieq 4321
rm -rf "$sdir"
echo "[selfhost-only-gate] multi-feature end-to-end smoke ok (10/153/6/111/11111/321/3021/11111/4321/148/4321/4321/78/4321/4321)"

# 40. V128 SIMD intrinsics (#536): the first-class V128 type + 12 wasm-SIMD
#     intrinsics (v128_load/store/splat/eq/le_u/ge_u/and/or/not/bitmask/
#     any_true/all_true) must type-check, lower to valid v128 instructions, and
#     run correctly on the default non-RC linear backend. fixtures/
#     v128_intrinsics_test.vibe asserts lane-wise results via i8x16.bitmask; a
#     failing assert traps (`unreachable`), so a clean `_start` exit == pass.
echo "[selfhost-only-gate] 40/40 V128 SIMD intrinsics compile+run"
vdir="_build/_gate_v128"
rm -rf "$vdir"; mkdir -p "$vdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/v128_intrinsics_test.vibe" "$vdir/v128.wasm" __no_entry__ >/dev/null 2>&1
if [ ! -s "$vdir/v128.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: v128 intrinsics test did not compile" >&2
  cat "$vdir/v128.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$vdir/v128.wasm" >/dev/null 2>&1; then
  echo "[selfhost-only-gate] FAIL: v128 intrinsics test trapped (assert failed)" >&2; exit 1
fi
rm -rf "$vdir"
echo "[selfhost-only-gate] V128 SIMD intrinsics ok"

# 40b. Fused SIMD whitespace skip (#536 Phase 3): simd_skip_ws(Bytes,Int,Int)
#      runs a single inline v128 scan loop (16 bytes/iteration, v128 kept on the
#      operand stack with NO per-op heap boxing) plus a scalar tail. The fixture
#      asserts the result equals the scalar first-non-whitespace index across the
#      tail-only, single-chunk bitmask/ctz, multi-chunk, and non-zero-start paths.
echo "[selfhost-only-gate] 40b/40 fused SIMD whitespace skip (simd_skip_ws)"
swdir="_build/_gate_simd_skip_ws"
rm -rf "$swdir"; mkdir -p "$swdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/simd_skip_ws_test.vibe" "$swdir/sw.wasm" __no_entry__ >/dev/null 2>&1
if [ ! -s "$swdir/sw.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: simd_skip_ws test did not compile" >&2
  cat "$swdir/sw.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$swdir/sw.wasm" >/dev/null 2>&1; then
  echo "[selfhost-only-gate] FAIL: simd_skip_ws test trapped (assert failed)" >&2; exit 1
fi
rm -rf "$swdir"
echo "[selfhost-only-gate] fused SIMD whitespace skip ok"

# 40c. Region capture (#629 step 2): a `let mut` captured by a closure inside a
#      struct/record literal, projection, handler, loop, labeled arg, map literal
#      or spread must still be heap-boxed (by-reference capture), not snapshotted.
#      The fixture asserts the read closure sees the writer's mutations and the
#      outer cell is updated; it traps under the pre-fix by-value snapshot bug.
echo "[selfhost-only-gate] 40c/40 region capture (mut captured inside struct literal etc.)"
rcdir="_build/_gate_region_capture"
rm -rf "$rcdir"; mkdir -p "$rcdir"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/region_capture_test.vibe" "$rcdir/rc.wasm" __no_entry__ >/dev/null 2>&1
if [ ! -s "$rcdir/rc.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: region_capture test did not compile" >&2
  cat "$rcdir/rc.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$rcdir/rc.wasm" >/dev/null 2>&1; then
  echo "[selfhost-only-gate] FAIL: region_capture test trapped (assert failed)" >&2; exit 1
fi
rm -rf "$rcdir"
echo "[selfhost-only-gate] region capture ok"

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
echo "[selfhost-only-gate] 40d/40 RC reclamation leak guard (tuple+cell+closure+enum+loop-consume)"
lkdir="_build/_gate_rc_leak"
rm -rf "$lkdir"; mkdir -p "$lkdir"
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/rc_reclaim_leak_test.vibe" "$lkdir/rc.wasm" main >/dev/null 2>&1
if [ ! -s "$lkdir/rc.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: rc_reclaim_leak fixture did not compile under VIBE_RC" >&2
  cat "$lkdir/rc.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
lk_json="$(node scripts/measure_selfhost_heap.mjs "$lkdir/rc.wasm" main 2>/dev/null)"
lk_used="$(printf '%s' "$lk_json" | sed -n 's/.*"heap_used":\([0-9]*\).*/\1/p')"
lk_result="$(printf '%s' "$lk_json" | sed -n 's/.*"result":\([0-9]*\).*/\1/p')"
if [ -z "$lk_used" ]; then
  echo "[selfhost-only-gate] FAIL: could not measure rc_reclaim_leak heap ($lk_json)" >&2; exit 1
fi
if [ "$lk_result" != "3200280000" ]; then
  echo "[selfhost-only-gate] FAIL: rc_reclaim_leak wrong result $lk_result (want 3200280000)" >&2; exit 1
fi
if [ "$lk_used" -ge 2000 ]; then
  echo "[selfhost-only-gate] FAIL: rc_reclaim_leak heap_used=$lk_used >= 2000 (RC reclamation regressed; ~800000 == full leak)" >&2; exit 1
fi
rm -rf "$lkdir"
echo "[selfhost-only-gate] RC reclamation leak guard ok (heap_used=$lk_used B at N=20000)"

# 40e. V128 SIMD intrinsics under RC (#705 follow-up): step 40 only exercised
#      the bump backend. v128 boxes are tagged pointers with NO rc header, so
#      naively letting them flow through RC's dup/drop guards would misread
#      their payload bytes as a refcount and corrupt them; Perceus now treats
#      v128-producing let-bindings as scalar (never dup/drop'd), matching their
#      forward-only, never-freed lifetime under bump too. Also covers a distinct
#      RC-only bug where v128_load/store's byte offset and v128_splat_i8x16's
#      byte value were used raw instead of untagged (RC tags Int as n<<1),
#      silently computing the wrong SIMD lane bytes.
echo "[selfhost-only-gate] 40e/40 V128 SIMD intrinsics compile+run under RC"
v2dir="_build/_gate_v128_rc"
rm -rf "$v2dir"; mkdir -p "$v2dir"
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/v128_intrinsics_test.vibe" "$v2dir/v128rc.wasm" __no_entry__ >/dev/null 2>&1
if [ ! -s "$v2dir/v128rc.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: v128 intrinsics test did not compile under RC" >&2
  cat "$v2dir/v128rc.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$v2dir/v128rc.wasm" >/dev/null 2>&1; then
  echo "[selfhost-only-gate] FAIL: v128 intrinsics test trapped under RC (assert failed)" >&2; exit 1
fi
rm -rf "$v2dir"
echo "[selfhost-only-gate] V128 SIMD intrinsics under RC ok"

# 40f. RC shadow-liveness regression guard (#715 recurrence prevention).
#      Compiles the #715 shape corpus (every minimal shape that once produced
#      a use-after-free / double-free in the Perceus RC backend) with
#      VIBE_RC=shadow -- codegen that marks freed blocks in a shadow byte
#      table and executes `unreachable` on the FIRST dup-of-freed or
#      drop-of-freed -- and runs it. A regression in the RC dup/drop
#      accounting traps HERE, deterministically, at the faulting operation,
#      instead of corrupting the free list and crashing later at an
#      unrelated, binary-layout-dependent location ("moving target").
echo "[selfhost-only-gate] 40f/40 RC shadow-liveness regression guard (#715 shapes)"
shdir="_build/_gate_rc_shadow"
rm -rf "$shdir"; mkdir -p "$shdir"
VIBE_RC=shadow VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/rc_shadow_regression_test.vibe" "$shdir/shadow.wasm" main >/dev/null 2>&1
if [ ! -s "$shdir/shadow.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: rc_shadow_regression fixture did not compile under VIBE_RC=shadow" >&2
  cat "$shdir/shadow.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
sh_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$shdir/shadow.wasm" 2>&1 | tail -1)"
if [ "$sh_out" != "122489" ]; then
  echo "[selfhost-only-gate] FAIL: rc_shadow_regression got '$sh_out' (want 122489). A trap here means an RC dup/drop accounting regression touched a freed block -- see fixtures/rc_shadow_regression_test.vibe for which shapes are covered and issue #715 for the debugging methodology." >&2
  exit 1
fi
rm -rf "$shdir"
echo "[selfhost-only-gate] RC shadow-liveness regression guard ok (122489)"

# 40g. #cfg conditional-compilation guard: the flag-off build must strip the
#      guarded statements entirely (compiles, dev symbols absent -> different
#      program), flag-on builds must select the matching statements.
echo "[selfhost-only-gate] 40g/40 #cfg conditional compilation"
cfdir="_build/_gate_cfg"
rm -rf "$cfdir"; mkdir -p "$cfdir"
VIBE_CFG=dev VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/cfg_flag_test.vibe" "$cfdir/dev.wasm" main >/dev/null 2>&1
cf_dev="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$cfdir/dev.wasm" 2>&1 | tail -1)"
VIBE_CFG=release VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/cfg_flag_test.vibe" "$cfdir/rel.wasm" main >/dev/null 2>&1
cf_rel="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$cfdir/rel.wasm" 2>&1 | tail -1)"
if [ "$cf_dev" != "102" ] || [ "$cf_rel" != "2" ]; then
  echo "[selfhost-only-gate] FAIL: #cfg selection wrong (dev='$cf_dev' want 102, release='$cf_rel' want 2)" >&2
  exit 1
fi
rm -rf "$cfdir"
echo "[selfhost-only-gate] #cfg conditional compilation ok (dev=102 release=2)"

# 40h. wasm-gc backend smoke: the VIBE_BACKEND=gc lane (selfhost port of the
#      gc backend, wired through the adapter) must compile and run the
#      supported-subset fixture identically to the linear backend. Guards the
#      gc/linear builtin-body name split (gc_gen_*) and the annotated-local-
#      lambda distribution on the gc path. See fixtures/gc_backend_smoke_test.vibe
#      for the covered subset and the known gc-lane gaps.
echo "[selfhost-only-gate] 40h/40 wasm-gc backend smoke"
gcdir="_build/_gate_gc"
rm -rf "$gcdir"; mkdir -p "$gcdir"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/gc_backend_smoke_test.vibe" "$gcdir/smoke.wasm" main >/dev/null 2>&1
if [ ! -s "$gcdir/smoke.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: gc backend smoke did not compile under VIBE_BACKEND=gc" >&2
  cat "$gcdir/smoke.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
gc_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$gcdir/smoke.wasm" 2>&1 | tail -1)"
if [ "$gc_out" != "101520" ]; then
  echo "[selfhost-only-gate] FAIL: gc backend smoke got '$gc_out' (want 101520)" >&2
  exit 1
fi
rm -rf "$gcdir"
echo "[selfhost-only-gate] wasm-gc backend smoke ok (101520)"

# 40i. effect->WIT golden (#537): `vibe compile --wit` (adapter VIBE_EMIT_WIT=1)
#      must render fixtures/wit_gen_http.vibe byte-exactly as the committed
#      golden. Pins the WIT mapping contract (docs/effect-wit-mapping.md):
#      declared effect -> inline interface import, host-capability effect ->
#      comment marker, exported fns -> world exports, type mapping.
echo "[selfhost-only-gate] 40i/40 effect->WIT golden (#537)"
witdir="_build/_gate_wit"
rm -rf "$witdir"; mkdir -p "$witdir"
VIBE_EMIT_WIT=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/wit_gen_http.vibe" "$witdir/out.wit" main >/dev/null 2>&1
if [ ! -s "$witdir/out.wit" ]; then
  echo "[selfhost-only-gate] FAIL: VIBE_EMIT_WIT produced no output" >&2
  cat "$witdir/out.wit.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! diff -u "fixtures/wit_gen_http.golden.wit" "$witdir/out.wit" >&2; then
  echo "[selfhost-only-gate] FAIL: WIT output differs from fixtures/wit_gen_http.golden.wit. If the mapping contract changed intentionally, update the golden AND docs/effect-wit-mapping.md together." >&2
  exit 1
fi
rm -rf "$witdir"
echo "[selfhost-only-gate] effect->WIT golden ok"

# 40j. `vibe serve` handler componentization (#537): the adapter's
#      VIBE_SERVE_COMPONENT=1 step must turn the serve smoke handler into a
#      valid component exporting
#        handler: func(method, url, headers, body: string) -> string
#      via the packed-string trampoline (component_codegen). Executed on
#      wasmtime when available (the same auth check the full HTTP gate curls);
#      otherwise only the emission is asserted.
echo "[selfhost-only-gate] 40j/40 serve handler componentization (#537)"
svdir="_build/_gate_serve"
rm -rf "$svdir"; mkdir -p "$svdir"
VIBE_SERVE_COMPONENT=1 VIBE_SERVE_WIT_OUT="$svdir/handler.wit" \
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_SELFHOST_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/serve_handler_smoke.vibe" "$svdir/handler.component.wasm" main >/dev/null 2>&1
if [ ! -s "$svdir/handler.component.wasm" ]; then
  echo "[selfhost-only-gate] FAIL: VIBE_SERVE_COMPONENT produced no component" >&2
  cat "$svdir/handler.component.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
sv_magic="$(od -An -t x1 -N 4 "$svdir/handler.component.wasm" | tr -d ' \n')"
if [ "$sv_magic" != "0061736d" ]; then
  echo "[selfhost-only-gate] FAIL: serve component is not wasm (magic=$sv_magic)" >&2
  exit 1
fi
if [ ! -s "$svdir/handler.wit" ]; then
  echo "[selfhost-only-gate] FAIL: VIBE_SERVE_WIT_OUT sidecar missing" >&2
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
      echo "[selfhost-only-gate] FAIL: serve component invoke got '$sv_out' (want 200 ok:GET:/gate). The packed-string trampoline (comp_emit_component_wasm_string_handler) no longer matches the linear-backend string ABI." >&2
      exit 1
      ;;
  esac
  echo "[selfhost-only-gate] serve handler componentization ok (invoked on wasmtime)"
else
  echo "[selfhost-only-gate] serve handler componentization ok (emission only; wasmtime unavailable)"
fi
rm -rf "$svdir"

echo "[selfhost-only-gate] ok"
