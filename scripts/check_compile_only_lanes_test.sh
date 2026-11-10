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
#                    Also run for a component-tool family (#2499).
#   3. lost       -- a named wasm with no async component composition: the
#                    presence check must say the production lane is gone.
#   4. accepted   -- the full CLI stage2, invoked as `cli_main`: it serves
#                    VIBE_BACKEND=gc, so the refusal check must fail; and it
#                    serves VIBE_EMIT_WIT=1, so the tool refusal must fail.
#   5. control    -- the real compile-only artifact passes.
#
# Fixture: the named compile-only artifact the gate builds
# (_build/compile_only/vibe_compile_only.names.wasm); built here when absent.
# In release-check this task depends on check-compile-only-lanes, so the gate
# has finished writing it before this reads it; the gate's own scratch is a
# private mktemp directory, so the two never share a path even when run side
# by side. COMPILE_ONLY_STAGE2 overrides the compiler, as for the gate.
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
ART="$ROOT_DIR/_build/compile_only/vibe_compile_only.names.wasm"
if [ ! -s "$ART" ]; then
  bash scripts/build_compile_only.sh --names --out "$ART" --compiler "$STAGE2" >&2
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/compile_only_lanes_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

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
  expect_fail lost "the async component composition the production lanes need is gone" --scan-only "$OUT"
}
check_lost

# 4. accepted: the full CLI serves the gc lane, so the refusal check fails on
# the first switch; it also serves the component tools, which the lane half
# fails before, so the tool half is asked on its own.
expect_fail accepted "VIBE_BACKEND=gc was ACCEPTED" --artifact "$STAGE2" --entry cli_main
expect_fail accepted_tool "VIBE_EMIT_WIT=1 was ACCEPTED" --artifact "$STAGE2" --entry cli_main --tools-only

# 5. control.
if ! bash "$GATE" --artifact "$ART" --entry cli_main_compile_only >"$TMP/control.log" 2>&1; then
  echo "check_compile_only_lanes_test: FAIL (control): the gate rejects the real compile-only artifact" >&2
  cat "$TMP/control.log" >&2
  exit 1
fi
echo "check_compile_only_lanes_test: ok (control)"
echo "check_compile_only_lanes_test: all cases ok"
