#!/usr/bin/env bash
# Integration test for debugger テーマ3 / DAP P1 groundwork: a function-call
# execution trace. `vibe run --trace <file>` must print the SEQUENCE of user
# function entries, each annotated with its source location, e.g.:
#   trace: main (prog.vibex:2)
#   trace: helper (prog.vibex:1)
#   trace: helper (prog.vibex:1)
#
# How it works (opt-in, default-off so the selfhost fixpoint is unaffected):
#   * VIBE_DEBUG=1 codegen appends each entered user function's index to an
#     in-memory trace log (modeled on the coverage hit region; no wasm import,
#     no function-index shift),
#   * a `vibe.trace` custom section records the log layout + function names,
#   * the runner (VIBE_TRACE_OUT=1) dumps the entry sequence as `trace: <name>`,
#   * `vibe run --trace` annotates each with `(<basename>:<line>)` via the same
#     funcmap sidecar used for trap backtraces.
#
# Installs a FRESH CLI wasm (carrying the debug instrumentation) into a throwaway
# VIBE_HOME/VIBE_BIN_DIR. Mirrors scripts/test_vibe_trace.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RT="$ROOT_DIR/runtime/viberun/target/release/viberun"
# Rebuild the runner if it is missing OR older than any runner source (a stale
# local binary would lack newly added host imports like vibe::dbg_break).
if [ ! -x "$RT" ] || [ -n "$(find runtime/viberun/src -name "*.rs" -newer "$RT" 2>/dev/null | head -1)" ]; then
  cargo build --release --manifest-path runtime/viberun/Cargo.toml >/dev/null
fi

cli="$(bash scripts/build_cli_wasm.sh)"
[ -s "$cli" ] || { echo "FAIL: no CLI wasm built" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
unset RUST_BACKTRACE || true

echo "[test] installing fresh CLI into $VIBE_HOME"
bash install/install.sh --cli-wasm "$cli" >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }

pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

proj="$WORK/proj"; mkdir -p "$proj"
# helper (line 1) called twice; main (line 2) calls it.
cat > "$proj/prog.vibex" <<'EOF'
let helper = (x: Int) -> Int { x * 2 }
fn main with Stdout { Stdout::write_stream("\{helper(20) + helper(1)}\n") }
EOF

# 1. Plain `vibe run` is unaffected: prints 42, emits NO trace lines.
plain="$("$VIBE" run "$proj/prog.vibex" 2>&1)"
[ "$(printf '%s' "$plain" | grep -o '42' | head -1)" = "42" ] && ok "plain run computes 42" || bad "plain run did not print 42 (got: $plain)"
if printf '%s\n' "$plain" | grep -q "trace:"; then bad "plain run leaked trace lines"; else ok "plain run emits no trace lines"; fi

# 2. `vibe run --trace` emits the call sequence annotated with source lines.
traced="$("$VIBE" run --trace "$proj/prog.vibex" 2>&1)"
echo "----- vibe run --trace -----"; printf '%s\n' "$traced"; echo "----------------------------"
[ "$(printf '%s' "$traced" | tr -dc '0-9' | grep -o '42' | head -1)" = "42" ] && ok "traced run still computes 42" || true
printf '%s\n' "$traced" | grep -qF "trace: main (prog.vibex:2)" && ok "trace names main at its source line (2)" || bad "missing 'trace: main (prog.vibex:2)'"
printf '%s\n' "$traced" | grep -qF "trace: helper (prog.vibex:1)" && ok "trace names helper at its source line (1)" || bad "missing 'trace: helper (prog.vibex:1)'"
helper_hits="$(printf '%s\n' "$traced" | grep -cF "trace: helper (prog.vibex:1)")"
[ "$helper_hits" -ge 2 ] && ok "helper appears >=2 times (called twice)" || bad "helper appeared $helper_hits time(s), expected >=2"

echo "[test_vibe_trace_calls] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
