#!/usr/bin/env bash
# Run a repository `.vibex` tool on the committed seed compiler:
#
#   bash scripts/vibe_run.sh [vibe run flags] path/to/prog.vibex [-- arg...]
#
# This is `vibe run` (runtime/vibe) with two tools chosen for a plain checkout,
# and nothing else (#3674):
#
#   - the compiler is the pinned seed, so a tool runs before (and independently
#     of) any stage2 build;
#   - the runner is the node host runner, because a checkout has no `viberun`
#     binary (scripts/vibe_run_runner.sh, which also hands the program the
#     caller's own VIBE_CLI_WASM / VIBE_RUNNER rather than these two).
#
# Everything else is `vibe run`'s: the argument grammar (a `.vibex` root, the
# fixed `main` entry, guest argv after `--`), compile diagnostics, the exit
# status, and `--coverage`. Paths resolve against the repo root, which is also
# the program's preopened directory. A `vibe run` flag newer than the seed is
# refused by the seed until the next seed bump.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

recorded() { if [ -n "${!1+x}" ]; then printf 'set:%s' "${!1}"; else printf unset; fi; }

bash "$ROOT_DIR/scripts/ensure_seed.sh" >&2
exec env \
  VIBE_RUN_CALLER_CLI_WASM="$(recorded VIBE_CLI_WASM)" \
  VIBE_RUN_CALLER_RUNNER="$(recorded VIBE_RUNNER)" \
  VIBE_CLI_WASM="$ROOT_DIR/bootstrap/seed/compiler.wasm" \
  VIBE_RUNNER="$ROOT_DIR/scripts/vibe_run_runner.sh" \
  VIBE_PREOPEN_DIR="${VIBE_PREOPEN_DIR:-$ROOT_DIR}" \
  "$ROOT_DIR/runtime/vibe" run "$@"
