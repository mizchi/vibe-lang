#!/usr/bin/env bash
# #715 minimal, correct reproduction: RC self-hosting `memory access out of
# bounds` (Perceus free-list corruption, same-address double-free).
#
# This script exists because getting to a *correct* repro burned several full
# debugging sessions on two silent methodology traps -- both are load-bearing,
# do not "simplify" this script without re-reading the notes below:
#
# 1. `scripts/generations.sh` (and everything built on it, including
#    `scripts/compiler_gate.sh`) pins `VIBE_RC=0` unless the caller
#    exports `VIBE_RC=1` FIRST. The default multi-stage seed->stage1->stage2
#    ->stage3 bootstrap therefore NEVER exercises the Perceus RC backend at
#    all -- any instrumentation added to RC-only code (`gen_rc_drop_body`,
#    `gen_rc_alloc_body`, `build_perceus_plan_with_params`, ...) and tested
#    only through that default chain is silently dead code. (Every early
#    "the Perceus plan is empty" finding in the #715 investigation turned out
#    to be this mistake, not a real bug.)
#
# 2. The *frozen* seed (`bootstrap/seed/compiler.wasm`)
#    cannot RC-self-compile the CURRENT flat source directly -- it is stale
#    relative to whatever syntax/feature the current source uses, and fails
#    immediately with `not EFn`. You must first build a *fresh* bump
#    (`VIBE_RC=0`, the default) stage2 from current HEAD, then use THAT
#    stage2 (not the seed) as the compiler for the RC self-compile step.
#
# The actual #715 repro is therefore a 3-step, 2-compiler-generation process:
#   (a) bump-build a fresh stage2 from current source (scripts/generations.sh, default VIBE_RC=0)
#   (b) use that stage2 to compile the flat CLI source AGAIN, this time with VIBE_RC=1
#       -> produces an RC-self-compiled compiler ("stage_rc.wasm")
#   (c) use stage_rc.wasm to compile a trivial one-line program
#       -> this is what actually crashes: `RuntimeError: memory access out of
#          bounds` inside `compile_wasi_module_linked_impl` (landing site
#          moves across rebuilds -- observed at `get_efn_params`,
#          `fn_type_param_types`, and inside the parser, depending on binary
#          layout; this is expected "moving target" behavior, not evidence of
#          a different bug -- see issue #715 for the full history).
#
# Usage:
#   scripts/repro_715_rc_free_list_corruption.sh [--out-dir DIR] [--reuse-stage2 PATH]
#
#   --out-dir DIR        Working directory for generated artifacts.
#                         Default: _build/repro_715
#   --reuse-stage2 PATH  Skip step (a) and use an existing bump stage2.wasm
#                         (e.g. from a previous compiler_gate.sh run) --
#                         much faster for iterating on a hypothesis, but make
#                         sure it was built from source that actually matches
#                         what you are testing.
#
# Exit code: 0 if the trivial-program compile in step (c) SUCCEEDS (i.e. #715
# is fixed / did not reproduce this run); non-zero if it crashes (the bug
# reproduced) OR if steps (a)/(b) themselves failed for an unrelated reason.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

OUT_DIR="_build/repro_715"
REUSE_STAGE2=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --reuse-stage2) REUSE_STAGE2="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"
FLAT_SRC="lib/@vibe/compiler/_cli_adapter_module_source.vibe"
[ -s "$FLAT_SRC" ] || {
  echo "[repro-715] flat source not found at $FLAT_SRC -- run:" >&2
  echo "  VIBE_REGEN_MODULE_SOURCE=1 VIBE_ADAPTER_MODULE_SOURCE_OUT=\$PWD/$FLAT_SRC bash scripts/generate_bundle.sh" >&2
  exit 1
}

if [ -n "$REUSE_STAGE2" ]; then
  [ -s "$REUSE_STAGE2" ] || { echo "[repro-715] --reuse-stage2 path not found: $REUSE_STAGE2" >&2; exit 1; }
  STAGE2="$REUSE_STAGE2"
  echo "[repro-715] (a) reusing existing bump stage2: $STAGE2"
else
  echo "[repro-715] (a) bump-building fresh stage2 from current HEAD (VIBE_RC=0, the default) ..."
  GEN_DIR="$OUT_DIR/gen"
  rm -rf "$GEN_DIR"
  VIBE_REGEN_MODULE_SOURCE=1 bash scripts/generations.sh build --out-dir "$GEN_DIR" --stage3
  STAGE2="$GEN_DIR/stage2.wasm"
  [ -s "$STAGE2" ] || { echo "[repro-715] FAIL: bump stage2 build did not produce $STAGE2" >&2; exit 1; }
fi

echo "[repro-715] (b) RC self-compiling flat source with stage2 (VIBE_RC=1) ..."
STAGE_RC="$OUT_DIR/stage_rc.wasm"
rm -f "$STAGE_RC"
if ! VIBE_INTERNAL_TRUSTED_SOURCE=1 VIBE_RC=1 VIBE_IMPORT_ABI=raw bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$STAGE2" "$FLAT_SRC" "$STAGE_RC" cli_main; then
  echo "[repro-715] FAIL: step (b) itself crashed (RC self-compile of the whole flat source) -- this is a DIFFERENT/earlier failure than #715's usual landing site, investigate separately" >&2
  exit 2
fi
[ -s "$STAGE_RC" ] || { echo "[repro-715] FAIL: step (b) produced no output at $STAGE_RC" >&2; exit 2; }

echo "[repro-715] (c) compiling a trivial one-line program with stage_rc.wasm ..."
TRIVIAL="$OUT_DIR/trivial.vibe"
printf 'let main = () -> Int { 42 }\n' > "$TRIVIAL"
if bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$STAGE_RC" "$TRIVIAL" "$OUT_DIR/trivial_out.wasm" main; then
  echo "[repro-715] OK: trivial program compiled successfully under a fully RC-self-compiled compiler -- #715 did NOT reproduce this run"
  exit 0
else
  echo "[repro-715] REPRODUCED: trivial program compile crashed under the RC-self-compiled compiler (see #715) -- exact landing site (function name in the stack trace) is expected to vary across rebuilds ('moving target', see issue history), so match on the crash TYPE (memory access out of bounds), not the specific function" >&2
  exit 1
fi
