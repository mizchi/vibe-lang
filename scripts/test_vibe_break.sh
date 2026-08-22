#!/usr/bin/env bash
# Integration test for debugger DAP P1: a live breakpoint. `vibe run --break
# helper <file>` must pause at `helper`'s entry, print the call stack (naming
# the entering function + its callers), then CONTINUE so the program finishes:
#   breakpoint hit: helper
#     at helper (prog.vibex:1)
#     at main (prog.vibex:2)
#   42
#
# How it works (opt-in, default-off so the selfhost fixpoint is unaffected):
#   * VIBE_DEBUG_BREAK=1 codegen emits a bare `call vibe::dbg_break` host hook at
#     each user function entry (conditional import, func_offset shifts by 1
#     consistently),
#   * the runner implements `vibe::dbg_break`: it captures the wasm backtrace,
#     names the entering function via the name section, and pauses when that
#     name is in VIBE_BREAK (auto-continue when stdin is not a TTY or
#     VIBE_BREAK_AUTO=1), printing the call stack, then continues,
#   * `vibe run --break <spec>` drives it, annotating each `  at <name>` frame
#     with `(<basename>:<line>)` via the same funcmap sidecar used for traces.
#
# Installs a FRESH CLI wasm (carrying the break instrumentation) into a throwaway
# VIBE_HOME/VIBE_BIN_DIR. Mirrors scripts/test_vibe_trace_calls.sh.
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
# helper (line 1) called by main (line 2).
cat > "$proj/prog.vibex" <<'EOF'
let helper = (x: Int) -> Int { x * 2 }
fn main with Stdout { Stdout::write_stream("\{helper(21)}\n") }
EOF

# 1. Plain `vibe run` is unaffected: prints 42, emits NO breakpoint output.
plain="$("$VIBE" run "$proj/prog.vibex" 2>&1)"
[ "$(printf '%s' "$plain" | grep -o '42' | head -1)" = "42" ] && ok "plain run computes 42" || bad "plain run did not print 42 (got: $plain)"
if printf '%s\n' "$plain" | grep -q "breakpoint hit"; then bad "plain run leaked breakpoint output"; else ok "plain run emits no breakpoint output"; fi

# 2. `vibe run --break helper` pauses at helper, prints the call stack, continues.
#    VIBE_BREAK_AUTO=1 makes the runner auto-continue without reading stdin.
broke="$(VIBE_BREAK_AUTO=1 "$VIBE" run --break helper "$proj/prog.vibex" 2>&1)"
echo "----- vibe run --break helper -----"; printf '%s\n' "$broke"; echo "-----------------------------------"
printf '%s\n' "$broke" | grep -qF "breakpoint hit: helper" && ok "breakpoint hit names helper" || bad "missing 'breakpoint hit: helper'"
# A stack frame must mention the caller `main`.
printf '%s\n' "$broke" | grep -E "at main" >/dev/null && ok "call stack mentions main" || bad "call stack does not mention main"
# The program still completes and prints 42 (breakpoint continued).
[ "$(printf '%s' "$broke" | tr -dc '0-9' | grep -o '42' | head -1)" = "42" ] && ok "broke run still computes 42 (continued)" || bad "broke run did not print 42 (got: $broke)"

echo "[test_vibe_break] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
