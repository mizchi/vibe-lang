#!/usr/bin/env bash
# Self-test for scripts/check_vibex_grants.sh (#3676, #2248): the gate must
# refuse each kind of over-grant, for the reason it states, and pass a
# least-authority script.
#
#   bash scripts/check_vibex_grants_test.sh <cli.wasm>
#
# Each case is a planted script, so there is no mutation that could fail to
# apply; each refusal is checked by the message that names it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CLI="${1:-}"
[ -n "$CLI" ] && [ -s "$CLI" ] || { echo "usage: check_vibex_grants_test.sh <cli.wasm>" >&2; exit 2; }
case "$CLI" in /*) ;; *) CLI="$ROOT_DIR/$CLI" ;; esac
unset VIBE_GRANTS_JOBS || true

WORK_REL="_build/vibex_grants_test.$$"
WORK="$ROOT_DIR/$WORK_REL"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "[vibex-grants-test] FAIL $*" >&2; exit 1; }

gate() { bash "$ROOT_DIR/scripts/check_vibex_grants.sh" "$CLI" "$@" > "$WORK/gate.out" 2>&1; }
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

# A file that does not check as written is not graded at all.
printf 'fn main() -> Unit allows Console {\n  let x: Int = "s"\n  println("x")\n}\n' > "$WORK/broken.vibex"
expect_refused broken 'does not check clean as written' "$WORK_REL/broken.vibex"

# One refused file among several fails the run, and is named.
gate "$WORK_REL/least.vibex" "$WORK_REL/unused.vibex" && fail "several: one refused file among several passed"
grep -qF "$WORK_REL/unused.vibex" "$WORK/gate.out" || { cat "$WORK/gate.out" >&2; fail "several: the refusal does not name the file"; }

echo "[vibex-grants-test] ok (least authority passes; an unused label, Stderr beside Console, a capability wider than its use and an unchecked file are each refused)"
