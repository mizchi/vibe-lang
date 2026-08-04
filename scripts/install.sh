#!/usr/bin/env bash
# vibe installer -- toolchain worker (docs/release-roadmap.md テーマ1, #755).
#
# Installs the selfhost vibe toolchain from THIS checkout into a
# rustup-style layout under $VIBE_HOME (default ~/.vibe):
#
#   $VIBE_HOME/bin/vibe                       dispatcher shim (stable PATH
#                                             entry; picks a toolchain)
#   $VIBE_HOME/toolchain                      default toolchain name
#   $VIBE_HOME/toolchains/<name>/bin/{vibe,viberun}
#   $VIBE_HOME/toolchains/<name>/lib/{vibe-cli.wasm,vibe-cli.cwasm,lsp...}
#   $VIBE_HOME/lib/@vibe/{core,ast,parser,wit_runtime}
#                                             stdlib packages, hash-verified
#                                             (the default VIBE_LIB root #751
#                                             -- SHARED across toolchains)
#   $VIBE_HOME/cache/...                        fetch cache (#754 -- shared)
#
# A future `vibe toolchain` selector only has to rewrite $VIBE_HOME/toolchain
# (or set $VIBE_TOOLCHAIN) -- the layout already isolates artifacts per
# toolchain while packages stay content-addressed and shared.
#
# Steps:
#   1. obtain the wasmtime runner `viberun` (build from source by default,
#      or use a prebuilt binary via --runner),
#   2. obtain the portable compiler wasm `vibe-cli.wasm` (fresh build via
#      build_cli_wasm.sh, falling back to the committed seed),
#   3. AOT-compile it to a host-specific `vibe-cli.cwasm`,
#   4. install the launcher into the toolchain + the dispatcher onto PATH,
#   5. materialize the stdlib packages into $VIBE_HOME/lib (hash-verified).
#
# PATH policy: `$VIBE_HOME/bin` (the dispatcher) IS the PATH entry -- the
# installer writes `$VIBE_HOME/env` (rustup's ~/.cargo/env pattern) and, for
# a default-prefix install, appends `. "$HOME/.vibe/env"` to the shell rc
# files (skip with --no-modify-path; custom --prefix installs never touch rc
# files). Symlinking into an extra bin dir is opt-in via --bin-dir /
# VIBE_BIN_DIR (used by the test harness).
#
# Usage:
#   bash scripts/install.sh [--prefix DIR] [--runner PATH] [--cli-wasm PATH]
#                           [--bin-dir DIR] [--no-link] [--no-modify-path]
#                           [--toolchain NAME] [--set-default] [--no-stdlib]
#
# Env overrides: VIBE_HOME, VIBE_BIN_DIR.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VIBE_HOME="${VIBE_HOME:-$HOME/.vibe}"
BIN_DIR="${VIBE_BIN_DIR:-}"
RUNNER_SRC=""
CLI_WASM_SRC=""
DO_LINK=1
DO_STDLIB=1
DO_MODIFY_PATH=1
TOOLCHAIN="main"
SET_DEFAULT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) VIBE_HOME="$2"; shift 2 ;;
    --bin-dir) BIN_DIR="$2"; shift 2 ;;
    --runner) RUNNER_SRC="$2"; shift 2 ;;
    --cli-wasm) CLI_WASM_SRC="$2"; shift 2 ;;
    --toolchain) TOOLCHAIN="$2"; shift 2 ;;
    --set-default) SET_DEFAULT=1; shift ;;
    --no-link) DO_LINK=0; shift ;;
    --no-modify-path) DO_MODIFY_PATH=0; shift ;;
    --no-stdlib) DO_STDLIB=0; shift ;;
    -h|--help) sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Codex review (PR #1162): an explicit --cli-wasm selects a compiler that
# may not match this checkout's HEAD (e.g. an older release artifact) --
# captured BEFORE the compiler-wasm block below can default CLI_WASM_SRC to
# a checkout-matched build, so the context-pack step can tell the two cases
# apart.
CLI_WASM_EXPLICIT=0
[ -n "$CLI_WASM_SRC" ] && CLI_WASM_EXPLICIT=1

say() { echo "[install] $*"; }
die() { echo "[install] error: $*" >&2; exit 1; }

TC_DIR="$VIBE_HOME/toolchains/$TOOLCHAIN"
mkdir -p "$TC_DIR/bin" "$TC_DIR/lib" "$VIBE_HOME/bin" "$VIBE_HOME/lib"

# 1. runner ----------------------------------------------------------------
if [ -z "$RUNNER_SRC" ]; then
  prebuilt="$ROOT_DIR/runtime/viberun/target/release/viberun"
  if [ -x "$prebuilt" ]; then
    RUNNER_SRC="$prebuilt"
    say "using already-built runner: $RUNNER_SRC"
  else
    command -v cargo >/dev/null 2>&1 || die "cargo not found; pass a prebuilt runner with --runner"
    say "building runner (cargo build --release)..."
    ( cd "$ROOT_DIR/runtime/viberun" && cargo build --release >/dev/null )
    RUNNER_SRC="$prebuilt"
  fi
fi
[ -x "$RUNNER_SRC" ] || die "runner not executable: $RUNNER_SRC"
install -m 0755 "$RUNNER_SRC" "$TC_DIR/bin/viberun"
say "runner -> $TC_DIR/bin/viberun"

# 2. compiler wasm ---------------------------------------------------------
# Prefer a freshly built compiler (latest source, incl. diagnostics); fall back
# to the committed seed if the build toolchain/runner is unavailable.
if [ -z "$CLI_WASM_SRC" ]; then
  built=""
  if built="$(bash "$ROOT_DIR/scripts/build_cli_wasm.sh" 2>/dev/null)" && [ -s "$built" ]; then
    CLI_WASM_SRC="$built"
    say "using freshly built compiler wasm: $CLI_WASM_SRC"
  else
    CLI_WASM_SRC="$ROOT_DIR/bootstrap/seed/compiler.wasm"
    say "build unavailable; using committed seed compiler as the CLI wasm"
  fi
fi
[ -f "$CLI_WASM_SRC" ] || die "compiler wasm not found: $CLI_WASM_SRC"
install -m 0644 "$CLI_WASM_SRC" "$TC_DIR/lib/vibe-cli.wasm"
say "compiler wasm -> $TC_DIR/lib/vibe-cli.wasm"

# 3. install-time AOT (.cwasm) --------------------------------------------
say "AOT-compiling host-specific .cwasm..."
"$TC_DIR/bin/viberun" --precompile "$TC_DIR/lib/vibe-cli.wasm" \
  -o "$TC_DIR/lib/vibe-cli.cwasm"
say "AOT compiler -> $TC_DIR/lib/vibe-cli.cwasm"

# 4. launcher + LSP server (toolchain-local artifacts) ---------------------
install -m 0755 "$ROOT_DIR/runtime/vibe" "$TC_DIR/bin/vibe"
say "launcher -> $TC_DIR/bin/vibe"
# `vibe pkg` delegates to vibe_pkg.sh (#805); ship it with the toolchain so
# the package/registry lane works standalone (no checkout needed).
install -m 0644 "$ROOT_DIR/scripts/vibe_pkg.sh" "$TC_DIR/lib/vibe_pkg.sh"
# #1239 step 4(D): the `--jobs=N` process-pool pre-warm. Shipping it is what
# makes `--jobs` more than a no-op in an installed toolchain -- the older node
# driver lives in the dev-repo scripts/ tree only, so `vibe` there printed a
# note and compiled serially. Needs nothing but bash and the installed runner.
install -m 0644 "$ROOT_DIR/scripts/parallel_warm_pool.sh" "$TC_DIR/lib/parallel_warm_pool.sh"
say "pkg tool -> $TC_DIR/lib/vibe_pkg.sh"
if [ -f "$ROOT_DIR/clients/js/lsp_server.js" ]; then
  install -m 0644 "$ROOT_DIR/clients/js/lsp_server.js" "$TC_DIR/lib/lsp_server.js"
  say "lsp server -> $TC_DIR/lib/lsp_server.js"
  # The LSP server requires the workspace symbol/call-hierarchy index alongside
  # it (workspace/symbol + callHierarchy).
  if [ -f "$ROOT_DIR/clients/js/symbol_index.js" ]; then
    install -m 0644 "$ROOT_DIR/clients/js/symbol_index.js" "$TC_DIR/lib/symbol_index.js"
    say "lsp symbol index -> $TC_DIR/lib/symbol_index.js"
  fi
  # Project graph query layer (vibe/graph custom request + dependency graph).
  if [ -f "$ROOT_DIR/clients/js/graph_query.js" ]; then
    install -m 0644 "$ROOT_DIR/clients/js/graph_query.js" "$TC_DIR/lib/graph_query.js"
    say "lsp graph query -> $TC_DIR/lib/graph_query.js"
  fi
fi
# `vibe context-pack` (#820 sub-item 3): a bundled cheatsheet + verified
# golden-example corpus for AI-harness context ingestion. The source
# docs/eval tree isn't shipped with the installed toolchain, so generate
# the bundle once here and ship the result as a toolchain-local asset.
#
# Codex review (PR #1162): this checkout's docs/eval tree only describes
# THIS checkout's compiler. With an explicit --cli-wasm (installing a
# released/older/different compiler than this checkout's HEAD), a pack
# generated from the checkout could describe syntax or APIs the installed
# compiler doesn't actually support -- so skip generating it in that case
# rather than shipping a version-mismatched pack. The default flow (no
# --cli-wasm, CLI_WASM_SRC built from or defaulting to this checkout) is
# unaffected: the pack and the compiler always come from the same source.
if [ "$CLI_WASM_EXPLICIT" = "1" ]; then
  say "skipping context pack (explicit --cli-wasm may not match this checkout's docs/eval)"
elif [ -f "$ROOT_DIR/scripts/gen_context_pack.sh" ]; then
  if bash "$ROOT_DIR/scripts/gen_context_pack.sh" "$ROOT_DIR" > "$TC_DIR/lib/context-pack.md.tmp" 2>/dev/null; then
    mv "$TC_DIR/lib/context-pack.md.tmp" "$TC_DIR/lib/context-pack.md"
    say "context pack -> $TC_DIR/lib/context-pack.md"
  else
    rm -f "$TC_DIR/lib/context-pack.md.tmp"
  fi
fi

# 5. dispatcher + default toolchain ----------------------------------------
cat > "$VIBE_HOME/bin/vibe" <<'DISPATCH'
#!/usr/bin/env bash
# vibe dispatcher (rustup-style, #755): selects a toolchain and execs its
# launcher. Selection order: $VIBE_TOOLCHAIN env > $VIBE_HOME/toolchain file
# > the single installed toolchain. Managed by the installer; a future
# `vibe toolchain` selector rewrites the default file.
set -euo pipefail
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
_self_dir="$(cd -P "$(dirname "$_src")" && pwd)"
VIBE_HOME="${VIBE_HOME:-$(dirname "$_self_dir")}"
tc="${VIBE_TOOLCHAIN:-}"
if [ -z "$tc" ] && [ -f "$VIBE_HOME/toolchain" ]; then
  tc="$(head -n 1 "$VIBE_HOME/toolchain" | tr -d '[:space:]')"
fi
if [ -z "$tc" ]; then
  count=0
  only=""
  for d in "$VIBE_HOME/toolchains"/*/; do
    [ -d "$d" ] || continue
    count=$((count + 1))
    only="$(basename "$d")"
  done
  if [ "$count" = "1" ]; then
    tc="$only"
  else
    echo "vibe: no default toolchain (set \$VIBE_TOOLCHAIN or write $VIBE_HOME/toolchain)" >&2
    exit 1
  fi
fi
launcher="$VIBE_HOME/toolchains/$tc/bin/vibe"
[ -x "$launcher" ] || { echo "vibe: toolchain '$tc' is not installed ($launcher)" >&2; exit 1; }
export VIBE_HOME
exec "$launcher" "$@"
DISPATCH
chmod 0755 "$VIBE_HOME/bin/vibe"
say "dispatcher -> $VIBE_HOME/bin/vibe"
if [ "$SET_DEFAULT" = "1" ] || [ ! -f "$VIBE_HOME/toolchain" ]; then
  printf '%s\n' "$TOOLCHAIN" > "$VIBE_HOME/toolchain"
  say "default toolchain -> $TOOLCHAIN"
fi

# 6. stdlib packages (shared, hash-verified) --------------------------------
# The runtime-relevant standard library is materialized into $VIBE_HOME/lib --
# the default VIBE_LIB resolution root (#751). Verification: the hash of the
# materialized copy must equal the hash of the source package, computed by
# the JUST-INSTALLED toolchain (`vibe hash`, ADR-0063 §5).
if [ "$DO_STDLIB" = "1" ]; then
  # @vibe/wit_runtime is in this list because it is USER-FACING: #1324 removed
  # `Result` from the language, and a WIT-facing fallible export has to import
  # it (docs/effect-wit-mapping.md tells users to). A package documented for
  # users but materialized only in a repo checkout would resolve in dev and
  # fail on an installed toolchain.
  for pkg in @vibe/core @vibe/ast @vibe/parser @vibe/wit_runtime; do
    src="$ROOT_DIR/lib/$pkg"
    [ -f "$src/index.vpkg" ] || [ -f "$src/index.vibei" ] || { say "stdlib $pkg missing in checkout; skipped"; continue; }
    src_hash="$("$TC_DIR/bin/vibe" hash "$src" | awk '/^package /{print $2}')"
    [ -n "$src_hash" ] || die "stdlib hash computation failed for $pkg"
    dest="$VIBE_HOME/lib/$pkg"
    rm -rf "$dest"
    mkdir -p "$dest"
    if [ -f "$src/index.vpkg" ]; then
      cp "$src/index.vpkg" "$dest/"
    else
      cp "$src/index.vibei" "$dest/"
    fi
    for f in "$src"/*.vibe; do
      [ -e "$f" ] || continue
      case "$(basename "$f")" in
        *_test.vibe|*_bench.vibe) ;;
        *) cp "$f" "$dest/" ;;
      esac
    done
    dest_hash="$("$TC_DIR/bin/vibe" hash "$dest" | awk '/^package /{print $2}')"
    if [ "$dest_hash" != "$src_hash" ]; then
      rm -rf "$dest"
      die "stdlib $pkg materialized copy hashes to $dest_hash, source is $src_hash"
    fi
    say "stdlib $pkg -> $dest ($src_hash)"
  done
fi

# 7. PATH setup --------------------------------------------------------------
# $VIBE_HOME/bin (the dispatcher) is THE PATH entry. Write the sourceable env
# file (rustup's ~/.cargo/env pattern) and -- for a default-prefix install
# only -- wire it into the shell rc files. A custom --prefix (tests, throwaway
# installs) never touches the user's rc files.
cat > "$VIBE_HOME/env" <<ENVEOF
#!/bin/sh
# vibe shell setup: prepends the vibe dispatcher dir to PATH.
# Wired into your shell rc by the installer; load manually with
#   . "$VIBE_HOME/env"
case ":\${PATH}:" in
  *:"$VIBE_HOME/bin":*) ;;
  *) export PATH="$VIBE_HOME/bin:\$PATH" ;;
esac
ENVEOF
chmod 0644 "$VIBE_HOME/env"
say "env file -> $VIBE_HOME/env"

if [ "$DO_MODIFY_PATH" = "1" ] && [ "$VIBE_HOME" = "$HOME/.vibe" ]; then
  env_line=". \"\$HOME/.vibe/env\""
  modified=""
  for rc in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    if ! grep -qsF '.vibe/env' "$rc"; then
      printf '\n%s\n' "$env_line" >> "$rc"
      modified="$modified $(basename "$rc")"
    fi
  done
  if [ -n "$modified" ]; then
    say "PATH: added '. \$HOME/.vibe/env' to:$modified"
    say "restart your shell or run: . \"\$HOME/.vibe/env\""
  else
    say "PATH: shell rc files already source ~/.vibe/env (or none found)"
  fi
else
  case ":$PATH:" in
    *":$VIBE_HOME/bin:"*) ;;
    *) say "PATH: add $VIBE_HOME/bin to PATH (e.g. . \"$VIBE_HOME/env\")" ;;
  esac
fi

# Optional extra symlink dir (test harness / packaging), opt-in only.
if [ "$DO_LINK" = "1" ] && [ -n "$BIN_DIR" ]; then
  mkdir -p "$BIN_DIR"
  ln -sf "$VIBE_HOME/bin/vibe" "$BIN_DIR/vibe"
  say "linked $BIN_DIR/vibe -> $VIBE_HOME/bin/vibe"
fi

say "done. try: vibe version"
