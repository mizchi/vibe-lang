#!/usr/bin/env bash
# Selfhost `vibe run` (#594): compile a .vibe entry file (resolving imports from
# the filesystem) with the committed seed compiler, then execute it via the Rust
# runner — no MoonBit host. Output (return value / effects) goes to stdout.
#
#   bash scripts/vibe_run.sh [--coverage] path/to/prog.vibe [entry]
#
# `entry` is the entry function name (default: main). Paths are interpreted
# relative to, and must live under, the repo root (the wasm preopen dir).
#
# --coverage (#cov): compile the program with function/branch hit
# instrumentation and, after the run, dump which functions and if/match branches
# executed. The program's own output still goes to stdout; the runner prints a
# `[vibe-cov]` summary to stderr and writes the JSON report to
# _build/vibe_run/<name>.cov.json.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Parse flags (only --coverage today); leave the rest as positional args.
coverage=0
_args=()
for _a in "$@"; do
  if [ "$_a" = "--coverage" ]; then
    coverage=1
  else
    _args+=("$_a")
  fi
done
set -- ${_args[@]+"${_args[@]}"}

if [ "$#" -lt 1 ]; then
  echo "usage: vibe_run.sh [--coverage] <file.vibe> [entry]" >&2
  exit 2
fi

src="$1"
entry="${2:-main}"
seed="$ROOT_DIR/bootstrap/seed/selfhost_compiler.wasm"

# Repo-root-relative source path for the wasm preopen.
case "$src" in
  "$ROOT_DIR"/*) src_rel="${src#"$ROOT_DIR"/}" ;;
  /*) echo "vibe_run.sh: path must be under the repo root: $src" >&2; exit 2 ;;
  *) src_rel="$src" ;;
esac
[ -f "$ROOT_DIR/$src_rel" ] || { echo "vibe_run.sh: not found: $src_rel" >&2; exit 2; }

out_rel="_build/vibe_run/$(basename "${src_rel%.vibe}").wasm"
mkdir -p "$ROOT_DIR/_build/vibe_run"

# 1. compile (FS import resolution) via the seed. VIBE_COVERAGE=$coverage selects
#    the instrumented codegen when --coverage.
VIBE_COVERAGE="$coverage" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
  --invoke cli_main "$seed" "$src_rel" "$out_rel" "$entry" >/dev/null

[ -s "$ROOT_DIR/$out_rel" ] || { echo "vibe_run.sh: compile produced no wasm" >&2; exit 1; }

# 2. execute the compiled program. Under --coverage, VIBE_COV_OUT makes the runner
#    dump the hit bitmap (functions + branches) after the run, before it exits —
#    so a plain exec still both runs the program and reports coverage.
cov_out=""
if [ "$coverage" = "1" ]; then
  cov_out="$ROOT_DIR/_build/vibe_run/$(basename "${src_rel%.vibe}").cov.json"
fi
exec env VIBE_COV_OUT="$cov_out" VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke "$entry" "$out_rel"
