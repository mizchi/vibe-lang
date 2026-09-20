#!/usr/bin/env bash
# Red test for scripts/check_builtin_emits.sh (#2248: a gate is worth nothing
# until it is shown to fail).
#
# The gate asks the real compiler 257 questions and takes ~9 minutes. That is
# the wrong instrument for proving its CLASSIFIER and its two ratchets, so this
# drives the gate with a STUB host runner over a scratch corpus: the stub
# decides each probe's diagnostic by the name it finds in the probe source, so
# every branch is reachable in ~0.1s and none of it depends on which names the
# tree happens to contain today.
#
# What the stub cannot prove is that the probes really compile -- a stub that
# answered nothing would look identical to a healthy sweep. That is what the
# gate's own two LIVENESS controls are for, against the real compiler, and case
# 3 below checks that they fire.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# Overridable ONLY so this test can point at a MUTATED copy of the gate and
# assert each case goes red -- the same escape hatch check_gate_self_tests.sh
# uses. Unset on every real invocation.
GATE="${VIBE_BUILTIN_EMITS_TEST_GATE:-$ROOT_DIR/scripts/check_builtin_emits.sh}"
[ -f "$GATE" ] || { echo "builtin-emits-test: gate not found: $GATE" >&2; exit 1; }

# Inherited state would silently change what is being tested (#2252).
unset VIBE_BUILTIN_EMITS_COMPILER VIBE_BUILTIN_EMITS_RUNNER VIBE_BUILTIN_EMITS_DECLS
unset VIBE_BUILTIN_EMITS_ALLOWLIST VIBE_BUILTIN_EMITS_FLOOR

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_builtin_emits_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fails=0
report() { echo "builtin-emits-test FAIL: $*" >&2; fails=$((fails + 1)); }

# The scratch corpus. Small on purpose -- the point is which BRANCH the gate
# takes, not how many names it reads.
cat >"$WORK/declarations.vibe" <<'DECL'
//# Scratch

declare Lines::parse(String) -> Array[String]
declare Http::close(Int) -> Unit
declare Good::emits(Int) -> Int
declare Weird::shape(Int) -> Int
DECL
: >"$WORK/stub_compiler.wasm"

# The stub. `$4` is the probe source, `$5` the output path; a diagnostic goes
# to `$5.diag`, and writing nothing means "it compiled".
#
# STUB_ICE / STUB_OTHER name one builtin each, so a case turns exactly one
# probe's answer and the rest of the sweep stays healthy. STUB_DEAD writes
# nothing at all, which is the dead-runner shape.
cat >"$WORK/stub_runner.sh" <<'STUB'
#!/usr/bin/env bash
src="$4"; out="$5"
[ "${STUB_DEAD:-0}" = "1" ] && exit 0
name="$(sed -n 's/.*let _r = \([A-Za-z_][A-Za-z0-9_:]*\)(.*/\1/p' "$src" | head -1)"
say() { printf '%s' "$1" > "$out.diag"; }
if [ -n "${STUB_ICE:-}" ] && [ "$name" = "$STUB_ICE" ]; then
  say "internal compiler error: \`$name\` (local, @call) reached code generation unresolved."
  exit 0
fi
if [ -n "${STUB_OTHER:-}" ] && [ "$name" = "$STUB_OTHER" ]; then
  say "line 1:4-9: unknown type \`Nope\` in parameter \`a0\`"
  exit 0
fi
case "$name" in
  # The gate's liveness controls: one must speak, one must stay silent.
  Lines::parse) say "unknown name: Lines::parse -- it is a library function, not a builtin" ;;
  Http::close) : ;;
  Good::emits) : ;;
  Weird::shape) say "line 1:4-9: unknown type \`Nope\` in parameter \`a0\`" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$WORK/stub_runner.sh"

run_gate() { # <allowlist> -> echoes status, output in $WORK/out
  local allow="$1" st=0
  VIBE_BUILTIN_EMITS_COMPILER="$WORK/stub_compiler.wasm" \
  VIBE_BUILTIN_EMITS_RUNNER="$WORK/stub_runner.sh" \
  VIBE_BUILTIN_EMITS_DECLS="$WORK/declarations.vibe" \
  VIBE_BUILTIN_EMITS_ALLOWLIST="$allow" \
  VIBE_BUILTIN_EMITS_FLOOR=4 \
    bash "$GATE" >"$WORK/out" 2>&1 || st=$?
  printf '%s' "$st"
}

printf 'Weird::shape\n' >"$WORK/allow.txt"

# --- 0. CONTROL: the healthy shape passes ------------------------------------
# Without this, "always fail" would satisfy every case below.
st="$(run_gate "$WORK/allow.txt")"
if [ "$st" != "0" ]; then
  report "the healthy corpus did not pass: $(cat "$WORK/out")"
fi

# --- 1. an admitted name with no lowering ------------------------------------
st="$(STUB_ICE="Good::emits" run_gate "$WORK/allow.txt")"
if [ "$st" = "0" ]; then
  report "a name that reached code generation unresolved was reported as ok"
elif ! grep -q 'Good::emits' "$WORK/out"; then
  report "the finding did not name the offending builtin: $(cat "$WORK/out")"
fi

# --- 2. a NEW inconclusive probe ---------------------------------------------
# Silence is unchecked, not safe: an answer the gate cannot classify must not
# be absorbed into a count.
st="$(STUB_OTHER="Good::emits" run_gate "$WORK/allow.txt")"
if [ "$st" = "0" ]; then
  report "a newly inconclusive probe was accepted without being listed"
elif ! grep -q 'Good::emits' "$WORK/out"; then
  report "the inconclusive report did not name the probe: $(cat "$WORK/out")"
fi

# --- 3. a DEAD runner ---------------------------------------------------------
# The failure this gate is most exposed to: a runner that produces nothing
# writes an empty diagnostic, which reads as "it compiled" for every name. The
# liveness controls exist for exactly this and must fire.
st="$(STUB_DEAD=1 run_gate "$WORK/allow.txt")"
if [ "$st" = "0" ]; then
  report "a runner that answered NOTHING swept the whole corpus and passed"
elif ! grep -q 'liveness control' "$WORK/out"; then
  report "the dead runner was caught by something other than the liveness control: $(cat "$WORK/out")"
fi

# --- 4. the inconclusive list is shrink-only ---------------------------------
printf 'Weird::shape\nGood::emits\n' >"$WORK/allow_stale.txt"
st="$(run_gate "$WORK/allow_stale.txt")"
if [ "$st" = "0" ]; then
  report "a stale inconclusive entry (the probe answers for it now) was accepted"
elif ! grep -q 'only shrinks' "$WORK/out"; then
  report "the stale entry was not reported as a shrink-only violation: $(cat "$WORK/out")"
fi

# --- 5. an empty or broken corpus scan ---------------------------------------
# A gate that reads nothing reports no findings. The floor makes that a
# failure instead of a vacuous pass.
: >"$WORK/empty.vibe"
st=0
VIBE_BUILTIN_EMITS_COMPILER="$WORK/stub_compiler.wasm" \
VIBE_BUILTIN_EMITS_RUNNER="$WORK/stub_runner.sh" \
VIBE_BUILTIN_EMITS_DECLS="$WORK/empty.vibe" \
VIBE_BUILTIN_EMITS_ALLOWLIST="$WORK/allow.txt" \
VIBE_BUILTIN_EMITS_FLOOR=4 \
  bash "$GATE" >"$WORK/out" 2>&1 || st=$?
if [ "$st" = "0" ]; then
  report "an empty corpus passed vacuously"
elif ! grep -q 'floor' "$WORK/out"; then
  report "the empty corpus was not caught by the floor: $(cat "$WORK/out")"
fi

if [ "$fails" -ne 0 ]; then
  echo "builtin-emits-test: $fails case(s) failed" >&2
  exit 1
fi
echo "builtin-emits-test ok (healthy control, ICE, new-inconclusive, dead runner, stale list entry, empty corpus)"
