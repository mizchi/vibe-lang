#!/usr/bin/env bash
# Regression test for `vibe diagnostics` (LSP multi-diagnostic MVP, テーマ4 土台A).
# The recovering parser (parse_program_recovering) NEVER rethrows on the first
# syntax error: it records the located (`line:col`) message, resynchronizes at
# the next top-level statement boundary, and keeps parsing. So a file with two
# INDEPENDENT top-level syntax errors yields TWO located diagnostics referencing
# DIFFERENT lines — proving recovery collected past the first error. A clean
# file yields empty output.
#
# The committed seed predates this feature, so this test builds a FRESH compiler
# via scripts/install.sh (default, no --cli-wasm seed override) into a throwaway
# VIBE_HOME/VIBE_BIN_DIR so it never touches a real install.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
unset RUST_BACKTRACE || true

# Fresh compiler (NOT the seed): the seed predates `vibe diagnostics`.
bash scripts/install.sh >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }

pass=0; fail=0

# Two INDEPENDENT top-level syntax errors with a valid statement between them.
# `export let a = = 1` (line 1) and `export let b = = 2` (line 3) are both bad
# (double `=`); `export let ok = 1` (line 2) parses fine. Recovery must surface
# BOTH errors, located on DIFFERENT lines (line 1 and line 3).
# #946: EXACTLY 2 — the anchor-based resync + (pos, message) dedupe must not
# re-report the same broken statement 4-5x from intermediate restart points.
multi="$WORK/multi.vibe"
printf 'export let a = = 1\nexport let ok = 1\nexport let b = = 2\n' > "$multi"

out="$("$VIBE" diagnostics "$multi" 2>/dev/null || true)"
nlines="$(printf '%s\n' "$out" | grep -c 'line ' || true)"
if [ "$nlines" -eq 2 ]; then
  echo "ok: two independent syntax errors -> exactly $nlines located diagnostics"; pass=$((pass + 1))
else
  echo "FAIL: expected exactly 2 located diagnostics (dedup, #946), got $nlines:" >&2
  printf '%s\n' "$out" >&2
  fail=$((fail + 1))
fi

if printf '%s\n' "$out" | grep -q 'line 1:' && printf '%s\n' "$out" | grep -q 'line 3:'; then
  echo "ok: diagnostics reference DIFFERENT lines (line 1 and line 3)"; pass=$((pass + 1))
else
  echo "FAIL: expected diagnostics on line 1 AND line 3 (recovery past first error):" >&2
  printf '%s\n' "$out" >&2
  fail=$((fail + 1))
fi

# #946: a LEXER error must surface as exactly one located diagnostic, not an
# empty ("clean") report. `$` is not a lexable character; the recovering lexer
# records it at line 1 col 18 and diagnostics reports it located.
lexerr="$WORK/lexerr.vibe"
printf 'export let a = 1 $\n' > "$lexerr"
out_lex="$("$VIBE" diagnostics "$lexerr" 2>/dev/null || true)"
nlex="$(printf '%s\n' "$out_lex" | grep -c 'line ' || true)"
if [ "$nlex" -eq 1 ] && printf '%s\n' "$out_lex" | grep -q 'line 1:18: unexpected character'; then
  echo "ok: lexer error -> 1 located diagnostic"; pass=$((pass + 1))
else
  echo "FAIL: expected exactly 1 located lexer diagnostic (line 1:18: unexpected character...), got:" >&2
  printf '%s\n' "$out_lex" >&2
  fail=$((fail + 1))
fi

# #963 (Codex P2 on #946): a bad escape INSIDE a string must yield exactly ONE
# diagnostic. The recovering lexer resumes past the whole quoted construct;
# resuming inside it re-lexed the interior and invented follow-on noise (the
# backslash as an unexpected char, the closing quote as a new unterminated
# string).
badesc="$WORK/badesc.vibe"
printf 'let s = "\\q"\n' > "$badesc"
out_esc="$("$VIBE" diagnostics "$badesc" 2>/dev/null || true)"
nesc="$(printf '%s\n' "$out_esc" | grep -c 'line ' || true)"
if [ "$nesc" -eq 1 ] && printf '%s\n' "$out_esc" | grep -q 'line 1:9: invalid escape'; then
  echo "ok: bad string escape -> exactly 1 located diagnostic"; pass=$((pass + 1))
else
  echo "FAIL: expected exactly 1 located diagnostic (line 1:9: invalid escape...), got:" >&2
  printf '%s\n' "$out_esc" >&2
  fail=$((fail + 1))
fi

# #963 (Codex P2 on #946): when a failed statement's error anchor IS the first
# token of the NEXT top-level statement (`export let a =` runs into `test`),
# recovery must resume AT that anchor so the second statement's own independent
# error is still reported: exactly 2 diagnostics (line 2:1 + line 2:16).
anchor2="$WORK/anchor2.vibe"
printf 'export let a =\ntest "x" { 1 + }\n' > "$anchor2"
out_a2="$("$VIBE" diagnostics "$anchor2" 2>/dev/null || true)"
na2="$(printf '%s\n' "$out_a2" | grep -c 'line ' || true)"
if [ "$na2" -eq 2 ] && printf '%s\n' "$out_a2" | grep -q 'line 2:1: ' && printf '%s\n' "$out_a2" | grep -q 'line 2:16: '; then
  echo "ok: anchor-on-next-statement -> both independent errors reported"; pass=$((pass + 1))
else
  echo "FAIL: expected exactly 2 diagnostics (line 2:1 and line 2:16), got:" >&2
  printf '%s\n' "$out_a2" >&2
  fail=$((fail + 1))
fi

# A clean file -> empty output.
clean="$WORK/clean.vibe"
printf 'export let add = (a: Int, b: Int) -> Int { a + b }\n' > "$clean"
out_clean="$("$VIBE" diagnostics "$clean" 2>/dev/null || true)"
if [ -z "$out_clean" ]; then
  echo "ok: clean file -> empty diagnostics"; pass=$((pass + 1))
else
  echo "FAIL: clean file should have no diagnostics, got '$out_clean'" >&2; fail=$((fail + 1))
fi

# #946(3): `vibe check` and `vibe diagnostics` must AGREE on an
# empty/comments-only file. Before this fix, `check` reused the full compile
# path and hard-errored ("no functions found to compile" -- a real BUILD
# constraint, not a check-only one), while `diagnostics` correctly reported
# clean on the identical input -- two contradictory judgments on one file.
empty="$WORK/empty.vibe"
printf '// just a comment\n' > "$empty"
out_empty_diag="$("$VIBE" diagnostics "$empty" 2>/dev/null || true)"
"$VIBE" check "$empty" >/dev/null 2>&1 && rc_empty_check=0 || rc_empty_check=$?
if [ -z "$out_empty_diag" ] && [ "$rc_empty_check" -eq 0 ]; then
  echo "ok: empty file -> check and diagnostics agree (both clean)"; pass=$((pass + 1))
else
  echo "FAIL: expected check exit 0 + empty diagnostics for a comment-only file (check rc=$rc_empty_check, diagnostics='$out_empty_diag')" >&2
  fail=$((fail + 1))
fi

# #946(4): an inline-wasm codegen validation error (e.g. a SIMD lane index out
# of range) must be a located diagnostic, not an empty ("clean") report --
# `compile`/`check` already fail on this with a located error; `diagnostics`
# used to report clean because it only ever ran the type checker, never the
# inline-wasm assembler that actually catches this class of bug.
badlane="$WORK/badlane.vibe"
printf 'fn bad_lane(a: Int) -> Int = wasm "(i8x16.extract_lane_s 16 (local.get $a))"\n\nexport fn main() -> Int {\n  bad_lane(1)\n}\n' > "$badlane"
out_badlane="$("$VIBE" diagnostics "$badlane" 2>/dev/null || true)"
if printf '%s\n' "$out_badlane" | grep -q 'line 1:' && printf '%s\n' "$out_badlane" | grep -q 'lane index 16 is out of range'; then
  echo "ok: inline-wasm lane error -> located diagnostic"; pass=$((pass + 1))
else
  echo "FAIL: expected a located 'lane index 16 is out of range' diagnostic, got:" >&2
  printf '%s\n' "$out_badlane" >&2
  fail=$((fail + 1))
fi

# #946(1,2): a unicode identifier char must report ONE diagnostic per actual
# (possibly multi-byte) character, with the ORIGINAL character text -- not one
# diagnostic per UTF-8 continuation BYTE, and not a mojibake replacement
# character built from a single lone byte (String::from_char_code only ever
# encodes one raw byte; this lexer is byte-indexed).
unicode="$WORK/unicode.vibe"
printf 'export let \xe3\x81\x93\xe3\x82\x93\xe3\x81\xab\xe3\x81\xa1\xe3\x81\xaf = 42\n' > "$unicode"
out_unicode="$("$VIBE" diagnostics "$unicode" 2>/dev/null || true)"
n_unicode="$(printf '%s\n' "$out_unicode" | grep -c 'line ' || true)"
if [ "$n_unicode" -eq 5 ] && printf '%s\n' "$out_unicode" | grep -qF 'unexpected character: こ'; then
  echo "ok: unicode identifier -> one diagnostic per character (5), real char in message"; pass=$((pass + 1))
else
  echo "FAIL: expected exactly 5 located diagnostics with the real characters, got:" >&2
  printf '%s\n' "$out_unicode" >&2
  fail=$((fail + 1))
fi

# #946(1,2): a leading UTF-8 BOM (EF BB BF) is skipped like any other editor
# artifact, not reported as an unlexable character (matches every mainstream
# tokenizer's handling of a leading BOM) -- both check and diagnostics must
# agree the file is clean.
bomf="$WORK/bom.vibe"
printf '\xef\xbb\xbfexport let a = 1\n' > "$bomf"
out_bom_diag="$("$VIBE" diagnostics "$bomf" 2>/dev/null || true)"
"$VIBE" check "$bomf" >/dev/null 2>&1 && rc_bom_check=0 || rc_bom_check=$?
if [ -z "$out_bom_diag" ] && [ "$rc_bom_check" -eq 0 ]; then
  echo "ok: leading UTF-8 BOM is skipped (both check and diagnostics clean)"; pass=$((pass + 1))
else
  echo "FAIL: expected a leading BOM to be silently skipped (check rc=$rc_bom_check, diagnostics='$out_bom_diag')" >&2
  fail=$((fail + 1))
fi

# #946(4): a pathologically deep expression recurses the checker (itself
# compiled to wasm) past the native call stack -- a host-level crash
# (wasmtime's graceful `Trap::StackOverflow` in runtime/viberun,
# where this test's freshly `install.sh`-built toolchain actually runs; a JS
# RangeError under the node-based scripts/wasm_vibe_host_runner.js) that no
# `handle {...} with Error {...}` inside the compiled program can intercept.
# This used to surface as a raw uncaught-exception crash dump that `vibe
# check`/`vibe diagnostics`'s `>/dev/null 2>&1 || true` wrapper silently
# swallowed into "clean". Both host runners now catch it and write the same
# `.diag` sidecar the checker's own error paths use, so both commands report
# a real (if unlocated) diagnostic instead.
#
# wasmtime's configured wasm-stack budget is 64 MiB (vs. V8's much smaller
# default under node) -- empirically a 100,000-deep chain still completes
# clean under the production (wasmtime) toolchain this test installs, while
# 300,000 reliably overflows. 500,000 keeps a comfortable margin; a plain
# `for` loop calling `printf` 500,000 times is too slow, so build the chain
# with one `printf` call recycling its format string across `seq`'s args.
deepexpr="$WORK/deepexpr.vibe"
{
  printf 'export fn f() -> Int {\n  1'
  printf '%.0s + 1' $(seq 1 500000)
  printf '\n}\n'
} > "$deepexpr"
out_deep="$("$VIBE" diagnostics "$deepexpr" 2>/dev/null || true)"
if printf '%s\n' "$out_deep" | grep -qi 'too deeply nested'; then
  echo "ok: pathologically deep expression -> diagnostic (not silently clean)"; pass=$((pass + 1))
else
  echo "FAIL: expected a 'too deeply nested' diagnostic for a 500000-deep expression, got:" >&2
  printf '%s\n' "$out_deep" >&2
  fail=$((fail + 1))
fi
# #1567 slice 2: `vibe check` reports on STDOUT (stderr is for warnings and
# launcher-level failures), so read the crash report from there.
deep_check_out="$WORK/deepexpr_check.stdout"
"$VIBE" check "$deepexpr" >"$deep_check_out" 2>/dev/null && rc_deep_check=0 || rc_deep_check=$?
if [ "$rc_deep_check" -ne 0 ] && grep -qi 'too deeply nested' "$deep_check_out" 2>/dev/null; then
  echo "ok: vibe check on the same file also reports the crash, not just failing"; pass=$((pass + 1))
else
  echo "FAIL: expected 'vibe check' to fail with a 'too deeply nested' message on stdout (rc=$rc_deep_check):" >&2
  cat "$deep_check_out" >&2 2>/dev/null
  fail=$((fail + 1))
fi

# #820 sub-item 1: `--json` emits the same diagnostics as an LSP-shaped
# JSON array (0-based line/character, matching the LSP protocol, unlike the
# 1-based `line L:C:` text form above) instead of plain text.
out_lex_json="$("$VIBE" diagnostics --json "$lexerr" 2>/dev/null || true)"
if python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert len(d) == 1, f'expected 1 entry, got {len(d)}'
e = d[0]
assert e['range']['start']['line'] == 0, e
assert e['range']['start']['character'] == 17, e  # 0-based: 'line 1:18' -> character 17
assert 'unexpected character' in e['message'], e
assert e['source'] == 'vibe', e
" "$out_lex_json" 2>/tmp/vibe_diag_json_err; then
  echo "ok: --json lexer diagnostic has correct 0-based range + message"; pass=$((pass + 1))
else
  echo "FAIL: --json lexer diagnostic malformed:" >&2
  cat /tmp/vibe_diag_json_err >&2 2>/dev/null
  printf '%s\n' "$out_lex_json" >&2
  fail=$((fail + 1))
fi
rm -f /tmp/vibe_diag_json_err

out_multi_json="$("$VIBE" diagnostics --json "$multi" 2>/dev/null || true)"
if python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert len(d) == 2, f'expected 2 entries, got {len(d)}'
lines = sorted(e['range']['start']['line'] for e in d)
assert lines == [0, 2], lines  # 0-based: source lines 1 and 3
" "$out_multi_json" 2>/tmp/vibe_diag_json_err; then
  echo "ok: --json reports both independent syntax errors as separate entries"; pass=$((pass + 1))
else
  echo "FAIL: --json multi-error output malformed:" >&2
  cat /tmp/vibe_diag_json_err >&2 2>/dev/null
  printf '%s\n' "$out_multi_json" >&2
  fail=$((fail + 1))
fi
rm -f /tmp/vibe_diag_json_err

out_clean_json="$("$VIBE" diagnostics --json "$clean" 2>/dev/null || true)"
if [ "$out_clean_json" = "[]" ]; then
  echo "ok: --json clean file -> [] (valid JSON, not empty output)"; pass=$((pass + 1))
else
  echo "FAIL: expected --json clean file to print '[]', got '$out_clean_json'" >&2
  fail=$((fail + 1))
fi

# #820 sub-item 2 (structured fix-it, minimal slice): an effect-row-mismatch
# diagnostic's `data` field names the exact function + operations to add, with
# NO position (resolving `target` to a location is `vibe symbols`'s job, kept
# out of this field on purpose -- see lsp_server.vibe's lsp_effect_row_mismatch_fix).
fixit="$WORK/fixit.vibe"
printf 'effect Ask {\n  Value(String) -> Int\n}\n\nfn asks() -> Int {\n  perform Ask::Value("q")\n}\n' > "$fixit"
out_fixit_json="$("$VIBE" diagnostics --json "$fixit" 2>/dev/null || true)"
if python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert len(d) == 1, f'expected 1 entry, got {len(d)}'
fix = d[0]['data']
assert fix is not None, d[0]
assert fix['kind'] == 'add_with_clause', fix
assert fix['target'] == 'asks', fix
assert fix['add'] == ['Ask::Value'], fix
assert fix['with'] == ['Ask::Value'], fix
assert 'vibe symbols' in fix['note'], fix
" "$out_fixit_json" 2>/tmp/vibe_diag_json_err; then
  echo "ok: --json effect-row-mismatch carries a structured fix-it in data"; pass=$((pass + 1))
else
  echo "FAIL: --json fix-it data malformed:" >&2
  cat /tmp/vibe_diag_json_err >&2 2>/dev/null
  printf '%s\n' "$out_fixit_json" >&2
  fail=$((fail + 1))
fi
rm -f /tmp/vibe_diag_json_err

# `vibe symbols` must actually resolve the fix-it's `target` to a real
# position, proving the documented hand-off works end-to-end (not just that
# both commands run in isolation).
if "$VIBE" symbols "$fixit" | grep -qE '^asks [0-9]+ [0-9]+ [0-9]+$'; then
  echo "ok: vibe symbols resolves the fix-it's target function to a position"; pass=$((pass + 1))
else
  echo "FAIL: vibe symbols did not resolve 'asks' to a position:" >&2
  "$VIBE" symbols "$fixit" >&2 2>/dev/null
  fail=$((fail + 1))
fi

# A non-effect diagnostic (plain syntax error) must carry data: null, not a
# spuriously-matched fix-it.
out_lex_fix_json="$("$VIBE" diagnostics --json "$lexerr" 2>/dev/null || true)"
if python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert d[0]['data'] is None, d[0]
" "$out_lex_fix_json" 2>/tmp/vibe_diag_json_err; then
  echo "ok: --json non-effect diagnostic has data: null"; pass=$((pass + 1))
else
  echo "FAIL: --json non-effect diagnostic's data field malformed:" >&2
  cat /tmp/vibe_diag_json_err >&2 2>/dev/null
  printf '%s\n' "$out_lex_fix_json" >&2
  fail=$((fail + 1))
fi
rm -f /tmp/vibe_diag_json_err

# Plain-text mode must be byte-identical to before `--json` existed (no
# accidental behavior change to the default path).
out_plain_again="$("$VIBE" diagnostics "$lexerr" 2>/dev/null || true)"
if [ "$out_plain_again" = "$out_lex" ]; then
  echo "ok: plain-text mode unaffected by --json's existence"; pass=$((pass + 1))
else
  echo "FAIL: plain-text diagnostics output changed:" >&2
  printf 'before: %s\nafter:  %s\n' "$out_lex" "$out_plain_again" >&2
  fail=$((fail + 1))
fi

echo "[vibe-diagnostics] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
