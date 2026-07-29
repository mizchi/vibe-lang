#!/usr/bin/env bash
# Stage 3 (opt-in): route the dev CLI to the selfhost compiler wasm, so
# `compile` / `check` / `build` run through selfhost codegen instead of the
# MoonBit host compiler. Drop-in for the run_cached_vibe seam via
# VIBE_CLI_BIN_OVERRIDE.
#
#   VIBE_CLI_BIN_OVERRIDE="$PWD/scripts/vibe_cli.sh" \
#     bash scripts/run_cached_vibe.sh compile --wasm foo.vibe -o foo.wasm
#
# Scope: only the commands the selfhost CLI (lib/@vibe/cli/entry.vibe, run via
# the lib/@vibe/cli/main.vibex ADR-0075 entry -- #1137 stage 1) implements —
# compile / build / check / compile-lite / bundle. Other commands (run, test,
# fmt, normalize, bench, ...) are not yet ported (see
# docs/moonbit-retirement.md, Stage 4.5) and must still go through the host CLI;
# this shim does not handle them.
#
# Path args are interpreted relative to the repo root (the wasm preopen dir).
# Absolute paths under the repo root are rewritten to repo-relative.
#
# The CLI wasm path can be supplied with VIBE_CLI_WASM (e.g. a
# prebuilt generation build); otherwise it is built by build_cli_core.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_WASM="${VIBE_CLI_WASM:-$ROOT_DIR/_build/bench/selfhost_cli_core/index_stage1.wasm}"

if [ ! -f "$CLI_WASM" ]; then
  echo "[vibe-selfhost-cli] building selfhost CLI core wasm" >&2
  bash "$ROOT_DIR/scripts/build_cli_core.sh" >&2
fi

# Rewrite absolute paths under the repo root to repo-relative for the preopen.
args=()
for a in "$@"; do
  case "$a" in
    "$ROOT_DIR"/*) args+=("${a#"$ROOT_DIR"/}") ;;
    *) args+=("$a") ;;
  esac
done

exec env VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
  --invoke _start "$CLI_WASM" "${args[@]}"
