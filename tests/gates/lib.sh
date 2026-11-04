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
# run_bounded <secs> <cmd...>: the portable spelling of GNU timeout(1), which a
# stock macOS does not have (#2958). Lanes call it wherever they bound a probe.
. "$ROOT_DIR/scripts/run_bounded.sh"

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
GATE_LANES="bootstrap early mid late selftests"

gate_lane_script() {
  local lane="$1"
  printf '%s/tests/gates/%s/run.sh' "$ROOT_DIR" "$lane"
}

# Fill $stage2_wasm (and $latest_gen when a generations tree already exists).
# Prefer an explicit VIBE_STAGE2_WASM, then HEAD's generation left by the
# bootstrap lane. Without either, regenerate the flat source and build for
# this invocation (no stage3, same as the CI unit shards). Directory mtimes
# identify neither the source revision nor the seed, so never use them to
# choose a compiler. An unproven _gate_lane_gen output is rebuilt too.
# EXPORTS the answer, it does not merely assign it (#2650 review). A lane
# spawns child processes that ask the same question for themselves, and two of
# them read it out of the ENVIRONMENT: check_compile_only_lanes.sh takes
# COMPILE_ONLY_STAGE2 then VIBE_STAGE2_WASM, and check_freeze_surface.sh the
# same. With `stage2_wasm` a plain shell variable they saw nothing, fell through
# to "newest generation on disk, else the committed seed", and certified a
# compiler the lane had not built -- silently, because that fallback is a
# successful run. CI masked it: the workflow exports VIBE_STAGE2_WASM for the
# lanes, so only the independently runnable path was wrong, which is the path
# `COMPILER_GATE_LANE=selftests bash scripts/compiler_gate.sh` takes.
#
# Exported in all three resolution branches, so the lane and everything under
# it agree on one compiler however it was found. Where the caller already set
# it, this is a no-op.
gate_resolve_stage2() {
  if [ -n "${VIBE_STAGE2_WASM:-}" ]; then
    stage2_wasm="$VIBE_STAGE2_WASM"
    if [ ! -f "$stage2_wasm" ]; then
      echo "[compiler-gate] FAIL: VIBE_STAGE2_WASM=$stage2_wasm does not exist" >&2
      exit 1
    fi
    export VIBE_STAGE2_WASM="$stage2_wasm"
    return 0
  fi
  . "$ROOT_DIR/scripts/resolve_stage2.sh"
  if stage2_wasm="$(resolve_stage2_strict compiler-gate "" 2>/dev/null)"; then
    latest_gen="${stage2_wasm%/*}/"
    export VIBE_STAGE2_WASM="$stage2_wasm"
    return 0
  fi
  latest_gen=""
  mkdir -p _build/_gate_lane_gen
  echo "[compiler-gate] building stage2 for this lane (no HEAD generation or explicit compiler)"
  bash scripts/ensure_generated.sh || {
    echo "[compiler-gate] FAIL: could not regenerate current compiler sources" >&2
    exit 1
  }
  VIBE_PREBUILT_MODULE_SOURCE="lib/@vibe/compiler/_cli_adapter_module_source.vibe" \
    bash scripts/generations.sh build --out-dir _build/_gate_lane_gen || {
      echo "[compiler-gate] FAIL: could not build this lane's compiler" >&2
      exit 1
    }
  stage2_wasm="_build/_gate_lane_gen/stage2.wasm"
  if [ ! -s "$stage2_wasm" ]; then
    echo "[compiler-gate] FAIL: lane stage2 build produced no wasm" >&2
    exit 1
  fi
  export VIBE_STAGE2_WASM="$stage2_wasm"
}

# gate_split_cli_cache_is_current <cache_dir> <stage2_wasm>
#
# Was the split CLI core in <cache_dir> built from THIS stage2? Answers 0 for
# yes; for anything else it REMOVES the directory and answers 1, so a caller
# that ignores the status still cannot reuse a mismatched artifact.
#
# Identity is `cmp` against a copy of the stage2 kept beside the build, not a
# hash and not a timestamp. `sha256sum` dies on this container's glibc
# mismatch under the task runner, and a gate must not fail for a reason
# unrelated to what it checks (#2252); mtime and size are proxies for
# identity, and trusting a proxy is what every failure this guards against
# had in common.
#
# Lives here rather than inline in the lane so it can be tested with
# fabricated inputs -- a copy of the decision inside a test would be another
# proxy, agreeing with itself.
gate_split_cli_cache_is_current() {
  _gscc_dir="$1"
  _gscc_stage2="$2"
  if [ -s "$_gscc_dir/index_stage1.wasm" ] && \
     [ -s "$_gscc_dir/base_stage2.wasm" ] && \
     [ -s "$_gscc_stage2" ] && \
     cmp -s "$_gscc_dir/base_stage2.wasm" "$_gscc_stage2"; then
    return 0
  fi
  rm -rf "$_gscc_dir"
  return 1
}

# --- the compile-and-require harness (#3671) ---------------------------------
#
# Every lane used to spell an FS-lane compile in three lines and its "the
# compile must have produced a module" check in five, hundreds of times over.
# These two helpers are those spellings, so a lane states WHAT it compiles and
# WHAT it requires, and the mechanics live in one place.

# gate_fs_compile <src> <out> <entry> [arg...]
#
# Compile <src> to <out> on the FS lane with $stage2_wasm. The previous <out>
# and <out>.diag are removed FIRST, so a compile that fails cannot be mistaken
# for one that succeeded by a stale artifact left by an earlier run. Never
# aborts: the caller's own check -- gate_require_artifact, or an assertion on
# the .diag -- is always reached. The selectors are inline, not routed through
# a variable (#2248).
gate_fs_compile() {
  rm -f "$2" "$2.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$@" >/dev/null 2>&1 || true
}

# gate_require_artifact <out> <message>
#
# FAIL the lane with <message> unless <out> is a non-empty file, showing the
# compiler's <out>.diag. <message> says what did not compile, in the lane's
# words.
gate_require_artifact() {
  if [ ! -s "$1" ]; then
    echo "[compiler-gate] FAIL: $2" >&2
    cat "$1.diag" >&2 2>/dev/null || true
    exit 1
  fi
}

# gate_require_refused <out> <message>
#
# FAIL the lane with <message> if <out> is a non-empty file: the compile was
# supposed to be refused. Pair it with gate_fs_compile, which removes a stale
# <out> first, so a refusal is not mistaken for success, nor a success for an
# old refusal.
gate_require_refused() {
  if [ -s "$1" ]; then
    echo "[compiler-gate] FAIL: $2" >&2
    exit 1
  fi
}

# gate_require_diag_has <diag> <text> <message>
# gate_require_diag_matches <diag> <pattern> <message>
#
# FAIL the lane with <message>, showing <diag>, unless the diagnostic file
# contains <text> (a fixed string, grep -F) or a line matching <pattern> (a
# basic regular expression, plain grep). A refusal is checked by its MESSAGE,
# not merely by its happening: the wrong error refuses a program too.
gate_require_diag_has() {
  if ! grep -qF -- "$2" "$1" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $3" >&2
    cat "$1" >&2 2>/dev/null || true
    exit 1
  fi
}

gate_require_diag_matches() {
  if ! grep -q -- "$2" "$1" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $3" >&2
    cat "$1" >&2 2>/dev/null || true
    exit 1
  fi
}
