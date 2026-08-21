#!/usr/bin/env bash
# compiler-gate lane: bootstrap (#1849 / #2001 Phase 1).
# Invoked by scripts/compiler_gate.sh or directly:
#   bash tests/gates/bootstrap/run.sh
set -euo pipefail
# shellcheck source=../lib.sh
GATES_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck disable=SC1090
source "$GATES_LIB"

if [ "${COMPILER_GATE_SKIP_PREFLIGHT:-0}" != "1" ]; then
  bash tests/gates/bootstrap/preflight.sh
fi

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

VIBE_RC_BOOTSTRAP_REUSE_GEN="${latest_gen}generation.json" \
  bash scripts/test_rc_bootstrap.sh

# CI runs the stage2 consumer oracles in their own cached job. Keep the local
# bootstrap lane complete by default, while letting the fixpoint job publish
# its stage2 without serializing unrelated consumers behind the selfbuild.
if [ "${COMPILER_GATE_SKIP_STAGE2_ORACLES:-0}" = "1" ]; then
  exit 0
fi

# #2148: build and exercise the supported split CLI entry with the stage2 from
# this checkout. This caught the entry's missing Stdout row and keeps direct
# build prerequisites plus the compile/build/check command surface live.
echo "[compiler-gate] 3cli/3 selfhost split CLI core"
VIBE_CLI_CORE_BASE_COMPILER="$stage2_wasm" VIBE_RC=1 \
  bash scripts/test_cli_core.sh

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
    >/dev/null 2>"$heap_log" || true
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
