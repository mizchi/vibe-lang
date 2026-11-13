#!/usr/bin/env bash
# Self-test for scripts/check_compile_only_lanes.sh (#2248 rule: a gate must
# prove it can fail). Each case mutates a REAL input and asserts the gate fails
# with the message for that mutation; the control run must pass.
#
#   1. blind      -- the named artifact with its name section stripped: the
#                    scan must refuse to certify what it cannot see.
#   2. leak       -- a named wasm that defines a function of a dropped lane
#                    (a probe program spelling `compile_file_fs_mode_gc`):
#                    the absence check must name it.
#                    Also run for component and editor tools (#2499) and the
#                    ingestion-pipeline telemetry encoder, the scheduler
#                    trace's row encoders, the heap-mark emitter, and the
#                    incremental typecheck sidecar's encoder and destination
#                    guard, the invalidation trace's encoders, and the
#                    ingestion fingerprint sidecar's encoder (#2498).
#   3. lost       -- a named wasm with no async component composition: the
#                    presence check must say the production lane is gone.
#   4. accepted   -- the full CLI stage2, invoked as `cli_main`: it serves
#                    VIBE_BACKEND=gc, so the refusal check must fail; and it
#                    serves VIBE_EMIT_WIT=1, so the tool refusal must fail.
#   4b. telemetry -- the same stage2, flattened WITH the compiler's
#                    `telemetry` cfg flag (#2498): it publishes the
#                    ingestion-pipeline sidecar, so --telemetry-only must
#                    fail.
#                    It also writes the scheduler trace, emits heap marks
#                    and publishes the incremental typecheck sidecar and the
#                    invalidation trace and the ingestion fingerprint
#                    sidecar, so --scheduler-trace-only, --memory-marks-only,
#                    --incremental-telemetry-only, --invalidation-trace-only
#                    and --ingestion-fingerprint-only must fail.
#   4c. stale     -- the compile-only artifact rebuilt from its own flat
#                    module source with the scheduler-trace and heap-mark
#                    refusals moved back in front of the shared
#                    stale-sidecar cleanup (the defect fixed after #4105's
#                    review): a stale VIBE_INCREMENTAL_TELEMETRY_OUT sidecar
#                    survives each refusal, so --scheduler-trace-only and
#                    --memory-marks-only must both fail. The same mutant
#                    clears VIBE_INCREMENTAL_TELEMETRY_OUT with no destination
#                    guard, so the probe naming the compile input deletes it
#                    and --incremental-telemetry-only must fail. It also
#                    refuses VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT before the
#                    cleanup, so --invalidation-trace-only must fail, and
#                    VIBE_INGESTION_TELEMETRY_OUT before any clear, so its own
#                    stale sidecar survives and --ingestion-fingerprint-only
#                    must fail.
#   5. control    -- the real compile-only artifact passes.
#
# Fixture: a fresh named compile-only artifact built with the selected compiler
# in this test's private scratch directory. An existing shared artifact can
# belong to older sources even when the selected stage2 is current.
# COMPILE_ONLY_STAGE2 overrides the compiler, as for the gate.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/resolve_stage2.sh"
GATE="scripts/check_compile_only_lanes.sh"
# `VIBE_STAGE2_WASM` is the lane's own answer to "which compiler", set by
# compiler-gate-lanes in CI and read the same way by check_freeze_surface.sh,
# minify_gate.sh, build_vibe_opt.sh, build_vibec.sh and coverage_suite.sh.
# Without it this gate fell through resolve_stage2 to the committed SEED --
# and its control case asserts that #2497 unit 2's fold DROPPED
# `emit_shadow_mark_freed` / `emit_str_operand_guard`, which is a property of
# a compiler containing that change. The seed does not, so the gate failed
# while reporting the artifact's contents accurately: the wrong-compiler trap
# (AGENTS.md, "Which compiler answered?"), in a gate whose subject is what a
# build dropped.
STAGE2="$(resolve_stage2 compile-only-lanes-test "${COMPILE_ONLY_STAGE2:-${VIBE_STAGE2_WASM:-}}")" || exit 1
TMP="$(mktemp -d "${TMPDIR:-/tmp}/compile_only_lanes_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ART="$TMP/vibe_compile_only.names.wasm"
bash scripts/build_compile_only.sh --names --out "$ART" --compiler "$STAGE2" >&2

expect_fail() { # <case> <needle> <gate args...>
  local label="$1" needle="$2"; shift 2
  local log="$TMP/$label.log" rc=0
  bash "$GATE" "$@" >"$log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "check_compile_only_lanes_test: FAIL ($label): the gate passed on a mutated input" >&2
    cat "$log" >&2
    exit 1
  fi
  if ! grep -qF -- "$needle" "$log"; then
    echo "check_compile_only_lanes_test: FAIL ($label): the gate failed, but not with '$needle':" >&2
    cat "$log" >&2
    exit 1
  fi
  echo "check_compile_only_lanes_test: ok ($label): failed as expected"
}

# 1. blind: drop the "name" custom section. The mutation must have hit -- a
# copy identical to the artifact proves nothing.
STRIPPED="$TMP/stripped.wasm"
python3 - "$ART" "$STRIPPED" <<'PY'
import sys
src, dst = sys.argv[1:]
b = open(src, "rb").read()
def uleb(p):
    r = s = 0
    while True:
        x = b[p]; p += 1
        r |= (x & 0x7f) << s; s += 7
        if not x & 0x80:
            return r, p
out = bytearray(b[:8]); p = 8; dropped = 0
while p < len(b):
    sid = b[p]; size, q = uleb(p + 1); end = q + size
    if sid == 0:
        nlen, r = uleb(q)
        if b[r:r + nlen] == b"name":
            dropped += 1; p = end; continue
    out += b[p:end]; p = end
assert dropped == 1, dropped
open(dst, "wb").write(out)
PY
cmp -s "$ART" "$STRIPPED" && { echo "check_compile_only_lanes_test: FAIL (blind): strip did not change the artifact" >&2; exit 1; }
expect_fail blind "names only" --scan-only "$STRIPPED"

# 2. leak: a named user build whose function names include a dropped lane's.
# Enough functions that the runtime's unnamed helpers stay under the 10% the
# scan tolerates; the mutation is verified by reading the names back first.
check_leak() { # <source-level name of a forbidden family>
  local witness="$1"
  local LEAK_SRC="$TMP/$witness.vibe"
  {
    echo "fn $witness() -> Int { 1 }"
    i=0
    while [ "$i" -lt 60 ]; do
      echo "fn helper_$i(x: Int) -> Int { x + $i }"
      i=$((i + 1))
    done
    printf 'fn main() -> Int {\n  let mut acc = %s()\n' "$witness"
    i=0
    while [ "$i" -lt 60 ]; do
      echo "  acc = helper_$i(x = acc)"
      i=$((i + 1))
    done
    printf '  acc\n}\n'
  } > "$LEAK_SRC"
  local LEAK="$TMP/$witness.wasm"
  _selector_order="$(bash "$ROOT_DIR/scripts/adapter_selector_order.sh")"
  [ -n "$_selector_order" ] || { echo "check_compile_only_lanes_test: FAIL: adapter_selector_order.sh printed nothing" >&2; exit 1; }
  echo "$_selector_order" | tr ' ' '\n' | grep -qx VIBE_FS_COMPILE \
    || { echo "check_compile_only_lanes_test: FAIL: adapter_selector_order.sh omitted VIBE_FS_COMPILE" >&2; exit 1; }
  env $(printf '%s\n' $_selector_order | sed 's/^/-u /' | tr '\n' ' ') \
    -u VIBE_RC VIBE_WASM_NAMES=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" "$LEAK_SRC" "$LEAK" main >"$TMP/leak.build.log" 2>&1 || true
  [ -s "$LEAK" ] || { echo "check_compile_only_lanes_test: FAIL (leak): probe did not compile" >&2; cat "$LEAK.diag" >&2 2>/dev/null; exit 1; }
  node scripts/wasm_func_sizes.mjs "$LEAK" --top 1000000 | grep -qF "$witness" \
    || { echo "check_compile_only_lanes_test: FAIL (leak): the probe's name section lacks $witness, so the mutation did not hit" >&2; exit 1; }
  expect_fail "$witness" "$witness" --scan-only "$LEAK"
}
check_leak compile_file_fs_mode_gc
check_leak codegen_body_cache_replay
check_leak adapter_serve_component
check_leak format_source
check_leak lsp_main
check_leak ingestion_pipeline_telemetry_json
check_leak scheduler_trace_project
check_leak scheduler_trace_step
check_leak profile_memory_mark_emit
check_leak incremental_typecheck_telemetry_json
check_leak telemetry_destination_conflict
check_leak incremental_invalidation_trace_json
check_leak incremental_trace_json_string
check_leak incremental_typecheck_telemetry_v1_json
check_leak cache_ingestion_fingerprint_telemetry_json
check_leak ingestion_telemetry_counter_

# 3. lost: a named build with no forbidden name and no async component lane.
# The same probe shape as a leak, under a name no pattern matches, so the
# absence half passes and only the presence half can fail it.
check_lost() {
  local witness="benign_probe_fn"
  local SRC="$TMP/$witness.vibe" OUT="$TMP/$witness.wasm" i
  {
    echo "fn $witness() -> Int { 1 }"
    i=0
    while [ "$i" -lt 60 ]; do
      echo "fn helper_$i(x: Int) -> Int { x + $i }"
      i=$((i + 1))
    done
    printf 'fn main() -> Int {\n  let mut acc = %s()\n' "$witness"
    i=0
    while [ "$i" -lt 60 ]; do
      echo "  acc = helper_$i(x = acc)"
      i=$((i + 1))
    done
    printf '  acc\n}\n'
  } > "$SRC"
  _selector_order="$(bash "$ROOT_DIR/scripts/adapter_selector_order.sh")"
  env $(printf '%s\n' $_selector_order | sed 's/^/-u /' | tr '\n' ' ') \
    -u VIBE_RC VIBE_WASM_NAMES=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" "$SRC" "$OUT" main >"$TMP/lost.build.log" 2>&1 || true
  [ -s "$OUT" ] || { echo "check_compile_only_lanes_test: FAIL (lost): probe did not compile" >&2; exit 1; }
  if node scripts/wasm_func_sizes.mjs "$OUT" --top 1000000 | grep -qF comp_emit_component_wasm_async_; then
    echo "check_compile_only_lanes_test: FAIL (lost): the probe defines an async component function, so the mutation did not hit" >&2
    exit 1
  fi
  expect_fail lost "defines no required function matching 'comp_emit_component_wasm_async_stdin_provider'" --scan-only "$OUT"
}
check_lost

# 4. accepted: the full CLI serves the gc lane, so the refusal check fails on
# the first switch; it also serves the component tools, which the lane half
# fails before, so the tool half is asked on its own.
expect_fail accepted "VIBE_BACKEND=gc was ACCEPTED" --artifact "$STAGE2" --entry cli_main
expect_fail accepted_tool "VIBE_EMIT_WIT=1 was ACCEPTED" --artifact "$STAGE2" --entry cli_main --tools-only

# 4b. telemetry: the generation's stage2 keeps the counters, so it publishes
# the sidecar the compile-only artifact must refuse.
expect_fail telemetry "VIBE_INGESTION_PIPELINE_TELEMETRY_OUT was ACCEPTED" --artifact "$STAGE2" --entry cli_main --telemetry-only
expect_fail scheduler_trace "VIBE_SCHEDULER_TRACE was ACCEPTED" --artifact "$STAGE2" --entry cli_main --scheduler-trace-only
expect_fail memory_marks "VIBE_PROFILE_MEMORY_MARKS=1 was ACCEPTED" --artifact "$STAGE2" --entry cli_main --memory-marks-only
expect_fail incremental "VIBE_INCREMENTAL_TELEMETRY_OUT was ACCEPTED" --artifact "$STAGE2" --entry cli_main --incremental-telemetry-only
expect_fail invalidation "VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT was ACCEPTED" --artifact "$STAGE2" --entry cli_main --invalidation-trace-only
expect_fail ingestion_fingerprint "VIBE_INGESTION_TELEMETRY_OUT was ACCEPTED" --artifact "$STAGE2" --entry cli_main --ingestion-fingerprint-only

# 4c. stale: refuse VIBE_SCHEDULER_TRACE and VIBE_PROFILE_MEMORY_MARKS=1
# before the stale-sidecar cleanup. One mutant carries both early refusals.
# The mutation is applied to the flat module source the fixture was built
# from, then compiled exactly as scripts/build_compile_only.sh compiles it.
check_stale_refusal() {
  local SRC="$TMP/vibe_compile_only.names.module_source.vibe"
  local MUT="$TMP/stale_refusal.module_source.vibe" OUT="$TMP/stale_refusal.wasm"
  [ -s "$SRC" ] || { echo "check_compile_only_lanes_test: FAIL (stale): no module source at $SRC" >&2; exit 1; }
  node - "$SRC" "$MUT" <<'NODE'
const fs = require("fs");
const [src, out] = process.argv.slice(2);
const text = fs.readFileSync(src, "utf8");
const anchor = '{ let fs_telemetry_out = Env::get("VIBE_INCREMENTAL_TELEMETRY_OUT");';
const refusal = text.match(/scheduler_trace_refusal_exp_[A-Za-z0-9_]+/);
const marks = text.match(/profile_memory_marks_refusal_[A-Za-z0-9_]+/);
const invalidation = text.match(/invalidation_trace_refusal_[A-Za-z0-9_]+/);
const fingerprint = text.match(/ingestion_fingerprint_telemetry_refusal_[A-Za-z0-9_]+/);
if (text.split(anchor).length !== 2 || !refusal || !marks || !invalidation || !fingerprint) {
  console.error("check_compile_only_lanes_test: FAIL (stale): the mutation anchor is not unique in the module source");
  process.exit(1);
}
const early = `{ if (Env::get("VIBE_SCHEDULER_TRACE") != "") { throw(${refusal[0]}()) } else { () }; if (Env::get("VIBE_PROFILE_MEMORY_MARKS") == "1") { throw(${marks[0]}()) } else { () }; if (Env::get("VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT") != "") { throw(${invalidation[0]}()) } else { () }; if (Env::get("VIBE_INGESTION_TELEMETRY_OUT") != "") { throw(${fingerprint[0]}()) } else { () }; let fs_telemetry_out = Env::get("VIBE_INCREMENTAL_TELEMETRY_OUT"); if (fs_telemetry_out != "") { Fs::remove_file(fs_telemetry_out) } else { () };`;
fs.writeFileSync(out, text.replace(anchor, early));
NODE
  cmp -s "$SRC" "$MUT" && { echo "check_compile_only_lanes_test: FAIL (stale): the mutation did not change the module source" >&2; exit 1; }
  _selector_order="$(bash "$ROOT_DIR/scripts/adapter_selector_order.sh")"
  env $(printf '%s\n' $_selector_order | sed 's/^/-u /' | tr '\n' ' ') \
    VIBE_RC=0 VIBE_INTERNAL_TRUSTED_SOURCE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    VIBE_WASM_PRE_GROW_PAGES=0 VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE=1 VIBE_SKIP_RUN_INIT=1 \
    VIBE_NODE_WASM_FLAGS="--experimental-wasm-exnref --stack-size=131072" \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" "$MUT" "$OUT" cli_main_compile_only >"$TMP/stale.build.log" 2>&1 || true
  [ -s "$OUT" ] || { echo "check_compile_only_lanes_test: FAIL (stale): the mutated artifact did not compile" >&2; cat "$OUT.diag" >&2 2>/dev/null; tail -5 "$TMP/stale.build.log" >&2; exit 1; }
  expect_fail stale "survived the refused invocation" --artifact "$OUT" --entry cli_main_compile_only --scheduler-trace-only
  expect_fail stale_marks "survived the refused invocation" --artifact "$OUT" --entry cli_main_compile_only --memory-marks-only
  expect_fail unguarded_clear "DELETED or rewrote it" --artifact "$OUT" --entry cli_main_compile_only --incremental-telemetry-only
  expect_fail stale_invalidation "survived the refused invocation" --artifact "$OUT" --entry cli_main_compile_only --invalidation-trace-only
  expect_fail stale_ingestion_fingerprint "survived the refused invocation" --artifact "$OUT" --entry cli_main_compile_only --ingestion-fingerprint-only
}
check_stale_refusal

# 5. control.
if ! bash "$GATE" --artifact "$ART" --entry cli_main_compile_only >"$TMP/control.log" 2>&1; then
  echo "check_compile_only_lanes_test: FAIL (control): the gate rejects the real compile-only artifact" >&2
  cat "$TMP/control.log" >&2
  exit 1
fi
echo "check_compile_only_lanes_test: ok (control)"
echo "check_compile_only_lanes_test: all cases ok"
