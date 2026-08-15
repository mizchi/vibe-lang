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

# #1348: inline-dispatched builtins that the closure-capture analysis does not
# know about are a latent miscompile (invalid module / null-function trap).
# Static check, so it runs here with the other pre-build checks.
bash scripts/check_inline_builtin_capture.sh

# #1587: a fixture with `test` blocks that no lane runs is coverage that does
# not exist. Pure shell + grep (~2s), so it runs before the multi-minute
# selfbuild rather than after it.
bash scripts/check_fixture_execution.sh

# #1821 / Codex review on #1822: the token formatter may conservatively miss
# an ambiguous `Name {` shape, but the public writer must never replace valid
# source with a candidate that no parser accepts.
bash scripts/vibe_fmt_parse_guard_test.sh

# B2 parser binder-context routing is intentionally semantically inert, so its
# no-fallback proof is structural. Keep the large source-body assertion table
# out of the Vibe unit and run the strict scanner directly under Node.
echo "[compiler-gate] parser binder-context spine"
node --test scripts/parser_binder_context_spine.test.mjs

# Capability-only gate for the future TDRE5 immutable cache publisher. The
# builtin remains unused by compiler source until the bootstrap seed is bumped.
node scripts/test_immutable_publish_plumbing.js

echo "[compiler-gate] 1-2/3 generated compiler artifacts"
# This used to be a SYNC CHECK: regenerate the five artifacts into a temp dir
# and assert the committed copies matched byte for byte. The artifacts are no
# longer committed (see scripts/ensure_generated.sh), so the same generation
# now simply produces them -- identical work, minus a failure mode that could
# only ever mean "someone forgot to run the regen".
#
# Warm (fingerprint unchanged since the last run) this is ~1s.
bash scripts/ensure_generated.sh

# #1553: exercise the measurement protocol with a fake runner. This validates
# isolation and fail-closed parsing without running the costly real full-CLI
# memory measurement, which remains opt-in via `pkf run measure-fs-heap`.
echo "[compiler-gate] 2a/3 FS heap measurement protocol"
bash scripts/measure_fs_heap_test.sh

echo "[compiler-gate] 3/3 selfbuild seed->stage1->stage2->stage3"
# ensure_generated just wrote the flat module source from the current tree, so
# feed it to the selfbuild directly rather than paying a second generation.
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

stage2_wasm="${latest_gen}stage2.wasm"
# #1553: a real compiled-CLI smoke. The protocol test above validates the
# measurement wrapper with a fake runner; this proves the freshly self-hosted
# CLI actually selects both marked helpers and emits their required codegen
# boundaries without changing the normal production lane.
echo "[compiler-gate] 3a/3 FS heap mark lane smoke"
heapmarkdir="_build/_gate_fs_heap_marks"
rm -rf "$heapmarkdir"; mkdir -p "$heapmarkdir"
printf 'export let _start: () -> Int = () -> { 42 }\n' > "$heapmarkdir/input.vibe"
for heap_backend in rc bump; do
  heap_rc=1
  heap_boundary=codegen_rc
  if [ "$heap_backend" = bump ]; then
    heap_rc=0
    heap_boundary=codegen_bump
  fi
  heap_log="$heapmarkdir/$heap_backend.log"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    VIBE_RC="$heap_rc" VIBE_PROFILE_MEMORY_MARKS=1 \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$heapmarkdir/input.vibe" "$heapmarkdir/$heap_backend.wasm" _start \
    >/dev/null 2>"$heap_log"
  if [ ! -s "$heapmarkdir/$heap_backend.wasm" ] \
    || ! grep -q "name=start" "$heap_log" \
    || ! grep -q "name=$heap_boundary" "$heap_log"; then
    echo "[compiler-gate] FAIL: compiled CLI did not emit selected $heap_backend heap marks" >&2
    cat "$heap_log" >&2 || true
    exit 1
  fi
done
rm -rf "$heapmarkdir"
echo "[compiler-gate] FS heap mark lanes ok (rc + bump)"

# 3a. Bounded artifact-input identity observation: use this just-built stage2
# against an isolated cache. The trace wrapper is VIBE_RC=0-only and verifies a
# cold miss/warm hit, dependency invalidation, and stale-sidecar fail-closed
# behavior without changing any production cache key or format.
echo "[compiler-gate] 3a/3 artifact-input trace oracle"
VIBE_RC=0 node scripts/artifact_input_trace_oracle.mjs "$stage2_wasm"

# 3b (#1696). This gate pins VIBE_RC=0 at the top -- a deliberate cutover pin --
# which meant NOTHING here ever exercised the RC lane, and a silently-wrong entry
# result (`return 777` handing the host 1554) survived in it. The pin stays; this
# step reaches into the RC lane explicitly and asserts only that the entry's
# observable result is the SAME in both lanes, which is cheap and cannot drift
# into a table of constants.
echo "[compiler-gate] 3b/3 RC entry-result parity (#1696)"
bash scripts/test_rc_entry_result_parity.sh "$stage2_wasm"

# 3aa. Schema-4 incremental observations: this isolated clean-vs-warm bridge
# checks source/token-stream/interface/checked-env parity without incorporating
# the new observation into a production cache key, cache format, or reuse
# decision. Ordinary compiler-source fingerprint invalidation still applies.
# #1548: the oracle also publishes the shadow planner vs current compiler
# decision diff into _build/ci-artifacts/ (CI uploads it), keeping the
# conservative over-invalidation residual visible per run instead of a log line.
echo "[compiler-gate] 3aa/3 incremental invalidation observation oracle"
mkdir -p _build/ci-artifacts
VIBE_RC=0 \
  VIBE_SHADOW_DECISION_DIFF_OUT="$ROOT_DIR/_build/ci-artifacts/incremental-shadow-decision-diff.json" \
  node scripts/incremental_invalidation_oracle.mjs "$stage2_wasm"

# 3ab. #1379 opt-in metadata-only ingestion stamp: isolated equivalent cache
# histories prove observed successful-check invalidation/output equivalence and
# an exact-token same-size mutation demonstrates the trusted-stat limitation
# where the filesystem supports it, while retaining fallback coverage.
echo "[compiler-gate] 3ab/3 persistent ingestion stamp observed-check equivalence oracle"
node scripts/ingestion_stamp_oracle.mjs "$stage2_wasm"

# 3ac. Experimental production typing reuse: only the persistent value-binding
# transport environment can authorize this sidecar alias; trace interfaces are
# explicitly excluded. The isolated oracle proves cold/warm, private/public,
# output/diagnostic parity, and malformed-alias fallback.
echo "[compiler-gate] 3ac/3 experimental typing dependency-env reuse oracle"
VIBE_RC=0 node scripts/experimental_typing_env_reuse_oracle.mjs "$stage2_wasm"

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
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/trait_bound_ufcs_method.vibe "$ufcsdir/ufcs.wasm" __no_entry__ >/dev/null 2>&1
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
      "$fx" "$fxout" __no_entry__ >/dev/null 2>&1
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
    "$eqtrap_src" "$eqtrap_wasm" _start >/dev/null 2>&1
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
  "$fadir/fa.vibe" "$fadir/fa.wasm" _start >/dev/null 2>&1
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
#     and the async `for`-driven terminals) — these prelude tests are not
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
  "fixtures/rc_user_shadowed_sleep_test.vibe" "$shdir/sh.wasm" main >/dev/null 2>&1
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
if [ "$sh_out" != "25297489" ]; then
  echo "[compiler-gate] FAIL: rc_shadow_regression got '$sh_out' (want 25297489). A trap here means an RC dup/drop accounting regression touched a freed block -- see fixtures/rc_shadow_regression_test.vibe for which shapes are covered and issue #715 for the debugging methodology." >&2
  exit 1
fi
rm -rf "$shdir"
echo "[compiler-gate] RC shadow-liveness regression guard ok (25297489)"

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
    "fixtures/gc_closure_builtin_capture_test.vibe" "$gccapdir/$gccap_lane.wasm" __no_entry__ >/dev/null 2>&1
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
    "fixtures/gc_closure_builtin_alias_test.vibe" "$gcaliasdir/$gcalias_lane.wasm" __no_entry__ >/dev/null 2>&1
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
    "fixtures/gc_host_abi_declaration.vibe" "$gcabidir/$gcabi_be.wasm" main >/dev/null 2>&1
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
    "fixtures/gc_host_builtins.vibe" "$gchbdir/$gchb_be.wasm" main >/dev/null 2>&1
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
  "$gchbdir/rdclosure.vibe" "$gchbdir/rdclosure.wasm" main >/dev/null 2>&1
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
    "fixtures/gc_region_arena_free.vibe" "$gcrgdir/$gcrg_be.wasm" __no_entry__ >/dev/null 2>&1
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

# #1295: String is a packed fat pointer, so the gc EForIn lowering must
# normalize it to character codes before its shared Array iteration loop.
echo "[compiler-gate] wasm-gc String for-in"
gcstrdir="_build/_gate_gc_string_forin"
rm -rf "$gcstrdir"; mkdir -p "$gcstrdir"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/gc_for_in_string_test.vibe" "$gcstrdir/out.wasm" main >/dev/null 2>&1
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
# #1571: the fixture is an inspect() test-block suite now, compiled AS-IS --
# no `__DATA__` tail to `sed` off, no temp copy, and the expected 105 is in
# the fixture instead of in this comparison. It still goes through the
# SINGLE-FILE lane (no VIBE_FS_COMPILE), which is the property this site
# exists to hold: `inspect` is import-free precisely so migrating a fixture
# does not force one.
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_local_closure_by_value_wrapper.vibe "$gcdeaddir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_effectset_expansion.vibe "$gcselfdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
    fixtures/effect_self_discharging_callee.vibe "$sdcdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_handle_call_evidence_closure_literal.vibe "$gcclosdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/gc_backend_effect_pure_builtin_index.vibe "$gcidxdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/gc_backend_suberror_ctor.vibe "$gcsuberrdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
    fixtures/to_string_shadow_gc_test.vibe; then
  echo "[compiler-gate] FAIL: wasm-gc test-block runtime regression suite" >&2
  exit 1
fi
echo "[compiler-gate] wasm-gc test-block runtime regression suite ok"

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
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_replay_corruption.vibe "$m2dir/m2.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_row_operation_item.vibe "$a71dir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_effectset_expansion.vibe "$a71bdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_effectset_param_expansion.vibe "$a71ddir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_handle_operation_level_discharge.vibe "$a71edir/out.wasm" __no_entry__ >/dev/null 2>&1
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
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_call_evidence.vibe "$edpdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_handle_call_evidence_branch.vibe "$edpbdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_handle_call_evidence_error_mix.vibe "$edpemdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_handle_multi_effect_row_nested.vibe "$edpmedir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_handle_multi_effect_nested_handles.vibe "$edpnhdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_handle_call_evidence_let_bound.vibe "$edpletdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_handle_call_evidence_pure_helper.vibe "$edppurdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_handle_call_evidence_struct_field.vibe "$edpdotdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_handle_call_evidence_closure_literal.vibe "$edpclodir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_handle_call_evidence_effectset_alias.vibe "$edpesdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_handle_call_evidence_qualified_op.vibe "$edpqodir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_handle_call_evidence_row_variable_tail.vibe "$edprvdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_handle_call_evidence_local_closure_capture_free.vibe "$edplccfdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_local_closure_capture_conversion.vibe "$lcccdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_local_closure_by_value_wrapper.vibe "$lcbvwdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_local_closure_wrapper_referenced_as_value.vibe "$lcwrvdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/local_closure_wrapper_wrong_arity_not_inlined.vibe "$lcwadir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_inline_lambda_literal_hof_arg.vibe "$illhadir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_inline_lambda_literal_labeled_arg.vibe "$illladir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/dtpw_wrapper_shadowed_by_parameter.vibe "$dtpwsdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/evidence_dict_needing_shadowed_by_local.vibe "$edpsdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_local_closure_by_value_hof_general.vibe "$edpgdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_local_closure_by_value_hof_escaping.vibe "$edpedir/out.wasm" __no_entry__ >/dev/null 2>&1
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
# workaround avoided it (@vibex/concurrent Nursery::spawn was the canary).
# Now fixed; pin BOTH RC lanes -- the corruption was RC bookkeeping, so the
# bump lane alone cannot see a regression.
cbvsdir="_build/_gate_closure_by_value_store"
rm -rf "$cbvsdir"; mkdir -p "$cbvsdir"
for cbvs_rc in 1 0; do
  VIBE_RC="$cbvs_rc" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    fixtures/closure_by_value_store_test.vibe "$cbvsdir/out.wasm" __no_entry__ >/dev/null 2>&1
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
  fixtures/effect_local_closure_handle_owner_param.vibe "$edphdir/out.wasm" __no_entry__ >/dev/null 2>&1
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

# 41. ADR-0069 Phase 1: `fn main {}` sugar + entry/top-level hardening.
#     (a) ok_fnmain: the paren-less/annotation-less `fn main with Stdout { .. }`
#         special form compiles as `let main: () -> Unit with Stdout` and the
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
fn main with Stdout {
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

# 42. #830 / #1281: `let record { .. } = <expr>` (record-pattern
# destructuring, #760) worked as a *local* `let` but used to hit a raw
# "expected = but got {" at the top level, and was then rejected with a
# located error. #1281 implements the multi-statement expansion it was
# waiting for, so the top-level form now COMPILES and RUNS: the record value
# lands in a hidden binding and each field name becomes its own positional
# `__rec_field` projection. Field patterns are positional (that is how the
# block-level desugar reads them too), so `record { name: n, ver: v }` binds
# slot 0 to `n` and slot 1 to `v`.
echo "[compiler-gate] 42/42 top-level record-pattern let (#830 / #1281)"
g830dir="_build/_gate_830"
rm -rf "$g830dir"; mkdir -p "$g830dir"
cat > "$g830dir/toplevel_record_destr.vibe" <<'EOF'
let r = record { name: "vibe", ver: 7 }
let record { name: n, ver: v } = r
export let _start: () -> Int = () -> { String::length(n) * 100 + v }
EOF
rm -f "$g830dir/toplevel_record_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g830dir/toplevel_record_destr.vibe" "$g830dir/toplevel_record_destr.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$g830dir/toplevel_record_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level 'let record { .. } = ..' did not compile (#1281)" >&2
  cat "$g830dir/toplevel_record_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g830_top_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g830dir/toplevel_record_destr.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g830_top_out" != "407" ]; then
  echo "[compiler-gate] FAIL: top-level record-pattern destructure output '$g830_top_out' (want 407, #1281)" >&2
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
echo "[compiler-gate] top-level record-pattern let (#830 / #1281) ok"

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

# 44. #1281 (was #859): top-level irrefutable pattern `let` -- tuple
#     `let (a, b) = pair`, named-struct `let Name::{ x, y } = v`, and
#     anonymous-record `let record { a, b } = r`. These used to parse and
#     type-check but had no codegen case (a raw "undefined variable" crash),
#     so they were rejected outright; they are now expanded by the parser
#     into a hidden binding for the value plus one projection binding per
#     name. Refutable patterns stay rejected with a clear, LOCATED error.
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

echo "[compiler-gate] 44/44 top-level irrefutable pattern let (#1281)"
g859dir="_build/_gate_859"
rm -rf "$g859dir"; mkdir -p "$g859dir"
# #1281 (was #859): a top-level irrefutable pattern `let` now compiles and
# runs. The parser expands it into a hidden binding holding the value plus one
# projection binding per name, so codegen still needs no top-level `SLetPat`
# case -- and the value is evaluated exactly ONCE (pinned below), which is the
# property a naive "repeat the RHS per name" expansion would break.
cat > "$g859dir/toplevel_tuple_destr.vibe" <<'EOF'
let (a, b) = (10, 32)
export let _start: () -> Int = () -> { a + b }
EOF
rm -f "$g859dir/toplevel_tuple_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g859dir/toplevel_tuple_destr.vibe" "$g859dir/toplevel_tuple_destr.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$g859dir/toplevel_tuple_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level 'let (a, b) = ..' did not compile (#1281)" >&2
  cat "$g859dir/toplevel_tuple_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g859_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g859dir/toplevel_tuple_destr.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g859_out" != "42" ]; then
  echo "[compiler-gate] FAIL: top-level tuple-pattern destructure output '$g859_out' (want 42, #1281)" >&2
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
if [ ! -s "$g859dir/toplevel_struct_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level 'let Name::{ .. } = ..' did not compile (#1281)" >&2
  cat "$g859dir/toplevel_struct_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g859_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g859dir/toplevel_struct_destr.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g859_out" != "42" ]; then
  echo "[compiler-gate] FAIL: top-level struct-pattern destructure output '$g859_out' (want 42, #1281)" >&2
  exit 1
fi
cat > "$g859dir/toplevel_record_destr.vibe" <<'EOF'
let record { a, b } = record { a: 10, b: 32 }
export let _start: () -> Int = () -> { a + b }
EOF
rm -f "$g859dir/toplevel_record_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g859dir/toplevel_record_destr.vibe" "$g859dir/toplevel_record_destr.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$g859dir/toplevel_record_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level 'let record { .. } = ..' did not compile (#1281)" >&2
  cat "$g859dir/toplevel_record_destr.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g859_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g859dir/toplevel_record_destr.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g859_out" != "42" ]; then
  echo "[compiler-gate] FAIL: top-level record-pattern destructure output '$g859_out' (want 42, #1281)" >&2
  exit 1
fi
# The value is evaluated ONCE, however many names the pattern binds: `mk`
# appends to a log, so a re-evaluated RHS shows up as a second entry (242).
cat > "$g859dir/toplevel_destr_once.vibe" <<'EOF'
let log = []

fn mk() -> (Int, Int) {
  Array::push(log, 1)
  (10, 32)
}

let (a, b) = mk()

export let _start: () -> Int = () -> { a + b + Array::length(log) * 100 }
EOF
rm -f "$g859dir/toplevel_destr_once.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g859dir/toplevel_destr_once.vibe" "$g859dir/toplevel_destr_once.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$g859dir/toplevel_destr_once.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level destructure of a call did not compile (#1281)" >&2
  cat "$g859dir/toplevel_destr_once.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g859_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$g859dir/toplevel_destr_once.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$g859_out" != "142" ]; then
  echo "[compiler-gate] FAIL: top-level pattern let evaluated its value $((g859_out / 100)) times (want 1, output '$g859_out' vs 142, #1281)" >&2
  exit 1
fi
# A REFUTABLE pattern is still rejected -- it can fail to match, and a
# top-level binding has nowhere to fail to.
cat > "$g859dir/toplevel_refutable_destr.vibe" <<'EOF'
let Some(a) = Some(42)
export let _start: () -> Int = () -> { a }
EOF
rm -f "$g859dir/toplevel_refutable_destr.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$g859dir/toplevel_refutable_destr.vibe" "$g859dir/toplevel_refutable_destr.wasm" _start >/dev/null 2>&1 || true
if [ -s "$g859dir/toplevel_refutable_destr.wasm" ]; then
  echo "[compiler-gate] FAIL: top-level 'let Some(a) = ..' compiled (refutable, should be rejected, #1281)" >&2
  exit 1
fi
if ! grep -q "requires an irrefutable pattern" "$g859dir/toplevel_refutable_destr.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: refutable top-level pattern let diag missing the clear #1281 message" >&2
  cat "$g859dir/toplevel_refutable_destr.wasm.diag" 2>/dev/null >&2 || true
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
echo "[compiler-gate] top-level irrefutable pattern let (#1281) ok"

# 45/45 (#897 Phase 4, ADR-0070): every directory in the repo must have
# migrated off the old index.vibei/bare-index.vibe facade to a proper
# index.vpkg contract. This is the CI-required half of the diagnostic
# implemented in loader/loader.vibe's find_missing_vpkg_dirs (Phase 1) --
# a passive `vibe check` command is easy to forget to run by hand, so once
# Phase 3 finished migrating all 76 directories this became a required gate
# to prevent a future PR from silently reintroducing a plain index.vibe dir.
# 44b. #944 (ADR-0073 stage B): checked-Error row discipline is ON by
#      default -- a row-less caller of a `with Error` function is
#      rejected with the row-mismatch diagnostic; VIBE_CHECK_ERROR_ROW=0
#      is the opt-out escape hatch that restores the old exemption; a
#      caller that discharges via `handle .. with Error` compiles and
#      runs under the default.
echo "[compiler-gate] 44b/44 checked-Error row discipline default-on (#944 stage B)"
g944dir="_build/_gate_944"
rm -rf "$g944dir"; mkdir -p "$g944dir"
cat > "$g944dir/leak.vibe" <<'EOF'
fn boom(x: Int) -> Int with Exception {
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
fn boom(x: Int) -> Int with Exception {
  if x == 0 {
    throw("zero")
  }
  x
}

export let main = () -> Int {
  handle {
    boom(1)
  } with Exception {
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
if ! grep -q "missing { Exception }" "$g944dir/leak_on.wasm.diag" 2>/dev/null; then
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
#      `with Error` whose Throw escapes must produce the stderr
#      diagnostic and evaluate to 1 (unsuccessful outcome) instead of
#      leaking a raw WebAssembly.Exception out of the entry.
echo "[compiler-gate] 44c/44 entry-boundary Error handler (#944 stage C)"
g944cdir="_build/_gate_944c"
rm -rf "$g944cdir"; mkdir -p "$g944cdir"
# #1571: the entry-boundary behaviour (stderr diagnostic + entry value) is
# asserted below, so the fixture carries no `__DATA__` tail any more and is
# compiled AS-IS -- no `sed` strip, no temp copy.
rm -f "$g944cdir/out.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/entry_error_boundary.vibe "$g944cdir/out.wasm" main >/dev/null 2>&1 || true
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
# #1372 review (Codex P1): the same boundary arm also catches every TYPED
# `Exception[E]` (ADR-0085's runtime has a single abortive tag and no kind
# discriminator, and the erased `Error` spelling is compatible with every
# kind). Writing that enum payload straight to `Stderr::write_stream`
# decoded the pointer as a packed `(ptr<<32)|len` string and printed
# unrelated memory.
#
# #1374: the throw site now records the payload's static type name, so the
# boundary names the KIND rather than printing a decimal that reads like a
# message. Three distinct outputs are pinned below, and each one fails
# differently if the channel breaks:
#   - typed enum payload -> `vibe: uncaught error: <Boom>`. A regression to
#     the raw payload prints memory; a regression to #1375's blind
#     `__to_string` prints a decimal. Neither matches.
#   - String payload -> `vibe: uncaught error: plain boom`, byte for byte
#     what it printed before either fix. This is the additivity check: the
#     overwhelmingly common case must not have moved.
rm -f "$g944cdir/typed.wasm" "$g944cdir/typed_stderr.txt"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_entry_boundary_typed_payload.vibe "$g944cdir/typed.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$g944cdir/typed.wasm" ]; then
  echo "[compiler-gate] FAIL: err_entry_boundary_typed_payload.vibe did not compile (#1372 review)" >&2
  cat "$g944cdir/typed.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g944c_typed_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$g944cdir/typed.wasm" 2>"$g944cdir/typed_stderr.txt" | tail -1)"
if [ "$g944c_typed_out" != "1" ]; then
  echo "[compiler-gate] FAIL: typed-payload entry boundary got '$g944c_typed_out' (want 1)" >&2
  exit 1
fi
if ! grep -qxF 'vibe: uncaught error: <Boom>' "$g944cdir/typed_stderr.txt"; then
  echo "[compiler-gate] FAIL: a TYPED exception escaping the entry did not name its kind -- the boundary is reading the payload as a string, or the #1374 kind side channel is not reaching it" >&2
  head -c 400 "$g944cdir/typed_stderr.txt" >&2 || true
  exit 1
fi
# #1374 additivity: a String payload must print verbatim, exactly as it did
# before the kind channel existed.
rm -f "$g944cdir/strp.wasm" "$g944cdir/strp_stderr.txt"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_entry_boundary_string_payload.vibe "$g944cdir/strp.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$g944cdir/strp.wasm" ]; then
  echo "[compiler-gate] FAIL: err_entry_boundary_string_payload.vibe did not compile (#1374)" >&2
  cat "$g944cdir/strp.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
g944c_strp_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$g944cdir/strp.wasm" 2>"$g944cdir/strp_stderr.txt" | tail -1)"
if [ "$g944c_strp_out" != "1" ]; then
  echo "[compiler-gate] FAIL: String-payload entry boundary got '$g944c_strp_out' (want 1)" >&2
  exit 1
fi
if ! grep -qxF 'vibe: uncaught error: plain boom' "$g944cdir/strp_stderr.txt"; then
  echo "[compiler-gate] FAIL: a String exception escaping the entry no longer prints verbatim -- #1374's kind dispatch changed the common case (want 'vibe: uncaught error: plain boom')" >&2
  head -c 400 "$g944cdir/strp_stderr.txt" >&2 || true
  exit 1
fi
rm -rf "$g944cdir"
echo "[compiler-gate] entry-boundary Error handler ok (#944 stage C, typed payload #1372, kind channel #1374)"

# 44d. #1087: a NON-tail `throw` inline in a `handle .. with Error` body
#      must abort the body -- the arm's value (1) is the handle's result,
#      not the body's continuation value (41). The ADR-0076 Phase 2 inliner
#      used to splice the arm in place of the perform (resumptive
#      semantics), running the arm but discarding its value; Error arms are
#      now excluded from that pass (idp_arms_discharge_error).
echo "[compiler-gate] 44d/44 with-Error non-tail throw abort (#1087)"
g1087dir="_build/_gate_1087"
rm -rf "$g1087dir"; mkdir -p "$g1087dir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. Entry is `__no_entry__`, which synthesizes
# the test-block runner; a mismatch prints inspect's own actual/expected
# (1 vs 41) from inside the run and fails it.
rm -f "$g1087dir/out.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_handle_error_nontail.vibe "$g1087dir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$g1087dir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_handle_error_nontail.vibe did not compile (#1087)" >&2
  cat "$g1087dir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! g1087_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$g1087dir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_handle_error_nontail want 1, NOT 41 -- a non-tail throw in a with-Error handle body ran the body's continuation instead of aborting to the arm's value (#1087; check idp_arms_discharge_error in inline_direct_perform.vibe)" >&2
  echo "$g1087_out" >&2
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
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/send_bound_structural.vibe "$senddir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$senddir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: send_bound_structural.vibe did not compile -- structural Send acceptance regressed" >&2
  cat "$senddir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! send_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$senddir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: send_bound_structural got '$send_pos_out' (want 42)" >&2
  echo "$send_pos_out" >&2
  exit 1
fi
# #1571: the expectation for each rejection is `$needle` right here, so these
# fixtures no longer carry an unread `__DATA__` error_contains copy and are
# compiled AS-IS -- no `sed` strip, no temp copy.
send_check_reject() {
  local fixture="$1" needle="$2" tag="$3"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/$fixture" "$senddir/$tag.wasm" main >/dev/null 2>&1 || true
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
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/rc_branch_loop_mixed_consume_test.vibe "$rc1085dir/src.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$rc1085dir/src.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_branch_loop_mixed_consume fixture did not compile" >&2
  cat "$rc1085dir/src.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! rc1085_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$rc1085dir/src.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: rc_branch_loop_mixed_consume got '$rc1085_out' (want 123123) -- #1085 over-drop regressed" >&2
  echo "$rc1085_out" >&2
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
# #1536 (a): a row-free closure param whose every by-name call site
# passes a provably suspend-inert literal is see-through (plain call in
# the clone; want 5), including the delegation shape (pick_any forwards
# its own param into pick's slot; want 5). One site passing a PERFORMING
# literal taints the slot and the rejection stays.
scps_run_expect "effect_closure_param_inert.vibe" "5" "inertparam"
scps_run_expect "effect_closure_param_inert_transitive.vibe" "5" "inertdeleg"
# #1536 (a), eager Stream slice: Stream::next must retarget before suspend
# CPS evaluates a resume-value Async handler. The fixture also pins its
# Array-backed ready Future[Option[T]] result and one evaluation (Some(41)+1).
scps_run_expect "effect_stream_next_suspend_retarget.vibe" "42" "streamnext"
# Fresh synthetic target and direct [ready, payload] cell: a user
# `__sn_next` must not capture the retarget and shadowed Future::ready must
# not change empty-stream layout (None fallback = 7).
scps_run_expect "effect_stream_next_retarget_hygiene.vibe" "7" "streamnexthygiene"
# #1723: a local pure closure shadows a top-level function whose callback
# parameter carries the suspend effect. The prepass must leave the literal on
# the plain convention; Done-wrapping it returns a step pointer instead of 8.
scps_run_expect "effect_scps_param_shadow_test.vibe" "8" "localparamshadow"
scps_run_expect "effect_scps_top_level_alias_test.vibe" "7" "toplevelalias"
# #1723 / #1803 P2 follow-up: effect_row_local_shadow_test.vibe's "unshadowed
# effectful call" control sits inside `handle`, where the missing-effect
# diagnostic is suppressed (in_handle), so it cannot pin "still charged when
# NOT shadowed" by itself. This is the un-suppressed half: with no local
# shadow and no handler, the row lands on the caller and a row-free caller is
# refused. The accepted twin is test 1 of effect_row_local_shadow_test.vibe.
scps_check_reject "err_effect_unshadowed_row_charged.vibe" "effect row mismatch for 'caller': missing { Ask }" "unshadowedrow"
# #1536 (a) v3 (let-floating): an async-iterator `for` in statement position
# desugars to a let-chain in SEQUENCE HEAD position; scps_split_tail floats
# it onto the continuation spine. Two sequential loops pin repeated floats
# of the same __iter_* spellings.
scps_run_expect "effect_for_await_suspend.vibe" "20" "forawaitsusp"
# Shadow pin for the float's alpha-rename: an inner block binder shadows an
# outer name the sequence TAIL references -- capture would print 8/wrong,
# not 1105. Covers both the handle-body spine and a needing fn's clone.
scps_run_expect "effect_seq_head_block_suspend.vibe" "1105" "seqheadshadow"
# Codex P1 on #1607: user code literally spelling the generated
# `__scps_seq<site>_<x>` target must not be captured -- the freshness
# probe bumps past any occurrence in the floated continuation or the
# tail. Control-measured: with the probe disabled this prints 1015.
scps_run_expect "effect_seq_head_reserved_name_collision.vibe" "3011" "seqheadfresh"
# #1536 (a) v4: suspendable if/match heads distribute the original sequence
# tail into each selected branch. The runtime pins one evaluation of the
# condition/scrutinee and capture-safe branch/pattern bindings.
scps_run_expect "effect_seq_head_if_suspend.vibe" "41100" "seqheadif"
scps_run_expect "effect_seq_head_match_suspend.vibe" "3200" "seqheadmatch"
# #1536 direct selection input: a recognized direct perform is first named on
# the CPS spine, evaluates once, then selects a branch/arm whose continuation
# runs once.
scps_run_expect "effect_seq_head_if_condition_suspend.vibe" "3210" "seqheadifcond"
scps_run_expect "effect_seq_head_match_scrutinee_suspend.vibe" "3210" "seqheadmatchscrut"
scps_run_expect "effect_tail_selection_input_suspend.vibe" "3311" "tailselectinput"
# #1536 direct plain-assignment RHS: name the resumed value on the CPS spine,
# then assign and continue once.
scps_run_expect "effect_assignment_rhs_suspend.vibe" "41112" "assignrhs"
# #1536 direct while condition: resume into the existing recursive loop
# closure once per condition check.
scps_run_expect "effect_while_condition_suspend.vibe" "3217" "whilecond"
# #1536 (a) v8: COMPOUND inputs -- an operand, a call argument, a constructor
# payload, a comparison in a condition. The suspension is named on the spine and
# everything the original evaluated before it is named in order ahead of it, so
# these pin evaluation order, not just acceptance (a handler that mutates shared
# state between perform and resume would show up in the numbers). The `while`
# case additionally pins that the chain stayed inside the loop closure.
# New positive regressions own their expectations as inspect snapshots. Run
# them unchanged with the freshly built stage2 that implements this lowering.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_assignment_rhs_compound_suspend.vibe \
  fixtures/effect_seq_head_if_condition_compound_suspend.vibe \
  fixtures/effect_seq_head_match_compound_scrutinee_suspend.vibe \
  fixtures/effect_compound_call_arg_suspend.vibe \
  fixtures/effect_while_condition_compound_suspend.vibe \
  fixtures/effect_assignment_op_rhs_suspend.vibe \
  fixtures/effect_assignment_op_name_collision_test.vibe \
  fixtures/effect_compound_anf_name_collision_test.vibe \
  fixtures/effect_compound_closure_literal_suspend_test.vibe
# #1536 tail-only short-circuit: the whole boolean expression lowers to EIf,
# preserving bypass and selected-RHS suspension. The snapshot pins four paths,
# operation order, handler visits, resumed source-continuation events, and the
# handler regaining control afterward; exact event counts pin exact-once flow.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_tail_shortcircuit_suspend.vibe \
  fixtures/effect_let_shortcircuit_suspend.vibe
# #1536 selection-valued bindings: an `if` / `match` that IS the whole bound
# value distributes the binding and the continuation into its branches. The
# snapshots pin exact-once continuation runs, that the non-suspending branch is
# still selected normally, that a `let mut` cell survives the distribution, and
# that an arm binder cannot capture a name the moved continuation reads.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_let_selection_suspend_test.vibe \
  fixtures/effect_let_selection_match_capture_test.vibe \
  fixtures/effect_letmut_selection_suspend_test.vibe
# #1536 block-valued bindings: `let x = { stmt..; value }` moves the binding
# inward past the statement prefix, so the ordinary spine picks the prefix up.
# The snapshot pins the prefix running once per binding and that a `let` inside
# the block cannot capture the continuation's outer name when it floats.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_let_block_value_suspend_test.vibe
# #1536 assignment mirror: `x = <if/match>` / `x = { stmt..; value }`. A boxed
# target is reshaped before cellification, a target bound outside the spine on
# the continuation spine; the two snapshots pin both arms agreeing.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_assign_selection_suspend_test.vibe \
  fixtures/effect_assign_outer_selection_suspend_test.vibe
# #1536 selection nested in a compound: the linearization names the selection
# WHOLE instead of walking into a branch, so the binding distribution lowers it.
# The snapshot's `order` digits pin that nothing moved across the suspension.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_compound_selection_suspend_test.vibe
# #1536 non-tail short-circuit: named whole too, but only after asking the
# immutable-let lowering whether it will take it (naming a form that lowering
# declines would not converge). The snapshots pin bypass, compound RHS
# terminals (comparison / nested short-circuit / call argument), and order.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_compound_shortcircuit_suspend_test.vibe \
  fixtures/effect_shortcircuit_compound_rhs_test.vibe
# #1536: loop bodies carrying `break` / `continue`. The transfers become calls
# on the CPS spine (exit continuation / loop self-call), dead statements behind
# a transfer drop, and a nested loop keeps its own transfers. `return` in the
# body stays fail-closed.
# New positive regressions use source-owned inspect snapshots and run as-is;
# do not add another __DATA__ + shell-duplicated expectation to this legacy
# helper. VIBE_TEST_CLI_WASM pins the freshly built stage2 that knows this
# lowering while the checked-in seed catches up through normal bootstrap.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_loop_form_suspend_test.vibe \
  fixtures/effect_while_break_continue_suspend_test.vibe \
  fixtures/effect_loop_nested_break_suspend_test.vibe \
  fixtures/effect_resume_store_loop_break_test.vibe \
  fixtures/effect_loop_ctl_name_collision_test.vibe
# #1536 boundary: generic linearization still walks only positions that every
# execution reaching a compound also reaches, so it never names a suspension
# INSIDE a branch or inside a short-circuit RHS. Both are instead named WHOLE
# (the snapshots above pin that, bypass included). A selected RHS that returns
# stays closed -- now via the general rule below, since a `return` anywhere on
# a split body's spine is refused before the split runs.
scps_check_reject "err_effect_let_shortcircuit_return_suspend.vibe" "cannot contain a \`return\`" "letshortcircuitreturn"
# #1536: a `return` on a split body's own spine is hoisted to the tail it
# already denotes (in a needing fn's clone / a closure literal, `return v` IS
# that computation's value). It used to be left in place, compile clean, and
# trap at runtime on the path that took it. The snapshots pin all four shapes
# and the capture-safe match-arm distribution; a `return` this hoist cannot
# reach -- inside a loop -- is still refused (err_effect_loop_return_suspend).
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_return_in_split_body_test.vibe \
  fixtures/effect_return_match_arm_split_test.vibe \
  fixtures/effect_return_in_loop_test.vibe
# #1536 P0: a transfer with a STATEMENT in front of it, after a resume. The
# transfer test used to see only a BARE break/continue, so `if d { acc = v;
# break }` was not a transfer, the continuation was not dropped, and execution
# fell through the rewritten call and kept looping -- silently answering
# differently than the same loop without a suspension. `scan` is 700 with and
# without effects; it used to be 800 here.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_transfer_after_resume_test.vibe
# `break` leaves only the INNERMOST loop, so each level records-and-breaks and
# is followed by a guard that carries the exit outward one level at a time.
# The snapshot covers two and three levels deep, and a return never taken.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_return_nested_loop_test.vibe
# #1536: `return` in a HANDLE body means "leave the enclosing function", not
# "the handle's value", so it is captured in a cell declared outside the handle
# and returned after it. The snapshot pins taken / not-taken / from inside a
# suspending loop nested in the handle body.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_return_in_handle_body_test.vibe
# #1536: `for x in xs` over a PROVED array becomes the indexed while form, which
# the split already handles. The proof is syntactic (a parameter annotated
# Array[..], or a let bound to an array literal) -- codegen decides String-ness
# at run time (#807), so an unproved iterand must not be rewritten. The snapshot
# pins break / continue / index advance / length re-read, not just acceptance.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_array_for_suspend_test.vibe
# The same loop over a PROVED String indexes the string directly, using the
# builtins codegen itself uses to materialize one. An UNPROVED iterand is still
# never rewritten -- that is what keeps a runtime String out of the array form.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_string_for_suspend_test.vibe
# #1536: two more self-proving iterands -- a LITERAL (`for x in [1, 2]` /
# `for c in "ab"`), and a name bound to a call whose callee declares an
# Array[..] / String return. The snapshot pins CHAR CODES for the string forms,
# so it fails if either lowering picks the other kind's indexing.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_for_proved_iterand_suspend_test.vibe
# #1536: and a BUILTIN callee proves it via the registry row, which is where a
# builtin's signature has lived all along. `Array::concat` also joins the
# hand-audited pure-builtin list -- without it the body was refused naming the
# concat, not the loop.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_for_builtin_iterand_suspend_test.vibe
# #1714 P0: the callee-return proof reads the module's TOP-LEVEL statements, so
# a local binding spelling the same name made it answer about the wrong
# function -- lowering a String iterand to the indexed ARRAY form, which
# compiled clean and answered 0 instead of 215. Refused now.
scps_check_reject "err_effect_for_shadowed_callee.vibe" "is not directly on the handle body" "forshadow"
# #1718 P0: the same root in the ELIGIBILITY check. A local `let pick = maker()`
# shadowing a top-level `fn pick() -> Int` (empty row) made scps_fn_row_of admit
# a call to a PERFORMING value -- compiled clean and answered 2285 instead of
# 110. Rename the local and the same program is (correctly) refused as an opaque
# callee; that is now the answer for the shadowed spelling too.
scps_check_reject "err_effect_shadowed_toplevel_callee.vibe" "cannot see through" "shadowtop"
# #1720 follow-up: authorization is lexical, not an additive set. Every newer
# binder masks an older inert/CPS proof, and source-spelled generated prefixes
# remain opaque. Pin the exact culprit so diagnostics and eligibility cannot
# drift apart again. The loop fixture exercises the parser-lowered local form;
# the plain closure-parameter convention also remains pinned by #1707 below.
scps_check_reject "err_effect_inert_local_reshadow.vibe" "here: the call to 'pick'" "inertreshadow"
scps_check_reject "err_effect_cps_local_reshadow.vibe" "here: the call to 'pick'" "cpsreshadow"
scps_check_reject "err_effect_reserved_local_opaque.vibe" "here: the call to '__scps_user'" "reservedopaque"
scps_check_reject "err_effect_enclosing_param_shadow.vibe" "here: the call to 'pick'" "paramshadow"
scps_check_reject "err_effect_clone_param_shadow.vibe" "here: the call to 'pick'" "cloneparamshadow"
scps_check_reject "err_effect_match_binder_reshadow.vibe" "here: the call to 'pick'" "matchreshadow"
scps_check_reject "err_effect_for_binder_reshadow.vibe" "here: the call to 'pick'" "forreshadow"
scps_check_reject "err_effect_loop_binder_reshadow.vibe" "here: the call to 'pick'" "loopreshadow"
# #1721 P0: the third instance, in the REWRITE rather than the check. A local
# shadowing a needing fn had its call retargeted to that fn's CPS clone, so it
# performed instead of returning the local closure's value -- 1511 instead of
# 1507. The fixture's two halves (shadowed / renamed) must agree.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_shadowed_needing_local_test.vibe
# #1536: a `with e` callee is admitted when its declared parameters mention no
# function type anywhere -- there is then no argument able to instantiate the
# row variable, so the call cannot perform the handled effect. A callee that
# does take a function stays refused; that is what keeps this sound.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_rowvar_first_order_call_test.vibe
scps_check_reject "err_effect_rowvar_hof_call.vibe" "cannot see through" "rowvarhof"
# #1536 boundary, measured 2026-08-14. Both of these are narrower than the
# residual list implied, so they are pinned rather than described: a closure may
# capture a scalar param, an outer scalar let, or a function param (all compile)
# -- only capturing another LOCAL CLOSURE is refused. And a `for` iterand is
# lowered only when proved; an unannotated callee proves nothing.
# #1536: capturing a PROVABLY INERT local closure literal is admitted (we can
# see what the name holds); capturing a PERFORMING one stays refused, which is
# what keeps that sound -- it is the #1707 shape.
VIBE_TEST_CLI_WASM="$stage2_wasm" bash scripts/vibe_test.sh \
  fixtures/effect_capture_inert_local_closure_test.vibe
scps_check_reject "err_effect_capture_performing_closure.vibe" "hand the step object back as the value" "captureperforming"
# #1707 P0: a step-split literal may only land in a parameter whose row carries
# the effect. Passed to a plain-convention parameter it used to compile and
# silently return the step object as the value (5 -> 177, 15 -> 301).
scps_check_reject "err_effect_step_literal_plain_param.vibe" "hand the step object back as the value" "stepliteralplainparam"
scps_check_reject "err_effect_for_unproved_iterand.vibe" "let/seq/tail/branch-tail spine" "forunproved"
# A nested handle inside a compound is refused EARLIER, by the pre-existing
# see-through rule -- the linearization neither widens nor narrows it. Gated on
# THAT diagnostic, so the fixture cannot silently start passing for the other
# reason if the boundary ever moves.
scps_check_reject "err_effect_compound_nested_handle_suspend.vibe" "cannot see through" "compoundnestedhandle"
scps_check_reject "err_resume_non_tail.vibe" "must be the last expression of the handler arm" "nontail"
scps_check_reject "err_effect_resume_store_ineligible.vibe" "cannot see through" "inelig"
scps_check_reject "err_effect_closure_param_taint.vibe" "cannot see through" "inerttaint"
# Codex review on #1602: a candidate literal that CAPTURES a performing
# closure and launders it into an eff-free helper must stay rejected --
# only names bound within the literal are trusted by the inert scan.
scps_check_reject "err_effect_closure_param_capture_launder.vibe" "cannot see through" "inertlaunder"
# #1536: the former `break`-in-a-suspending-loop rejection now lives in the
# inspect snapshot suite above. Its arm stores `resume` and never resumes, so
# the first perform escapes with its value; the loop shape is what changed.
# #1261: an unannotated performing closure is row-backfilled by
# dlh_hoist_expr and so gets the evidence dict prepended; handing that value
# to a row-FREE fn-typed slot used to compile clean and trap at runtime with
# a wasm signature mismatch. Reject it, and keep the annotated form working.
scps_check_reject "err_effect_needing_value_escape.vibe" "passed as a VALUE into a slot whose type does not carry that row" "valesc"
scps_run_expect "effect_needing_value_annotated.vibe" "42" "valann"
scps_run_expect "effect_needing_value_escape_wrapped.vibe" "42" "valwrap"
# #1380: the row-slot literal whose body CALLS a needing fn (rather than
# performing inline). The type-directed sweep and the handle-site rewrite
# each prepended an evidence dict to that call, so the callee got one
# argument too many -- clean compile, module failed to instantiate.
# The capture variant additionally blocks the hoist-to-top-level escape
# hatch and mixes a perform with the call in one body.
scps_run_expect "effect_needing_call_in_row_slot.vibe" "142" "callslot"
scps_run_expect "effect_needing_call_in_row_slot_capture.vibe" "188" "callslotcap"
# #1385: the same literal reached through an IIFE. dlh_hoist_expr only named
# an IIFE'd literal when its body performed DIRECTLY, so one that discharges
# the row by CALLING stayed anonymous -- and an opaque callee sinks the whole
# effect's eligibility. The wrapper lane never types an IIFE: trivial-wrapper
# inlining (#1070) makes one out of `apply0(lit)`, which is why only the
# ZERO-argument slot was affected.
scps_run_expect "effect_iife_needing_call.vibe" "142" "iifecall"
scps_run_expect "effect_trivial_wrapper_needing_call.vibe" "142" "iifewrap"
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
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/rc_match_payload_closure_capture_test.vibe "$rc1097dir/src.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$rc1097dir/src.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_match_payload_closure_capture fixture did not compile" >&2
  cat "$rc1097dir/src.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! rc1097_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$rc1097dir/src.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: rc_match_payload_closure_capture got '$rc1097_out' (want 38013) -- #1097 regressed" >&2
  echo "$rc1097_out" >&2
  exit 1
fi
rm -rf "$rc1097dir"
echo "[compiler-gate] RC match-payload closure capture (#1097) ok"

# #1272: a function returning an ELEMENT of a container it owns LOCALLY --
#        `Array::get` hands back an interior reference, so the local must be
#        retained-then-dropped, not dropped outright. Only `.field` used to
#        count as an escaping projection, so both shapes in the fixture
#        returned pointers into freed memory (silent until a later allocation
#        reused the cell: the two shapes summed to 12 and 207, not 45 and 300).
rc1272dir="_build/_gate_rc_local_elem_escape"
rm -rf "$rc1272dir"; mkdir -p "$rc1272dir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/rc_local_container_element_escape.vibe "$rc1272dir/src.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$rc1272dir/src.wasm" ]; then
  echo "[compiler-gate] FAIL: rc_local_container_element_escape fixture did not compile" >&2
  cat "$rc1272dir/src.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! rc1272_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$rc1272dir/src.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: rc_local_container_element_escape got '$rc1272_out' (want 345) -- #1272 regressed" >&2
  echo "$rc1272_out" >&2
  exit 1
fi
rm -rf "$rc1272dir"
echo "[compiler-gate] RC local-container element escape (#1272) ok"

# #1230: `await` hoisted onto the AST spine (await_poll_pass) so a PENDING
#        future can raise a perform the effect passes still see. The fixture
#        puts awaits in let-value, match-scrutinee and nested-operand
#        positions, more than one of each -- splicing the expansion in place
#        instead of hoisting put an `ELet` in a `let` VALUE, which no source
#        program can write and which sent the compiler itself into unbounded
#        recursion once two appeared in one function.
awmdir="_build/_gate_await_multi"
rm -rf "$awmdir"; mkdir -p "$awmdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/async_await_multi.vibe "$awmdir/src.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$awmdir/src.wasm" ]; then
  echo "[compiler-gate] FAIL: async_await_multi fixture did not compile" >&2
  cat "$awmdir/src.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! awm_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$awmdir/src.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: async_await_multi got '$awm_out' (want 50) -- #1230 await hoist regressed" >&2
  echo "$awm_out" >&2
  exit 1
fi
rm -rf "$awmdir"
echo "[compiler-gate] multi-position await hoist (#1230) ok"

# #1230: the producer half -- Future::pending() / Future::resolve(f, v). Both
#        futures are resolved before they are awaited, so this pins the
#        representation and the two builtins rather than the scheduling (a
#        still-pending await needs a driver parking the continuation).
fpdir="_build/_gate_future_pending"
rm -rf "$fpdir"; mkdir -p "$fpdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/async_future_pending.vibe "$fpdir/src.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$fpdir/src.wasm" ]; then
  echo "[compiler-gate] FAIL: async_future_pending fixture did not compile" >&2
  cat "$fpdir/src.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! fp_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$fpdir/src.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: async_future_pending got '$fp_out' (want 42) -- #1230 pending producer regressed" >&2
  echo "$fp_out" >&2
  exit 1
fi
rm -rf "$fpdir"
echo "[compiler-gate] pending future producer (#1230) ok"

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
# #1324: ordinary arithmetic on a value bound from a GENERIC suspend-lane
# callee must stay eligible. `v`'s syntactically inferable type is the type
# variable `T`, so desugar_trait_dict rewrites `v + 2` to `__generic_add`
# (#973) -- a registered pure builtin that was missing from
# idp_pure_builtin_names, which sank the whole literal to ineligible on the
# synthesized callee name alone. Positive pin 70.
rm -f "$ccpsdir/genop.wasm" "$ccpsdir/genop.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_closure_cps_generic_operand.vibe "$ccpsdir/genop.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$ccpsdir/genop.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_closure_cps_generic_operand did not compile -- a pure desugar helper (__generic_add / __generic_rel_diff / str_lex_diff) sank a suspend-class closure literal again (#1324)" >&2
  cat "$ccpsdir/genop.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
ccps_genop_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$ccpsdir/genop.wasm" 2>/dev/null | tail -1)"
if [ "$ccps_genop_out" != "70" ]; then
  echo "[compiler-gate] FAIL: effect_closure_cps_generic_operand got '$ccps_genop_out' (want 70)" >&2
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
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_vacuous_handle_erased.vibe "$v2dir/vacuous.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$v2dir/vacuous.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_vacuous_handle_erased fixture did not compile" >&2
  cat "$v2dir/vacuous.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! v2_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$v2dir/vacuous.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_vacuous_handle_erased got '$v2_out' (want 46) -- vacuous-handle elimination regressed" >&2
  echo "$v2_out" >&2
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
# #1511 rewrote this message (actionable sentence first, ADR jargon last).
# Anchor on the identifying phrase rather than the trailing ADR note, which is
# the part most likely to be reworded again.
if ! grep -qF "cannot be compiled here" "$v2dir/reject.wasm.diag" 2>/dev/null; then
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
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/closure_shadowed_inline_builtin.vibe "$csibdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$csibdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: closure_shadowed_inline_builtin.vibe did not compile" >&2
  cat "$csibdir/out.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! csib_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$csibdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: closure_shadowed_inline_builtin got '$csib_out' (want 28) -- either a shadowed inline builtin fell back to the builtin instead of the captured closure (#1114), or a non-recursive let binder was treated as an enclosing shadow inside its own initializer (#1120 Codex P1)" >&2
  echo "$csib_out" >&2
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

export fn fetch(url: String) -> Int with Net {
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
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_basic.vibe "$regiondir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$regiondir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_basic.vibe did not compile -- plain non-escaping nursery use regressed" >&2
  cat "$regiondir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! region_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$regiondir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_basic.vibe got '$region_pos_out' (want 42)" >&2
  echo "$region_pos_out" >&2
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_region_escape_return.vibe "$regiondir/neg.wasm" main >/dev/null 2>&1 || true
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
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_spawnable_capture.vibe "$spawnabledir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_capture.vibe did not compile -- same-region Sender capture regressed" >&2
  cat "$spawnabledir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! spawnable_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$spawnabledir/pos.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_capture.vibe got '$spawnable_pos_out' (want 42)" >&2
  echo "$spawnable_pos_out" >&2
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawnable_capture_array.vibe "$spawnabledir/neg_array.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_array.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_array.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'no impl `Spawnable` for `Array[Int]`' "$spawnabledir/neg_array.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_array.vibe did not produce the expected diagnostic" >&2
  cat "$spawnabledir/neg_array.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawnable_capture_cross_region.vibe "$spawnabledir/neg_cross.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_cross.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_cross_region.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF 'no impl `Spawnable`' "$spawnabledir/neg_cross.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_cross_region.vibe did not produce the expected diagnostic" >&2
  cat "$spawnabledir/neg_cross.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawnable_capture_letmut.vibe "$spawnabledir/neg_letmut.wasm" main >/dev/null 2>&1 || true
if [ -s "$spawnabledir/neg_letmut.wasm" ]; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut.vibe compiled successfully -- must be rejected" >&2
  exit 1
fi
if ! grep -qF "no impl \`Spawnable\` for a \`let mut\` binding" "$spawnabledir/neg_letmut.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_spawnable_capture_letmut.vibe did not produce the expected diagnostic" >&2
  cat "$spawnabledir/neg_letmut.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1571: the expectation for this rejection is the diagnostic grep below,
# so the fixture no longer carries an unread `__DATA__` error_contains copy
# and is compiled AS-IS -- no `sed` strip, no temp copy.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/err_spawnable_capture_letmut_outer_scope.vibe "$spawnabledir/neg_letmut_outer.wasm" main >/dev/null 2>&1 || true
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
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_spawnable_capture_shadowed_letmut.vibe "$spawnabledir/pos_shadow.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$spawnabledir/pos_shadow.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_capture_shadowed_letmut.vibe did not compile -- scope-blind let-mut false positive regressed" >&2
  cat "$spawnabledir/pos_shadow.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! spawnable_shadow_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$spawnabledir/pos_shadow.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_spawnable_capture_shadowed_letmut.vibe got '$spawnable_shadow_out' (want 42)" >&2
  echo "$spawnable_shadow_out" >&2
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
# #1571: the expected value lives in the fixture now (an `inspect` test
# block declaring the entry's own row, #1508), so this compiles it AS-IS --
# no `__DATA__` strip, no temp copy, and no expected value in shell.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_taskgroup_sugar.vibe "$taskgroupdir/pos.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$taskgroupdir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_taskgroup_sugar.vibe did not compile" >&2
  cat "$taskgroupdir/pos.wasm.diag" 2>/dev/null >&2 || true
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
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_frozen_array_basic.vibe "$frozenarrdir/basic.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$frozenarrdir/basic.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_frozen_array_basic.vibe did not compile" >&2
  cat "$frozenarrdir/basic.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$frozenarrdir/send.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$frozenarrdir/neg.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$frozenarrdir/capture.wasm.diag" 2>/dev/null >&2 || true
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
if ! grep -qF "missing { Fs } (declared { Ask, Ask::Get }, requires { Ask, Ask::Get, Fs })" "$eff639dir/partial.wasm.diag" 2>/dev/null; then
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
if ! grep -qF "missing { Ask::Get } (declared { Ask::Other }, requires { Ask::Get, Ask::Other })" "$eff1161dir/x.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_effect_op_level_partial_row_bare_perform.vibe did not produce the expected diagnostic" >&2
  cat "$eff1161dir/x.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! grep -qF "hint: add 'with Ask::Get + Ask::Other' to 'asks'" "$eff1161dir/x.wasm.diag" 2>/dev/null; then
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
# r4: the repair corpus is the measurement the `repair_convergence` score rests
# on (rubric dimension 8). It is a TWO-WAY ratchet -- a diagnostic that stops
# firing, whose wording drifts, OR that starts firing on a case recorded as
# silent all fail here, because each of those invalidates the recorded score.
if ! bash eval/lang-review/run_repair.sh; then
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
  cat "$dcolldir/default.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
diag_all_lines="$(run_diag_collect all VIBE_DIAGNOSTICS_ALL=1)"
if [ "$diag_all_lines" != "2" ]; then
  echo "[compiler-gate] FAIL: VIBE_DIAGNOSTICS_ALL=1 reported $diag_all_lines diagnostic lines (want 2: one per independent bad leaf, none for the blocked importer)" >&2
  cat "$dcolldir/all.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$dcolldir/ok.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$r90dir/pos.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$r90dir/neg.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$r90dir/forged.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$r90dir/cap.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$r90dir/tok.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# The false-positive guard: a closure that captures a region value but stays
# inside the region is valid, and the body still exits via freeze. It also
# covers shadowing and an initialiser that merely touches the token while
# evaluating to a scalar -- both shapes an over-eager taint rule rejects.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_ok_closure_local.vibe "$r90dir/caplocal.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/caplocal.wasm" ]; then
  echo "[compiler-gate] FAIL: region_ok_closure_local.vibe did not compile -- the #1725 capture check is over-approximating" >&2
  cat "$r90dir/caplocal.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! r90_cap_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$r90dir/caplocal.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: region_ok_closure_local.vibe got '$r90_cap_out' (want 55)" >&2
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
  cat "$r90dir/copyout.wasm.diag" 2>/dev/null >&2 || true
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
    cat "$r90dir/release.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$r90dir/bounded.wasm.diag" 2>/dev/null >&2 || true
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
    cat "$r90dir/cycles_$r90_cyc_n.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$r90dir/bpos.wasm.diag" 2>/dev/null >&2 || true
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
    cat "$r90dir/bneg.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$r90dir/bcopy.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/region_bytes_arena_bounded.vibe "$r90dir/bbounded.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$r90dir/bbounded.wasm" ]; then
  echo "[compiler-gate] FAIL: region_bytes_arena_bounded.vibe did not compile" >&2
  cat "$r90dir/bbounded.wasm.diag" 2>/dev/null >&2 || true
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
    cat "$r90dir/consume.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$r90dir/nested.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$za91dir/pos.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$za91dir/neg.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$za91dir/shadowed.wasm.diag" 2>/dev/null >&2 || true
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
    cat "$za91dir/${za_typed}.wasm.diag" 2>/dev/null >&2 || true
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
    cat "$za91mdir/measured_$za_n.wasm.diag" 2>/dev/null >&2 || true
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
# builtin). Negative: adding suspend-class Async handling (TaskGroup
# spawn_suspend) under an Async-row entry mixes conventions and must be
# REJECTED by the ADR-0076 guard, not silently miscompiled
# (err_async_boundary_mixed_convention.vibe).
echo "[compiler-gate] 77/77 ADR-0089 D1 async sleep boundary (#1218)"
asb89dir="_build/_gate_async_sleep89"
rm -rf "$asb89dir"; mkdir -p "$asb89dir"
cp fixtures/async_sleep_boundary_test.vibe "$asb89dir/pos.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/pos.vibe" "$asb89dir/pos.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: async_sleep_boundary_test.vibe did not compile -- ADR-0089 D1 sleep boundary regressed" >&2
  cat "$asb89dir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
asb89_pos_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$asb89dir/pos.wasm" 2>/dev/null | tail -1)"
if [ "$asb89_pos_out" != "42" ]; then
  echo "[compiler-gate] FAIL: async_sleep_boundary_test.vibe got '$asb89_pos_out' (want 42)" >&2
  exit 1
fi
cp fixtures/err_async_boundary_mixed_convention.vibe "$asb89dir/neg.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/neg.vibe" "$asb89dir/neg.wasm" main >/dev/null 2>&1 || true
if [ -s "$asb89dir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: err_async_boundary_mixed_convention.vibe compiled successfully -- convention mixing must be rejected" >&2
  exit 1
fi
# Either guard may catch this: the ADR-0076 mixing guard, or #1707's more
# specific one (a step-split literal landing in a plain-convention parameter,
# which is the same root -- a step value meeting a plain call). What this pins
# is that it is REJECTED with an actionable diagnostic, not miscompiled.
if ! grep -qF 'mixing the step convention' "$asb89dir/neg.wasm.diag" 2>/dev/null \
   && ! grep -qF 'hand the step object back as the value' "$asb89dir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_async_boundary_mixed_convention.vibe did not produce the expected diagnostic" >&2
  cat "$asb89dir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
# #1342: the same guard must be POSITION-INDEPENDENT and must key on the
# boundary that is actually injected.
#   - err_async_boundary_mixed_operand.vibe puts the `spawn_suspend` call in an
#     OPERAND. Its walker was missing EBinOp (and most other arms), so this
#     exact program COMPILED while the let-bound spelling above was rejected.
#   - async_boundary_user_sleep_test.vibe supplies its OWN `sleep`, so no
#     boundary is built and there is nothing to mix -- it must COMPILE and
#     return 42. The guard used to omit that half of the injection's condition.
cp fixtures/err_async_boundary_mixed_operand.vibe "$asb89dir/negop.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/negop.vibe" "$asb89dir/negop.wasm" main >/dev/null 2>&1 || true
if [ -s "$asb89dir/negop.wasm" ]; then
  echo "[compiler-gate] FAIL: err_async_boundary_mixed_operand.vibe compiled -- the mixing guard is position-dependent again (#1342)" >&2
  exit 1
fi
if ! grep -qF 'mixing the step convention' "$asb89dir/negop.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: err_async_boundary_mixed_operand.vibe did not produce the mixing diagnostic" >&2
  cat "$asb89dir/negop.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
cp fixtures/async_boundary_user_sleep_test.vibe "$asb89dir/usersleep.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asb89dir/usersleep.vibe" "$asb89dir/usersleep.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asb89dir/usersleep.wasm" ]; then
  echo "[compiler-gate] FAIL: async_boundary_user_sleep_test.vibe was rejected -- the guard fired without an injected boundary (#1342)" >&2
  cat "$asb89dir/usersleep.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$asb89dir/dis.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$asb89dir/aw.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$asb89dir/mx.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$asb89dir/fr.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$asb89dir/fd.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
asb89_fd_out="$(timeout 30 bash -c "VIBE_PREOPEN_DIR='$ROOT_DIR' bash scripts/run_wasm_vibe_host_runner.sh --invoke main '$asb89dir/fd.wasm' 2>&1" || true)"
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
  cat "$nhf37dir/nested.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$nhf37dir/shadowed.wasm.diag" 2>/dev/null >&2 || true
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
  fixtures/effect_generic_row_instantiation.vibe "$g1340dir/pos.wasm" __no_entry__ >/dev/null 2>&1
if [ ! -s "$g1340dir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_generic_row_instantiation.vibe did not compile (with State[Int] row grammar or generic registration regressed)" >&2
  cat "$g1340dir/pos.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$g1340dir/arity.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$g1340dir/rowtarg.wasm.diag" 2>/dev/null >&2 || true
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
  fixtures/effect_builtin_operation_row.vibe "$opb/pos.wasm" __no_entry__ >/dev/null 2>&1
if [ ! -s "$opb/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: with Fs::read_file no longer authorizes the Fs::read_file builtin (#1343)" >&2
  cat "$opb/pos.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$opb/neg.wasm.diag" 2>/dev/null >&2 || true
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
  "$opb/bare.vibe" "$opb/bare.wasm" main >/dev/null 2>&1
if [ ! -s "$opb/bare.wasm" ]; then
  echo "[compiler-gate] FAIL: the bare effect row stopped granting all of its operations (#1343 must be a pure widening)" >&2
  cat "$opb/bare.wasm.diag" 2>/dev/null >&2 || true
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
  fixtures/effect_async_for_row.vibe "$afdir/pos.wasm" __no_entry__ >/dev/null 2>&1
if [ ! -s "$afdir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_async_for_row.vibe did not compile -- a declared `with Async` row must still accept the async for loop (#1358)" >&2
  cat "$afdir/pos.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$afdir/neg.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$lcdir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
cat > "$lcdir/pos.vibe" <<'EOF'
let main = () -> Unit with Stdout + Env {
  let read_home = () -> String with Env {
    Env::get("HOME")
  }
  println(read_home())
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$lcdir/pos.vibe" "$lcdir/pos.wasm" main >/dev/null 2>&1
if [ ! -s "$lcdir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: declaring the local closure's row must satisfy the leak check (#1361)" >&2
  cat "$lcdir/pos.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
cat > "$lcdir/pure.vibe" <<'EOF'
let main = () -> Unit with Stdout {
  let twice = (n: Int) -> Int {
    n * 2
  }
  println(__to_string(twice(21)))
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$lcdir/pure.vibe" "$lcdir/pure.wasm" main >/dev/null 2>&1
if [ ! -s "$lcdir/pure.wasm" ]; then
  echo "[compiler-gate] FAIL: a PURE local closure must stay free of any row requirement (#1361 must not over-require)" >&2
  cat "$lcdir/pure.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$hsdir/neg.wasm.diag" 2>/dev/null >&2 || true
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
  "$hsdir/live.vibe" "$hsdir/live.wasm" main >/dev/null 2>&1
if [ ! -s "$hsdir/live.wasm" ]; then
  echo "[compiler-gate] FAIL: a handle whose body DOES reach the effect must still compile (#1347 must not over-reject)" >&2
  cat "$hsdir/live.wasm.diag" 2>/dev/null >&2 || true
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
  "$hsdir/param.vibe" "$hsdir/param.wasm" main >/dev/null 2>&1
if [ ! -s "$hsdir/param.wasm" ]; then
  echo "[compiler-gate] FAIL: a handled body whose only callee is a row-carrying PARAMETER (or annotated local) must compile -- #1347 must consult the #885/#1361 overlay, not just top-level bindings" >&2
  cat "$hsdir/param.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$hodir/neg.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$hodir"
echo "[compiler-gate] higher-order effect diagnostic ok"

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
  fixtures/exception_typed_row.vibe "$excdir/pos.wasm" __no_entry__ >/dev/null 2>&1
if [ ! -s "$excdir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: exception_typed_row.vibe did not compile (Exception[E] rows / kinded handle / erased alias regressed)" >&2
  cat "$excdir/pos.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$excdir/neg.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$excdir/neglocal.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$excdir/fixit.wasm.diag" 2>/dev/null >&2 || true
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
if ! grep -q "missing { Exception\[IoError\] }" "$excdir/handle.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a kinded handle must leave the foreign kind in the row (#1344)" >&2
  cat "$excdir/handle.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$showdir/show.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$retshowdir/missing.wasm.diag" 2>/dev/null >&2 || true
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
    cat "$exnmsgdir/$name.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  local got
  got="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$exnmsgdir/$name.wasm" 2>&1 | grep "uncaught error" | head -1)"
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

fn Boom::to_string(self: Boom) -> String {
  println("FORMATTER RAN")
  "boom"
}

let _start = () -> Int {
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
  cat "$exnmsgdir/handwritten.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$refcelldir/cell.wasm.diag" 2>/dev/null >&2 || true
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
  "fixtures/wit_gen_result.vibe" "$witresdir/fixture.wasm" __no_entry__ >/dev/null 2>&1
if [ ! -s "$witresdir/fixture.wasm" ]; then
  echo "[compiler-gate] FAIL: fixtures/wit_gen_result.vibe did not FS-compile -- the @vibe/wit_runtime import does not resolve or does not type-check (#1324)" >&2
  cat "$witresdir/fixture.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
VIBE_EMIT_WIT=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "fixtures/wit_gen_result.vibe" "$witresdir/out.wit" main >/dev/null 2>&1
if [ ! -s "$witresdir/out.wit" ]; then
  echo "[compiler-gate] FAIL: VIBE_EMIT_WIT produced no output for the @vibe/wit_runtime fixture (#1324)" >&2
  cat "$witresdir/out.wit.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! diff -u "fixtures/wit_gen_result.golden.wit" "$witresdir/out.wit" >&2; then
  echo "[compiler-gate] FAIL: WIT output differs from fixtures/wit_gen_result.golden.wit. If the boundary contract changed intentionally, update the golden AND docs/effect-wit-mapping.md together." >&2
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
      cat "$resdir/$rname.wasm.diag" 2>/dev/null >&2 || true
      exit 1
    fi
  else
    if [ -s "$resdir/$rname.wasm" ]; then
      echo "[compiler-gate] FAIL: resource case '$rname' should be rejected but compiled (ADR-0075/#1343)" >&2
      exit 1
    fi
    if [ -n "$rneedle" ] && ! grep -q -- "$rneedle" "$resdir/$rname.wasm.diag" 2>/dev/null; then
      echo "[compiler-gate] FAIL: resource case '$rname' rejected without naming '$rneedle' (ADR-0075/#1343):" >&2
      cat "$resdir/$rname.wasm.diag" 2>/dev/null >&2 || true
      exit 1
    fi
  fi
}
res_case basic ok 'resource Posts : S3::Bucket

fn main {
  println("ok")
}
'
res_case unqualified err 'resource Posts : Bucket

fn main {
  println("ok")
}
' 'must be qualified'
res_case duplicate err 'resource Posts : S3::Bucket
resource Posts : S3::Table

fn main {
  println("ok")
}
' 'already declared'
res_case singleton err 'resource Home : Process::Root

fn main {
  println("ok")
}
' 'singleton'
res_case exported err 'export resource Posts : S3::Bucket

fn main {
  println("ok")
}
' 'cannot be exported'
# `resource` stays an ordinary identifier: the declaration form needs an
# identifier right after the word, which no expression can have at statement
# position, so nothing that used the name breaks.
res_case as_name ok 'let resource = 1

fn main {
  println("ok")
}
'
rm -rf "$resdir"
echo "[compiler-gate] resource declaration identity rules ok"

echo "[compiler-gate] 92/92 fixtures/typecheck verdicts match expected.tsv (#138)"
# These 61 fixtures came with `.diag` snapshots of the RETIRED MoonBit host's
# rendered diagnostic. No current path emits that shape, no harness read them,
# and every one was stale -- so they were documentation of an expectation
# nothing checked. fixtures/typecheck/expected.tsv replaces them with a verdict
# plus a message substring, and this section is the harness they never had.
#
# Running them turned out to matter: 13 fixtures the old snapshots said were
# REJECTED now compile (see the `debt-accepts` rows). Those are checks the
# compiler no longer performs, and nothing else in this gate covers them.
# They are locked at today's behaviour so the debt cannot grow silently, and
# the gate FAILS if one starts being rejected again -- promote the row then.
tcdir="_build/_gate_typecheck_fixtures"
rm -rf "$tcdir"; mkdir -p "$tcdir"
# `__no_entry__`: a fixture without a `main` would otherwise fail on "entry
# `main` not found" and count as rejected without its actual check ever having
# run -- measured, that masked 4 of the 13 lost checks.
tc_names="$(grep -v '^#' fixtures/typecheck/expected.tsv | cut -f1)"
# One compile each (~250ms), fanned out -- serially this section would be ~15s.
printf '%s\n' $tc_names | xargs -P "$(nproc 2>/dev/null || echo 4)" -I{} env \
  ROOT_DIR="$ROOT_DIR" stage2_wasm="$stage2_wasm" tcdir="$tcdir" \
  bash -c 'VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "fixtures/typecheck/{}.vibe" "$tcdir/{}.wasm" __no_entry__ >/dev/null 2>&1 || true'
tc_fail=0
tc_debt=0
while IFS=$'\t' read -r tcname tcstatus tcneedle; do
  case "$tcname" in ''|'#'*) continue ;; esac
  if [ -s "$tcdir/$tcname.wasm" ]; then tcact="ok"; else tcact="reject"; fi
  tcdiag="$(head -1 "$tcdir/$tcname.wasm.diag" 2>/dev/null || true)"
  case "$tcstatus" in
    ok) tcwant="ok" ;;
    debt-accepts) tcwant="ok"; tc_debt=$((tc_debt + 1)) ;;
    reject) tcwant="reject" ;;
    debt-rejects) tcwant="reject"; tc_debt=$((tc_debt + 1)) ;;
    *) echo "[compiler-gate] FAIL: unknown status '$tcstatus' for $tcname in fixtures/typecheck/expected.tsv" >&2; exit 1 ;;
  esac
  if [ "$tcact" != "$tcwant" ]; then
    case "$tcstatus" in
      debt-accepts)
        echo "[compiler-gate] FAIL: fixtures/typecheck/$tcname.vibe is REJECTED again -- the lost check is back. Promote its row in expected.tsv from 'debt-accepts' to 'reject' with the new message (#138)." >&2 ;;
      debt-rejects)
        echo "[compiler-gate] FAIL: fixtures/typecheck/$tcname.vibe COMPILES again. Promote its row in expected.tsv from 'debt-rejects' to 'ok' (#138)." >&2 ;;
      *)
        echo "[compiler-gate] FAIL: fixtures/typecheck/$tcname.vibe expected '$tcwant', got '$tcact' (#138)" >&2 ;;
    esac
    [ -n "$tcdiag" ] && echo "    diag: $tcdiag" >&2
    tc_fail=1
  elif [ "$tcwant" = "reject" ] && [ -n "$tcneedle" ]; then
    case "$tcdiag" in
      *"$tcneedle"*) ;;
      *)
        echo "[compiler-gate] FAIL: fixtures/typecheck/$tcname.vibe is rejected, but not for the recorded reason (#138)" >&2
        echo "    expected substring: $tcneedle" >&2
        echo "    actual:             $tcdiag" >&2
        tc_fail=1 ;;
    esac
  fi
done < fixtures/typecheck/expected.tsv
if [ "$tc_fail" -ne 0 ]; then
  exit 1
fi
rm -rf "$tcdir"
echo "[compiler-gate] typecheck fixtures ok ($(printf '%s\n' $tc_names | wc -l | tr -d ' ') fixtures, $tc_debt known debt)"

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
  "$pbdir/pb_test.vibe" "$pbdir/pb.wasm" __no_entry__ >/dev/null 2>&1
if [ ! -s "$pbdir/pb.wasm" ]; then
  echo "[compiler-gate] FAIL: per-block test fixture did not compile (#819)" >&2
  cat "$pbdir/pb.wasm.diag" 2>/dev/null >&2 || true
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
      cat "$endir/$ename.wasm.diag" 2>/dev/null >&2 || true
      exit 1
    fi
  else
    if [ -s "$endir/$ename.wasm" ]; then
      echo "[compiler-gate] FAIL: enum-import case '$ename' should be rejected but compiled (#1455)" >&2
      exit 1
    fi
    if [ -n "$eneedle" ] && ! grep -q -- "$eneedle" "$endir/$ename.wasm.diag" 2>/dev/null; then
      echo "[compiler-gate] FAIL: enum-import case '$ename' rejected without naming '$eneedle' (#1455):" >&2
      cat "$endir/$ename.wasm.diag" 2>/dev/null >&2 || true
      exit 1
    fi
  fi
}
# 1. `Box::Mk` resolves. This used to be `unknown name: Box::Mk`, which made
#    #1455's "require the qualified spelling" plan unimplementable: there was
#    no way to WRITE a qualified reference to an imported constructor.
en_case qualified ok 'import ./dep.vibe { Box, Mk, Nil }

fn main {
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

fn main {
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

fn main {
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

fn main {
  let a = Got(3)
  let r = match a {
    Got(v) => v,
    Missed => 0
  }
  println(__to_string(r))
}
'
en_case parameterized_qualified ok 'import ./dep.vibe { Attempt, Got, Missed }

fn main {
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

fn main {
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

fn main {
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

fn main {
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

fn main {
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

fn main {
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
      cat "$uidir/$uname.wasm.diag" 2>/dev/null >&2 || true
      exit 1
    fi
  else
    if [ -s "$uidir/$uname.wasm" ]; then
      echo "[compiler-gate] FAIL: unresolved-import case '$uname' compiled; the bogus import was not caught (#1521)" >&2
      exit 1
    fi
    if ! grep -q "is not exported by" "$uidir/$uname.wasm.diag" 2>/dev/null; then
      echo "[compiler-gate] FAIL: unresolved-import case '$uname' was rejected by something OTHER than the #1521 check" >&2
      cat "$uidir/$uname.wasm.diag" 2>/dev/null >&2 || true
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
ui_case bogus_uppercase_not_reported err 'import ./dep.vibe { Hue, NoSuchType }

export let _start = () -> Int { 1 }
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
  "lib/@vibe/compiler/codegen/common_base/common_base.vibe" \
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
if ! awk '/^export fn resolve_local\(/,/^}/' "$ROOT_DIR/lib/@vibe/compiler/codegen/common_base/common_base.vibe" \
  | grep -q "codegen_unresolved_name_prefix()"; then
  echo "[compiler-gate] FAIL: resolve_local's own error no longer uses the shared wording" >&2
  exit 1
fi
if ! grep -q 'internal compiler error' "$ROOT_DIR/lib/@vibe/compiler/codegen/common_base/common_base.vibe"; then
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
  cat "$cgdir/ok.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$cgdir"
echo "[compiler-gate] codegen unresolved-name error is legible ok"

echo "[compiler-gate] 96/96 host-side tracing spans nest, propagate and record failures (docs/tracing-design.md step 0)"
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
    cat "$dvdir/$dvname.wasm.diag" 2>/dev/null >&2 || true
    exit 1
  fi
done
rm -rf "$dvdir"
echo "[compiler-gate] desugar-emitted builtins resolve in both lanes ok"

echo "[compiler-gate] 98/104 \`vibe grep\`'s typed filters resolve imports like \`vibe check\` (#1572)"
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
    cat "$gvdir/all.txt" "$gvdir/all.txt.diag" 2>/dev/null >&2 || true
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
  cat "$gvdir/row.txt" "$gvdir/row.txt.diag" 2>/dev/null >&2 || true
  exit 1
fi
# Resolved-name filter: `h` is an ALIAS for dep.vibe's `helper`, so a text grep
# for `helper(` finds nothing here and this must still find it.
gv_run alias.txt VIBE_GREP_PATTERN='$(f:id)($(a:args))' VIBE_GREP_WHERE='$f = helper'
if ! grep -qF 'h(1)' "$gvdir/alias.txt"; then
  echo "[compiler-gate] FAIL: --where '\$f = helper' did not resolve the import alias" >&2
  cat "$gvdir/alias.txt" "$gvdir/alias.txt.diag" 2>/dev/null >&2 || true
  exit 1
fi
# A bad pattern is an ERROR on the .diag sidecar, never a plausible-but-wrong
# match list on output_path (the VIBE_SYMBOLS convention).
gv_run bad.txt VIBE_GREP_PATTERN='f($(x:expr))'
if [ -s "$gvdir/bad.txt" ] || ! grep -q 'unknown metavariable kind' "$gvdir/bad.txt.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a bad grep pattern did not land on the .diag sidecar" >&2
  cat "$gvdir/bad.txt" "$gvdir/bad.txt.diag" 2>/dev/null >&2 || true
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
  cat "$gvdir/sweep.txt" "$gvdir/sweep.txt.diag" "$gvdir/sweep.txt.warn" 2>/dev/null >&2 || true
  exit 1
fi
if grep -qF 'b_sweep_bad.vibe' "$gvdir/sweep.txt" || [ -s "$gvdir/sweep.txt.diag" ]; then
  echo "[compiler-gate] FAIL: typed grep did not fail closed per broken file" >&2
  cat "$gvdir/sweep.txt" "$gvdir/sweep.txt.diag" "$gvdir/sweep.txt.warn" 2>/dev/null >&2 || true
  exit 1
fi
if [ "$(grep -cF 'b_sweep_bad.vibe' "$gvdir/sweep.txt.warn" 2>/dev/null || true)" -ne 1 ]; then
  echo "[compiler-gate] FAIL: typed grep did not report the skipped file exactly once" >&2
  cat "$gvdir/sweep.txt.warn" 2>/dev/null >&2 || true
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
fn main() -> Int {
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
  cat "$inspdir/hygiene.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$inspdir/assignop.wasm.diag" 2>/dev/null >&2 || true
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
  cat "$inspdir/shadow_fn.wasm.diag" 2>/dev/null >&2 || true
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
  B((Int, String) -> Unit)
}

fn shout(v: Int, c: String) -> Unit {
  println(c)
}

fn main() -> Int {
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
  cat "$inspdir/shadow_pat.wasm.diag" 2>/dev/null >&2 || true
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
# stdout (#1567 slice 2, pinned in scripts/test_vibe_cli_install.sh, which is
# the layer that owns the user-facing contract). This step stays at the
# compiler layer and only pins the counts.
chk_n="$(grep -c '^line ' "$chkdir/check.out.diag" 2>/dev/null || true)"
diag_n="$(grep -c '^line ' "$chkdir/diag.out" 2>/dev/null || true)"
[ -n "$chk_n" ] || chk_n=0
[ -n "$diag_n" ] || diag_n=0
if [ "$chk_n" != "2" ]; then
  echo "[compiler-gate] FAIL: vibe check reported $chk_n parse errors, want 2 -- check_linked_file is dropping diagnostics the recovering parser already collected (#1567)" >&2
  cat "$chkdir/check.out.diag" 2>/dev/null >&2 || true
  exit 1
fi
if [ "$diag_n" != "2" ]; then
  echo "[compiler-gate] FAIL: vibe diagnostics reported $diag_n parse errors, want 2 (#1567)" >&2
  cat "$chkdir/diag.out" 2>/dev/null >&2 || true
  exit 1
fi
# Same errors, not merely the same count: both must name line 1 and line 3.
for want in 'line 1:' 'line 3:'; do
  if ! grep -qF "$want" "$chkdir/check.out.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: vibe check's report is missing '$want' (#1567)" >&2
    cat "$chkdir/check.out.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  if ! grep -qF "$want" "$chkdir/diag.out" 2>/dev/null; then
    echo "[compiler-gate] FAIL: vibe diagnostics' report is missing '$want' (#1567)" >&2
    cat "$chkdir/diag.out" 2>/dev/null >&2 || true
    exit 1
  fi
done
# A clean file must stay clean on both, with check still exiting 0.
printf 'export let a = 1\n' > "$chkdir/clean.vibe"
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$chkdir/clean.vibe" "$chkdir/clean.out" main >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: vibe check rejected a clean file (#1567)" >&2
  cat "$chkdir/clean.out.diag" 2>/dev/null >&2 || true
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
  cat "$depdir/direct.txt" "$depdir/direct.txt.diag" 2>/dev/null >&2 || true
  exit 1
fi

# (b) The closure reaches a contract's SIBLING IMPLEMENTATION. No import line
# anywhere names lib/@vibe/ast/ast.vibe -- it enters the build only because the
# loader pulls a .vpkg's impls in. A selection built on anything less would
# miss every change to that file.
dep_run closure.txt lib/@vibe/parser/parser_smoke_test.vibe
if ! grep -qx 'lib/@vibe/ast/ast.vibe' "$depdir/closure.txt"; then
  echo "[compiler-gate] FAIL: vibe deps closure missed the .vpkg sibling impl lib/@vibe/ast/ast.vibe (#988)" >&2
  cat "$depdir/closure.txt" "$depdir/closure.txt.diag" 2>/dev/null >&2 || true
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
  cat "$depdir/broken.txt" "$depdir/broken.txt.diag" 2>/dev/null >&2 || true
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
  cat "$alcdir/none.txt" "$alcdir/none.txt.diag" 2>/dev/null >&2 || true
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
    cat "$escdir/real_$lane.txt" "$escdir/real_$lane.txt.diag" 2>/dev/null >&2 || true
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
  cat "$escdir/shadow_loose.txt" "$escdir/shadow_loose.txt.diag" 2>/dev/null >&2 || true
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
    cat "$escdir/broken_$lane.txt" "$escdir/broken_$lane.txt.diag" 2>/dev/null >&2 || true
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
    cat "$sbdir/$spelling.wasm.diag" 2>/dev/null >&2 || true
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
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$chkpkgdir/entry.vibe" "$chkpkgdir/check.out" main >/dev/null 2>&1
chk_rc=$?
# (a) it must SUCCEED. A crash here used to produce exit 1 with an empty
# output AND an empty .diag -- indistinguishable from a diagnostic-free
# failure, which is the one thing this surface must never be.
if [ "$chk_rc" != "0" ]; then
  echo "[compiler-gate] FAIL: vibe check exited $chk_rc on a file importing @vibe/core -- the second import resolver is back (#1262)" >&2
  cat "$chkpkgdir/check.out" "$chkpkgdir/check.out.diag" 2>/dev/null >&2 || true
  exit 1
fi
if ! grep -q '^ok$' "$chkpkgdir/check.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: vibe check on a @scope/pkg importer did not report clean (#1262)" >&2
  cat "$chkpkgdir/check.out" "$chkpkgdir/check.out.diag" 2>/dev/null >&2 || true
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
  cat "$aliasdir/opaque.wasm.diag" 2>/dev/null >&2 || true
  exit 1
fi
rm -rf "$aliasdir"
echo "[compiler-gate] generic transparent alias + opaque control ok (#1700)"

echo "[compiler-gate] ok"
