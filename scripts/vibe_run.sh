#!/usr/bin/env bash
# Selfhost `vibe run` (#594): compile a .vibex executable root (resolving imports from
# the filesystem) with the committed seed compiler, then execute it via the Rust
# runner — no MoonBit host. Program output is produced through declared effects.
#
#   bash scripts/vibe_run.sh [--coverage] path/to/prog.vibex [-- arg...]
#
# The entry is always `main` (ADR-0075); arbitrary entry names are internal
# compiler ABI and are not accepted here. Paths are interpreted relative to,
# and must live under, the repo root (the wasm preopen dir).
# Any arguments after a literal `--` are forwarded as
# trailing argv to the compiled program, readable via `Env::args_len` /
# `Env::args_get` (#865 -- these host builtins already worked; this wrapper
# previously just dropped anything past `entry` on the floor).
#
# --coverage (#cov): compile the program with function/branch hit
# instrumentation and, after the run, dump which functions and if/match branches
# executed. The program's own output still goes to stdout; the runner prints a
# `[vibe-cov]` summary to stderr and writes the JSON report to
# _build/vibe_run/<name>.cov.json.
#
# Exit code: canonical `main` returns Unit and exits 0. A non-zero exit is an
# explicit Process operation (or a runtime trap), never an implicit Int result.
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
  echo "usage: vibe_run.sh [--coverage] <file.vibex> [-- arg...]" >&2
  exit 2
fi

src="$1"
shift
entry="main"
case "$src" in
  *.vibex) ;;
  *) echo "vibe run requires a .vibex executable root: $src" >&2; exit 2 ;;
esac
# #865: arguments after the literal `--` separator are guest argv. A second
# positional argument used to select an arbitrary entry; ADR-0075 removes that
# user-visible ABI.
if [ "$#" -gt 0 ] && [ "${1:-}" != "--" ]; then
  echo ".vibex entry is always main; arbitrary entry names are not allowed" >&2
  exit 2
fi
if [ "$#" -gt 0 ] && [ "${1:-}" = "--" ]; then
  shift
fi
extra_args=("$@")
bash "$ROOT_DIR/scripts/ensure_seed.sh"
seed="$ROOT_DIR/bootstrap/seed/compiler.wasm"

# Repo-root-relative source path for the wasm preopen.
case "$src" in
  "$ROOT_DIR"/*) src_rel="${src#"$ROOT_DIR"/}" ;;
  /*) echo "vibe_run.sh: path must be under the repo root: $src" >&2; exit 2 ;;
  *) src_rel="$src" ;;
esac
[ -f "$ROOT_DIR/$src_rel" ] || { echo "vibe_run.sh: not found: $src_rel" >&2; exit 2; }

out_rel="_build/vibe_run/$(basename "${src_rel%.vibex}").wasm"
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
  cov_out="$ROOT_DIR/_build/vibe_run/$(basename "${src_rel%.vibex}").cov.json"
fi
# Keep the runner's result-to-status bridge enabled for the canonical Unit
# result (0); explicit Process exit and traps still determine non-zero status.
# Trailing argv (parsed above) is appended after $out_rel, exactly where the
# runner's own arg parser (scripts/wasm_vibe_host_runner.js::parseArgs)
# starts collecting `passthroughArgs` once it has seen the wasm path.
exec env VIBE_COV_OUT="$cov_out" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_RUNNER_EXIT_WITH_RESULT=1 \
  bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke "$entry" "$out_rel" \
  ${extra_args[@]+"${extra_args[@]}"}
