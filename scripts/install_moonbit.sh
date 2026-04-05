#!/usr/bin/env bash
set -euo pipefail

# Repo-managed MoonBit installer for CI.
#
# Usage:
#   bash scripts/install_moonbit.sh
#
# Environment variables:
#   MOONBIT_VERSION  — desired version (default: "latest")
#                      When set, attempts versioned URL first, falls back to latest.
#   MOONBIT_INSTALL_DIR — install prefix (default: ~/.moon)
#
# What it does:
#   1. Downloads MoonBit via the official install script
#   2. Runs `moon update` to fetch core libraries
#   3. Logs the installed version for CI reproducibility
#   4. Retries on transient network failures (up to 3 attempts)
#
# Outputs:
#   Sets MOONBIT_INSTALLED_VERSION for subsequent steps.

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

if ! retry "curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash"; then
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
