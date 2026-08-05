#!/usr/bin/env bash
# Integration test for debugger span-arc step5: LINE-granularity breakpoints.
# `vibe run --break <file>:<line> <file>` must pause when execution reaches the
# function defined at that source line, print the pause line + call stack, then
# CONTINUE so the program finishes:
#   breakpoint hit: prog.vibex:1
#     at helper (prog.vibex:1)
#     at main (prog.vibex:2)
#   42
#
# How it works (opt-in, default-off so the selfhost fixpoint is unaffected):
#   * The SAME break-mode codegen as `--break <fn>` is used (VIBE_DEBUG_BREAK=1
#     emits a bare `call vibe::dbg_break` host hook at each user function entry).
#     NO new codegen instrumentation is added, so default (no-flag) builds stay
#     byte-identical (stage2==stage3 fixpoint holds).
#   * The runner parses `<file>:<line>` (or bare `<line>`) VIBE_BREAK entries into
#     a line break-set (alongside the function-name set). At each dbg_break it
#     resolves the entering function's declaration line via the `.funcmap` sidecar
#     (name<TAB>declLine) and pauses when that line is in the set, printing
#     `breakpoint hit: <file>:<line>`, then continues.
#   * `vibe run --break <file>:<line>` drives it, passing VIBE_BREAK / VIBE_FUNCMAP
#     / VIBE_BREAK_FILE; the `<file>:<line>` spec flows through unchanged.
#
# Scope: line breakpoints resolve to the function whose DECLARATION line matches.
# Mid-body line breakpoints and line-stepping are deferred (the selfhost AST
# carries no inner-statement source offsets — see the commit message).
#
# Installs a FRESH CLI wasm (carrying the break instrumentation) into a throwaway
# VIBE_HOME/VIBE_BIN_DIR. Mirrors scripts/test_vibe_break.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RT="$ROOT_DIR/runtime/viberun/target/release/viberun"
# Rebuild the runner if it is missing OR older than any runner source (a stale
# local binary would lack newly added line-break parsing).
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
# helper (declared on line 1) called by main (declared on line 2).
cat > "$proj/prog.vibex" <<'EOF'
export let helper = (x: Int) -> Int { x * 2 }
fn main with Stdout { Stdout::write_stream("\{helper(21)}\n") }
EOF

# 1. Plain `vibe run` is unaffected: prints 42, emits NO breakpoint output.
plain="$("$VIBE" run "$proj/prog.vibex" 2>&1)"
[ "$(printf '%s' "$plain" | grep -o '42' | head -1)" = "42" ] && ok "plain run computes 42" || bad "plain run did not print 42 (got: $plain)"
if printf '%s\n' "$plain" | grep -q "breakpoint hit"; then bad "plain run leaked breakpoint output"; else ok "plain run emits no breakpoint output"; fi

# 2. `vibe run --break prog.vibex:1` pauses at the line-1 function (helper),
#    prints `breakpoint hit: prog.vibex:1`, the call stack, then continues.
broke="$(VIBE_BREAK_AUTO=1 "$VIBE" run --break "prog.vibex:1" "$proj/prog.vibex" 2>&1)"
echo "----- vibe run --break prog.vibex:1 -----"; printf '%s\n' "$broke"; echo "-----------------------------------------"
printf '%s\n' "$broke" | grep -qF "breakpoint hit: prog.vibex:1" && ok "line breakpoint hit prints prog.vibex:1" || bad "missing 'breakpoint hit: prog.vibex:1'"
# A stack frame must mention the caller `main`.
printf '%s\n' "$broke" | grep -E "at main" >/dev/null && ok "call stack mentions main" || bad "call stack does not mention main"
# The program still completes and prints 42 (breakpoint continued).
[ "$(printf '%s' "$broke" | tr -dc '0-9' | grep -o '42' | head -1)" = "42" ] && ok "broke run still computes 42 (continued)" || bad "broke run did not print 42 (got: $broke)"

# 3. A bare `<line>` spec (no file) also pauses at the line-1 function.
bare="$(VIBE_BREAK_AUTO=1 "$VIBE" run --break "1" "$proj/prog.vibex" 2>&1)"
printf '%s\n' "$bare" | grep -qF "breakpoint hit: prog.vibex:1" && ok "bare line spec hits prog.vibex:1" || bad "bare line spec did not hit line 1 (got: $bare)"

# 4. A non-matching line spec does NOT pause but still runs to completion.
nohit="$(VIBE_BREAK_AUTO=1 "$VIBE" run --break "prog.vibex:99" "$proj/prog.vibex" 2>&1)"
if printf '%s\n' "$nohit" | grep -q "breakpoint hit"; then bad "non-matching line 99 should not pause"; else ok "non-matching line 99 does not pause"; fi
[ "$(printf '%s' "$nohit" | tr -dc '0-9' | grep -o '42' | head -1)" = "42" ] && ok "non-matching run still computes 42" || bad "non-matching run did not print 42 (got: $nohit)"

# 5. The existing function-name break path is NOT regressed.
fn="$(VIBE_BREAK_AUTO=1 "$VIBE" run --break helper "$proj/prog.vibex" 2>&1)"
printf '%s\n' "$fn" | grep -qF "breakpoint hit: helper" && ok "function-name break still works" || bad "function-name break regressed (got: $fn)"

echo "[test_vibe_break_line] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
