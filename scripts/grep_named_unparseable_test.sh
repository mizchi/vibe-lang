#!/usr/bin/env bash
# Naming a file is asking about THAT file, so `vibe grep` must not answer
# "no matches" for one it could not parse (#2940).
#
# Before this, the same file gave two different verdicts depending on which
# verb asked -- measured on a stage2 from `d5d78b0f9`:
#
#   vibe check broken.vibe   -> exit 1, `error: line 2:13: unexpected character: \`
#   vibe grep  broken.vibe   -> exit 0, empty stdout (warning on stderr only)
#
# A caller reading stdout and the exit code, which is how AGENTS.md says these
# surfaces are meant to be consumed, read that as "clean, no matches" for a
# file the compiler could not read. Same conflation as #2914 one level up.
#
# The SWEEP case is the opposite and must not change: #1943 decided that one
# work-in-progress file cannot stop a repo-wide answer, and that is right --
# asking about a corpus and getting the part that could be answered is useful.
# So the two controls below carry as much weight as the red case:
#
#   1. RED     a named unparseable file exits non-zero and names the file
#   2. CONTROL a swept DIRECTORY containing it still exits 0 and still prints
#              the clean file's match -- otherwise the fix broke #1943
#   3. CONTROL a named file with genuinely no matches still exits 0 with empty
#              stdout -- otherwise "refuse when stdout is empty" would satisfy
#              case 1 while answering nothing
#
#   VIBE_CLI_WASM  the compiler to ask. Unset, scripts/resolve_stage2.sh picks
#                  HEAD's generation and SAYS which -- never silently, since
#                  the committed seed is a different compiler.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

. "$(dirname "$0")/resolve_stage2.sh"
CLI="$(resolve_stage2 grep-named-unparseable "${VIBE_CLI_WASM:-}")" || exit 1
[ -n "$CLI" ] && [ -f "$CLI" ] || {
  echo "grep-named-unparseable: no compiler to ask; set VIBE_CLI_WASM" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-grep-named.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/corpus"
cat > "$WORK/corpus/ok.vibe" <<'V'
export fn good(x: Int) -> Int {
  x + 1
}

export fn caller() -> Int {
  good(41)
}
V
# A lexer error, not a parse error: the cheapest thing that cannot be read.
printf 'export fn bad() -> Int {\n  let x = 1 \\ 2\n  x\n}\n' > "$WORK/corpus/broken.vibe"

fail=0
note() { printf '%s\n' "$*"; }
grep_run() { # grep_run <path> <pattern> -> OUT, RC
  OUT="$(VIBE_CLI_WASM="$CLI" timeout 600 bash "$ROOT_DIR/scripts/vibe_grep_bin.sh" \
    --pattern "$2" "$1" 2>&1)"
  RC=$?
}

note "=== 1. RED: a named unparseable file is refused, not answered ==="
grep_run "$WORK/corpus/broken.vibe" 'good($(a:args))'
if [ "$RC" = 0 ]; then
  note "  FAIL exit: got 0, want non-zero -- an unreadable file answered as 'no matches'"
  fail=1
else
  note "  ok   exit: $RC"
fi
if printf '%s' "$OUT" | grep -qF "broken.vibe"; then note "  ok   the message names the file"
else note "  FAIL the message does not name the file"; printf '%s\n' "$OUT" | sed 's/^/      /' | head -3; fail=1; fi
if printf '%s' "$OUT" | grep -qF "could not be parsed"; then note "  ok   and says why"
else note "  FAIL does not say why"; fail=1; fi

note "=== 2. CONTROL: a swept directory still answers for the rest (#1943) ==="
grep_run "$WORK/corpus" 'good($(a:args))'
if [ "$RC" = 0 ]; then note "  ok   exit: 0"
else note "  FAIL exit: got $RC, want 0 -- the fix broke sweeping"; printf '%s\n' "$OUT" | sed 's/^/      /' | head -3; fail=1; fi
if printf '%s' "$OUT" | grep -qF "ok.vibe:6:3: good(41)"; then note "  ok   the clean file's match is still printed"
else note "  FAIL the clean file's match was lost"; printf '%s\n' "$OUT" | sed 's/^/      /' | head -3; fail=1; fi
if printf '%s' "$OUT" | grep -qF "skipped"; then note "  ok   and the skip is still warned about"
else note "  FAIL the skip is no longer reported"; fail=1; fi

note "=== 3. CONTROL: a named file with no matches is still a clean zero ==="
# Without this, case 1 would be satisfied by refusing whenever stdout is empty,
# which would answer nothing at all.
grep_run "$WORK/corpus/ok.vibe" 'nosuchfunction($(a:args))'
if [ "$RC" = 0 ]; then note "  ok   exit: 0"
else note "  FAIL exit: got $RC, want 0 -- no-matches is not a failure"; fail=1; fi
if [ -z "$OUT" ]; then note "  ok   empty output"
else note "  FAIL expected empty output, got:"; printf '%s\n' "$OUT" | sed 's/^/      /' | head -3; fail=1; fi

note
if [ "$fail" = 0 ]; then note "[grep-named-unparseable] ok"; else note "[grep-named-unparseable] FAIL"; fi
exit "$fail"
