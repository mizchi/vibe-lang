#!/usr/bin/env bash
# #2133, enforced: every line-oriented `vibe` query must TERMINATE its output
# with a newline, not merely separate its records with one.
#
# AGENTS.md asks these commands to be greppable, one record per line, with the
# LLM as the first reader. A separator-only join breaks that in three ways, and
# none of them errors:
#
#   - `wc -l` undercounts by exactly one, always
#   - a shell `while read` loop DROPS the last record, because `read` returns
#     non-zero at EOF without a delimiter
#   - concatenating two answers MERGES the last record of the first with the
#     first of the second into one malformed line
#
# Empty output must stay byte-EMPTY. "Empty output = clean" is the contract, so
# a bare newline would read as one blank record -- and this checks that too,
# because the obvious wrong fix (always append) breaks it.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

STAGE2="${CLI_NL_STAGE2:-}"
if [ -n "$STAGE2" ]; then
  [ -f "$STAGE2" ] || { echo "cli-line-termination: CLI_NL_STAGE2=$STAGE2 does not exist" >&2; exit 1; }
else
  for gen in $(ls -td _build/selfhost/generations/*/ 2>/dev/null); do
    [ -s "${gen}stage2.wasm" ] && { STAGE2="${gen}stage2.wasm"; break; }
  done
  [ -n "${STAGE2:-}" ] || STAGE2="bootstrap/seed/compiler.wasm"
  [ -s "$STAGE2" ] || { echo "cli-line-termination: no compiler available" >&2; exit 1; }
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_cli_nl.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fails=0
note() { printf 'cli-line-termination: ok: %s\n' "$1"; }
bad() { printf 'cli-line-termination: FAIL: %s\n' "$1" >&2; fails=1; }

# A file with something for EVERY query to report -- an empty answer would make
# that case assert nothing, so the checks below fail loudly on one. It needs:
# several declarations (so the outline has a LAST record that can be dropped),
# an import (deps), an escaping `let mut` (escapes), a classifiable function
# (rc-classify), and a binding used twice (binding-at).
cat > "$WORK/dep.vibe" <<'VIBE'
export fn dep_twice(n: Int) -> Int { n * 2 }
VIBE
cat > "$WORK/q.vibe" <<'VIBE'
import ./dep.vibe { dep_twice }

fn first_name(xs: Array[String]) -> String {
  if Array::length(xs) > 0 { Array::get(xs, 0) } else { "" }
}

fn helper(n: Int) -> Int {
  let mut acc = 0
  let bump = () -> { acc = acc + n }
  bump()
  acc + dep_twice(n)
}

fn main() -> Unit {
  let v = helper(2)
  let _ = v + v
  let _ = first_name(["a"])
}
VIBE

run() { # run <out-name> <env>...
  local out="$1"; shift
  rm -f "$WORK/$out" "$WORK/$out.diag"
  env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw "$@" \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    "$WORK/q.vibe" "$WORK/$out" >/dev/null 2>&1 || true
}

check() { # check <label> <out-name> <env>...
  local label="$1" out="$2"; shift 2
  run "$out" "$@"
  if [ ! -s "$WORK/$out" ]; then
    bad "$label produced no output, so this case asserts nothing (fix the probe)"
    return
  fi
  if [ "$(tail -c 1 "$WORK/$out" | od -An -c | tr -d ' \n')" != '\n' ]; then
    bad "$label output does not end with a newline (bytes=$(wc -c < "$WORK/$out"), wc -l=$(wc -l < "$WORK/$out"))"
    return
  fi
  # The consequence, not just the byte: a shell reader must see every record.
  local shell_n=0
  while read -r _; do shell_n=$((shell_n + 1)); done < "$WORK/$out"
  local real_n; real_n="$(grep -c '' "$WORK/$out")"
  if [ "$shell_n" != "$real_n" ]; then
    bad "$label: a shell read loop saw $shell_n of $real_n records"
    return
  fi
  note "$label terminates its last record ($real_n records)"
}

check "vibe symbols"     syms  VIBE_SYMBOLS=1
check "vibe escapes"     esc   VIBE_ESCAPES=1
check "vibe deps"        deps  VIBE_DEPS=1
check "vibe rc-plan"     plan  VIBE_RC_PLAN=1 VIBE_RC_PLAN_FN=
check "vibe rc-classify" cls   VIBE_RC_CLASSIFY=1
check "vibe binding-at"  bind  VIBE_BINDING_AT=1 VIBE_TYPE_LINE=16 VIBE_TYPE_COL=11
check "vibe type-at"     tat   VIBE_TYPE_AT=1 VIBE_TYPE_LINE=16 VIBE_TYPE_COL=11
# SINGLE quotes: `$(a:args)` is a grep metavariable, and in double quotes bash
# would run `a:args` as a command substitution and send an empty pattern.
check "vibe grep"        grep  VIBE_GREP=1 'VIBE_GREP_PATTERN=Array::length($(a:args))'

# Concatenating two answers must not merge records across the seam. This is the
# silent-wrong case: no error, one malformed line.
run syms2 VIBE_SYMBOLS=1
if [ -s "$WORK/syms2" ]; then
  one="$(grep -c '' "$WORK/syms2")"
  cat "$WORK/syms2" "$WORK/syms2" > "$WORK/both"
  two="$(grep -c '' "$WORK/both")"
  if [ "$two" != "$((one * 2))" ]; then
    bad "concatenating two symbol answers gave $two records, want $((one * 2)) -- records merged across the seam"
  else
    note "two answers concatenate without merging records"
  fi
fi

# Empty output stays byte-empty. A file with no escaping `let mut` must produce
# ZERO bytes, not a lone newline -- otherwise "clean" reads as one blank record
# and the always-append fix would pass everything above while breaking this.
cat > "$WORK/clean.vibe" <<'VIBE'
fn main() -> Unit {
  let a = 1
  let _ = a
}
VIBE
rm -f "$WORK/none"
env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_ESCAPES=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
  "$WORK/clean.vibe" "$WORK/none" >/dev/null 2>&1 || true
empty_bytes="$(wc -c < "$WORK/none" 2>/dev/null || echo 0)"
if [ "$empty_bytes" != "0" ]; then
  bad "a clean file's escapes output is $empty_bytes bytes, want 0 -- 'empty output = clean' must stay byte-empty"
else
  note "a clean file answers with zero bytes, not a blank record"
fi

[ "$fails" -eq 0 ] || exit 1
echo "cli-line-termination: ok"
