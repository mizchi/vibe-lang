#!/usr/bin/env bash
# Self-test for scripts/check_vibex_grants.vibex (#3676, #2248): the gate must
# refuse each kind of over-grant, for the reason it states, and pass a
# least-authority script.
#
#   bash scripts/check_vibex_grants_test.sh [cli.wasm]
#
# The compiler under test defaults to VIBE_STAGE2_WASM, which the self-test
# lane exports (tests/gates/selftests/run.sh).
#
# Each case is a planted script, so there is no mutation that could fail to
# apply; each refusal is checked by the message that names it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CLI="${1:-${VIBE_STAGE2_WASM:-}}"
[ -n "$CLI" ] && [ -s "$CLI" ] || { echo "usage: check_vibex_grants_test.sh <cli.wasm> (or set VIBE_STAGE2_WASM)" >&2; exit 2; }
case "$CLI" in /*) ;; *) CLI="$ROOT_DIR/$CLI" ;; esac

WORK_REL="_build/vibex_grants_test.$$"
WORK="$ROOT_DIR/$WORK_REL"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "[vibex-grants-test] FAIL $*" >&2; exit 1; }

gate() { VIBE_GRANTS_TAG="selftest$$" bash "$ROOT_DIR/scripts/vibe_run.sh" scripts/check_vibex_grants.vibex -- "$CLI" "$@" > "$WORK/gate.out" 2>&1; }
expect_refused() { # <case> <expected message> <file>
  if gate "$3"; then cat "$WORK/gate.out" >&2; fail "$1: the gate passed"; fi
  grep -qF "$2" "$WORK/gate.out" || { cat "$WORK/gate.out" >&2; fail "$1: refused, but not with '$2'"; }
}

# A least-authority script: every label is used, at the width it is used.
printf 'fn main() -> Unit allows Console + Fs::read_file {\n  println(Fs::read_file("README.md"))\n}\n' > "$WORK/least.vibex"
gate "$WORK_REL/least.vibex" || { cat "$WORK/gate.out" >&2; fail "least: a least-authority script was refused"; }
grep -q 'ok (1 files, 2 grant labels' "$WORK/gate.out" || { cat "$WORK/gate.out" >&2; fail "least: the gate did not probe both labels"; }

# A label nothing uses.
printf 'fn main() -> Unit allows Console + Env {\n  println("x")\n}\n' > "$WORK/unused.vibex"
expect_refused unused '`Env` is not needed' "$WORK_REL/unused.vibex"

# `Stderr` next to `Console`, which already authorizes it.
printf 'fn main() -> Unit allows Console + Stderr {\n  Stderr::write_stream("x\\n")\n}\n' > "$WORK/legacy.vibex"
expect_refused legacy '`Stderr` is not needed' "$WORK_REL/legacy.vibex"

# A whole capability where one operation is all the script uses.
printf 'fn main() -> Unit allows Console + Fs {\n  println(Fs::read_file("README.md"))\n}\n' > "$WORK/wide.vibex"
expect_refused wide '`Fs` is wider than its use -- the file needs only `Fs::read_file`' "$WORK_REL/wide.vibex"

# A declaration whose body opens on the next line is read like any other: the
# declarations come from the compiler, not from a line pattern (a line scan
# found no row here and passed the file unchecked). `export fn main` is not a
# case: a .vibex entry cannot be exported.
printf 'fn main() -> Unit allows Console + Env\n{\n  println("x")\n}\n' > "$WORK/multiline.vibex"
expect_refused multiline '`Env` is not needed' "$WORK_REL/multiline.vibex"

# The optional grade is the same width question: `Fs?` where one optional
# operation is all the script uses is `Fs::read_file?`.
printf 'fn cached() -> Attempt[String, String] with Fs::read_file? {\n  perform? Fs::read_file("cache.json")\n}\n\nfn main allows Console + Fs? {\n  match cached() {\n    NotGranted => println("n"),\n    Errored(_) => println("e"),\n    Granted(_) => println("g")\n  }\n}\n' > "$WORK/optional.vibex"
expect_refused optional '`Fs?` is wider than its use -- the file needs only `Fs::read_file?`' "$WORK_REL/optional.vibex"

# A comment between `fn` and the name: the declaration is the compiler's
# function row, not a text pattern, so it is still probed.
printf 'fn // entry\nmain allows Console + Env {\n  println("x")\n}\n' > "$WORK/commented.vibex"
expect_refused commented '`Env` is not needed' "$WORK_REL/commented.vibex"

# A pure entry grants nothing and needs nothing: its `()` row is read, and
# there is no label to probe.
printf 'fn main allows () {\n  ()\n}\n' > "$WORK/pure.vibex"
gate "$WORK_REL/pure.vibex" || { cat "$WORK/gate.out" >&2; fail "pure: an entry declaring allows () was refused"; }

# A file that does not check as written is not graded at all.
printf 'fn main() -> Unit allows Console {\n  let x: Int = "s"\n  println("x")\n}\n' > "$WORK/broken.vibex"
expect_refused broken 'does not check clean as written' "$WORK_REL/broken.vibex"

# One refused file among several fails the run, and is named.
gate "$WORK_REL/least.vibex" "$WORK_REL/unused.vibex" && fail "several: one refused file among several passed"
grep -qF "$WORK_REL/unused.vibex" "$WORK/gate.out" || { cat "$WORK/gate.out" >&2; fail "several: the refusal does not name the file"; }

# The default corpus is every script but the gate itself (a gate must not see
# itself), and the gate's own grant is still checked, by naming the file.
VIBE_GRANTS_TAG="selftest$$" bash "$ROOT_DIR/scripts/vibe_run.sh" scripts/check_vibex_grants.vibex -- --list > "$WORK/list.out" 2>&1 \
  || { cat "$WORK/list.out" >&2; fail "list: --list failed"; }
grep -qx 'scripts/test_report.vibex' "$WORK/list.out" || { cat "$WORK/list.out" >&2; fail "list: the default corpus is missing scripts/test_report.vibex"; }
grep -qx 'scripts/check_vibex_grants.vibex' "$WORK/list.out" && fail "list: the default corpus contains the gate itself"
gate scripts/check_vibex_grants.vibex || { cat "$WORK/gate.out" >&2; fail "self: the gate's own grant is not least authority"; }

echo "[vibex-grants-test] ok (least authority passes; an unused label, Stderr beside Console, a capability wider than its use (optional grade too), a body opened on the next line, a comment before the name and an unchecked file are each refused; a pure entry passes; the gate is outside its own corpus, and its own grant is checked)"
