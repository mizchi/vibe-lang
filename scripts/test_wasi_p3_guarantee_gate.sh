#!/usr/bin/env bash
# WASI p3 guarantee gate (#821): assert that vibe-built artifacts run on
# wasmtime's WASI p3 surface, on a SPECIFIC wasmtime binary, with missing
# tooling treated as failure. This is the CI entry point; it composes the two
# existing verticals, the optional stdin success-lifecycle probe, and a WIT
# version-pin assert:
#
#   phase A  async component vertical (test_async_component_gate.sh plus the
#            spawned-future / concurrent-awaits / future+stream value /
#            host-future / named-host* / sleep / interleaving / wit-import
#            probes; #2592)
#            .vibe async entry -> component-model async component -> 42
#   phase B  wasi:http p3 world (test_wasi_http_p3_full_gate.sh) plus the
#            incoming-body stream-parameter composition probe (#1540)
#            componentize -> wac plug -> wasmtime serve -> curl assertions,
#            and the async-lift/string-task.return option-set probe that has
#            to hold before those canon emitters are generalized
#   phase C  wasi:cli/stdin lifecycle
#            generated shadow adapter + checker-hidden arbitrary-core route +
#            hand-WAT provider measurement; exact ratified import,
#            drain-to-EOF, and early-drop completion
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
# One compiler override for every async vertical that has its own env var.
# The wasi-p3 CI job sets VIBE_ASYNC_GATE_COMPILER at the stage2 artifact;
# without this copy, a child gate falls back to generations/ or the seed and
# CI (which has neither) skips or fails for a reason that is not the probe.
if [ -n "${VIBE_ASYNC_GATE_COMPILER:-}" ]; then
  : "${VIBE_SPAWNED_FUTURE_GATE_COMPILER:=$VIBE_ASYNC_GATE_COMPILER}"
  : "${VIBE_CONCURRENT_AWAITS_GATE_COMPILER:=$VIBE_ASYNC_GATE_COMPILER}"
  : "${VIBE_FUTURE_VALUE_GATE_COMPILER:=$VIBE_ASYNC_GATE_COMPILER}"
  : "${VIBE_STREAM_VALUE_GATE_COMPILER:=$VIBE_ASYNC_GATE_COMPILER}"
  : "${VIBE_HOST_FUTURE_GATE_COMPILER:=$VIBE_ASYNC_GATE_COMPILER}"
  : "${VIBE_HOSTFUTURE_SOURCE_GATE_COMPILER:=$VIBE_ASYNC_GATE_COMPILER}"
  : "${VIBE_NAMED_HOSTFUTURES_GATE_COMPILER:=$VIBE_ASYNC_GATE_COMPILER}"
  : "${VIBE_NAMED_HOSTSTREAMS_GATE_COMPILER:=$VIBE_ASYNC_GATE_COMPILER}"
  : "${VIBE_ASYNC_SLEEP_GATE_COMPILER:=$VIBE_ASYNC_GATE_COMPILER}"
  export VIBE_SPAWNED_FUTURE_GATE_COMPILER VIBE_CONCURRENT_AWAITS_GATE_COMPILER \
    VIBE_FUTURE_VALUE_GATE_COMPILER VIBE_STREAM_VALUE_GATE_COMPILER \
    VIBE_HOST_FUTURE_GATE_COMPILER VIBE_HOSTFUTURE_SOURCE_GATE_COMPILER \
    VIBE_NAMED_HOSTFUTURES_GATE_COMPILER VIBE_NAMED_HOSTSTREAMS_GATE_COMPILER \
    VIBE_ASYNC_SLEEP_GATE_COMPILER
fi

case ",$PHASES," in *",async,"*)
  echo "[p3-guarantee] phase A: async component vertical"
  bash "$SCRIPT_DIR/test_async_component_gate.sh"
  # Additional async verticals (#2592). Each had a pkf task and no workflow
  # path, so an unwired one was invisible the same way check_book_console.sh
  # was. They belong on this CI entry point, not on an allowlist.
  bash "$SCRIPT_DIR/test_spawned_future_component_gate.sh"
  bash "$SCRIPT_DIR/test_concurrent_awaits_component_gate.sh"
  bash "$SCRIPT_DIR/test_future_value_component_gate.sh"
  bash "$SCRIPT_DIR/test_stream_value_component_gate.sh"
  bash "$SCRIPT_DIR/test_host_future_value_component_gate.sh"
  bash "$SCRIPT_DIR/test_hostfuture_source_component_gate.sh"
  bash "$SCRIPT_DIR/test_named_hostfutures_component_gate.sh"
  bash "$SCRIPT_DIR/test_named_hoststreams_component_gate.sh"
  bash "$SCRIPT_DIR/test_host_stream_value_probe_gate.sh"
  bash "$SCRIPT_DIR/test_async_sleep_component_gate.sh"
  bash "$SCRIPT_DIR/test_interleaved_tasks_probe_gate.sh"
  bash "$SCRIPT_DIR/test_wit_async_import_component_gate.sh"
  ;;
esac
case ",$PHASES," in *",http,"*)
  run_http=1
  echo "[p3-guarantee] phase B: wasi:http p3 world"
  bash "$SCRIPT_DIR/test_wasi_http_p3_full_gate.sh"
  bash "$SCRIPT_DIR/test_http_body_stream_probe_gate.sh"
  bash "$SCRIPT_DIR/test_http_body_read_probe_gate.sh"
  bash "$SCRIPT_DIR/test_serve_async_lift_gate.sh"
  bash "$SCRIPT_DIR/test_serve_body_stream_gate.sh"
  bash "$SCRIPT_DIR/test_async_string_lift_probe_gate.sh"
  ;;
esac
case ",$PHASES," in *",stdin,"*)
  echo "[p3-guarantee] phase C: wasi:cli/stdin lifecycle"
  bash "$SCRIPT_DIR/test_wasi_cli_stdin_provider_component_gate.sh"
  bash "$SCRIPT_DIR/test_wasi_cli_stdin_provider_guest_component_gate.sh"
  bash "$SCRIPT_DIR/test_wasi_cli_stdin_provider_source_component_gate.sh"
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
