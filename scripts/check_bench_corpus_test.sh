#!/usr/bin/env bash
# Red test for check_bench_corpus.sh (#2248: a gate means nothing until it is
# known to be able to fail).
#
# Five cases, each mutation checked for having LANDED before its verdict is
# believed -- an edit that matches nothing passes while proving nothing.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# The gate reads these; inherit nothing (#2252).
unset VIBE_BENCH_CORPUS_GATE_ROOT
unset VIBE_BENCH_CORPUS_ALLOWLIST
unset VIBE_BENCH_CORPUS_GLOBS
unset VIBE_BENCH_CORPUS_ROOT

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_benchcorpus_selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "[bench-corpus-test] FAIL: $*" >&2; exit 1; }

run_gate() { bash scripts/check_bench_corpus.sh >"$WORK/out" 2>&1; }

# GREEN control. Without it a gate failing for an unrelated reason would make
# every red case below "pass".
if ! run_gate; then
  cat "$WORK/out" >&2
  fail "the gate does not pass on the unmutated tree; the red cases below would prove nothing"
fi

# RED 1: a snapshot edited without going through the bump script. This is the
# case that matters most -- the corpus is a file anyone can open, and a one-byte
# change silently restates every number in the series.
CORPUS=bench/perf/corpus/lexer.vibe.txt
cp "$CORPUS" "$WORK/lexer.orig"
printf '\n// stray edit\n' >> "$CORPUS"
if ! cmp -s "$CORPUS" "$WORK/lexer.orig"; then :; else
  cp "$WORK/lexer.orig" "$CORPUS"
  fail "RED 1 mutation did not land (the corpus is unchanged)"
fi
red1=0; run_gate || red1=1
cp "$WORK/lexer.orig" "$CORPUS"
[ "$red1" -eq 1 ] || fail "RED 1: the gate accepted an edited corpus (the digest is not being checked)"
grep -qF 'does not match its recorded digest' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 1 failed for the wrong reason"; }

# RED 2: a bench repointed back at a live source. Uses a scratch corpus so the
# tree's own bench files are never touched.
mkdir -p "$WORK/r2"
cat > "$WORK/r2/regressed_bench.vibe" <<'VIBE'
bench "reads the live checker" {
  let _ = lex(Fs::read_file("lib/@vibe/compiler/checker/checker.vibe"))
}
VIBE
red2=0
VIBE_BENCH_CORPUS_GLOBS="$WORK/r2/*_bench.vibe" bash scripts/check_bench_corpus.sh >"$WORK/out" 2>&1 || red2=1
[ "$red2" -eq 1 ] || fail "RED 2: the gate accepted a bench reading a live source path"
grep -qF 'names a LIVE source path' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 2 failed for the wrong reason"; }

# RED 3: an allow-list row with no reason. The row is the decision surface; a
# bare path records that someone was exempted and not why.
mkdir -p "$WORK/r3"
printf '%s\n' "$WORK/r2/regressed_bench.vibe" > "$WORK/r3/allow.txt"
grep -qF 'regressed_bench.vibe' "$WORK/r3/allow.txt" \
  || fail "RED 3 mutation did not land (the allow-list row was not written)"
red3=0
VIBE_BENCH_CORPUS_ALLOWLIST="$WORK/r3/allow.txt" VIBE_BENCH_CORPUS_GLOBS="$WORK/r2/*_bench.vibe" \
  bash scripts/check_bench_corpus.sh >"$WORK/out" 2>&1 || red3=1
[ "$red3" -eq 1 ] || fail "RED 3: the gate accepted an allow-list row with no reason"
grep -qF 'allow-list row with no reason' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 3 failed for the wrong reason"; }
# ...and the control: WITH a reason, the same row exempts it. Without this the
# case above would also pass a gate that rejected every allow-list row.
printf '%s\tbecause the test says so\n' "$WORK/r2/regressed_bench.vibe" > "$WORK/r3/allow_ok.txt"
VIBE_BENCH_CORPUS_ALLOWLIST="$WORK/r3/allow_ok.txt" VIBE_BENCH_CORPUS_GLOBS="$WORK/r2/*_bench.vibe" \
  bash scripts/check_bench_corpus.sh >"$WORK/out" 2>&1 \
  || { cat "$WORK/out" >&2; fail "RED 3 control: a row WITH a reason did not exempt the file"; }

# RED 4: a stale allow-list row. It exempts nothing and hides that the corpus
# moved, so it must not pass quietly.
mkdir -p "$WORK/r4"
printf 'lib/@vibe/compiler/no_such_bench.vibe\tgone\n' > "$WORK/r4/allow.txt"
red4=0
VIBE_BENCH_CORPUS_ALLOWLIST="$WORK/r4/allow.txt" bash scripts/check_bench_corpus.sh >"$WORK/out" 2>&1 || red4=1
[ "$red4" -eq 1 ] || fail "RED 4: the gate accepted an allow-list row naming a file that does not exist"
grep -qF 'names a file that does not exist' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 4 failed for the wrong reason"; }

# RED 5: an empty corpus of bench files. Silence is "unchecked", not "clean".
mkdir -p "$WORK/r5"
red5=0
VIBE_BENCH_CORPUS_GLOBS="$WORK/r5/*_bench.vibe" bash scripts/check_bench_corpus.sh >"$WORK/out" 2>&1 || red5=1
[ "$red5" -eq 1 ] || fail "RED 5: the gate passed with no bench files matched"
grep -qF 'no bench files matched' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 5 failed for the wrong reason"; }

# RED 6: `bump_bench_corpus.sh` is ADDITIVE by default (#2878). Adding a corpus
# entry must not re-freeze the ones already there -- the first attempt at the
# fourth entry did exactly that, because `main` had changed `checker.vibe` in
# between, and silently reset two series the change was not about. Only `--all`
# is a bump.
#
# Built in a scratch root so the tree's own corpus is never touched. The paths
# are the ones the script hardcodes.
mkdir -p "$WORK/r6/lib/@vibe/compiler/checker" \
         "$WORK/r6/lib/@vibe/parser" \
         "$WORK/r6/lib/@vibex/url" \
         "$WORK/r6/bench/perf/corpus" \
         "$WORK/r6/scripts"
cp scripts/bump_bench_corpus.sh "$WORK/r6/scripts/"
printf 'fn checker() -> Int {\n  1\n}\n'  > "$WORK/r6/lib/@vibe/compiler/checker/checker.vibe"
printf 'fn lexer() -> Int {\n  1\n}\n'    > "$WORK/r6/lib/@vibe/parser/lexer.vibe"
printf 'fn parser() -> Int {\n  1\n}\n'   > "$WORK/r6/lib/@vibe/parser/parser.vibe"
printf 'fn url() -> Int {\n  1\n}\n'      > "$WORK/r6/lib/@vibex/url/url.vibe"

VIBE_BENCH_CORPUS_ROOT="$WORK/r6" bash scripts/bump_bench_corpus.sh --all >"$WORK/out" 2>&1 \
  || { cat "$WORK/out" >&2; fail "RED 6 setup: the initial --all freeze failed"; }
before="$(cat "$WORK/r6/bench/perf/corpus/checker.vibe.txt")"

# The mutation: the SOURCE moves, exactly as a merge from main would move it.
printf 'fn checker() -> Int {\n  2\n}\n' > "$WORK/r6/lib/@vibe/compiler/checker/checker.vibe"
if cmp -s "$WORK/r6/lib/@vibe/compiler/checker/checker.vibe" /dev/null; then
  fail "RED 6 mutation did not land (the source file is empty)"
fi

VIBE_BENCH_CORPUS_ROOT="$WORK/r6" bash scripts/bump_bench_corpus.sh >"$WORK/out" 2>&1 \
  || { cat "$WORK/out" >&2; fail "RED 6: the default (additive) run failed"; }
if [ "$(cat "$WORK/r6/bench/perf/corpus/checker.vibe.txt")" != "$before" ]; then
  fail "RED 6: the default run RE-FROZE an existing snapshot; adding an entry would bump the others"
fi
grep -qF 'already frozen at' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 6: the default run did not report keeping the existing snapshot"; }

# ...and the control: --all DOES re-freeze, or "additive" would just mean broken.
VIBE_BENCH_CORPUS_ROOT="$WORK/r6" bash scripts/bump_bench_corpus.sh --all >"$WORK/out" 2>&1 \
  || { cat "$WORK/out" >&2; fail "RED 6 control: the --all run failed"; }
if [ "$(cat "$WORK/r6/bench/perf/corpus/checker.vibe.txt")" = "$before" ]; then
  fail "RED 6 control: --all did NOT re-freeze a moved source; the bump path is broken"
fi
# Whichever mode ran, the result must still verify against its own record.
VIBE_BENCH_CORPUS_ROOT="$WORK/r6" bash scripts/bump_bench_corpus.sh --check >"$WORK/out" 2>&1 \
  || { cat "$WORK/out" >&2; fail "RED 6 control: the re-frozen corpus does not match its recorded digest"; }

echo "[bench-corpus-test] ok (6 red cases + 3 controls, each mutation verified to land)"
