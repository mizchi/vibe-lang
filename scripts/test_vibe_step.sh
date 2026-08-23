#!/usr/bin/env bash
# Integration test for debugger DAP P3: STEP EXECUTION at a live breakpoint.
# `vibe run --break main <file>` pauses at main's entry. Reading commands from
# stdin then drives stepping:
#   s/step  -> step into the next function entry (pause at the very next entry)
#   n/next  -> step over (pause at the next entry at the same/shallower depth)
#   o/finish-> finish the current frame (pause once we return shallower)
#   c/empty -> continue (only explicit break_set hits pause)
#   q/quit  -> abort (exit 130)
#
# With the call chain main -> mid -> leaf, feeding `s\ns\ns\nc\n` should stop at
# main, then step into mid, then leaf, then continue to completion. A step pause
# prints `stopped at: <fn>` (vs `breakpoint hit:` for explicit break_set hits),
# and each frame is funcmap-annotated `(prog.vibex:LINE)` like P1.
#
# Pure runner-side: the per-entry `vibe::dbg_break` hook already fires at every
# user function entry; stepping is just the runner deciding WHEN to pause. The
# launcher keeps stdin attached so scripted input flows through.
#
# Installs a FRESH CLI wasm (carrying break instrumentation) into a throwaway
# VIBE_HOME/VIBE_BIN_DIR. Mirrors scripts/test_vibe_break.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RT="$ROOT_DIR/runtime/viberun/target/release/viberun"
# Rebuild the runner if it is missing OR older than any runner source.
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
# A clear call chain: main (line 3) -> mid (line 2) -> leaf (line 1). leaf(40)=41,
# mid=42, main=42.
cat > "$proj/prog.vibex" <<'EOF'
let leaf = (x: Int) -> Int { x + 1 }
let mid = (x: Int) -> Int { leaf(x) + 1 }
fn main with Stdout { Stdout::write_stream("\{mid(40)}\n") }
EOF

# 1. Plain `vibe run` is unaffected: prints 42, emits NO debugger output.
plain="$("$VIBE" run "$proj/prog.vibex" 2>&1)"
[ "$(printf '%s' "$plain" | grep -o '42' | head -1)" = "42" ] && ok "plain run computes 42" || bad "plain run did not print 42 (got: $plain)"
if printf '%s\n' "$plain" | grep -qE "breakpoint hit|stopped at"; then bad "plain run leaked debugger output"; else ok "plain run emits no debugger output"; fi

# 2. VIBE_BREAK_AUTO=1 still auto-continues without reading stdin (existing behavior).
auto="$(VIBE_BREAK_AUTO=1 "$VIBE" run --break main "$proj/prog.vibex" 2>&1)"
printf '%s\n' "$auto" | grep -qF "breakpoint hit: main" && ok "auto: breakpoint hit names main" || bad "auto: missing 'breakpoint hit: main'"
[ "$(printf '%s' "$auto" | tr -dc '0-9' | grep -o '42' | head -1)" = "42" ] && ok "auto: run still computes 42 (continued)" || bad "auto: did not print 42 (got: $auto)"

# 3. Step script: break at main, then `s` step into mid, `s` step into leaf,
#    then `c` continue. Assert the stepped-through functions appear in order.
stepped="$(printf 's\ns\ns\nc\n' | "$VIBE" run --break main "$proj/prog.vibex" 2>&1)"
echo "----- step: printf 's\\ns\\ns\\nc\\n' | vibe run --break main -----"
printf '%s\n' "$stepped"
echo "------------------------------------------------------------------"

# main is the explicit breakpoint -> labelled `breakpoint hit:`.
printf '%s\n' "$stepped" | grep -qF "breakpoint hit: main" && ok "step: initial pause is breakpoint hit: main" || bad "step: missing 'breakpoint hit: main'"
# After stepping, mid and leaf are step-induced pauses -> `stopped at:`.
printf '%s\n' "$stepped" | grep -qF "stopped at: mid" && ok "step: stepped into mid (stopped at: mid)" || bad "step: missing 'stopped at: mid'"
printf '%s\n' "$stepped" | grep -qF "stopped at: leaf" && ok "step: stepped into leaf (stopped at: leaf)" || bad "step: missing 'stopped at: leaf'"

# Order: the pause headers must appear main, then mid, then leaf.
order="$(printf '%s\n' "$stepped" | grep -E "breakpoint hit:|stopped at:" | sed -E 's/^(breakpoint hit|stopped at): //' | tr '\n' ' ')"
case "$order" in
  "main mid leaf "*) ok "step: pause order is main -> mid -> leaf (got: $order)" ;;
  *) bad "step: pause order not main->mid->leaf (got: $order)" ;;
esac

# Funcmap annotation `(prog.vibex:LINE)` appears on stepped frames (P1 behavior).
printf '%s\n' "$stepped" | grep -E "at (mid|leaf) \(prog\.vibex:[0-9]+\)" >/dev/null && ok "step: frames annotated with (prog.vibex:LINE)" || bad "step: missing (prog.vibex:LINE) annotation"

# The program still completes and prints 42 after continuing.
[ "$(printf '%s' "$stepped" | tr -dc '0-9' | grep -o '42' | head -1)" = "42" ] && ok "step: run completes and computes 42" || bad "step: did not print 42 (got: $stepped)"

# 4. `n` (step over) at main skips into nested calls: with `n` then `c`, mid/leaf
#    must NOT produce a `stopped at:` pause (depth of mid/leaf > pause_depth).
over="$(printf 'n\nc\n' | "$VIBE" run --break main "$proj/prog.vibex" 2>&1)"
if printf '%s\n' "$over" | grep -qE "stopped at: (mid|leaf)"; then
  bad "step-over: unexpectedly paused inside a nested call (got: $over)"
else
  ok "step-over (n): nested mid/leaf not paused"
fi
[ "$(printf '%s' "$over" | tr -dc '0-9' | grep -o '42' | head -1)" = "42" ] && ok "step-over: run completes and computes 42" || bad "step-over: did not print 42 (got: $over)"

# 5. `o` (finish) at main returns to a shallower frame (none) -> no further pause.
fin="$(printf 'o\n' | "$VIBE" run --break main "$proj/prog.vibex" 2>&1)"
[ "$(printf '%s' "$fin" | tr -dc '0-9' | grep -o '42' | head -1)" = "42" ] && ok "finish (o): run completes and computes 42" || bad "finish: did not print 42 (got: $fin)"

# 6. `q` (quit) at main aborts with exit 130.
qstatus=0
printf 'q\n' | "$VIBE" run --break main "$proj/prog.vibex" >/dev/null 2>&1 || qstatus=$?
[ "$qstatus" -eq 130 ] && ok "quit (q): aborts with exit 130" || bad "quit: expected exit 130, got $qstatus"

echo "[test_vibe_step] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
