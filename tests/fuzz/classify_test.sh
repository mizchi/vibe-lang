#!/usr/bin/env bash
# classify.sh must be able to FAIL on the #2979 classes (CLAUDE.md, "a gate is
# trusted only once it is shown it can fail").
#
# Two verdicts are tested here, both through the real classify.sh and the
# real lib_oracle.sh, with the compiler and the two runtimes replaced by stubs
# so that the answer under test is FIXED rather than whatever today's compiler
# happens to print:
#
#   * mutation mode (`--mutate`): a diagnostic with no `line N:M` is
#     DIAG_NO_LOCATION, one reporting a separator the source does not contain
#     is DIAG_INTERNAL_TOKEN, and a located, honest diagnostic stays
#     COMPILE_DIAG -- the expected rejection;
#   * the lane-independent oracle: every lane printing the SAME wrong value is
#     an ORACLE_* finding, not OK, which is exactly what a differential oracle
#     cannot see.
#
# Each red case is paired with a MUTANT of lib_oracle.sh that has the check
# removed, and asserts the mutant answers the harmless verdict: that proves the
# case is caught by the check under test rather than by something incidental.
# The mutation is verified to have landed before its answer is believed.
set -uo pipefail
# The oracle reads these; a value inherited from the caller's environment
# must not decide what the stubs are asked to do (#2252).
unset RUNNER CTIMEOUT RTIMEOUT STUB_DIAG STUB_OUT
cd "$(dirname "$0")/../.."
ROOT="$PWD"

WORK="$(mktemp -d 2>/dev/null || true)"
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
  echo "classify_test: could not allocate a temporary directory (TMPDIR=${TMPDIR:-unset})" >&2
  exit 1
fi
PROBE_CLS="tests/fuzz/.probe_cls$$.sh"
PROBE_LIB="tests/fuzz/.probe_lib$$.sh"
cleanup() { rm -rf "$WORK" "$PROBE_CLS" "$PROBE_LIB" "$PROBE_LIB.bak" 2>/dev/null; }
trap cleanup EXIT
rc=0
say() { printf '%s\n' "$*"; }
bad() { say "  FAIL $*"; rc=1; }

# --- stubs -----------------------------------------------------------------
# The compiler: `--invoke cli_main CLI SRC OUT _start` writes $STUB_DIAG to
# OUT.diag when it is set (a rejection), else a placeholder module to OUT.
# The linear runtime: `--invoke _start WASM` prints $STUB_OUT.
cat > "$WORK/runner.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--invoke" ] || exit 2
if [ "$2" = "cli_main" ]; then
  out="$5"
  if [ -n "${STUB_DIAG:-}" ]; then cp "$STUB_DIAG" "$out.diag"; exit 1; fi
  printf 'stub-module\n' > "$out"
  exit 0
fi
cat "$STUB_OUT"
EOF
# The gc runtime is called by name, so it is shadowed on PATH.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/wasmtime" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_OUT"
EOF
chmod +x "$WORK/runner.sh" "$WORK/bin/wasmtime"
printf 'stub compiler\n' > "$WORK/cli.wasm"
export RUNNER="bash $WORK/runner.sh"
export PATH="$WORK/bin:$PATH"

# classify <classify-script> <dir> [--mutate] -> the verdict line
run_classify() {
  local script="$1" dir="$2"; shift 2
  bash "$script" "$dir" --cli "$WORK/cli.wasm" "$@" 2>/dev/null
}

# A mutant of lib_oracle.sh, driven by a probe classify.sh that sources it.
# `sed` edits a COPY; the real files are never touched.
make_mutant() { # <sed-expression> <grep pattern that must be GONE afterwards>
  cp tests/fuzz/lib_oracle.sh "$PROBE_LIB"
  sed -i.bak -e "$1" "$PROBE_LIB" && rm -f "$PROBE_LIB.bak"
  sed -e "s|\"\$ROOT/tests/fuzz/lib_oracle.sh\"|\"\$ROOT/$PROBE_LIB\"|" \
    tests/fuzz/classify.sh > "$PROBE_CLS"
  if ! grep -qF "$PROBE_LIB" "$PROBE_CLS"; then
    bad "mutant: the probe classify.sh does not source the mutant library"
    return 1
  fi
  if grep -qE "$2" "$PROBE_LIB"; then
    bad "mutant: the mutation did not land (still matches: $2)"
    return 1
  fi
  return 0
}

verdict_is() { # <label> <verdict-line> <expected class>
  case "$2" in
    "$3"|"$3 "*) say "  ok   $1: $3" ;;
    *) bad "$1: expected $3, got: ${2:-<nothing>}" ;;
  esac
}

# --- mutation mode: diagnostic quality -------------------------------------
say "=== --mutate: diagnostic quality ==="
D="$WORK/mut"; mkdir -p "$D"
printf 'export let _start = () -> Int {\n  7\n}\n' > "$D/mut.vibe"

# Verbatim what a stage2 of main answered on 2026-09-24 for
# `println("\{Int::parse("42")}")` -- a refusal with no position at all.
printf '%s' 'cannot interpolate the result of `Int::parse`: its type is an Option, Array, tuple, Bytes or record whose shape the renderer could not resolve here, so it would print a memory address -- bind it with a type annotation first (e.g. `let v: Option[Int] = ...`, then interpolate `v`) (#2987)' > "$WORK/unlocated.diag"
printf '%s' 'line 2:3-9: unknown name: foo' > "$WORK/located.diag"
# The shape #2979 cites: a position, but the token it names was never written.
printf '%s' 'line 1:1: unexpected in pattern: ;' > "$WORK/internal.diag"

export STUB_DIAG="$WORK/unlocated.diag"
verdict_is "an unlocated diagnostic" "$(run_classify tests/fuzz/classify.sh "$D" --mutate)" DIAG_NO_LOCATION
export STUB_DIAG="$WORK/located.diag"
verdict_is "a located diagnostic (control)" "$(run_classify tests/fuzz/classify.sh "$D" --mutate)" COMPILE_DIAG
export STUB_DIAG="$WORK/internal.diag"
verdict_is "a separator the source lacks" "$(run_classify tests/fuzz/classify.sh "$D" --mutate)" DIAG_INTERNAL_TOKEN
printf 'export let _start = () -> Int {\n  let a = 1; 7\n}\n' > "$D/mut.vibe"
verdict_is "the same separator, present in the source (control)" \
  "$(run_classify tests/fuzz/classify.sh "$D" --mutate)" COMPILE_DIAG
printf 'export let _start = () -> Int {\n  7\n}\n' > "$D/mut.vibe"
unset STUB_DIAG
verdict_is "a clean compile (control)" "$(run_classify tests/fuzz/classify.sh "$D" --mutate)" OK

say "=== --mutate: the checks are what catch it ==="
if make_mutant 's/^    dc=\$(diag_class "\$out.diag" "\$src")$/    dc=""/' 'dc=\$\(diag_class'; then
  export STUB_DIAG="$WORK/unlocated.diag"
  verdict_is "without diag_class, the unlocated diagnostic passes as" \
    "$(run_classify "$PROBE_CLS" "$D" --mutate)" COMPILE_DIAG
  export STUB_DIAG="$WORK/internal.diag"
  verdict_is "without diag_class, the invented separator passes as" \
    "$(run_classify "$PROBE_CLS" "$D" --mutate)" COMPILE_DIAG
  unset STUB_DIAG
fi

# --- the lane-independent oracle -------------------------------------------
say "=== oracle: one wrong answer on every lane ==="
O="$WORK/oracle"; mkdir -p "$O"
printf 'export let _start = () -> Int with Stdout {\n  7\n}\n' > "$O/single.vibe"
printf 'R1|Some(Some(1))\nT1|caught Kd0A(6)\nC1|43\n' > "$O/expected.txt"

export STUB_OUT="$WORK/right.out"
printf 'R1|Some(Some(1))\nT1|caught Kd0A(6)\nC1|43\n7\n' > "$STUB_OUT"
verdict_is "every lane right (control)" "$(run_classify tests/fuzz/classify.sh "$O")" OK

# The #2979 shape: `return` in a handler arm treated as a resume, so every
# lane prints the same wrong number and the differential oracle says OK.
export STUB_OUT="$WORK/cont.out"
printf 'R1|Some(Some(1))\nT1|caught Kd0A(6)\nC1|1440\n7\n' > "$STUB_OUT"
v="$(run_classify tests/fuzz/classify.sh "$O")"
verdict_is "a shared wrong continuation answer" "$v" ORACLE_CONT
case "$v" in
  *"id=C1 expected='43' bump='1440' rc='1440' gc='1440'"*) say "  ok   the detail names the id, the expectation and each lane" ;;
  *) bad "the detail does not name id/expected/lanes: $v" ;;
esac

export STUB_OUT="$WORK/throw.out"
printf 'R1|Some(Some(1))\nT1|caught 1769\nC1|43\n7\n' > "$STUB_OUT"
verdict_is "a payload rendered as an address" "$(run_classify tests/fuzz/classify.sh "$O")" ORACLE_THROW

export STUB_OUT="$WORK/render.out"
printf 'R1|Some(Some(0))\nT1|caught Kd0A(6)\nC1|43\n7\n' > "$STUB_OUT"
verdict_is "a wrong rendering" "$(run_classify tests/fuzz/classify.sh "$O")" ORACLE_RENDER

export STUB_OUT="$WORK/missing.out"
printf 'R1|Some(Some(1))\nC1|43\n7\n' > "$STUB_OUT"
v="$(run_classify tests/fuzz/classify.sh "$O")"
verdict_is "a line that was never printed" "$v" ORACLE_THROW
case "$v" in
  *"<missing>"*) say "  ok   the missing line is named as missing" ;;
  *) bad "the missing line is not named: $v" ;;
esac

say "=== oracle: skipped lanes are reported, not compared ==="
printf 'bump rc\n' > "$O/skip_lanes"
export STUB_OUT="$WORK/cont.out"
v="$(run_classify tests/fuzz/classify.sh "$O")"
verdict_is "a shared wrong answer on the lanes that ran" "$v" ORACLE_CONT
case "$v" in
  *"bump=skipped rc=skipped gc='1440'"*) say "  ok   the skipped lanes say so" ;;
  *) bad "the skipped lanes are not reported as skipped: $v" ;;
esac
export STUB_OUT="$WORK/right.out"
v="$(run_classify tests/fuzz/classify.sh "$O")"
verdict_is "the lanes that ran are right (control)" "$v" OK
rm -f "$O/skip_lanes"

say "=== oracle: the expected.txt comparison is what catches it ==="
if make_mutant 's/^  if \[ -f "\$dir\/expected.txt" \]; then$/  if false; then/' '^  if \[ -f "\$dir/expected.txt" \]; then$'; then
  export STUB_OUT="$WORK/cont.out"
  verdict_is "without the oracle, the shared wrong answer passes as" \
    "$(run_classify "$PROBE_CLS" "$O")" OK
fi

if [ "$rc" -eq 0 ]; then
  say "[classify-test] ok"
else
  say "[classify-test] FAILED"
fi
exit "$rc"
