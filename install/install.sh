#!/usr/bin/env bash
# vibe installer (#755) -- public curl entry point and checkout installer.
#
#   curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/install/install.sh | bash
#
# With no checkout, this script fetches VIBE_INSTALL_REPO at VIBE_INSTALL_REF
# into a temporary directory and safely reinvokes the matching installer from
# that checkout. When run from a checkout, it installs that checkout directly.
#
# The installed rustup-style layout under VIBE_HOME (default ~/.vibe) is:
#
#   $VIBE_HOME/bin/vibe                       stable dispatcher
#   $VIBE_HOME/toolchain                      default toolchain name
#   $VIBE_HOME/toolchains/<name>/bin/{vibe,viberun}
#   $VIBE_HOME/toolchains/<name>/lib/{vibe-cli.wasm,vibe-cli.cwasm,lsp...}
#   $VIBE_HOME/lib/@vibe/{core,ast,parser,prelude,wit_runtime}
#   $VIBE_HOME/cache/...
#
# Usage:
#   bash install/install.sh [--repo URL] [--ref REF] [--prefix DIR]
#       [--runner PATH] [--cli-wasm PATH] [--bin-dir DIR] [--no-link]
#       [--no-modify-path] [--toolchain NAME] [--set-default] [--no-stdlib]
#
# Curl arguments follow `bash -s --`, for example:
#   curl -fsSL URL | bash -s -- --ref v1.0.0 --no-modify-path
#
# Env overrides: VIBE_INSTALL_REPO, VIBE_INSTALL_REF, VIBE_HOME, VIBE_BIN_DIR.
# Requirements: git and bash; Node.js unless --cli-wasm supplies the compiler;
# cargo unless --runner points to a prebuilt runner.
set -euo pipefail

usage() {
  cat <<'USAGE'
vibe installer

Usage:
  bash install/install.sh [--repo URL] [--ref REF] [install options]
  curl -fsSL URL | bash -s -- [--repo URL] [--ref REF] [install options]

Bootstrap options:
  --repo URL             source repository (or VIBE_INSTALL_REPO)
  --ref REF              source ref and default toolchain name (or VIBE_INSTALL_REF)

Install options:
  --prefix DIR           VIBE_HOME (default ~/.vibe)
  --runner PATH          prebuilt viberun executable
  --cli-wasm PATH        portable compiler wasm
  --bin-dir DIR          optional extra symlink directory
  --toolchain NAME       installed toolchain name
  --set-default          select this toolchain as default
  --no-link              do not create an extra bin-dir symlink
  --no-modify-path       do not edit shell startup files
  --no-stdlib            do not install standard library packages

Requirements:
  Git and Bash; Node.js unless --cli-wasm supplies the compiler; Cargo unless
  --runner supplies a prebuilt viberun executable.
USAGE
}

bootstrap_die() { echo "[vibe-installer] error: $*" >&2; exit 1; }
bootstrap_say() { echo "[vibe-installer] $*"; }

# The private root argument is emitted only by the bootstrap half below. It
# makes reinvocation explicit and avoids trusting BASH_SOURCE after curl|bash.
if [ "${1:-}" = "--__vibe-install-root" ]; then
  [ "$#" -ge 2 ] || bootstrap_die "missing checkout root"
  ROOT_DIR="$2"
  shift 2
  ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"
  [ -f "$ROOT_DIR/install/install.sh" ] || bootstrap_die "invalid checkout root: $ROOT_DIR"
  [ -f "$ROOT_DIR/bootstrap/seed.json" ] || bootstrap_die "checkout has no seed manifest: $ROOT_DIR"
else
  REPO="${VIBE_INSTALL_REPO:-https://github.com/mizchi/vibe-lang}"
  REF="${VIBE_INSTALL_REF:-main}"
  passthrough=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)
        [ "$#" -ge 2 ] || bootstrap_die "--repo requires a value"
        REPO="$2"; shift 2 ;;
      --ref)
        [ "$#" -ge 2 ] || bootstrap_die "--ref requires a value"
        REF="$2"; shift 2 ;;
      --) shift; passthrough+=("$@"); break ;;
      -h|--help) usage; exit 0 ;;
      *) passthrough+=("$1"); shift ;;
    esac
  done

  SRC_DIR=""
  script_source="${BASH_SOURCE[0]:-}"
  if [ -n "$script_source" ] && [ "$script_source" != "-" ] && [ -f "$script_source" ]; then
    candidate="$(cd "$(dirname "$script_source")/.." && pwd)"
    if [ -f "$candidate/install/install.sh" ] && [ -f "$candidate/bootstrap/seed.json" ]; then
      SRC_DIR="$candidate"
    fi
  fi
  if [ -z "$SRC_DIR" ] && [ -f "$PWD/install/install.sh" ] && [ -f "$PWD/bootstrap/seed.json" ]; then
    SRC_DIR="$PWD"
  fi

  case "$REF" in
    ""|-*) bootstrap_die "invalid ref '$REF'" ;;
  esac

  work=""
  if [ -n "$SRC_DIR" ]; then
    bootstrap_say "installing from the current checkout: $SRC_DIR (ref selection ignored)"
  else
    command -v git >/dev/null 2>&1 || bootstrap_die "git is required"
    work="$(mktemp -d "${TMPDIR:-/tmp}/vibe-install-XXXXXX")"
    cleanup_bootstrap() { rm -rf -- "$work"; }
    trap cleanup_bootstrap EXIT
    trap 'exit 130' HUP INT TERM
    bootstrap_say "fetching $REPO @ $REF..."
    git init -q "$work/src" || bootstrap_die "cannot initialize temporary checkout"
    git -C "$work/src" remote add origin "$REPO" \
      || bootstrap_die "cannot configure source repository: $REPO"
    # Fetch the exact requested object instead of using clone --branch. Besides
    # branches and tags, this supports a reachable commit SHA without checking
    # out a moving branch tip.
    git -C "$work/src" fetch -q --depth 1 origin "$REF" \
      || bootstrap_die "fetch failed: $REPO @ $REF"
    git -C "$work/src" checkout -q --detach FETCH_HEAD \
      || bootstrap_die "checkout failed: $REPO @ $REF"
    SRC_DIR="$work/src"
  fi

  # A ref can contain path separators and other punctuation that cannot be
  # used as a toolchain directory name. Preserve readable ASCII components and
  # map every other byte to '-'; the install half validates the result again.
  TOOLCHAIN="$(printf '%s' "$REF" | sed 's/[^A-Za-z0-9._-]/-/g')"
  [ -n "$TOOLCHAIN" ] || TOOLCHAIN="ref"
  bootstrap_say "installing toolchain '$TOOLCHAIN'..."
  bash "$SRC_DIR/install/install.sh" --__vibe-install-root "$SRC_DIR" \
    --toolchain "$TOOLCHAIN" "${passthrough[@]}"
  exit $?
fi

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

# The seed wasm is a fetched/build cache rather than a tracked checkout file.
# Both fresh compilation and seed acquisition use the Node bootstrap runner, so
# do not pretend a default install can continue without Node. An explicitly
# supplied compiler wasm remains a fully supported Node-free install path.
if [ "$CLI_WASM_EXPLICIT" = "0" ] && ! command -v node >/dev/null 2>&1; then
  die "Node.js is required to acquire or build the compiler; install Node.js or pass --cli-wasm PATH"
fi

validate_toolchain_name() {
  case "$1" in
    ""|.|..|*[!A-Za-z0-9._-]*)
      die "invalid toolchain name '$1'; use one nonempty ASCII component containing only letters, digits, '.', '_', or '-'"
      ;;
  esac
}

validate_toolchain_name "$TOOLCHAIN"
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
case "$tc" in
  ""|.|..|*[!A-Za-z0-9._-]*)
    echo "vibe: invalid toolchain name '$tc'" >&2
    exit 1
    ;;
esac
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
  # it (docs/effect-wit-mapping.md tells users to). @vibe/builtin is the same
  # class (#1949) -- the book imports `Int::abs` and friends from it.
  # @vibe/console joins them in #2102: it is now where the tty surface lives
  # (`read_line`, `eprintln`, `tap`, the `tui_*` helpers), so it is documented
  # for users. A package documented for users but materialized only in a repo
  # checkout would resolve in dev and fail on an installed toolchain -- which
  # is exactly what tests/integration/install/install_test.sh probes.
  for pkg in @vibe/core @vibe/ast @vibe/parser @vibe/builtin @vibe/console @vibe/wit_runtime; do
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
# Emit one POSIX-shell single-quoted word. Prefixes may contain whitespace,
# quotes, command substitutions, or newlines; sourcing the generated file must
# always treat those bytes as path data rather than shell syntax.
shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}
{
  cat <<'ENV_HEAD'
#!/bin/sh
# vibe shell setup: prepends the vibe dispatcher dir to PATH.
# Wired into your shell rc by the installer.
_vibe_bin=
ENV_HEAD
  printf '_vibe_bin='
  shell_quote "$VIBE_HOME/bin"
  printf '\n'
  cat <<'ENV_TAIL'
case ":${PATH}:" in
  *:"${_vibe_bin}":*) ;;
  *) PATH="${_vibe_bin}:${PATH}"; export PATH ;;
esac
unset _vibe_bin
ENV_TAIL
} > "$VIBE_HOME/env"
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
