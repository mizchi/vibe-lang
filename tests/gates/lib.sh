#!/usr/bin/env bash
# Shared host helpers for independently runnable compiler-gate lanes
# (#1849 / #2001 Phase 1).
#
# Lane scripts source this file. It does not run any gate. It sets ROOT_DIR,
# the VIBE_RC pin, and the exit-status helpers that `set -e` otherwise
# swallows. `gate_resolve_stage2` fills `$stage2_wasm` / `$latest_gen` for
# lanes that do not themselves perform the seed->stage3 fixpoint.

# shellcheck disable=SC2034
: "${VIBE_RC:=0}"; export VIBE_RC

if [ -z "${ROOT_DIR:-}" ]; then
  _gates_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ROOT_DIR="$(cd "$_gates_lib_dir/../.." && pwd)"
fi
cd "$ROOT_DIR"
SCRIPT_DIR="${SCRIPT_DIR:-$ROOT_DIR/scripts}"

# gate_status <var> <cmd...> -- run cmd, assign its exit status to <var>.
# Never aborts, so the caller's own assertion is always reached.
gate_status() {
  local __var="$1"; shift
  local __rc=0
  "$@" >/dev/null 2>&1 || __rc=$?
  printf -v "$__var" '%s' "$__rc"
}

# gate_status_out <var> <outfile> <cmd...> -- same, but keep stdout+stderr in
# <outfile> so a FAIL branch can show what actually happened.
gate_status_out() {
  local __var="$1"; local __out="$2"; shift 2
  local __rc=0
  "$@" >"$__out" 2>&1 || __rc=$?
  printf -v "$__var" '%s' "$__rc"
}

# Known independently runnable lanes. `all` is the aggregator, not a file.
GATE_LANES="bootstrap early mid late"

gate_lane_script() {
  local lane="$1"
  printf '%s/tests/gates/%s/run.sh' "$ROOT_DIR" "$lane"
}

# Fill $stage2_wasm (and $latest_gen when a generations tree already exists).
# Prefer an explicit VIBE_STAGE2_WASM, then the freshest generations/ tree
# left by the bootstrap lane, then a unit-test-style build from the
# committed flat module source (no stage3, same as the CI unit shards).
gate_resolve_stage2() {
  if [ -n "${VIBE_STAGE2_WASM:-}" ]; then
    stage2_wasm="$VIBE_STAGE2_WASM"
    if [ ! -f "$stage2_wasm" ]; then
      echo "[compiler-gate] FAIL: VIBE_STAGE2_WASM=$stage2_wasm does not exist" >&2
      exit 1
    fi
    return 0
  fi
  latest_gen="$(ls -dt _build/selfhost/generations/*/ 2>/dev/null | head -1 || true)"
  if [ -n "$latest_gen" ] && [ -f "${latest_gen}stage2.wasm" ]; then
    stage2_wasm="${latest_gen}stage2.wasm"
    return 0
  fi
  mkdir -p _build/_gate_lane_gen
  if [ ! -f _build/_gate_lane_gen/stage2.wasm ]; then
    echo "[compiler-gate] building stage2 for this lane (no generations tree, no VIBE_STAGE2_WASM)"
    VIBE_PREBUILT_MODULE_SOURCE="lib/@vibe/compiler/_cli_adapter_module_source.vibe" \
      bash scripts/generations.sh build --out-dir _build/_gate_lane_gen
  fi
  stage2_wasm="_build/_gate_lane_gen/stage2.wasm"
  if [ ! -f "$stage2_wasm" ]; then
    echo "[compiler-gate] FAIL: lane stage2 build produced no wasm" >&2
    exit 1
  fi
}
