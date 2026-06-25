#!/usr/bin/env bash
# vibe installer (docs/release-roadmap.md テーマ1).
#
# Installs the selfhost vibe toolchain into $VIBE_HOME (default ~/.vibe):
#   1. obtain the wasmtime runner `moonrun_wt` (build from source by default,
#      or use a prebuilt binary via --runner),
#   2. obtain the portable compiler wasm `vibe-cli.wasm` (the committed seed by
#      default, or any artifact via --cli-wasm),
#   3. AOT-compile the compiler wasm to a host-specific `vibe-cli.cwasm`,
#   4. install the `vibe` launcher and link it onto PATH.
#
# Usage:
#   bash scripts/install.sh [--prefix DIR] [--runner PATH] [--cli-wasm PATH]
#                           [--bin-dir DIR] [--no-link]
#
# Env overrides: VIBE_HOME, VIBE_BIN_DIR.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VIBE_HOME="${VIBE_HOME:-$HOME/.vibe}"
BIN_DIR="${VIBE_BIN_DIR:-$HOME/.local/bin}"
RUNNER_SRC=""
CLI_WASM_SRC=""
DO_LINK=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) VIBE_HOME="$2"; shift 2 ;;
    --bin-dir) BIN_DIR="$2"; shift 2 ;;
    --runner) RUNNER_SRC="$2"; shift 2 ;;
    --cli-wasm) CLI_WASM_SRC="$2"; shift 2 ;;
    --no-link) DO_LINK=0; shift ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { echo "[install] $*"; }
die() { echo "[install] error: $*" >&2; exit 1; }

mkdir -p "$VIBE_HOME/bin" "$VIBE_HOME/lib"

# 1. runner ----------------------------------------------------------------
if [ -z "$RUNNER_SRC" ]; then
  prebuilt="$ROOT_DIR/tools/moonrun_wasmtime/target/release/moonrun_wt"
  if [ -x "$prebuilt" ]; then
    RUNNER_SRC="$prebuilt"
    say "using already-built runner: $RUNNER_SRC"
  else
    command -v cargo >/dev/null 2>&1 || die "cargo not found; pass a prebuilt runner with --runner"
    say "building runner (cargo build --release)…"
    ( cd "$ROOT_DIR/tools/moonrun_wasmtime" && cargo build --release >/dev/null )
    RUNNER_SRC="$prebuilt"
  fi
fi
[ -x "$RUNNER_SRC" ] || die "runner not executable: $RUNNER_SRC"
install -m 0755 "$RUNNER_SRC" "$VIBE_HOME/bin/moonrun_wt"
say "runner -> $VIBE_HOME/bin/moonrun_wt"

# 2. compiler wasm ---------------------------------------------------------
# Prefer a freshly built compiler (latest source, incl. diagnostics); fall back
# to the committed seed if the build toolchain/runner is unavailable.
if [ -z "$CLI_WASM_SRC" ]; then
  built=""
  if built="$(bash "$ROOT_DIR/scripts/build_cli_wasm.sh" 2>/dev/null)" && [ -s "$built" ]; then
    CLI_WASM_SRC="$built"
    say "using freshly built compiler wasm: $CLI_WASM_SRC"
  else
    CLI_WASM_SRC="$ROOT_DIR/bootstrap/selfhost/seed/selfhost_compiler.wasm"
    say "build unavailable; using committed seed compiler as the CLI wasm"
  fi
fi
[ -f "$CLI_WASM_SRC" ] || die "compiler wasm not found: $CLI_WASM_SRC"
install -m 0644 "$CLI_WASM_SRC" "$VIBE_HOME/lib/vibe-cli.wasm"
say "compiler wasm -> $VIBE_HOME/lib/vibe-cli.wasm"

# 3. install-time AOT (.cwasm) --------------------------------------------
say "AOT-compiling host-specific .cwasm…"
"$VIBE_HOME/bin/moonrun_wt" --precompile "$VIBE_HOME/lib/vibe-cli.wasm" \
  -o "$VIBE_HOME/lib/vibe-cli.cwasm"
say "AOT compiler -> $VIBE_HOME/lib/vibe-cli.cwasm"

# 4. launcher + LSP server -------------------------------------------------
install -m 0755 "$ROOT_DIR/runtime/vibe" "$VIBE_HOME/bin/vibe"
say "launcher -> $VIBE_HOME/bin/vibe"
if [ -f "$ROOT_DIR/js/vibe/lsp_server.js" ]; then
  install -m 0644 "$ROOT_DIR/js/vibe/lsp_server.js" "$VIBE_HOME/lib/lsp_server.js"
  say "lsp server -> $VIBE_HOME/lib/lsp_server.js"
fi

if [ "$DO_LINK" = "1" ]; then
  mkdir -p "$BIN_DIR"
  ln -sf "$VIBE_HOME/bin/vibe" "$BIN_DIR/vibe"
  say "linked $BIN_DIR/vibe -> $VIBE_HOME/bin/vibe"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) say "note: $BIN_DIR is not on your PATH; add it to use 'vibe' directly" ;;
  esac
fi

say "done. try: vibe version"
