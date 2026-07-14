#!/usr/bin/env bash
# Verify the committed prebuilt flat module source is in sync with the
# current compiler source (#594 Stage 1, moonbit-retirement).
#
# emit-module-source is a deterministic function of the committed compiler
# source. The default (moon-free) build consumes the committed prebuilt
# lib/@vibe/compiler/cli_adapter_module_source.vibe instead of calling
# the MoonBit host. This gate regenerates it through the host compiler
# (VIBE_SELFHOST_REGEN_MODULE_SOURCE=1) and fails on drift, so a stale
# prebuilt can never silently ship.
#
# When no host compiler is available (no vibe.exe and no `moon`), the freshness
# check cannot run; the gate skips with a clear message. Moon-free consumers
# trust the pinned artifact; CI (which has the host) enforces freshness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_SELFHOST_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
COMPILER_DIR="${VIBE_SELFHOST_COMPILER_DIR:-$PROJECT_ROOT/lib/@vibe/compiler}"
EXPECTED="${VIBE_SELFHOST_MODULE_SOURCE_EXPECTED:-$COMPILER_DIR/cli_adapter_module_source.vibe}"

if [ ! -f "$EXPECTED" ]; then
  echo "selfhost module source sync: committed prebuilt not found: $EXPECTED" >&2
  exit 1
fi

# Prefer the selfhost seed compiler (moon-free) to regenerate; the seed carries
# emit-module-source. Fall back to the MoonBit host only if the seed is absent.
# If neither is available, the freshness check cannot run and is skipped.
have_emit=0
if [ -f "$PROJECT_ROOT/bootstrap/seed/selfhost_compiler.wasm" ] &&
  [ "${VIBE_SELFHOST_EMIT_VIA_HOST:-0}" != "1" ]; then
  have_emit=1
elif [ -x "$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe" ] ||
  [ -x "$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe" ] ||
  [ -x "$PROJECT_ROOT/target/native/release/build/cmd/vibe/vibe.exe" ] ||
  command -v moon >/dev/null 2>&1; then
  have_emit=1
fi
if [ "$have_emit" -ne 1 ]; then
  echo "selfhost module source sync: skipped (no seed or host compiler; trusting pinned prebuilt)"
  exit 0
fi

# Outputs must live under the repo root: the seed emit runs with the repo root as
# its wasm preopen and cannot write outside it.
mkdir -p "$PROJECT_ROOT/_build"
TMP_ROOT="$(mktemp -d "$PROJECT_ROOT/_build/vibe_selfhost_module_source_sync.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
TMP_MODULE_SOURCE="$TMP_ROOT/cli_adapter_module_source.vibe"

VIBE_SELFHOST_PROJECT_ROOT="$PROJECT_ROOT" \
VIBE_SELFHOST_COMPILER_DIR="$COMPILER_DIR" \
VIBE_SELFHOST_REGEN_MODULE_SOURCE=1 \
VIBE_SELFHOST_BUNDLE_OUT="$TMP_ROOT/sources_bundle.vibe" \
VIBE_SELFHOST_ADAPTER_BUNDLE_OUT="$TMP_ROOT/cli_adapter_bundle.vibe" \
VIBE_SELFHOST_RUNTIME_ENTRY_BUNDLE_OUT="$TMP_ROOT/selfbuild_runtime_entry_bundle.vibe" \
VIBE_SELFHOST_ADAPTER_MODULE_SOURCE_OUT="$TMP_MODULE_SOURCE" \
bash "$SCRIPT_DIR/generate_bundle.sh" >/dev/null

if [ ! -s "$TMP_MODULE_SOURCE" ]; then
  echo "selfhost module source sync: host regeneration produced no output" >&2
  exit 1
fi

if cmp -s "$EXPECTED" "$TMP_MODULE_SOURCE"; then
  echo "selfhost module source sync: ok"
  exit 0
fi

echo "selfhost module source sync: drift detected; regenerate $EXPECTED" >&2
echo "  (VIBE_SELFHOST_REGEN_MODULE_SOURCE=1 VIBE_SELFHOST_ADAPTER_MODULE_SOURCE_OUT=$EXPECTED bash scripts/generate_bundle.sh)" >&2
diff -u "$EXPECTED" "$TMP_MODULE_SOURCE" >&2 || true
exit 1
