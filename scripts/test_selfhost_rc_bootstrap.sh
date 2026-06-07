#!/usr/bin/env bash
set -euo pipefail

# ADR-0055 #493 — whole-compiler-under-RC bootstrap parity gate.
#
# The selfhost compiler compiles *itself* via the module-source + source-groups
# path (build_selfhost_cli_adapter_bytes, entry `cli_main`). This gate drives
# that exact path through stage1 under BOTH backends and asserts RC-vs-default
# parity — the cutover-safety invariant: RC must introduce no compile gap that
# the default bump path does not already have, at full compiler scale.
#
#   stage0 (MoonBit host) compiles vibe/compiler/index.vibe -> index_stage1.wasm
#   stage1 self-compiles (default bump) via selfbuild_compile_cli_adapter_env
#   stage1 self-compiles (Perceus RC)   via selfbuild_compile_cli_adapter_rc_env
#
# Outcomes:
#   * both produce valid wasm        -> FULL GREEN whole-compiler-under-RC signal
#   * both fail with the same error  -> PARITY HOLDS (blocked only by a shared
#                                       default-path ceiling; RC adds no gap)
#   * RC fails where default succeeds,
#     or RC error differs            -> FAIL (RC-specific regression)
#
# Today the shared ceiling is a default-path stage1 limitation in the
# source-group merge ("no functions found to compile"); the full whole-compiler
# self-compile through stage1 is gated on lifting that (and the checker/parser
# recursion-depth ceiling), tracked separately from RC. This gate stays green on
# parity and auto-upgrades to the full signal once those default-path ceilings
# are lifted. See docs/spec/selfhost-rc-cutover-readiness.md.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/_build/bench/selfhost_rc_bootstrap"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/index.vibe}"
STAGE_TIMEOUT_SEC="${VIBE_SELFHOST_RC_BOOTSTRAP_STAGE_TIMEOUT_SEC:-600}"
STAGE1_CORE_WASM="$OUT_DIR/index_stage1.wasm"
OUTPUT_DEFAULT_WASM="$OUT_DIR/whole_compiler_default.wasm"
OUTPUT_RC_WASM="$OUT_DIR/whole_compiler_rc.wasm"
DEFAULT_LOG="$OUT_DIR/whole_compiler_default.log"
RC_LOG="$OUT_DIR/whole_compiler_rc.log"
# Raised V8 stack lets stage1's recursive-descent parser/checker get deep into
# the full-scale source before any shared default-path ceiling is hit.
NODE_STACK_SIZE="${VIBE_SELFHOST_RC_BOOTSTRAP_NODE_STACK_SIZE:-16000}"
VIBE_NODE_WASM_FLAGS="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref --stack-size=$NODE_STACK_SIZE}"
export VIBE_NODE_WASM_FLAGS
HOST_VIBE_EXE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"

run_with_timeout() {
  local timeout_sec="$1"; shift
  if [ "$timeout_sec" -le 0 ]; then "$@"; return $?; fi
  if command -v timeout >/dev/null 2>&1; then timeout "$timeout_sec" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$timeout_sec" "$@"; return $?; fi
  "$@"
}

# NOTE: does not toggle errexit (so it never clobbers a caller's `set +e`).
# Callers must capture the status, e.g. `run_stage ... || st=$?`.
run_stage() {
  local name="$1"; shift
  echo "[rc-bootstrap] $name"
  local status=0
  run_with_timeout "$STAGE_TIMEOUT_SEC" "$@" || status=$?
  if [ "$status" -eq 124 ]; then
    echo "[rc-bootstrap] timeout: $name (${STAGE_TIMEOUT_SEC}s)" >&2
  fi
  return "$status"
}

is_wasm() {
  [ -f "$1" ] || return 1
  local magic; magic="$(od -An -t x1 -N 4 "$1" | tr -d ' \n')"
  [ "$magic" = "0061736d" ]
}

# Extract a stable "outcome signature" from a self-compile attempt:
#   "ok:<bytes>"           on success (valid wasm produced)
#   "err:<error message>"  on a compiler-reported error
#   "trap:<kind>"          on a host trap (stack overflow / OOM)
#   "none"                 if nothing usable was produced
outcome_signature() {
  local wasm="$1" log="$2"
  if is_wasm "$wasm"; then
    echo "ok:$(wc -c <"$wasm" | tr -d ' ')"
    return
  fi
  local err
  err="$(grep -E 'Error string \(tag=error\):' "$log" | tail -n 1 | sed 's/.*Error string (tag=error): //')"
  if [ -n "$err" ]; then echo "err:$err"; return; fi
  if grep -q 'Maximum call stack size exceeded' "$log"; then echo "trap:stack-overflow"; return; fi
  if grep -qiE 'out of memory|RangeError: WebAssembly' "$log"; then echo "trap:oom"; return; fi
  echo "none"
}

mkdir -p "$OUT_DIR"
rm -f "$STAGE1_CORE_WASM" "$OUTPUT_DEFAULT_WASM" "$OUTPUT_RC_WASM" "$DEFAULT_LOG" "$RC_LOG"

if ! command -v node >/dev/null 2>&1; then
  echo "rc bootstrap gate failed: node not found" >&2; exit 1
fi
if [ ! -f "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" ]; then
  echo "rc bootstrap gate failed: wasm host runner wrapper not found" >&2; exit 1
fi

if [ -x "$HOST_VIBE_EXE" ]; then
  HOST_COMPILE_CMD=("$HOST_VIBE_EXE" compile --wasm --force-cabi-realloc)
else
  HOST_COMPILE_CMD=(moon run --target native src/cmd/vibe -- compile --wasm --force-cabi-realloc)
fi

# stage0 -> stage1 selfhost compiler core wasm
if ! run_stage "stage0 host compiler -> stage1 selfhost compiler core wasm" \
  "${HOST_COMPILE_CMD[@]}" "$ENTRY_PATH" -o "$STAGE1_CORE_WASM"; then
  echo "rc bootstrap gate failed: stage1 core build failed" >&2; exit 1
fi
if ! is_wasm "$STAGE1_CORE_WASM"; then
  echo "rc bootstrap gate failed: stage1 core is not wasm" >&2; exit 1
fi
echo "[rc-bootstrap] stage1 core: $(wc -c <"$STAGE1_CORE_WASM" | tr -d ' ') bytes"

export VIBE_PREOPEN_DIR="$PROJECT_ROOT"

# default-backend whole-compiler self-compile (status captured, never aborts)
default_status=0
run_stage "stage1 -> whole-compiler self-compile (default bump path)" \
  env VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_OUTPUT="${OUTPUT_DEFAULT_WASM#$PROJECT_ROOT/}" \
    bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
      --invoke selfbuild_compile_cli_adapter_env "$STAGE1_CORE_WASM" >"$DEFAULT_LOG" 2>&1 \
  || default_status=$?

# RC-backend whole-compiler self-compile (status captured, never aborts)
rc_status=0
run_stage "stage1 -> whole-compiler self-compile (Perceus RC path)" \
  env VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_OUTPUT="${OUTPUT_RC_WASM#$PROJECT_ROOT/}" \
    bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
      --invoke selfbuild_compile_cli_adapter_rc_env "$STAGE1_CORE_WASM" >"$RC_LOG" 2>&1 \
  || rc_status=$?

unset VIBE_PREOPEN_DIR

default_sig="$(outcome_signature "$OUTPUT_DEFAULT_WASM" "$DEFAULT_LOG")"
rc_sig="$(outcome_signature "$OUTPUT_RC_WASM" "$RC_LOG")"
echo "[rc-bootstrap] default outcome: $default_sig"
echo "[rc-bootstrap] RC outcome:      $rc_sig"

default_ok=0; rc_ok=0
case "$default_sig" in ok:*) default_ok=1 ;; esac
case "$rc_sig" in ok:*) rc_ok=1 ;; esac

emit_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    echo "### Selfhost RC Bootstrap Parity Gate (ADR-0055 #493)"
    echo
    echo "- whole-compiler self-compile through stage1, both backends"
    echo "- default outcome: \`$default_sig\`"
    echo "- RC outcome:      \`$rc_sig\`"
    echo "- $1"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
}

# RC succeeded where default failed is impossible to call a regression; but RC
# failing where default succeeded, or both succeeding, are the decisive cases.
if [ "$rc_ok" -eq 1 ] && [ "$default_ok" -eq 1 ]; then
  if command -v wasm-tools >/dev/null 2>&1; then
    wasm-tools validate --features=exceptions,function-references,gc "$OUTPUT_RC_WASM" >/dev/null \
      || { echo "rc bootstrap gate failed: RC whole-compiler wasm failed validate" >&2; exit 1; }
  fi
  echo "[rc-bootstrap] FULL GREEN: whole compiler compiled under RC and default"
  emit_summary "FULL GREEN — whole compiler compiles under RC at full scale"
  echo "selfhost rc bootstrap gate passed (full whole-compiler-under-RC)"
  exit 0
fi

if [ "$default_ok" -eq 1 ] && [ "$rc_ok" -eq 0 ]; then
  echo "rc bootstrap gate failed: RC-specific regression — default succeeded ($default_sig) but RC failed ($rc_sig)" >&2
  emit_summary "FAIL — RC-specific regression vs default"
  exit 1
fi

if [ "$default_sig" = "$rc_sig" ]; then
  echo "[rc-bootstrap] PARITY: RC reaches the same point as default ($rc_sig)"
  echo "[rc-bootstrap] (blocked by a shared default-path ceiling, not RC)"
  emit_summary "PARITY HOLDS — RC adds no gap vs default (shared default-path ceiling)"
  echo "selfhost rc bootstrap gate passed (RC-vs-default parity)"
  exit 0
fi

echo "rc bootstrap gate failed: RC outcome diverges from default — default=$default_sig rc=$rc_sig" >&2
echo "  (RC must not fail differently than default; investigate the RC path)" >&2
emit_summary "FAIL — RC diverges from default"
exit 1
