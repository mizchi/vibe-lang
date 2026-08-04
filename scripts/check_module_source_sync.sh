#!/usr/bin/env bash
# Verify the committed prebuilt flat module source is in sync with the
# current compiler source (#594 Stage 1, moonbit-retirement).
#
# emit-module-source is a deterministic function of the committed compiler
# source. The default build consumes the committed prebuilt
# lib/@vibe/compiler/_cli_adapter_module_source.vibe instead of calling
# the MoonBit host. This gate regenerates it through the host compiler
# (VIBE_REGEN_MODULE_SOURCE=1) and fails on drift, so a stale
# prebuilt can never silently ship.
#
# When no host compiler is available (no vibe.exe and no `moon`), the freshness
# check cannot run; the gate skips with a clear message. Moon-free consumers
# trust the pinned artifact; CI (which has the host) enforces freshness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
COMPILER_DIR="${VIBE_COMPILER_DIR:-$PROJECT_ROOT/lib/@vibe/compiler}"
EXPECTED="${VIBE_MODULE_SOURCE_EXPECTED:-$COMPILER_DIR/_cli_adapter_module_source.vibe}"

if [ ! -f "$EXPECTED" ]; then
  echo "selfhost module source sync: committed prebuilt not found: $EXPECTED" >&2
  exit 1
fi

# The selfhost seed compiler regenerates the module source (it carries
# emit-module-source). The MoonBit-host fallbacks (_build/native/**/vibe.exe,
# `command -v moon`) were retired with the host itself (#594) — nothing in this
# repo builds them any more. Without the seed the freshness check cannot run
# and is skipped.
if [ ! -f "$PROJECT_ROOT/bootstrap/seed/compiler.wasm" ]; then
  echo "selfhost module source sync: skipped (no seed compiler; trusting pinned prebuilt)"
  exit 0
fi

# Outputs must live under the repo root: the seed emit runs with the repo root as
# its wasm preopen and cannot write outside it.
mkdir -p "$PROJECT_ROOT/_build"
TMP_ROOT="$(mktemp -d "$PROJECT_ROOT/_build/vibe_selfhost_module_source_sync.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
TMP_MODULE_SOURCE="$TMP_ROOT/_cli_adapter_module_source.vibe"

VIBE_PROJECT_ROOT="$PROJECT_ROOT" \
VIBE_COMPILER_DIR="$COMPILER_DIR" \
VIBE_REGEN_MODULE_SOURCE=1 \
VIBE_BUNDLE_OUT="$TMP_ROOT/sources_bundle.vibe" \
VIBE_ADAPTER_BUNDLE_OUT="$TMP_ROOT/cli_adapter_bundle.vibe" \
VIBE_RUNTIME_ENTRY_BUNDLE_OUT="$TMP_ROOT/selfbuild_runtime_entry_bundle.vibe" \
VIBE_ADAPTER_MODULE_SOURCE_OUT="$TMP_MODULE_SOURCE" \
bash "$SCRIPT_DIR/generate_bundle.sh" >/dev/null

if [ ! -s "$TMP_MODULE_SOURCE" ]; then
  echo "selfhost module source sync: host regeneration produced no output" >&2
  exit 1
fi

status=0
if ! cmp -s "$EXPECTED" "$TMP_MODULE_SOURCE"; then
  echo "selfhost module source sync: drift detected; regenerate $EXPECTED" >&2
  echo "  (VIBE_REGEN_MODULE_SOURCE=1 VIBE_ADAPTER_MODULE_SOURCE_OUT=$EXPECTED bash scripts/generate_bundle.sh)" >&2
  diff -u "$EXPECTED" "$TMP_MODULE_SOURCE" >&2 || true
  status=1
fi

# VIBE_CHECK_BUNDLES_TOO=1 (CI wall-time, 2026-07): the generate_bundle.sh run
# above already produced all three bundles as a side effect of regenerating
# the module source, so comparing them here makes a separate
# check_bundle_sync.sh invocation (a second full ~25s generate_bundle.sh run)
# redundant for callers that want both checks — compiler_gate.sh passes this
# flag and drops its standalone bundle-sync step. check_bundle_sync.sh remains
# for standalone use (pkf run check-bundle-sync).
if [ "${VIBE_CHECK_BUNDLES_TOO:-0}" = "1" ]; then
  check_bundle_pair() {
    local expected_path="$1" generated_path="$2"
    if [ ! -f "$expected_path" ]; then
      echo "selfhost bundle sync: expected bundle not found: $expected_path" >&2
      status=1
      return 0
    fi
    if ! cmp -s "$expected_path" "$generated_path"; then
      echo "selfhost bundle sync: drift detected; regenerate $expected_path" >&2
      diff -u "$expected_path" "$generated_path" >&2 || true
      status=1
    fi
    return 0
  }
  check_bundle_pair "$COMPILER_DIR/cli_adapter_bundle.vibe" "$TMP_ROOT/cli_adapter_bundle.vibe"
  check_bundle_pair "$COMPILER_DIR/selfbuild_runtime_entry_bundle.vibe" "$TMP_ROOT/selfbuild_runtime_entry_bundle.vibe"
  check_bundle_pair "$COMPILER_DIR/compiler_sources_bundle.vibe" "$TMP_ROOT/sources_bundle.vibe"
  if [ "$status" -eq 0 ]; then
    echo "selfhost bundle sync: ok"
  fi
fi

if [ "$status" -eq 0 ]; then
  echo "selfhost module source sync: ok"
fi
exit "$status"
