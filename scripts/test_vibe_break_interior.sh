#!/usr/bin/env bash
# Regression test for INTERIOR-line breakpoints (span-arc step5, docs/release-
# roadmap.md テーマ3 debugger). Unlike the function-declaration-line breakpoints
# (test_vibe_break_line.sh), these pause at a statement IN THE MIDDLE of a
# function body: the break-mode codegen emits `call vibe::dbg_line(<line>)` at
# each ELet/ELetMut/ESeq boundary, and the runner pauses when that line is in the
# break-set or on a step. v1-scoped to single-file entry programs.
#
# Builds a FRESH compiler+runner via install/install.sh into a throwaway
# VIBE_HOME/VIBE_BIN_DIR (the committed seed predates dbg_line).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
unset RUST_BACKTRACE || true

install_log="$WORK/install.log"
bash install/install.sh >"$install_log" 2>&1 || true
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }
# Fresh-build detection: without a standalone wasmtime, install.sh falls back
# to the committed seed compiler, which lags features that postdate the seed
# (the #644 bare-literal stmt-offset case below). CI installs wasmtime and
# always builds fresh; locally we skip seed-lagging cases instead of failing.
fresh_cli=1
grep -q "using committed seed compiler" "$install_log" && fresh_cli=0

pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

# A single-file program whose body has interior statements on known lines.
#   line 2: let a = 1       (bare literal -> breakable via the ELet stmt offset, #644)
#   line 3: let b = a + 2   (identifier-led -> breakable)
#   line 4: let c = b + 3   (identifier-led -> breakable)
P="$WORK/p.vibex"
printf 'fn main with Stdout {\n  let a = 1\n  let b = a + 2\n  let c = b + 3\n  Stdout::write_stream("\\{c}\\n")\n}\n' > "$P"

# 0. (#644) break at line 2, a bare-literal `let a = 1`. The literal value
#    carries no offset of its own; the ELet statement offset (the `let`
#    keyword token, threaded by the parser) anchors the dbg_line probe.
#    Requires a fresh-built compiler (the committed seed predates #644).
if [ "$fresh_cli" = "1" ]; then
  out2="$(VIBE_BREAK_AUTO=1 "$VIBE" run --break "$P:2" "$P" 2>&1 || true)"
  if printf '%s' "$out2" | grep -qF "breakpoint hit: p.vibex:2"; then
    ok "bare-literal interior line 2 pauses (#644)"
  else
    bad "bare-literal line 2 should pause; got: $out2"
  fi
else
  echo "skip: bare-literal line 2 (#644) -- seed-fallback install (no standalone wasmtime)"
fi

# 1. break at interior line 3 (mid-function, NOT the function decl line).
out3="$(VIBE_BREAK_AUTO=1 "$VIBE" run --break "$P:3" "$P" 2>&1 || true)"
if printf '%s' "$out3" | grep -qF "breakpoint hit: p.vibex:3"; then
  ok "interior line 3 pauses (breakpoint hit: p.vibex:3)"
else
  bad "interior line 3 should pause; got: $out3"
fi

# 2. break at interior line 4.
out4="$(VIBE_BREAK_AUTO=1 "$VIBE" run --break "$P:4" "$P" 2>&1 || true)"
if printf '%s' "$out4" | grep -qF "breakpoint hit: p.vibex:4"; then
  ok "interior line 4 pauses (breakpoint hit: p.vibex:4)"
else
  bad "interior line 4 should pause; got: $out4"
fi

# 3. the broken run still computes its result (42-style: here main returns 6).
if printf '%s' "$out3" | grep -qx "6"; then
  ok "broken run still computes 6 (continued)"
else
  bad "broken run should still print 6; got: $out3"
fi

# 4. line STEPPING: break at line 3, then `s` (step) stops at the next statement
#    line 4 (labelled `stopped at:`). Confirms dbg_line drives line-granularity
#    step, not just breakpoints.
outs="$(printf 's\nc\n' | "$VIBE" run --break "$P:3" "$P" 2>&1 || true)"
if printf '%s' "$outs" | grep -qF "stopped at: p.vibex:4"; then
  ok "step (s) from line 3 advances to the next statement line 4"
else
  bad "step from line 3 should stop at line 4; got: $outs"
fi

# 5. a non-matching interior line (99) does not pause; the program runs clean.
out99="$(VIBE_BREAK_AUTO=1 "$VIBE" run --break "$P:99" "$P" 2>&1 || true)"
if printf '%s' "$out99" | grep -qx "6" && ! printf '%s' "$out99" | grep -q "breakpoint hit"; then
  ok "non-matching interior line 99 does not pause"
else
  bad "interior line 99 should not pause; got: $out99"
fi

# 6. the DEFAULT run (no --break) is unaffected: no debug output, just the result.
outd="$("$VIBE" run "$P" 2>&1 || true)"
if printf '%s' "$outd" | grep -qx "6" && ! printf '%s' "$outd" | grep -q "breakpoint\|stopped at"; then
  ok "default run is unaffected (no instrumentation output)"
else
  bad "default run should be clean; got: $outd"
fi

# 7-8. MULTI-FILE: a `--break <file>:<line>` resolves to the right FILE. `compute`
#      lives in helper.vibe; main.vibex imports it. dbg_line carries a file id so
#      `helper.vibe:3` breaks in the imported module and `main.vibex:3` in the entry
#      — the per-file provenance + `vibe.dbgfiles` table disambiguate colliding
#      line numbers across files.
printf 'export let compute = (n: Int) -> Int {\n  let doubled = n + n\n  let plused = doubled + 5\n  plused\n}\n' > "$WORK/helper.vibe"
printf 'import ./helper.vibe { compute }\nfn main with Stdout {\n  let r = compute(10)\n  Stdout::write_stream("\\{r}\\n")\n}\n' > "$WORK/main.vibex"
outh="$(VIBE_BREAK_AUTO=1 "$VIBE" run --break "helper.vibe:3" "$WORK/main.vibex" 2>&1 || true)"
if printf '%s' "$outh" | grep -qF "breakpoint hit: helper.vibe:3"; then
  ok "multi-file: interior line in an IMPORTED module (helper.vibe:3) pauses"
else
  bad "multi-file helper.vibe:3 should pause; got: $outh"
fi
outm="$(VIBE_BREAK_AUTO=1 "$VIBE" run --break "main.vibex:3" "$WORK/main.vibex" 2>&1 || true)"
if printf '%s' "$outm" | grep -qF "breakpoint hit: main.vibex:3" && ! printf '%s' "$outm" | grep -qF "helper.vibe:3"; then
  ok "multi-file: interior line in the ENTRY file (main.vibex:3) pauses, not the import"
else
  bad "multi-file main.vibex:3 should pause (and not helper); got: $outm"
fi

echo "----"
echo "[test_vibe_break_interior] passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
