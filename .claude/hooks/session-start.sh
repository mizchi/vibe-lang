#!/usr/bin/env bash
#
# SessionStart hook for Claude Code on the web.
#
# Provisions the toolchains that vibe's build / test / bench gates need but that
# are NOT reliably on PATH in a fresh remote container. The guiding principle is
# to install the SAME toolchain CI uses (.github/actions/setup-vibe), so a web
# session reproduces CI behavior and can build the current source:
#
#   1. nix       (already installed under ~/.nix-profile, just not on PATH)
#   2. moon      (MoonBit; ~/.moon if pre-baked, else scripts/install_moonbit.sh
#                 — the official CDN "latest", identical to CI. The CDN cannot
#                 serve pinned versions, so the project tracks latest by design;
#                 do NOT substitute a frozen nix pin here, it will be too stale
#                 to build the current source.) Also fetches project deps into
#                 .mooncakes (moon update + check) so the first build works.
#   3. wasmtime  (scripts/install_wasmtime_release.sh — version pinned in-script)
#   4. pkf       (pkfire task runner; nix install pinned to v0.10.0, as CI uses)
#
# Each tool's location is persisted into $CLAUDE_ENV_FILE so every subsequent
# Bash tool invocation resolves it on PATH. After provisioning, a verification
# gate asserts the required tools resolve and exits non-zero if any are missing,
# so a half-provisioned environment fails loudly instead of surfacing later as
# confusing build errors.
#
# The hook is idempotent and non-interactive.

set -euo pipefail

# Only run in the remote (Claude Code on the web) environment. Local sessions
# manage their own toolchains. Override by exporting CLAUDE_CODE_REMOTE=true.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)}"
ENV_FILE="${CLAUDE_ENV_FILE:-/dev/null}"

# Append `export <line>` to the session env file once (idempotent).
persist_env() {
  local line="$1"
  if [ "$ENV_FILE" = "/dev/null" ]; then
    return 0
  fi
  if ! grep -qsF -- "$line" "$ENV_FILE"; then
    printf 'export %s\n' "$line" >> "$ENV_FILE"
  fi
  # Also apply to the current hook shell so the install/verify steps below work.
  export "${line?}"
}

# retry <max> <description> <cmd...> — run cmd with exponential backoff (2,4,8…).
# Returns the command's status; emits a WARNING (not fatal) after the last try so
# the verification gate can decide what is actually required.
retry() {
  local max="$1" desc="$2"
  shift 2
  local n=1 delay=2
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "$n" -ge "$max" ]; then
      echo "[session-start] WARNING: $desc failed after ${max} attempts" >&2
      return 1
    fi
    echo "[session-start] $desc failed (attempt ${n}/${max}); retrying in ${delay}s..." >&2
    sleep "$delay"
    delay=$((delay * 2))
    n=$((n + 1))
  done
}

# --- 1. nix --------------------------------------------------------------
NIX_PROFILE_BIN="$HOME/.nix-profile/bin"
NIX_PROFILE_SH="$HOME/.nix-profile/etc/profile.d/nix.sh"
if [ -x "$NIX_PROFILE_BIN/nix" ]; then
  persist_env "PATH=$NIX_PROFILE_BIN:$PATH"
  # nix needs a CA bundle for fetching; mirror what nix.sh sets up.
  if [ -e /etc/ssl/certs/ca-certificates.crt ]; then
    persist_env "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
  fi
  echo "[session-start] nix: $("$NIX_PROFILE_BIN/nix" --version)"
elif [ -f "$NIX_PROFILE_SH" ]; then
  # Fallback: defer to nix's own profile script for PATH setup.
  if [ "$ENV_FILE" != "/dev/null" ] && ! grep -qsF "$NIX_PROFILE_SH" "$ENV_FILE"; then
    printf '. %s\n' "$NIX_PROFILE_SH" >> "$ENV_FILE"
  fi
  # shellcheck disable=SC1090
  . "$NIX_PROFILE_SH"
  echo "[session-start] nix initialized via profile script"
else
  echo "[session-start] WARNING: nix not found under ~/.nix-profile" >&2
fi

# --- 2. moonbit (moon) ---------------------------------------------------
# Use ~/.moon if the image pre-baked it (the common, fast path); otherwise
# install via scripts/install_moonbit.sh — the exact installer CI's setup-vibe
# action uses (official CDN "latest", with internal retries). This keeps the
# web toolchain identical to CI. install_moonbit.sh also runs `moon update`
# (fetches core) and stamps .moon-version (gitignored).
MOON_BIN="$HOME/.moon/bin"
if ! [ -x "$MOON_BIN/moon" ]; then
  echo "[session-start] installing moonbit via scripts/install_moonbit.sh ..."
  MOONBIT_INSTALL_DIR="$HOME/.moon" bash "$PROJECT_DIR/scripts/install_moonbit.sh" \
    || echo "[session-start] WARNING: install_moonbit.sh failed" >&2
fi
if [ -x "$MOON_BIN/moon" ]; then
  persist_env "PATH=$MOON_BIN:$PATH"
  echo "[session-start] moon: $("$MOON_BIN/moon" version 2>/dev/null)"
else
  echo "[session-start] WARNING: moon not found under ~/.moon/bin" >&2
fi

# --- 2b. project dependencies (.mooncakes) -------------------------------
# A fresh clone has no .mooncakes, and even a pre-baked ~/.moon can carry a
# stale registry index (deps fail with "module not found"). Refresh the index
# (moon update) and fetch the deps declared in moon.mod (moon install) so the
# first check/build/test in the session works. Best-effort: a transient network
# failure here should not abort the whole session (the build will surface it).
if [ -x "$MOON_BIN/moon" ] \
  && { [ -f "$PROJECT_DIR/moon.mod" ] || [ -f "$PROJECT_DIR/moon.mod.json" ]; } \
  && [ ! -d "$PROJECT_DIR/.mooncakes" ]; then
  echo "[session-start] fetching MoonBit deps (moon update + check) ..."
  ( cd "$PROJECT_DIR" && retry 3 "moon update" "$MOON_BIN/moon" update ) || true
  # `moon check` resolves and downloads the deps declared in moon.mod into
  # .mooncakes (the non-deprecated path — bare `moon install` is deprecated) and
  # doubles as a build smoke test. Output is suppressed; the status line below
  # reports whether .mooncakes ended up present.
  moon_fetch_deps() { ( cd "$PROJECT_DIR" && "$MOON_BIN/moon" check >/dev/null 2>&1 ); }
  retry 3 "moon check" moon_fetch_deps || true
fi
if [ -x "$MOON_BIN/moon" ] \
  && { [ -f "$PROJECT_DIR/moon.mod" ] || [ -f "$PROJECT_DIR/moon.mod.json" ]; }; then
  if [ -d "$PROJECT_DIR/.mooncakes" ]; then
    echo "[session-start] MoonBit deps present (.mooncakes)"
  else
    echo "[session-start] WARNING: .mooncakes missing — deps not fetched" >&2
  fi
fi

# wasm-opt: dist optimization (scripts/build_selfhost_dist.sh) calls `wasm-opt`.
# MoonBit bundles binaryen as `moon-wasm-opt`; expose it under the expected name
# when no standalone wasm-opt is on PATH. ~/.local/bin is writable and on PATH.
if [ -x "$MOON_BIN/moon" ] && ! command -v wasm-opt >/dev/null 2>&1; then
  if [ -x "$MOON_BIN/moon-wasm-opt" ]; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$MOON_BIN/moon-wasm-opt" "$HOME/.local/bin/wasm-opt"
    persist_env "PATH=$HOME/.local/bin:$PATH"
    echo "[session-start] wasm-opt -> $MOON_BIN/moon-wasm-opt"
  fi
fi

# --- 3. wasmtime ---------------------------------------------------------
WASMTIME_DIR="$HOME/.wasmtime"
WASMTIME_BIN="$WASMTIME_DIR/bin/wasmtime"
if ! [ -x "$WASMTIME_BIN" ] && ! command -v wasmtime >/dev/null 2>&1; then
  echo "[session-start] installing wasmtime ..."
  retry 3 "wasmtime install" \
    env WASMTIME_INSTALL_DIR="$WASMTIME_DIR" bash "$PROJECT_DIR/scripts/install_wasmtime_release.sh" \
    || true
fi
if [ -x "$WASMTIME_BIN" ]; then
  persist_env "PATH=$WASMTIME_DIR/bin:$PATH"
  echo "[session-start] wasmtime: $("$WASMTIME_BIN" --version)"
elif command -v wasmtime >/dev/null 2>&1; then
  echo "[session-start] wasmtime: $(wasmtime --version) (system PATH)"
else
  echo "[session-start] WARNING: wasmtime install failed" >&2
fi

# --- 4. pkfire (pkf) -----------------------------------------------------
# pkf is the canonical task runner (Taskfile.pkl). It is not in nixpkgs, so we
# install it from the upstream flake. Pinned to the same tag CI uses
# (mizchi/pkfire@v0.10.0). The github: fetcher hits the rate-limited GitHub API,
# so use the git+https fetcher which works unauthenticated.
#
# IMPORTANT: install into a DEDICATED profile, never the default one. The
# nix-installer's default profile (~/.nix-profile) is classic-managed and holds
# the `nix` binary itself; running `nix profile install` against it starts a
# fresh manifest and would drop `nix` from PATH. A separate profile keeps both.
NIX="$HOME/.nix-profile/bin/nix"
PKF_PROFILE="$HOME/.nix-profiles/pkfire"
PKF_BIN="$PKF_PROFILE/bin/pkf"
if [ -x "$NIX" ] && ! [ -x "$PKF_BIN" ]; then
  echo "[session-start] installing pkfire (pkf) via nix ..."
  # nix builds Go modules without a sandbox here; an existing /homeless-shelter
  # breaks the purity check, so clear it before building.
  rm -rf /homeless-shelter 2>/dev/null || true
  mkdir -p "$(dirname "$PKF_PROFILE")"
  retry 3 "pkf install" \
    "$NIX" profile install --profile "$PKF_PROFILE" \
    'git+https://github.com/mizchi/pkfire?ref=refs/tags/v0.10.0' \
    --extra-experimental-features 'nix-command flakes' \
    || true
fi
if [ -x "$PKF_BIN" ]; then
  persist_env "PATH=$PKF_PROFILE/bin:$PATH"
  echo "[session-start] pkf installed: $PKF_BIN"

  # pkf evaluates Taskfile.pkl via a bundled `pkl`, which fetches the pkfire Pkl
  # package over HTTPS. The bundled JDK truststore can't verify pkg.pkl-lang.org,
  # so warm the pkl package cache once using the system CA bundle; afterwards pkf
  # resolves from cache (~/.pkl/cache) without needing --ca-certificates.
  PKL_BIN_DIR="$(grep -oE '/nix/store/[a-z0-9]+-pkl-[0-9.]+/bin' "$PKF_BIN" 2>/dev/null | head -1 || true)"
  CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
  if [ -n "$PKL_BIN_DIR" ] && [ -x "$PKL_BIN_DIR/pkl" ] && [ -f "$PROJECT_DIR/Taskfile.pkl" ] && [ -e "$CA_BUNDLE" ]; then
    if retry 3 "pkl cache warm" \
      "$PKL_BIN_DIR/pkl" eval --ca-certificates="$CA_BUNDLE" "$PROJECT_DIR/Taskfile.pkl" >/dev/null 2>&1; then
      echo "[session-start] pkl package cache warmed"
    else
      echo "[session-start] WARNING: pkl cache warm failed (run pkf with pkl --ca-certificates)" >&2
    fi
  fi

  # Install the pkfire-managed git hooks (e.g. the `pre-commit` task that
  # `moon fmt`s staged sources) so commits in this fresh clone land formatted.
  # Idempotent and best-effort; `.git/hooks` is not version-controlled.
  if [ -d "$PROJECT_DIR/.git" ] && [ -f "$PROJECT_DIR/Taskfile.pkl" ]; then
    if (cd "$PROJECT_DIR" && "$PKF_BIN" hooks install >/dev/null 2>&1); then
      echo "[session-start] pkf git hooks installed"
    fi
  fi
fi

# --- 5. verification gate ------------------------------------------------
# Fail loudly if a required tool did not land on PATH, instead of letting the
# session proceed half-provisioned. Optional tools only warn.
verify_fail=0
verify_tool() {
  local kind="$1" name="$2" ver_cmd="$3"
  if command -v "$name" >/dev/null 2>&1; then
    echo "[session-start] ok: $name — $(eval "$ver_cmd" 2>/dev/null | head -1)"
  elif [ "$kind" = required ]; then
    echo "[session-start] MISSING (required): $name" >&2
    verify_fail=1
  else
    echo "[session-start] WARNING (optional): $name not found" >&2
  fi
}
verify_tool required moon "moon version"
verify_tool required moonc "moonc -v"
verify_tool required moonrun "moonrun --version"
verify_tool required wasmtime "wasmtime --version"
verify_tool required pkf "pkf --version"
verify_tool optional wasm-opt "wasm-opt --version"

if [ "$verify_fail" = 1 ]; then
  echo "[session-start] toolchain verification FAILED — required tools missing (see above)" >&2
  exit 1
fi

echo "[session-start] toolchain init complete"
