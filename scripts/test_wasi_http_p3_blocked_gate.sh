#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
REQUIRE_READY="${VIBE_WASI_HTTP_P3_REQUIRE_READY:-0}"
RUN_COMPOSE="${VIBE_WASI_HTTP_P3_RUN_COMPOSE:-0}"
WAC_BIN="${WAC_BIN:-wac}"

mode_name() {
  if [ "$REQUIRE_READY" = "1" ]; then
    echo "strict"
  else
    echo "blocked"
  fi
}

log_summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### WASI HTTP P3 Gate"
      echo ""
      echo "- mode: \`$(mode_name)\` (\`VIBE_WASI_HTTP_P3_REQUIRE_READY=$REQUIRE_READY\`)"
      echo "- compose probe: \`$RUN_COMPOSE\` (\`VIBE_WASI_HTTP_P3_RUN_COMPOSE\`)"
      echo "- wac bin: \`$WAC_BIN\`"
    } >>"$GITHUB_STEP_SUMMARY"
  fi
}

echo "[p3-gate] mode=$(mode_name) require_ready=$REQUIRE_READY run_compose=$RUN_COMPOSE"
log_summary

if ! command -v cargo >/dev/null 2>&1; then
  if [ "$REQUIRE_READY" = "1" ]; then
    echo "[p3-gate] strict mode: cargo not found" >&2
    exit 1
  fi
  echo "[p3-gate] blocked mode: skip (cargo not found)"
  exit 0
fi

if ! command -v wasm-tools >/dev/null 2>&1; then
  if [ "$REQUIRE_READY" = "1" ]; then
    echo "[p3-gate] strict mode: wasm-tools not found" >&2
    exit 1
  fi
  echo "[p3-gate] blocked mode: skip (wasm-tools not found)"
  exit 0
fi

if ! command -v wasmtime >/dev/null 2>&1; then
  if [ "$REQUIRE_READY" = "1" ]; then
    echo "[p3-gate] strict mode: wasmtime not found" >&2
    exit 1
  fi
  echo "[p3-gate] blocked mode: skip (wasmtime not found)"
  exit 0
fi

echo "[p3-gate] service-only probe"
VIBE_WASI_HTTP_P3_REQUIRE_READY="$REQUIRE_READY" \
  "$PROJECT_ROOT/scripts/probe_wasi_http_p3_service_only.sh"

if [ "$RUN_COMPOSE" != "1" ]; then
  echo "[p3-gate] compose probe: skipped (set VIBE_WASI_HTTP_P3_RUN_COMPOSE=1 to enable)"
  exit 0
fi

if ! command -v "$WAC_BIN" >/dev/null 2>&1; then
  if [ "$REQUIRE_READY" = "1" ]; then
    echo "[p3-gate] strict mode: wac binary not found: $WAC_BIN" >&2
    exit 1
  fi
  echo "[p3-gate] compose probe: skipped (wac not found: $WAC_BIN)"
  exit 0
fi

echo "[p3-gate] compose probe"
VIBE_WASI_HTTP_P3_REQUIRE_READY="$REQUIRE_READY" \
  WAC_BIN="$WAC_BIN" \
  "$PROJECT_ROOT/scripts/probe_wasi_http_p3_compose.sh"
