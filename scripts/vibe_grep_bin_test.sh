#!/usr/bin/env bash
# Red test for scripts/vibe_grep_bin.sh's failure reporting (#2914).
#
# The defect this pins: a wasm trap inside the grep invocation reached the
# caller as `exit 0` with empty stdout -- byte-for-byte what a legitimate
# no-match sweep looks like. Two independent causes, both here:
#
#   1. `if ! cmd; then status=$?; fi` records the status of the INVERTED
#      pipeline, which is 0 exactly when the command failed. The variable was
#      dead: 0 on success (branch skipped) and 0 on failure (inverted).
#   2. the fatal guard additionally required `[ ! -s "$out" ]`, so a sweep that
#      trapped part-way printed what it had reached as though it had finished.
#
# No compiler is needed. The script's ROOT_DIR comes from its own location, so
# each case runs a COPY of it in a scratch tree beside a stub host runner whose
# behaviour is the variable under test. ~0.1s total.
#
# The five cases are three failures, one success, and -- the control that keeps
# the failures honest -- a legitimate no-match run that must stay silent and
# exit 0. Without that control, "always fail" would pass the other four.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="${VIBE_GREP_BIN_TEST_SUBJECT:-$ROOT_DIR/scripts/vibe_grep_bin.sh}"
[ -f "$SUBJECT" ] || { echo "vibe-grep-bin-test: subject not found: $SUBJECT" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_grep_bin_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fails=0
report() {
  echo "vibe-grep-bin-test FAIL: $*" >&2
  fails=$((fails + 1))
}

# Build a scratch tree: scripts/vibe_grep_bin.sh (the subject) + a stub runner.
# `$5` is the output path the subject hands the runner; STUB_MODE picks the
# behaviour. The stub never touches the real compiler.
setup_tree() {
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/corpus"
  cp "$SUBJECT" "$dir/scripts/vibe_grep_bin.sh"
  : >"$dir/corpus/a.vibe"
  cat >"$dir/scripts/run_wasm_vibe_host_runner.sh" <<'STUB'
#!/usr/bin/env bash
# args: --invoke cli_main <cli> <path> <out>
out="$5"
case "${STUB_MODE:-}" in
  trap)
    echo "RuntimeError: memory access out of bounds" >&2
    exit 1
    ;;
  silent_zero)
    exit 0
    ;;
  partial_then_fail)
    printf 'corpus/a.vibe:1:1: reached\n' >"$out"
    echo "RuntimeError: memory access out of bounds" >&2
    exit 1
    ;;
  match)
    printf 'corpus/a.vibe:1:1: hit\n' >"$out"
    exit 0
    ;;
  no_match)
    : >"$out"
    exit 0
    ;;
  *)
    echo "stub: unknown STUB_MODE" >&2
    exit 3
    ;;
esac
STUB
  chmod +x "$dir/scripts/run_wasm_vibe_host_runner.sh"
  # pick_cli_wasm only checks that the path exists.
  : >"$dir/fake-cli.wasm"
}

# Run the subject copy in its scratch tree. Echoes "<status>" and leaves
# stdout/stderr in $WORK/<name>.out / .err.
run_case() {
  # Separate statements: `local a=$1 b=$WORK/$a` declares every name first and
  # then assigns, so `$a` is an unset local when `b` is evaluated -- unbound
  # under `set -u`.
  local name="$1" mode="$2" st=0
  local dir="$WORK/$name"
  setup_tree "$dir"
  ( cd "$dir" \
    && STUB_MODE="$mode" VIBE_CLI_WASM="$dir/fake-cli.wasm" VIBE_PREOPEN_DIR="$dir" \
       bash "$dir/scripts/vibe_grep_bin.sh" grep --pattern 'f($(x:exp))' corpus \
       >"$WORK/$name.out" 2>"$WORK/$name.err" ) || st=$?
  printf '%s' "$st"
}

# --- 1. the measured trap: non-zero status, nothing written ------------------
st="$(run_case trap trap)"
if [ "$st" = "0" ]; then
  report "a trapping runner was reported as success (exit 0) -- this is the #2914 defect"
elif [ -s "$WORK/trap.out" ]; then
  report "a trapping runner produced stdout: $(cat "$WORK/trap.out")"
elif ! grep -q 'could not run' "$WORK/trap.err"; then
  report "a trapping runner did not say so on stderr: $(cat "$WORK/trap.err")"
fi

# --- 2. exit 0 but no result file at all -------------------------------------
# Only reachable because the subject REMOVES the mktemp file before invoking.
# With the file merely truncated, this is indistinguishable from case 5.
st="$(run_case silent_zero silent_zero)"
if [ "$st" = "0" ]; then
  report "a runner that exited 0 without writing a result file was reported as a no-match sweep"
elif ! grep -q 'no result file' "$WORK/silent_zero.err"; then
  report "missing result file was not named on stderr: $(cat "$WORK/silent_zero.err")"
fi

# --- 3. failure AFTER partial output -----------------------------------------
st="$(run_case partial partial_then_fail)"
if [ "$st" = "0" ]; then
  report "a sweep that trapped part-way was reported as a complete answer (exit 0)"
elif [ -s "$WORK/partial.out" ]; then
  report "a sweep that trapped part-way printed its partial answer: $(cat "$WORK/partial.out")"
fi

# --- 4. a real match still gets through --------------------------------------
st="$(run_case match match)"
if [ "$st" != "0" ]; then
  report "a successful match run exited $st: $(cat "$WORK/match.err")"
elif ! grep -q 'corpus/a.vibe:1:1: hit' "$WORK/match.out"; then
  report "a successful match run did not print its match: $(cat "$WORK/match.out")"
fi

# --- 5. CONTROL: a legitimate no-match run stays silent and exits 0 ----------
# Without this, a subject that failed unconditionally would pass 1-3 while
# destroying the tool. Empty output is a report, not an error.
st="$(run_case nomatch no_match)"
if [ "$st" != "0" ]; then
  report "a legitimate no-match run exited $st: $(cat "$WORK/nomatch.err")"
elif [ -s "$WORK/nomatch.out" ]; then
  report "a legitimate no-match run printed something: $(cat "$WORK/nomatch.out")"
fi

if [ "$fails" -ne 0 ]; then
  echo "vibe-grep-bin-test: $fails case(s) failed" >&2
  exit 1
fi
echo "vibe-grep-bin-test ok (trap, silent-zero, partial-then-fail, match, no-match control)"
