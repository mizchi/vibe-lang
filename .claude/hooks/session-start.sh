#!/usr/bin/env bash
#
# SessionStart hook for Claude Code on the web.
#
# Provisions the toolchain that vibe's build / test / bench gates need but that
# is NOT reliably on PATH in a fresh remote container. Guiding principle: install
# the SAME toolchain CI uses (.github/actions/setup-vibe) so a web session
# reproduces CI and can build the current source.
#
# Steps (one setup_* function each, run from main at the bottom):
#   1. nix       — already installed under ~/.nix-profile, just not on PATH.
#   2. moon      — MoonBit. ~/.moon if pre-baked, else scripts/install_moonbit.sh
#                  (official CDN "latest", identical to CI). The CDN cannot serve
#                  pinned versions, so the project tracks latest by design — do
#                  NOT substitute a frozen nix pin, it would be too stale to build
#                  the current source.
#      + deps     — fetch moon.mod deps into .mooncakes (moon update + check).
#      + wasm-opt — expose MoonBit's bundled binaryen for dist optimization.
#   3. wasmtime  — scripts/install_wasmtime_release.sh (version pinned in-script).
#   4. pkf       — pkfire task runner; nix install pinned to v0.10.0, as CI uses.
#
# Each tool's location is persisted into $CLAUDE_ENV_FILE so every subsequent
# Bash tool invocation resolves it on PATH. A final verification gate exits
# non-zero if a required tool is missing, so a half-provisioned environment fails
# loudly instead of surfacing later as confusing build errors.
#
# The hook is idempotent and non-interactive.

set -euo pipefail

# Only run in the remote (Claude Code on the web) environment. Local sessions
# manage their own toolchains. Override by exporting CLAUDE_CODE_REMOTE=true.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

readonly PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)}"
readonly ENV_FILE="${CLAUDE_ENV_FILE:-/dev/null}"
readonly CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
readonly NIX="$HOME/.nix-profile/bin/nix"
readonly MOON_BIN="$HOME/.moon/bin"
readonly WASMTIME_DIR="$HOME/.wasmtime"
readonly PKF_PROFILE="$HOME/.nix-profiles/pkfire"

# =============================================================== helpers ====

log()  { echo "[session-start] $*"; }
warn() { echo "[session-start] WARNING: $*" >&2; }

# Persist `export <line>` to the session env file once (idempotent) and apply it
# to the current hook shell so later install/verify steps can resolve the tool.
persist_env() {
  local line="$1"
  if [ "$ENV_FILE" != "/dev/null" ] && ! grep -qsF -- "$line" "$ENV_FILE"; then
    printf 'export %s\n' "$line" >> "$ENV_FILE"
  fi
  export "${line?}"
}

# retry <max> <description> <cmd...> — run cmd with exponential backoff (2,4,8…).
# Returns cmd's status; warns (non-fatal) after the last attempt.
retry() {
  local max="$1" desc="$2"; shift 2
  local n=1 delay=2
  while true; do
    if "$@"; then return 0; fi
    if [ "$n" -ge "$max" ]; then
      warn "$desc failed after ${max} attempts"
      return 1
    fi
    log "$desc failed (attempt ${n}/${max}); retrying in ${delay}s..." >&2
    sleep "$delay"; delay=$((delay * 2)); n=$((n + 1))
  done
}

# True when PROJECT_DIR is a MoonBit module.
is_moon_project() {
  [ -f "$PROJECT_DIR/moon.mod" ] || [ -f "$PROJECT_DIR/moon.mod.json" ]
}

# ================================================================ steps =====

# 1. nix — already installed under ~/.nix-profile, just not on PATH here.
setup_nix() {
  local nix_sh="$HOME/.nix-profile/etc/profile.d/nix.sh"
  if [ -x "$NIX" ]; then
    persist_env "PATH=$HOME/.nix-profile/bin:$PATH"
    # nix needs a CA bundle for fetching; mirror what nix.sh sets up.
    if [ -e "$CA_BUNDLE" ]; then
      persist_env "NIX_SSL_CERT_FILE=$CA_BUNDLE"
    fi
    log "nix: $("$NIX" --version)"
  elif [ -f "$nix_sh" ]; then
    # Fallback: defer to nix's own profile script for PATH setup.
    if [ "$ENV_FILE" != "/dev/null" ] && ! grep -qsF "$nix_sh" "$ENV_FILE"; then
      printf '. %s\n' "$nix_sh" >> "$ENV_FILE"
    fi
    # shellcheck disable=SC1090
    . "$nix_sh"
    log "nix initialized via profile script"
  else
    warn "nix not found under ~/.nix-profile"
  fi
  return 0
}

# 2. moon — install the CDN "latest" toolchain CI uses when ~/.moon is absent.
# install_moonbit.sh has internal retries, runs `moon update`, and stamps
# .moon-version (gitignored).
setup_moon() {
  if [ ! -x "$MOON_BIN/moon" ]; then
    log "installing moonbit via scripts/install_moonbit.sh ..."
    MOONBIT_INSTALL_DIR="$HOME/.moon" bash "$PROJECT_DIR/scripts/install_moonbit.sh" \
      || warn "install_moonbit.sh failed"
  fi
  if [ -x "$MOON_BIN/moon" ]; then
    persist_env "PATH=$MOON_BIN:$PATH"
    log "moon: $("$MOON_BIN/moon" version 2>/dev/null)"
  else
    warn "moon not found under ~/.moon/bin"
  fi
  return 0
}

# 2 (deps) — populate .mooncakes. A fresh clone has none, and even a pre-baked
# ~/.moon can carry a stale registry index (deps fail "module not found").
# Best-effort: a transient network failure must not abort the session.
setup_moon_deps() {
  if [ ! -x "$MOON_BIN/moon" ] || ! is_moon_project; then
    return 0
  fi
  if [ ! -d "$PROJECT_DIR/.mooncakes" ]; then
    log "fetching MoonBit deps (moon update + check) ..."
    ( cd "$PROJECT_DIR" && retry 3 "moon update" "$MOON_BIN/moon" update ) || true
    # `moon check` resolves and downloads the moon.mod deps into .mooncakes (the
    # non-deprecated path — bare `moon install` is deprecated) and doubles as a
    # build smoke test. Output suppressed; status reported below.
    fetch_deps() { ( cd "$PROJECT_DIR" && "$MOON_BIN/moon" check >/dev/null 2>&1 ); }
    retry 3 "moon check" fetch_deps || true
  fi
  if [ -d "$PROJECT_DIR/.mooncakes" ]; then
    log "MoonBit deps present (.mooncakes)"
  else
    warn ".mooncakes missing — deps not fetched"
  fi
  return 0
}

# 2 (wasm-opt) — dist optimization (scripts/build_selfhost_dist.sh) calls
# `wasm-opt`. MoonBit bundles binaryen as `moon-wasm-opt`; expose it under the
# expected name when no standalone wasm-opt is on PATH (~/.local/bin is on PATH).
setup_wasm_opt() {
  if [ -x "$MOON_BIN/moon-wasm-opt" ] && ! command -v wasm-opt >/dev/null 2>&1; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$MOON_BIN/moon-wasm-opt" "$HOME/.local/bin/wasm-opt"
    persist_env "PATH=$HOME/.local/bin:$PATH"
    log "wasm-opt -> $MOON_BIN/moon-wasm-opt"
  fi
  return 0
}

# 3. wasmtime — repo helpers locate it via `command -v wasmtime`, so putting
# ~/.wasmtime/bin on PATH is what makes the wasm gates work.
setup_wasmtime() {
  local bin="$WASMTIME_DIR/bin/wasmtime"
  if [ ! -x "$bin" ] && ! command -v wasmtime >/dev/null 2>&1; then
    log "installing wasmtime ..."
    retry 3 "wasmtime install" \
      env WASMTIME_INSTALL_DIR="$WASMTIME_DIR" bash "$PROJECT_DIR/scripts/install_wasmtime_release.sh" \
      || true
  fi
  if [ -x "$bin" ]; then
    persist_env "PATH=$WASMTIME_DIR/bin:$PATH"
    log "wasmtime: $("$bin" --version)"
  elif command -v wasmtime >/dev/null 2>&1; then
    log "wasmtime: $(wasmtime --version) (system PATH)"
  else
    warn "wasmtime install failed"
  fi
  return 0
}

# 4. pkf — canonical task runner (Taskfile.pkl), not in nixpkgs, so install from
# the upstream flake pinned to the tag CI uses (mizchi/pkfire@v0.10.0). The
# github: fetcher hits the rate-limited GitHub API; git+https works unauthed.
#
# Install into a DEDICATED profile, never the default one: ~/.nix-profile is
# classic-managed and holds `nix` itself; `nix profile install` there would start
# a fresh manifest and drop `nix` from PATH.
setup_pkf() {
  local bin="$PKF_PROFILE/bin/pkf"
  if [ -x "$NIX" ] && [ ! -x "$bin" ]; then
    log "installing pkfire (pkf) via nix ..."
    # nix builds Go modules without a sandbox here; a stale /homeless-shelter
    # breaks the purity check, so clear it first.
    rm -rf /homeless-shelter 2>/dev/null || true
    mkdir -p "$(dirname "$PKF_PROFILE")"
    retry 3 "pkf install" \
      "$NIX" profile install --profile "$PKF_PROFILE" \
      'git+https://github.com/mizchi/pkfire?ref=refs/tags/v0.10.0' \
      --extra-experimental-features 'nix-command flakes' \
      || true
  fi
  if [ ! -x "$bin" ]; then
    return 0  # verification gate reports the failure
  fi
  persist_env "PATH=$PKF_PROFILE/bin:$PATH"
  log "pkf installed: $bin"
  warm_pkl_cache "$bin"
  install_pkf_hooks "$bin"
  return 0
}

# pkf evaluates Taskfile.pkl via a bundled `pkl` that fetches the pkfire Pkl
# package over HTTPS. The bundled JDK truststore can't verify pkg.pkl-lang.org,
# so warm the cache once with the system CA bundle; afterwards pkf resolves from
# ~/.pkl/cache without --ca-certificates.
warm_pkl_cache() {
  local pkf_bin="$1" pkl_dir
  pkl_dir="$(grep -oE '/nix/store/[a-z0-9]+-pkl-[0-9.]+/bin' "$pkf_bin" 2>/dev/null | head -1 || true)"
  if [ -z "$pkl_dir" ] || [ ! -x "$pkl_dir/pkl" ] \
    || [ ! -f "$PROJECT_DIR/Taskfile.pkl" ] || [ ! -e "$CA_BUNDLE" ]; then
    return 0
  fi
  if retry 3 "pkl cache warm" \
    "$pkl_dir/pkl" eval --ca-certificates="$CA_BUNDLE" "$PROJECT_DIR/Taskfile.pkl" >/dev/null 2>&1; then
    log "pkl package cache warmed"
  else
    warn "pkl cache warm failed (run pkf with pkl --ca-certificates)"
  fi
  return 0
}

# Install the pkfire-managed git hooks (e.g. the pre-commit `moon fmt` task) so
# commits in this fresh clone land formatted. Best-effort; .git/hooks isn't
# version-controlled.
install_pkf_hooks() {
  local pkf_bin="$1"
  if [ -d "$PROJECT_DIR/.git" ] && [ -f "$PROJECT_DIR/Taskfile.pkl" ]; then
    if ( cd "$PROJECT_DIR" && "$pkf_bin" hooks install >/dev/null 2>&1 ); then
      log "pkf git hooks installed"
    fi
  fi
  return 0
}

# 5. verification gate — fail loudly if a required tool did not land on PATH,
# instead of letting the session proceed half-provisioned. Optional tools warn.
verify_toolchain() {
  local fail=0
  check() {
    local kind="$1" name="$2" ver_cmd="$3"
    if command -v "$name" >/dev/null 2>&1; then
      log "ok: $name — $(eval "$ver_cmd" 2>/dev/null | head -1)"
    elif [ "$kind" = required ]; then
      echo "[session-start] MISSING (required): $name" >&2
      fail=1
    else
      echo "[session-start] WARNING (optional): $name not found" >&2
    fi
  }
  check required moon "moon version"
  check required moonc "moonc -v"
  check required moonrun "moonrun --version"
  check required wasmtime "wasmtime --version"
  check required pkf "pkf --version"
  check optional wasm-opt "wasm-opt --version"
  if [ "$fail" = 1 ]; then
    echo "[session-start] toolchain verification FAILED — required tools missing (see above)" >&2
    return 1
  fi
  return 0
}

# ================================================================= main =====

setup_nix
setup_moon
setup_moon_deps
setup_wasm_opt
setup_wasmtime
setup_pkf

if verify_toolchain; then
  log "toolchain init complete"
else
  exit 1
fi
