#!/usr/bin/env bash
# build_compile_only.sh -- the compile-only compiler artifact (#2497).
#
# The same env-mode CLI as stage2, DCE-rooted at `main_compile_only`
# (lib/@vibe/compiler/cli_adapter.vibe) instead of `main`. Its lane tables
# name only the two production allocator lanes (RC, and bump under VIBE_RC=0),
# so the gc backend, the coverage / trace / break instrumentation compiles,
# the rc-shadow lane and the body-cache / heap-marked / testmeta twins are
# unreachable at module-source emission and absent from the wasm -- not merely
# skipped at run time. A request for one of them (VIBE_BACKEND=gc,
# VIBE_DEBUG_BREAK=1, VIBE_RC=shadow, ...) is refused by name; it never falls
# through to a lane it did not ask for. scripts/check_compile_only_lanes.sh
# pins both halves.
#
# Steps: ensure the generated bundles are current, emit the compile-only module
# source from the exact merged program (scripts/generate_bundle.sh,
# VIBE_COMPILE_ONLY_MODULE_SOURCE_OUT), compile it with stage2.
#
# Usage:
#   bash scripts/build_compile_only.sh [--out FILE] [--names] [--compiler stage2.wasm]
#     --out FILE      default _build/compile_only/vibe_compile_only.wasm
#     --names         keep the name section (VIBE_WASM_NAMES=1), for attribution
#                     and for check_compile_only_lanes.sh
#     --compiler W    the compiler that compiles the flat source; default: the
#                     generation for HEAD (scripts/resolve_stage2.sh), override
#                     also via COMPILE_ONLY_COMPILER
# Prints `compile-only artifact: <path> (<bytes> bytes)` on success.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/resolve_stage2.sh"

OUT="$ROOT_DIR/_build/compile_only/vibe_compile_only.wasm"
NAMES=0
COMPILER_OVERRIDE="${COMPILE_ONLY_COMPILER:-}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --names) NAMES=1; shift ;;
    --compiler) COMPILER_OVERRIDE="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "build_compile_only: unknown argument: $1" >&2; exit 2 ;;
  esac
done
COMPILER="$(resolve_stage2 build-compile-only "$COMPILER_OVERRIDE")" || exit 1

WORK="$(dirname "$OUT")"
mkdir -p "$WORK"
MODULE_SOURCE="$WORK/cli_compile_only_module_source.vibe"

# The bundles and the merge-flatten tool are keyed by ensure_generated's
# fingerprint; this brings them up to date (a no-op when they already are).
bash "$ROOT_DIR/scripts/ensure_generated.sh" >&2

# The generator rewrites its default outputs in lib/; point them at scratch
# copies so this build touches nothing but its own directory, and ask only
# for the compile-only emission (no adapter module source, hence no seed
# validation compile).
BUNDLE_TMP="$(mktemp -d "$WORK/.bundle.XXXXXX")"
trap 'rm -rf "$BUNDLE_TMP"' EXIT
rm -f "$MODULE_SOURCE"
VIBE_BUNDLE_OUT="$BUNDLE_TMP/compiler_sources_bundle.vibe" \
VIBE_ADAPTER_BUNDLE_OUT="$BUNDLE_TMP/cli_adapter_bundle.vibe" \
VIBE_RUNTIME_ENTRY_BUNDLE_OUT="$BUNDLE_TMP/selfbuild_runtime_entry_bundle.vibe" \
VIBE_ADAPTER_MODULE_SOURCE_OUT="" \
VIBE_COMPILE_ONLY_MODULE_SOURCE_OUT="$MODULE_SOURCE" \
  bash "$ROOT_DIR/scripts/generate_bundle.sh" >"$WORK/generate_bundle.log" 2>&1 || {
    echo "build_compile_only: compile-only module source emission failed:" >&2
    tail -40 "$WORK/generate_bundle.log" >&2
    exit 1
  }
[ -s "$MODULE_SOURCE" ] || { echo "build_compile_only: module source not produced: $MODULE_SOURCE" >&2; exit 1; }

# Same compile as a stage hop (scripts/generations.sh run_cli_compile): the
# compiler self-build is pinned to the bump lane, flat generated source is
# the trusted-source lane, and the persistent artifact cache stays out of a
# build whose output is compared by bytes.
rm -f "$OUT" "$OUT.diag"
if ! (
  cd "$ROOT_DIR" &&
    VIBE_RC=0 \
    VIBE_INTERNAL_TRUSTED_SOURCE=1 \
    VIBE_PREOPEN_DIR="$ROOT_DIR" \
    VIBE_IMPORT_ABI="${VIBE_IMPORT_ABI:-raw}" \
    VIBE_WASM_PRE_GROW_PAGES="${VIBE_GENERATION_WASM_PRE_GROW_PAGES:-0}" \
    VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE="${VIBE_GENERATION_DISABLE_PERSISTENT_ARTIFACT_CACHE:-1}" \
    VIBE_SKIP_RUN_INIT="${VIBE_GENERATION_SKIP_RUN_INIT:-1}" \
    VIBE_NODE_WASM_FLAGS="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref --stack-size=${VIBE_GENERATION_NODE_STACK_SIZE:-131072}}" \
    VIBE_WASM_NAMES="$([ "$NAMES" = 1 ] && echo 1 || echo 0)" \
    bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke cli_main \
      "$COMPILER" "$MODULE_SOURCE" "$OUT" cli_main_compile_only >"$WORK/compile.log" 2>&1
); then
  echo "build_compile_only: compile failed:" >&2
  cat "$OUT.diag" 2>/dev/null >&2 || true
  tail -40 "$WORK/compile.log" >&2
  exit 1
fi
[ -s "$OUT" ] || { echo "build_compile_only: no output: $OUT" >&2; cat "$OUT.diag" 2>/dev/null >&2 || true; exit 1; }
echo "compile-only artifact: $OUT ($(wc -c <"$OUT") bytes)"
