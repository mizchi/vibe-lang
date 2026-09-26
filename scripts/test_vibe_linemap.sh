#!/usr/bin/env bash
# Regression test for the `vibe.linemap` custom section (#644): a static
# (wasm func index, code offset) -> (file, line) table emitted alongside the
# existing interior-line `dbg_line` probes in debug-break builds. Unlike the
# LIVE dbg_line hook (statement-boundary pauses, exercised by
# test_vibe_break_interior.sh), this table is consumed WITHOUT running the
# program: `viberun --dump-linemap` reads it directly out of the compiled
# wasm, and the runner also uses it to annotate an uncaught TRAP's backtrace
# with the trapping statement's actual line (not just the function's
# declaration line).
#
# Builds a FRESH compiler+runner via install/install.sh into a throwaway
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
bash install/install.sh >"$install_log" 2>&1 || true
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
VIBERUN="$TC_DIR/bin/viberun"
CLI_WASM="$TC_DIR/lib/vibe-cli.wasm"
[ -x "$VIBERUN" ] || { echo "FAIL: viberun runner not installed" >&2; exit 1; }
[ -s "$CLI_WASM" ] || { echo "FAIL: toolchain cli wasm not installed" >&2; exit 1; }

# A single-file program whose body has interior statements on known lines,
# mirroring test_vibe_break_interior.sh's layout (line 2 = bare-literal
# let, breakable only via the #644 ELet statement-offset fallback).
P="$WORK/p.vibex"
printf 'fn main allows Stdout {\n  let a = 1\n  let b = a + 2\n  let c = b + 3\n  Stdout::write_stream("\\{c}\\n")\n}\n' > "$P"
OUT="$WORK/p.wasm"
env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_DEBUG_BREAK=1 VIBE_WASM_NAMES=1 \
  "$VIBERUN" "$CLI_WASM" "$P" "$OUT" main >"$WORK/compile.log" 2>&1
if [ -s "$OUT" ]; then
  ok "break-mode compile produced a wasm module"
else
  bad "break-mode compile failed: $(cat "$WORK/compile.log")"
fi

linemap_out="$("$VIBERUN" --dump-linemap "$OUT" 2>"$WORK/dump.log" || true)"
nrecords="$(printf '%s\n' "$linemap_out" | grep -c . || true)"
if [ "$nrecords" -ge 3 ]; then
  ok "dump-linemap emits at least one record per interior statement ($nrecords records)"
else
  bad "expected >=3 linemap records, got $nrecords: $linemap_out"
fi

# Lines 2/3/4 (a/b/c) must each resolve to file "p.vibex" with the matching
# line number, in increasing code-offset order (offsets strictly increase --
# later statements compile to later bytes in the same function body).
# #2199: the table holds the PATH the compiler opened (here an absolute one
# under $WORK), so the file column is compared by its last component.
lm_basenames() { printf '%s\n' "$1" | awk -F'\t' '{n = split($3, seg, "/"); print seg[n], $4}'; }
if lm_basenames "$linemap_out" | grep -qx "p.vibex 2" \
  && lm_basenames "$linemap_out" | grep -qx "p.vibex 3" \
  && lm_basenames "$linemap_out" | grep -qx "p.vibex 4"; then
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

# #2199: a NON-break production compile carries a compact `vibe.linemap`
# so an uncaught trap can report path:line without debug-break probes.
# VIBE_WASM_NAMES=1 keeps the section; `vibe build` strips it with `name`.
OUT_PLAIN="$WORK/plain.wasm"
env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_WASM_NAMES=1 \
  "$VIBERUN" "$CLI_WASM" "$P" "$OUT_PLAIN" main >/dev/null 2>&1
plain_dump="$("$VIBERUN" --dump-linemap "$OUT_PLAIN" 2>/dev/null || true)"
plain_nrecords="$(printf '%s\n' "$plain_dump" | grep -c . || true)"
if [ "$plain_nrecords" -ge 1 ]; then
  ok "a non-break build carries a compact vibe.linemap ($plain_nrecords records)"
else
  bad "non-break build produced no linemap output (#2199): $plain_dump"
fi

# End-to-end: an uncaught trap in a --break run gets a "frame:" line with the
# TRAPPING statement's actual line, not just the function's declaration line
# (the pre-#644 limitation: only the innermost live dbg_line/dbg_break call
# knew its exact line; every OTHER frame just repeated the function's start
# line). `t.vibex`'s division is on line 4, while `main` declares on line 1.
T="$WORK/t.vibex"
printf 'fn main allows Stdout {\n  let a = 1\n  let b = a + 2\n  let z = 10 / (b - 3)\n  Stdout::write_stream("\\{z}\\n")\n}\n' > "$T"
# The location is the PATH the compiler opened, not a bare basename: a
# basename is not openable from the project root, and two packages both
# holding an `index.vibe` would print the same one (#2199, PR #2867).
frame_re='frame: main \(.*t\.vibex:4\)'
trap_out="$(VIBE_BREAK_AUTO=1 "$VIBE" run --break "$T:99" "$T" 2>&1 || true)"
if printf '%s' "$trap_out" | grep -qE "$frame_re"; then
  ok "uncaught trap annotates the CALLER frame with its actual line (t.vibex:4), not just main's declaration line"
else
  bad "expected 'frame: main (<path>/t.vibex:4)' in trap output; got: $trap_out"
fi
if ! printf '%s' "$trap_out" | grep -qE 'frame: main \(.*t\.vibex:4\) \(.*t\.vibex:4\)'; then
  ok "the new frame annotation is not double-annotated by the launcher's funcmap-based stderr filter"
else
  bad "frame annotation was double-annotated: $trap_out"
fi

# #2199: a plain (non-break) run's trap reports the trapping statement's
# path:line via the production linemap.
plain_trap_out="$(env -u VIBE_RUNNER_BACKTRACE -u RUST_BACKTRACE "$VIBE" run "$T" 2>&1 || true)"
if printf '%s' "$plain_trap_out" | grep -qE "$frame_re"; then
  ok "a plain (non-break) trap annotates the access with t.vibex:4"
else
  bad "plain run missing 'frame: main (<path>/t.vibex:4)': $plain_trap_out"
fi
# The directory is part of it: `$T` is under $WORK, so the annotation must
# carry a path and not just `t.vibex:4`. This is what fails if `vibe.dbgfiles`
# goes back to basenames.
if printf '%s' "$plain_trap_out" | grep -qE 'frame: main \(.*/t\.vibex:4\)'; then
  ok "the trap location carries the source PATH, not just the file name"
else
  bad "expected a directory in the trap location; got: $plain_trap_out"
fi

# #2199: the compact table is identified by its `VLM1` marker, not by the
# section name alone -- #644's 16-byte records under the same name decode as
# LEB quadruples without erroring. A module whose marker is corrupted must
# report NO location rather than a fabricated one.
LEGACY="$WORK/legacy.wasm"
OUT_T="$WORK/t.wasm"
env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_WASM_NAMES=1 \
  "$VIBERUN" "$CLI_WASM" "$T" "$OUT_T" main >/dev/null 2>&1
if [ -s "$OUT_T" ] && [ -n "$("$VIBERUN" --dump-linemap "$OUT_T" 2>/dev/null || true)" ]; then
  ok "the sample compiles with a readable linemap (control for the marker case)"
else
  bad "expected a linemap in $OUT_T before corrupting its marker"
fi
node -e '
const fs = require("node:fs");
const src = fs.readFileSync(process.argv[1]);
const at = src.indexOf(Buffer.from("vibe.linemapVLM1", "latin1"));
if (at < 0) { console.error("no marked vibe.linemap section to corrupt"); process.exit(1); }
const out = Buffer.from(src);
out.write("VLM0", at + "vibe.linemap".length, "latin1");
fs.writeFileSync(process.argv[2], out);
' "$OUT_T" "$LEGACY"
legacy_dump="$("$VIBERUN" --dump-linemap "$LEGACY" 2>/dev/null || true)"
if [ -z "$legacy_dump" ]; then
  ok "an unmarked vibe.linemap dumps nothing instead of fabricated rows"
else
  bad "unmarked vibe.linemap was decoded anyway: $legacy_dump"
fi
# #3126: the division by zero prints its OWN location before it traps
# (`Int `/` by zero at <path>/t.vibex:4:13`), so a `t.vibex:N` in the output
# no longer means the linemap spoke. What an unmarked table must not add is a
# SECOND location: every `t.vibex:N` has to sit on the program's own line.
# The marked module is the control -- the runner annotates its frame from the
# linemap, so the negative check below is not vacuous.
div_msg_re='^Int `/` by zero at .*/t\.vibex:4:[0-9]+$'
marked_trap="$(env -u VIBE_RUNNER_BACKTRACE -u RUST_BACKTRACE "$VIBERUN" "$OUT_T" 2>&1 || true)"
if printf '%s\n' "$marked_trap" | grep -vE "$div_msg_re" | grep -qE 't\.vibex:[0-9]+'; then
  ok "a marked vibe.linemap adds a location of its own at a trap (control)"
else
  bad "expected the marked module's trap to carry a linemap location besides the program's message: $marked_trap"
fi
legacy_trap="$(env -u VIBE_RUNNER_BACKTRACE -u RUST_BACKTRACE "$VIBERUN" "$LEGACY" 2>&1 || true)"
if printf '%s\n' "$legacy_trap" | grep -qE "$div_msg_re"; then
  ok "the unmarked module still reaches the trap and prints the program's own message"
else
  bad "expected 'Int \`/\` by zero at <path>/t.vibex:4:<col>' from the unmarked module: $legacy_trap"
fi
if ! printf '%s\n' "$legacy_trap" | grep -vE "$div_msg_re" | grep -qE 't\.vibex:[0-9]+'; then
  ok "an unmarked vibe.linemap annotates no location at a trap"
else
  bad "unmarked vibe.linemap produced a location: $legacy_trap"
fi

echo "----"
echo "[test_vibe_linemap] passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
