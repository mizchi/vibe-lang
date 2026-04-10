#!/usr/bin/env bash
set -euo pipefail

# Repo-managed MoonBit installer for CI.
#
# Usage:
#   bash scripts/install_moonbit.sh
#
# Environment variables:
#   MOONBIT_VERSION  — desired version (default: "latest").
#                      Note: the official CDN only exposes "latest" and
#                      "nightly" for GET; dated versions return 403. We
#                      therefore can't fully pin, but we DO record the
#                      installed version in a stamp file so CI cache keys
#                      can invalidate when moonc changes (see below).
#   MOONBIT_INSTALL_DIR — install prefix (default: ~/.moon)
#
# What it does:
#   1. Downloads MoonBit via the official install script
#   2. Runs `moon update` to fetch core libraries
#   3. Writes the installed version to a stamp file at the repo root
#      (.moon-version) so GitHub Actions `hashFiles` can pick up the
#      version change in its cache key. This prevents stale `_build`
#      artifacts produced by a previous (possibly buggy) moonc from
#      being reused after an upstream release.
#   4. Retries on transient network failures (up to 3 attempts)
#
# Outputs:
#   Sets MOONBIT_INSTALLED_VERSION for subsequent steps.
#   Writes <repo-root>/.moon-version containing the full version string.
#
# Context: this stamp mechanism was added after a Linux-only moonc
# regression cluster (#265/#266/#267/#268/#280/#281) where CI kept
# reusing build artifacts from moon 0.1.20260403 because the cache key
# only hashed source files.

MOONBIT_VERSION="${MOONBIT_VERSION:-latest}"
MOONBIT_INSTALL_DIR="${MOONBIT_INSTALL_DIR:-$HOME/.moon}"
MAX_RETRIES=3
RETRY_DELAY=5

log() { echo "[install-moonbit] $*"; }
warn() { echo "[install-moonbit] WARNING: $*" >&2; }

retry() {
  local attempt=1
  local cmd="$*"
  while [ "$attempt" -le "$MAX_RETRIES" ]; do
    if eval "$cmd"; then
      return 0
    fi
    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
      warn "attempt $attempt/$MAX_RETRIES failed, retrying in ${RETRY_DELAY}s..."
      sleep "$RETRY_DELAY"
      RETRY_DELAY=$((RETRY_DELAY * 2))
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

# --- Install MoonBit ---

log "installing MoonBit (requested: $MOONBIT_VERSION)..."

# The official installer accepts a positional version argument (or
# MOONBIT_INSTALL_VERSION env var). We pass the version explicitly so
# that CI is deterministic and a buggy upstream moonc cannot silently
# get picked up.
if [ "$MOONBIT_VERSION" = "latest" ]; then
  install_cmd="curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash"
else
  install_cmd="curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash -s -- $MOONBIT_VERSION"
fi

if ! retry "$install_cmd"; then
  log "ERROR: failed to install MoonBit after $MAX_RETRIES attempts"
  exit 1
fi

# Ensure moon is on PATH
export PATH="$MOONBIT_INSTALL_DIR/bin:$PATH"

if ! command -v moon >/dev/null 2>&1; then
  log "ERROR: moon not found after installation"
  exit 1
fi

# --- Update core libraries ---

log "updating core libraries..."
if ! retry "moon update 2>&1"; then
  warn "moon update failed — continuing with bundled core"
fi

# --- Log version ---

INSTALLED_VERSION=$(moon version 2>/dev/null | head -1 || echo "unknown")
log "installed: $INSTALLED_VERSION"

# --- Write version stamp file for CI cache invalidation ---
# Resolve repo root relative to this script so the stamp lands at a
# stable location regardless of where the installer was invoked from.
_STAMP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
_STAMP_FILE="$_STAMP_ROOT/.moon-version"
printf '%s\n' "$INSTALLED_VERSION" > "$_STAMP_FILE"
log "stamped version -> $_STAMP_FILE"

# Export for GitHub Actions
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "moonbit-version=$INSTALLED_VERSION" >> "$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$MOONBIT_INSTALL_DIR/bin" >> "$GITHUB_PATH"
fi

# Export for current shell
export MOONBIT_INSTALLED_VERSION="$INSTALLED_VERSION"

log "done"
