#!/usr/bin/env bash
# WASI p3 guarantee gate (#821): assert that vibe-built artifacts run on
# wasmtime's WASI p3 surface, on a SPECIFIC wasmtime binary, with missing
# tooling treated as failure. This is the CI entry point; it composes the two
# existing verticals, the optional stdin success-lifecycle probe, and a WIT
# version-pin assert:
#
#   phase A  async component vertical (test_async_component_gate.sh)
#            .vibe async entry -> component-model async component -> 42
#   phase B  wasi:http p3 world (test_wasi_http_p3_full_gate.sh)
#            componentize -> wac plug -> wasmtime serve -> curl 200/401
#   phase C  wasi:cli/stdin lifecycle (test_wasi_cli_stdin_p3_probe_gate.sh)
#            exact ratified import; drain-to-EOF and early-drop completion
#   phase D  WIT pin: the composed serve component's world must reference the
#            pinned wasi:http version, so adapter/vendored-WIT/runtime drift
#            fails loudly instead of as a mysterious resolution error.
#
# Env:
#   WASMTIME_BIN                 wasmtime under test (default: wasmtime_bin.sh
#                                resolution — PATH / submodule)
#   VIBE_P3_GATE_REQUIRE_TOOLS   1 = missing tool/compiler is FAIL (CI mode).
#                                Default 0: phases skip like their underlying
#                                gates (local dev convenience).
#   VIBE_P3_WIT_PIN              expected wasi:http version substring in the
#                                composed component (default: the ratified
#                                pin 0.3.0, wasmtime 46 cutover, #821 — was
#                                the RC pin 0.3.0-rc-2026-03-15 on wasmtime 45)
#   VIBE_P3_GATE_PHASES          comma list of phases to run (default
#                                "async,http,stdin"). The async/http phases pass on wasmtime
#                                46.0.1 as of the ratified-WIT cutover (#821):
#                                the vendored WIT was refreshed to
#                                wasi:http@0.3.0 (matching what 46 serves),
#                                which was the blocker for phase B linking
#                                (previously "resource implementation is
#                                missing" against the RC world).
#   VIBE_ASYNC_GATE_WASMTIME_FLAGS / VIBE_HTTP_GATE_WASMTIME_FLAGS
#                                flag overrides (e.g. to pin an older
#                                wasmtime's RC flag set for compat testing)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

WASMTIME_BIN="${WASMTIME_BIN:-$("$SCRIPT_DIR/wasmtime_bin.sh" 2>/dev/null || command -v wasmtime || true)}"
export WASMTIME_BIN
REQUIRE="${VIBE_P3_GATE_REQUIRE_TOOLS:-0}"
WIT_PIN="${VIBE_P3_WIT_PIN:-0.3.0}"

if [ -z "${WASMTIME_BIN:-}" ] || ! "$WASMTIME_BIN" --version >/dev/null 2>&1; then
  if [ "$REQUIRE" = "1" ]; then
    echo "[p3-guarantee] FAILED: wasmtime not available (required mode)" >&2
    exit 1
  fi
  echo "[p3-guarantee] SKIP: wasmtime not available"
  exit 0
fi
PHASES="${VIBE_P3_GATE_PHASES:-async,http,stdin}"
echo "[p3-guarantee] wasmtime under test: $("$WASMTIME_BIN" --version) ($WASMTIME_BIN)"
echo "[p3-guarantee] required-tools mode: $REQUIRE / phases: $PHASES / wit pin: wasi:http@$WIT_PIN"

run_http=0
case ",$PHASES," in *",async,"*)
  echo "[p3-guarantee] phase A: async component vertical"
  bash "$SCRIPT_DIR/test_async_component_gate.sh"
  ;;
esac
case ",$PHASES," in *",http,"*)
  run_http=1
  echo "[p3-guarantee] phase B: wasi:http p3 world"
  bash "$SCRIPT_DIR/test_wasi_http_p3_full_gate.sh"
  ;;
esac
case ",$PHASES," in *",stdin,"*)
  echo "[p3-guarantee] phase C: wasi:cli/stdin lifecycle"
  bash "$SCRIPT_DIR/test_wasi_cli_stdin_p3_probe_gate.sh"
  ;;
esac

if [ "$run_http" != "1" ]; then
  echo "[p3-guarantee] PASS (phases: $PHASES) on $("$WASMTIME_BIN" --version)"
  exit 0
fi

echo "[p3-guarantee] phase D: WIT version pin"
COMPOSED="$PROJECT_ROOT/_build/bench/wasi_http_p3_full/handler.serve.wasm"
if command -v wasm-tools >/dev/null 2>&1 && [ -s "$COMPOSED" ]; then
  if ! wasm-tools component wit "$COMPOSED" | grep -q "wasi:http/handler@$WIT_PIN"; then
    echo "[p3-guarantee] FAILED: composed component does not reference wasi:http/handler@$WIT_PIN" >&2
    echo "[p3-guarantee] actual wasi:http references:" >&2
    wasm-tools component wit "$COMPOSED" | grep "wasi:http" | head -5 >&2 || true
    exit 1
  fi
  echo "[p3-guarantee] WIT pin ok: wasi:http/handler@$WIT_PIN"
else
  if [ "$REQUIRE" = "1" ]; then
    echo "[p3-guarantee] FAILED: WIT pin unverifiable (wasm-tools or composed component missing) in required mode" >&2
    exit 1
  fi
  echo "[p3-guarantee] SKIP: WIT pin (wasm-tools or composed component missing)"
fi

echo "[p3-guarantee] PASS on $("$WASMTIME_BIN" --version)"
