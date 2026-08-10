#!/usr/bin/env bash
# #1539: fail-closed availability check for wasi:cli/stdin@0.3.0.
#
# The probe deliberately declares the ratified WIT import, including the
# returned readable stream and completion future. It has no guest lifecycle
# body: a successful link is the prerequisite for measuring normal EOF, early
# readable-end drop, and completion-result errors. Do not substitute the
# older RC interface; an RC observation is not evidence for @0.3.0.
#
# Env:
#   WASMTIME_BIN                 wasmtime binary under test (default: PATH)
#   VIBE_P3_GATE_REQUIRE_TOOLS=1 missing tools = FAIL instead of skip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/wasi_cli_stdin_p3_probe}"
mkdir -p "$OUT_DIR"

require_or_skip() {
  local what="$1"
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "wasi cli stdin p3 probe FAILED: $what (required mode)" >&2
    exit 1
  fi
  echo "wasi cli stdin p3 probe skipped: $what"
  exit 0
}

command -v wasm-tools >/dev/null 2>&1 || require_or_skip "wasm-tools not installed"
WASMTIME_BIN="${WASMTIME_BIN:-$(command -v wasmtime || true)}"
[ -n "$WASMTIME_BIN" ] || require_or_skip "wasmtime not installed"

WAT="$PROJECT_ROOT/tools/wasip3_component_probe/stdin_read_via_stream/component.wat"
COMPONENT="$OUT_DIR/stdin_read_via_stream.wasm"
wasm-tools parse "$WAT" -o "$COMPONENT"
wasm-tools validate --features all "$COMPONENT"
PRINTED="$OUT_DIR/stdin_read_via_stream.print.wat"
wasm-tools print "$COMPONENT" >"$PRINTED"
grep -Fq 'wasi:cli/stdin@0.3.0' "$PRINTED"
grep -Fq 'read-via-stream' "$PRINTED"

# There is intentionally no success case yet. A host that links this import
# means the ABI availability blocker has moved: this gate must then grow the
# two lifecycle runs instead of silently claiming they passed.
LOG="$OUT_DIR/wasmtime.log"
if "$WASMTIME_BIN" run -Sp3 -Wcomponent-model-async=y "$COMPONENT" >"$LOG" 2>&1; then
  echo "wasi cli stdin p3 probe FAILED: $WASMTIME_BIN linked @0.3.0; add normal-EOF and early-drop lifecycle measurements before accepting it" >&2
  exit 1
fi

# Wasmtime releases/tool builds can reject the unavailable interface during
# parsing or linker construction. Either is an availability failure, not a
# lifecycle result. Preserve the exact log for review.
if ! grep -Eq 'instance not valid to be used as import|matching implementation was not found|function implementation is missing|wrong type' "$LOG"; then
  echo "wasi cli stdin p3 probe FAILED: unexpected wasmtime rejection" >&2
  cat "$LOG" >&2
  exit 1
fi

echo "[wasi-cli-stdin-p3-probe] validated ratified @0.3.0 import; wasmtime could not link it"
echo "[wasi-cli-stdin-p3-probe] lifecycle unmeasured: normal EOF, early readable-end drop, and completion errors remain blocked"
echo "wasi cli stdin p3 probe gate OK (fail-closed availability result)"
