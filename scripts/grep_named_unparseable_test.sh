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

# A SECOND root, all-clean, for the multi-path cases at the bottom. Kept apart
# from corpus/ so "several paths" is a real mix rather than one directory named
# twice.
mkdir -p "$WORK/corpus2"
cat > "$WORK/corpus2/ok2.vibe" <<'V'
export fn good(x: Int) -> Int {
  x + 2
}

export fn caller2() -> Int {
  good(40)
}
V

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

# The cases above all go through `scripts/vibe_grep_bin.sh`, whose entry takes
# ONE root. `runtime/vibe` takes several, and #2914's chunking made that
# difference matter: the driver cuts chunks from the COMBINED listing of every
# path, so the sweep sees one file list with no single root. The boolean that
# used to carry #2940's distinction had to pick an answer for it, picked
# "directory", and a named `broken.vibe` went back to warning with exit 0
# (Codex on #2956, P1) -- with every gate in the tree still green, because
# every one of them named exactly one path.
#
# Skipped rather than failed when there is no native runner: this file's
# subject is the DIAGNOSTIC, and cases 1-3 above already prove it on the lane
# that needs no runner. `check_grep_driver_parity.sh` is the gate that refuses
# without one.
RUNNER="${VIBE_RUNNER:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
if [ ! -x "$RUNNER" ]; then
  note "=== 4. SKIPPED: no viberun at $RUNNER, so the argv lane is not exercised ==="
else
  note "=== 4. RED: a named unparseable file among SEVERAL paths is still refused ==="
  OUT="$(VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" timeout 900 \
    "$ROOT_DIR/runtime/vibe" grep --pattern 'good($(a:args))' \
    "$WORK/corpus2" "$WORK/corpus/broken.vibe" 2>&1)"
  RC=$?
  if [ "$RC" = 0 ]; then
    note "  FAIL exit: got 0, want non-zero -- naming a file among several"
    note "       paths stopped making it fatal"
    printf '%s\n' "$OUT" | sed 's/^/      /' | head -5
    fail=1
  else
    note "  ok   exit: $RC"
  fi
  if printf '%s' "$OUT" | grep -qF "broken.vibe"; then note "  ok   the message names the file"
  else note "  FAIL the message does not name the file"; printf '%s\n' "$OUT" | sed 's/^/      /' | head -3; fail=1; fi

  note "=== 5. CONTROL: the same two paths, both readable, still answer 0 ==="
  # Without this, case 4 is satisfied by refusing EVERY multi-path sweep.
  OUT="$(VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" timeout 900 \
    "$ROOT_DIR/runtime/vibe" grep --pattern 'good($(a:args))' \
    "$WORK/corpus2" "$WORK/corpus2/ok2.vibe" 2>&1)"
  RC=$?
  if [ "$RC" = 0 ]; then note "  ok   exit: 0"
  else note "  FAIL exit: got $RC, want 0"; printf '%s\n' "$OUT" | sed 's/^/      /' | head -5; fail=1; fi
  if printf '%s' "$OUT" | grep -qF "ok2.vibe"; then note "  ok   the match is printed"
  else note "  FAIL the match was lost"; printf '%s\n' "$OUT" | sed 's/^/      /' | head -3; fail=1; fi

  note "=== 6. CONTROL: a DIRECTORY holding the broken file is still swept (#1943) ==="
  # The argv lane's own version of case 2: widening fatality to "any path is a
  # file" would make an unparseable file INSIDE a named directory fatal too,
  # which is the opposite regression and just as invisible.
  OUT="$(VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" timeout 900 \
    "$ROOT_DIR/runtime/vibe" grep --pattern 'good($(a:args))' \
    "$WORK/corpus" "$WORK/corpus2/ok2.vibe" 2>&1)"
  RC=$?
  if [ "$RC" = 0 ]; then note "  ok   exit: 0"
  else note "  FAIL exit: got $RC, want 0 -- a file inside a NAMED DIRECTORY"; note "       became fatal, which breaks #1943"; printf '%s\n' "$OUT" | sed 's/^/      /' | head -5; fail=1; fi
  if printf '%s' "$OUT" | grep -qF "ok.vibe"; then note "  ok   the directory's clean match is still printed"
  else note "  FAIL the directory's match was lost"; printf '%s\n' "$OUT" | sed 's/^/      /' | head -3; fail=1; fi
fi

note
if [ "$fail" = 0 ]; then note "[grep-named-unparseable] ok"; else note "[grep-named-unparseable] FAIL"; fi
exit "$fail"
