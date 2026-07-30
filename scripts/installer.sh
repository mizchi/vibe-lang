#!/usr/bin/env bash
# vibe curl installer (#755) -- the `curl | bash` entry point.
#
#   curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/scripts/installer.sh | bash
#
# Obtains a vibe-lang source tree (a shallow git clone unless it is already
# running inside a checkout) and delegates to scripts/install.sh, which lays
# down the rustup-style toolchain layout under ~/.vibe:
#
#   ~/.vibe/bin/vibe                    dispatcher (put this dir -- or the
#                                       --bin-dir symlink -- on PATH)
#   ~/.vibe/toolchains/<name>/...         compiler wasm + runner + launcher
#   ~/.vibe/lib/@vibe/{core,ast,parser} stdlib packages (hash-verified;
#                                       the default VIBE_LIB root)
#   ~/.vibe/cache/...                     package fetch cache
#
# The toolchain name defaults to the installed ref, so a future rustup-like
# selector can install several refs side by side and flip
# ~/.vibe/toolchain (or $VIBE_TOOLCHAIN).
#
# Env knobs:
#   VIBE_INSTALL_REPO   git URL      (default https://github.com/mizchi/vibe-lang)
#   VIBE_INSTALL_REF    ref to install (default main)
#   VIBE_HOME           install root (default ~/.vibe)
#   VIBE_BIN_DIR        symlink dir  (default ~/.local/bin)
#
# Everything after `--` is passed through to install.sh
# (e.g. `bash installer.sh -- --runner /path/to/viberun`).
#
# Requirements: git, bash; cargo (to build the wasmtime runner from source)
# unless a prebuilt runner is passed through; node is optional (used to
# freshly self-build the compiler -- without it the committed seed compiler
# wasm is installed, which is always functional).
set -euo pipefail

REPO="${VIBE_INSTALL_REPO:-https://github.com/mizchi/vibe-lang}"
REF="${VIBE_INSTALL_REF:-main}"

say() { echo "[vibe-installer] $*"; }
die() { echo "[vibe-installer] error: $*" >&2; exit 1; }

passthrough=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --) shift; passthrough=("$@"); break ;;
    -h|--help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (pass install.sh flags after --)" ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git is required"

# When already inside a vibe-lang checkout (developer flow), install from it
# directly. The pipe flow (`curl | bash`) has no checkout -- clone one.
SRC_DIR=""
if [ -f "scripts/install.sh" ] && [ -f "bootstrap/seed/compiler.wasm" ]; then
  SRC_DIR="$(pwd)"
  say "installing from the current checkout: $SRC_DIR (ref flags ignored)"
else
  work="$(mktemp -d "${TMPDIR:-/tmp}/vibe-install-XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  say "cloning $REPO @ $REF..."
  git clone -q --depth 1 --branch "$REF" "$REPO" "$work/src" \
    || die "clone failed: $REPO @ $REF"
  SRC_DIR="$work/src"
fi

# Toolchain name = the installed ref (slashes flattened), so several refs can
# coexist under ~/.vibe/toolchains and a selector can flip between them.
TOOLCHAIN="$(printf '%s' "$REF" | tr '/' '-')"

say "installing toolchain '$TOOLCHAIN'..."
bash "$SRC_DIR/scripts/install.sh" --toolchain "$TOOLCHAIN" ${passthrough[@]+"${passthrough[@]}"}
