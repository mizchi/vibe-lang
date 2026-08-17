#!/usr/bin/env bash
# #1949: the documented first program must compile and run from a directory
# that cannot see the repository lib/ tree. Host-builtin Stdout::write_stream
# only — this smoke does not install. The installed-toolchain prelude import
# is pinned in tests/integration/install/install_test.sh.
#
# A full `vibe run hello.vibex` needs the install layout (viberun +
# vibe-cli.wasm). This matches scripts/vibe_run_smoke.sh (seed compile +
# host runner) but cds into a temp dir and preopens only that dir so
# workspace lib/ is not on the search path.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-install-hello.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

printf 'fn main with Stdout { Stdout::write_stream("42\\n") }\n' > "$WORK/hello.vibex"

# Hide repo lib / any inherited VIBE_LIB so a prelude import would fail.
unset VIBE_LIB || true
export VIBE_HOME="$WORK/empty-home"
mkdir -p "$VIBE_HOME"

bash "$ROOT_DIR/scripts/ensure_seed.sh"
seed="$ROOT_DIR/bootstrap/seed/compiler.wasm"

cd "$WORK"

VIBE_PREOPEN_DIR="$WORK" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
  --invoke cli_main "$seed" "hello.vibex" "hello.wasm" "main" >/dev/null

if [ ! -s "$WORK/hello.wasm" ]; then
  echo "[install-hello-smoke] FAIL: compile produced no wasm" >&2
  if [ -s "$WORK/hello.wasm.diag" ]; then
    cat "$WORK/hello.wasm.diag" >&2
  fi
  exit 1
fi

out="$(VIBE_PREOPEN_DIR="$WORK" VIBE_RUNNER_EXIT_WITH_RESULT=1 \
  bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke main "hello.wasm" \
  | tr -d '\r' | sed -n '1p')"
out="${out%"${out##*[![:space:]]}"}"

if [ "$out" != "42" ]; then
  echo "[install-hello-smoke] FAIL: expected 42, got '$out'" >&2
  exit 1
fi

echo "[install-hello-smoke] ok (stdout=42, no repo lib/)"
