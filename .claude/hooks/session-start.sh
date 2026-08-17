#!/usr/bin/env bash
#
# SessionStart hook for Claude Code on the web.
#
# Initializes the toolchains that vibe's build / test / bench gates need but
# that are NOT on PATH by default in a fresh remote container:
#
#   1. nix       (already installed under ~/.nix-profile, just not on PATH)
#   2. moon      (MoonBit; ships under ~/.moon/bin, only added by interactive bashrc)
#   3. wasmtime  (installed on demand via scripts/install_wasmtime_release.sh)
#   4. pkf       (pkfire task runner; installed via nix from the upstream flake)
#
# Each is persisted into $CLAUDE_ENV_FILE so that every subsequent Bash tool
# invocation in the session can resolve these tools on PATH. The repo helper
# scripts/wasmtime_bin.sh locates wasmtime via `command -v wasmtime`, so putting
# ~/.wasmtime/bin on PATH is what makes the `pkf` wasm gates work.
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
# wasmtime is only useful here if vibe can be (re)built, and `moon` is what
# builds it. moon ships under ~/.moon/bin but is only added to PATH by the
# interactive section of ~/.bashrc, so non-interactive tool shells miss it.
MOON_BIN="$HOME/.moon/bin"
if [ -x "$MOON_BIN/moon" ]; then
  persist_env "PATH=$MOON_BIN:$PATH"
  echo "[session-start] moon: $("$MOON_BIN/moon" version 2>/dev/null)"
else
  echo "[session-start] WARNING: moon not found under ~/.moon/bin" >&2
fi

# --- 3. wasmtime ---------------------------------------------------------
WASMTIME_DIR="$HOME/.wasmtime"
WASMTIME_BIN="$WASMTIME_DIR/bin/wasmtime"
if ! [ -x "$WASMTIME_BIN" ] && ! command -v wasmtime >/dev/null 2>&1; then
  echo "[session-start] installing wasmtime ..."
  WASMTIME_INSTALL_DIR="$WASMTIME_DIR" bash "$PROJECT_DIR/scripts/install_wasmtime_release.sh"
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
# install it from the upstream flake, pinned to the same tag CI uses
# (.github/actions/setup-vibe + pkfire-pkspec.yml — keep the three in sync).
# The github: fetcher hits the rate-limited GitHub API, so use the git+https
# fetcher which works unauthenticated.
#
# pkfire was rewritten in MoonBit (the flake installs the prebuilt release
# binary since v0.12); tags up to v0.10.0 built the RETIRED Go implementation.
# Never pin below v0.12 — a stale pin silently hands every fresh container the
# Go binary again.
#
# IMPORTANT: install into a DEDICATED profile, never the default one. The
# nix-installer's default profile (~/.nix-profile) is classic-managed and holds
# the `nix` binary itself; running `nix profile install` against it starts a
# fresh manifest and would drop `nix` from PATH. A separate profile keeps both.
NIX="$HOME/.nix-profile/bin/nix"
PKF_VERSION="0.14.2"
PKF_PROFILE="$HOME/.nix-profiles/pkfire"
PKF_BIN="$PKF_PROFILE/bin/pkf"
# Long-lived containers keep whatever the profile last held (the hook used to
# skip install when the binary existed). Verify the version and wipe a stale
# profile so the pin above is the single source of truth. The retired Go build
# reports "dev", so it always mismatches and gets replaced.
if [ -x "$PKF_BIN" ]; then
  PKF_INSTALLED="$("$PKF_BIN" --version 2>/dev/null || true)"
  if [ "$PKF_INSTALLED" != "$PKF_VERSION" ]; then
    echo "[session-start] pkf ${PKF_INSTALLED:-unknown} != $PKF_VERSION; replacing stale install ..."
    rm -f "$PKF_PROFILE"
    rm -rf "$PKF_PROFILE"-*-link
  fi
fi
if [ -x "$NIX" ] && ! [ -x "$PKF_BIN" ]; then
  echo "[session-start] installing pkfire (pkf) $PKF_VERSION via nix ..."
  # nix evaluates/builds without a sandbox here; an existing /homeless-shelter
  # breaks the purity check, so clear it before building.
  rm -rf /homeless-shelter 2>/dev/null || true
  mkdir -p "$(dirname "$PKF_PROFILE")"
  "$NIX" profile install --profile "$PKF_PROFILE" \
    "git+https://github.com/mizchi/pkfire?ref=refs/tags/v$PKF_VERSION" \
    --extra-experimental-features 'nix-command flakes' || \
    echo "[session-start] WARNING: pkf install failed" >&2
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
    if "$PKL_BIN_DIR/pkl" eval --ca-certificates="$CA_BUNDLE" "$PROJECT_DIR/Taskfile.pkl" >/dev/null 2>&1; then
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

# The five generated compiler artifacts are build outputs, not tracked files
# (scripts/ensure_generated.sh), and lib/@vibe/compiler/compiler.vibe IMPORTS
# three of them -- so a fresh clone cannot typecheck the compiler, and `vibe
# lsp` reports phantom unresolved-import errors, until they exist. Produce them
# once here. ~1s when the fingerprint has not moved; the first run in a fresh
# container pays the full generation.
if [ -f "$PROJECT_DIR/scripts/ensure_generated.sh" ]; then
  if (cd "$PROJECT_DIR" && bash scripts/ensure_generated.sh >/dev/null 2>&1); then
    echo "[session-start] generated compiler artifacts ready"
    # #1988: `runtime/vibe` does not run in remote sessions (no bin/viberun).
    # Persist a host-runner invoker only after a real grep probe succeeds, so
    # we never hand review-lint a lying VIBE_REVIEW_LINT_GREP_BIN.
    GREP_BIN="$PROJECT_DIR/scripts/vibe_grep_bin.sh"
    if [ -f "$GREP_BIN" ] && bash "$GREP_BIN" --probe >/dev/null 2>&1; then
      persist_env "VIBE_REVIEW_LINT_GREP_BIN=$GREP_BIN"
      echo "[session-start] review-lint grep: $GREP_BIN"
    else
      echo "[session-start] WARNING: vibe grep probe failed; leaving VIBE_REVIEW_LINT_GREP_BIN unset (review AST tier will skip)" >&2
    fi
  else
    echo "[session-start] WARNING: ensure_generated.sh failed; run it manually before building" >&2
  fi
fi

echo "[session-start] toolchain init complete"
