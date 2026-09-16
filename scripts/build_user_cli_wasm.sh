#!/usr/bin/env bash
# Build the USER CLI wasm -- the artifact `runtime/vibe` hands its argv to.
#
# Since the launcher stopped parsing verbs itself, `vibe test foo.vibe` is
# delivered to a wasm, and only ONE of the two wasms this repo builds can read
# it:
#
#   - lib/@vibe/compiler/cli_adapter.vibe  -> dist/cli/vibe-cli.wasm, stage2.wasm
#     The COMPILER. Positional `<input> <output> <entry>` plus VIBE_* selectors.
#     Handed a verb it reads it as a path: `vibe test x` became
#     `fs_read_file failed for 'test'`.
#   - lib/@vibe/cli/main.vibex            -> this script's output
#     The CLI. Reads verbs, plans host actions, and carries the compiler with
#     it.
#
# `pick_cli` in runtime/vibe looks for `lib/vibe-user-cli.wasm` (installed) or
# `_build/cli/vibe-user-cli.wasm` (checkout). Nothing produced either, so every
# launcher verb fell through to the compiler adapter. This is what produces it.
#
#   bash scripts/build_user_cli_wasm.sh [out.wasm]
#
# The compiler used to build it is VIBE_USER_CLI_BASE_COMPILER; without one a
# stage2 is built from the current tree (scripts/build_cli_wasm.sh). Pass the
# compiler explicitly when the answer must be about a SPECIFIC compiler -- the
# CLI links the compiler in, so "which compiler answered?" (AGENTS.md) is
# decided here and not at the call site.
#
# Prints the resulting wasm path on stdout.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

out="${1:-$ROOT_DIR/_build/cli/vibe-user-cli.wasm}"
case "$out" in /*) ;; *) out="$ROOT_DIR/$out" ;; esac
mkdir -p "$(dirname "$out")"

base="${VIBE_USER_CLI_BASE_COMPILER:-}"
if [ -z "$base" ]; then
  base="$ROOT_DIR/_build/cli/base-compiler.wasm"
  echo "[build-user-cli] building the base compiler (seed -> stage1 -> stage2)" >&2
  bash "$ROOT_DIR/scripts/build_cli_wasm.sh" "$base" >&2
fi
[ -s "$base" ] || { echo "build-user-cli: base compiler not found: $base" >&2; exit 1; }

VIBE_CLI_CORE_OUT_DIR="$(dirname "$out")" \
VIBE_CLI_CORE_REBUILD="${VIBE_USER_CLI_REBUILD:-always}" \
VIBE_CLI_CORE_BASE_COMPILER="$base" \
VIBE_CLI_CORE_STAGE_TIMEOUT_SEC="${VIBE_USER_CLI_STAGE_TIMEOUT_SEC:-900}" \
ENTRY_PATH="$ROOT_DIR/lib/@vibe/cli/main.vibex" \
STAGE1_CORE_WASM="$out" \
  bash "$ROOT_DIR/scripts/build_cli_core.sh" >&2

[ -s "$out" ] || { echo "build-user-cli: artifact not produced: $out" >&2; exit 1; }
magic="$(od -An -t x1 -N 4 "$out" | tr -d ' \n')"
[ "$magic" = "0061736d" ] || { echo "build-user-cli: artifact is not wasm (magic=$magic): $out" >&2; exit 1; }

printf '%s\n' "$out"
