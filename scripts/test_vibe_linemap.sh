#!/usr/bin/env bash
# Regression test for the `vibe.linemap` custom section (#644): a static
# (wasm func index, code offset) -> (file, line) table emitted alongside the
# existing interior-line `dbg_line` probes in debug-break builds. Unlike the
# LIVE dbg_line hook (statement-boundary pauses, exercised by
# test_vibe_break_interior.sh), this table is consumed WITHOUT running the
# program: `vibewt --dump-linemap` reads it directly out of the compiled
# wasm, and the runner also uses it to annotate an uncaught TRAP's backtrace
# with the trapping statement's actual line (not just the function's
# declaration line).
#
# Builds a FRESH compiler+runner via scripts/install.sh into a throwaway
# VIBE_HOME/VIBE_BIN_DIR (the committed seed predates #644).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
unset RUST_BACKTRACE VIBE_RUNNER_BACKTRACE || true

install_log="$WORK/install.log"
bash scripts/install.sh >"$install_log" 2>&1 || true
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }
# Fresh-build detection (see test_vibe_break_interior.sh): without a
# standalone wasmtime, install.sh falls back to the committed seed compiler,
# which lags features that postdate the seed (#644 postdates it). CI installs
# wasmtime and always builds fresh; locally we skip instead of failing.
fresh_cli=1
grep -q "using committed seed compiler" "$install_log" && fresh_cli=0

pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

if [ "$fresh_cli" != "1" ]; then
  echo "skip: #644 vibe.linemap -- seed-fallback install (no standalone wasmtime)"
  echo "[test_vibe_linemap] passed: 0, failed: 0 (skipped)"
  exit 0
fi

tc="$(cat "$VIBE_HOME/toolchain")"
TC_DIR="$VIBE_HOME/toolchains/$tc"
VIBEWT="$TC_DIR/bin/vibewt"
CLI_WASM="$TC_DIR/lib/vibe-cli.wasm"
[ -x "$VIBEWT" ] || { echo "FAIL: vibewt runner not installed" >&2; exit 1; }
[ -s "$CLI_WASM" ] || { echo "FAIL: toolchain cli wasm not installed" >&2; exit 1; }

# A single-file program whose body has interior statements on known lines,
# mirroring test_vibe_break_interior.sh's layout (line 2 = bare-literal
# let, breakable only via the #644 ELet statement-offset fallback).
P="$WORK/p.vibex"
printf 'fn main with { Stdout } {\n  let a = 1\n  let b = a + 2\n  let c = b + 3\n  Stdout::write_stream("\\{c}\\n")\n}\n' > "$P"
OUT="$WORK/p.wasm"
env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_DEBUG_BREAK=1 VIBE_WASM_NAMES=1 \
  "$VIBEWT" "$CLI_WASM" "$P" "$OUT" main >"$WORK/compile.log" 2>&1
if [ -s "$OUT" ]; then
  ok "break-mode compile produced a wasm module"
else
  bad "break-mode compile failed: $(cat "$WORK/compile.log")"
fi

linemap_out="$("$VIBEWT" --dump-linemap "$OUT" 2>"$WORK/dump.log" || true)"
nrecords="$(printf '%s\n' "$linemap_out" | grep -c . || true)"
if [ "$nrecords" -ge 3 ]; then
  ok "dump-linemap emits at least one record per interior statement ($nrecords records)"
else
  bad "expected >=3 linemap records, got $nrecords: $linemap_out"
fi

# Lines 2/3/4 (a/b/c) must each resolve to file "p.vibex" with the matching
# line number, in increasing code-offset order (offsets strictly increase --
# later statements compile to later bytes in the same function body).
if printf '%s\n' "$linemap_out" | awk -F'\t' '{print $3, $4}' | grep -qx "p.vibex 2" \
  && printf '%s\n' "$linemap_out" | awk -F'\t' '{print $3, $4}' | grep -qx "p.vibex 3" \
  && printf '%s\n' "$linemap_out" | awk -F'\t' '{print $3, $4}' | grep -qx "p.vibex 4"; then
  ok "linemap resolves lines 2, 3, and 4 to p.vibex"
else
  bad "linemap missing an expected p.vibex line entry: $linemap_out"
fi
offsets="$(printf '%s\n' "$linemap_out" | awk -F'\t' '{print $2}')"
if [ "$(printf '%s\n' "$offsets" | sort -n -u | wc -l)" = "$(printf '%s\n' "$offsets" | wc -l)" ]; then
  ok "linemap offsets are unique (one per probe site)"
else
  bad "linemap offsets are not unique: $offsets"
fi
# All records share one function (there's only one user function, `main`);
# the func index column must be constant.
if [ "$(printf '%s\n' "$linemap_out" | awk -F'\t' '{print $1}' | sort -u | wc -l)" = "1" ]; then
  ok "all linemap records share main's single func index"
else
  bad "linemap records disagree on func index: $linemap_out"
fi

# A NON-break compile carries no `vibe.linemap` section at all (off by
# default; byte-identical normal builds).
OUT_PLAIN="$WORK/plain.wasm"
env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  "$VIBEWT" "$CLI_WASM" "$P" "$OUT_PLAIN" main >/dev/null 2>&1
plain_dump="$("$VIBEWT" --dump-linemap "$OUT_PLAIN" 2>/dev/null || true)"
if [ -z "$plain_dump" ]; then
  ok "a non-break build carries no vibe.linemap section"
else
  bad "non-break build unexpectedly produced linemap output: $plain_dump"
fi

# End-to-end: an uncaught trap in a --break run gets a "frame:" line with the
# TRAPPING statement's actual line, not just the function's declaration line
# (the pre-#644 limitation: only the innermost live dbg_line/dbg_break call
# knew its exact line; every OTHER frame just repeated the function's start
# line). `t.vibex`'s division is on line 4, while `main` declares on line 1.
T="$WORK/t.vibex"
printf 'fn main with { Stdout } {\n  let a = 1\n  let b = a + 2\n  let z = 10 / (b - 3)\n  Stdout::write_stream("\\{z}\\n")\n}\n' > "$T"
trap_out="$(VIBE_BREAK_AUTO=1 "$VIBE" run --break "$T:99" "$T" 2>&1 || true)"
if printf '%s' "$trap_out" | grep -qF "frame: main (t.vibex:4)"; then
  ok "uncaught trap annotates the CALLER frame with its actual line (t.vibex:4), not just main's declaration line"
else
  bad "expected 'frame: main (t.vibex:4)' in trap output; got: $trap_out"
fi
if ! printf '%s' "$trap_out" | grep -qF "frame: main (t.vibex:4) (t.vibex:4)"; then
  ok "the new frame annotation is not double-annotated by the launcher's funcmap-based stderr filter"
else
  bad "frame annotation was double-annotated: $trap_out"
fi

# A plain (non-break) run's trap is completely unaffected (no linemap, no
# "frame:" lines) -- the enhancement is additive and gated on debug-break.
plain_trap_out="$(VIBE_RUNNER_BACKTRACE= "$VIBE" run "$T" 2>&1 || true)"
if ! printf '%s' "$plain_trap_out" | grep -q "frame:"; then
  ok "a plain (non-break) run's trap output is unaffected (no 'frame:' lines)"
else
  bad "plain run unexpectedly emitted 'frame:' lines: $plain_trap_out"
fi

echo "----"
echo "[test_vibe_linemap] passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
