#!/usr/bin/env bash
# Red/green for the failure reporting in scripts/vibe_grep_bin.sh (#2914).
#
# The runner used to turn a LOUD failure into silence. `status=$?` sat inside
# `if ! cmd; then`, where `$?` is the status of the `!`-INVERTED pipeline -- 0
# whenever the command failed -- so the branch whose only job was to record a
# failure recorded success:
#
#   $ status=0; if ! (exit 42); then status=$?; fi; echo $status   -> 0
#   $ status=0; (exit 42) || status=$?; echo $status               -> 42
#
# Measured before the fix: a tree-wide typed sweep really does still trap
# (`RuntimeError: memory access out of bounds`, status 1, no output files
# written), and `vibe grep` reported `exit 0` with no output for it -- which is
# what `--where` over a corpus with no matches also looks like. A tool whose
# whole purpose is answering questions ABOUT a corpus cannot have "it broke"
# and "the answer is none" share a spelling.
#
# The stub runner is the point: these cases need no compiler, so they stay
# runnable and fast, and each one is a shape the real runner produced.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-grep-bin-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
note() { printf '%s\n' "$*"; }
check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then note "  ok   $1: $2"
  else note "  FAIL $1: got '$2' want '$3'"; fail=1; fi
}
says() {
  if printf '%s' "$1" | grep -qF "$2"; then note "  ok   says: $2"
  else note "  FAIL did not say: $2"; printf '%s\n' "$1" | sed 's/^/      /'; fail=1; fi
}
silent_about() {
  if printf '%s' "$1" | grep -qF "$2"; then note "  FAIL unexpectedly said: $2"; fail=1
  else note "  ok   free of: $2"; fi
}

# A scratch tree holding the script under test and a STUB runner whose
# behaviour each case chooses. `$4` is the output path cli_main would write.
setup() { # setup <behaviour>
  rm -rf "$WORK/t"
  mkdir -p "$WORK/t/scripts" "$WORK/t/corpus"
  cp "$ROOT_DIR/scripts/vibe_grep_bin.sh" "$WORK/t/scripts/"
  : > "$WORK/t/fake-compiler.wasm"
  printf 'fn f() -> Int {\n  1\n}\n' > "$WORK/t/corpus/a.vibe"
  cat > "$WORK/t/scripts/run_wasm_vibe_host_runner.sh" <<STUB
#!/usr/bin/env bash
# args: --invoke cli_main <cli> <input> <output>
out="\${5:-}"
case "$1" in
  fail-silent)   echo "RuntimeError: memory access out of bounds" >&2; exit 1 ;;
  ok-no-file)    exit 0 ;;
  fail-partial)  printf 'corpus/a.vibe:1:1: f()\n' > "\$out"; exit 1 ;;
  ok-match)      printf 'corpus/a.vibe:1:1: f()\n' > "\$out"; exit 0 ;;
  ok-empty)      : > "\$out"; exit 0 ;;
esac
STUB
  chmod +x "$WORK/t/scripts/run_wasm_vibe_host_runner.sh"
}

run() { # run -> echoes combined output; sets RC
  set +e
  OUT="$( cd "$WORK/t" && VIBE_CLI_WASM="$WORK/t/fake-compiler.wasm" \
    bash scripts/vibe_grep_bin.sh --pattern '$(f:id)($(a:args))' corpus 2>&1 )"
  RC=$?
  set -e
}

note "=== red 1: the runner fails and writes nothing (the measured shape) ==="
setup fail-silent; run
check "exit" "$RC" "1"
says "$OUT" "grep could not run"
says "$OUT" "memory access out of bounds"

note "=== red 2: the runner exits 0 but produces no result file ==="
setup ok-no-file; run
check "exit" "$RC" "1"
says "$OUT" "the sweep did not complete"

note "=== red 3: the runner fails but left PARTIAL output ==="
# The old guard was `status != 0 AND output empty`, so this case printed the
# files it had reached as though the sweep had finished.
setup fail-partial; run
check "exit" "$RC" "1"
says "$OUT" "grep could not run"
silent_about "$OUT" "corpus/a.vibe:1:1"

note "=== green 1: a successful run with a match still prints it ==="
setup ok-match; run
check "exit" "$RC" "0"
says "$OUT" "corpus/a.vibe:1:1: f()"
silent_about "$OUT" "grep could not run"

note "=== green 2: a successful run with NO matches is silent and exits 0 ==="
# The control that keeps the three reds honest: a guard that refused
# everything would fail here, and "no matches" must stay a clean answer.
setup ok-empty; run
check "exit" "$RC" "0"
check "no output" "$(printf '%s' "$OUT" | wc -c | tr -d ' ')" "0"

note
if [ "$fail" = 0 ]; then note "[vibe-grep-bin-test] ok"; else note "[vibe-grep-bin-test] FAIL"; fi
exit "$fail"
