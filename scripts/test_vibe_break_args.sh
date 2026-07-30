#!/usr/bin/env bash
# Integration test for debugger DAP P2/P4: argument inspection at a breakpoint.
# `vibe run --break helper <file>` must, in addition to the P1 call stack, print
# the entering function's NAMED argument values (DAP P4):
#   breakpoint hit: helper
#     args: [x=20]
#     at helper (prog.vibex:1)
#     at main (prog.vibex:2)
#
# How it works (opt-in, default-off so the selfhost fixpoint is unaffected):
#   * In break mode the codegen spills each user function's i64 parameters to a
#     reserved memory region (dbgargs) before the `call vibe::dbg_break` hook,
#     and stores the param count; the two addresses are published in a
#     `vibe.dbgargs` custom section. The parameter NAMES (per function) are
#     published in a sibling `vibe.dbgnames` custom section (DAP P4).
#   * The runner parses both sections at load, then in `vibe::dbg_break` reads the
#     count + values out of the instance's exported memory, decodes them
#     (tagged-int aware: a tagged INT shows as `raw >> 2`), looks up the entering
#     function's parameter names, and prints `args: [name=value, ...]` alongside
#     the call stack (falling back to bare positional values if names are absent).
#
# Installs a FRESH CLI wasm (carrying the break instrumentation) into a throwaway
# VIBE_HOME/VIBE_BIN_DIR. Mirrors scripts/test_vibe_break.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RT="$ROOT_DIR/runtime/viberun/target/release/viberun"
# Rebuild the runner if it is missing OR older than any runner source (a stale
# local binary would lack newly added behavior like dbgargs decoding).
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
bash scripts/install.sh --cli-wasm "$cli" >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }

pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

proj="$WORK/proj"; mkdir -p "$proj"
# helper (line 1) called by main (line 2). main calls helper(20) then helper(1).
cat > "$proj/prog.vibex" <<'EOF'
export let helper = (x: Int) -> Int { x * 2 }
fn main with { Stdout } { Stdout::write_stream("\{helper(20) + helper(1)}\n") }
EOF

# 1. Plain `vibe run` is unaffected: prints 42 (20*2 + 1*2), no breakpoint/args.
plain="$("$VIBE" run "$proj/prog.vibex" 2>&1)"
[ "$(printf '%s' "$plain" | grep -o '42' | head -1)" = "42" ] && ok "plain run computes 42" || bad "plain run did not print 42 (got: $plain)"
if printf '%s\n' "$plain" | grep -q "args:"; then bad "plain run leaked args output"; else ok "plain run emits no args output"; fi

# 2. `vibe run --break helper` pauses at helper and prints its NAMED argument
#    values. The FIRST hit is helper(20), so the first `args:` line must report
#    the parameter name x bound to 20, i.e. `x=20` (DAP P4).
broke="$(VIBE_BREAK_AUTO=1 "$VIBE" run --break helper "$proj/prog.vibex" 2>&1)"
echo "----- vibe run --break helper -----"; printf '%s\n' "$broke"; echo "-----------------------------------"
printf '%s\n' "$broke" | grep -qF "breakpoint hit: helper" && ok "breakpoint hit names helper" || bad "missing 'breakpoint hit: helper'"
# An `args:` line must be present and the first one must report x=20.
first_args="$(printf '%s\n' "$broke" | grep -E "^[[:space:]]*args:" | head -1)"
[ -n "$first_args" ] && ok "args line present ($first_args)" || bad "no 'args:' line emitted"
printf '%s\n' "$first_args" | grep -qF "x=20" && ok "first hit (helper(20)) reports named arg x=20" || bad "first args line does not contain x=20 (got: $first_args)"
# The program still completes and prints 42 (breakpoint continued).
[ "$(printf '%s' "$broke" | tr -dc '0-9' | grep -o '42' | head -1)" = "42" ] && ok "broke run still computes 42 (continued)" || bad "broke run did not print 42 (got: $broke)"

echo "[test_vibe_break_args] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
