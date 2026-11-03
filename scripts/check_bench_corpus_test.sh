#!/usr/bin/env bash
# Red test for check_bench_corpus.vibex (#2248: a gate means nothing until it
# is known to be able to fail). #3672 ported the gate; this test plants a
# synthetic tree for each case and passes it as --root, so the repository's own
# corpus is never edited.
#
# Each mutation is checked for having LANDED before its verdict is believed --
# an edit that matches nothing passes while proving nothing.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# bump_bench_corpus.sh reads this; inherit nothing (#2252).
unset VIBE_BENCH_CORPUS_ROOT

# The gate reads only inside the repository, so the trees live under _build/.
WORK_REL="_build/bench_corpus_test.$$"
WORK="$ROOT_DIR/$WORK_REL"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "[bench-corpus-test] FAIL: $*" >&2; exit 1; }

run_gate() { # <tree name under $WORK>
  bash scripts/vibe_run.sh scripts/check_bench_corpus.vibex -- --root "$WORK_REL/$1" >"$WORK/out" 2>&1
}

# A well-formed tree at $WORK/$1: the repository's real snapshots and their
# PROVENANCE.tsv, an allow-list with no rows, and one bench reading the corpus.
build_tree() {
  t="$WORK/$1"
  rm -rf "$t"
  mkdir -p "$t/bench/perf/corpus" "$t/lib/@vibe/compiler"
  cp bench/perf/corpus/PROVENANCE.tsv bench/perf/corpus/*.vibe.txt "$t/bench/perf/corpus/"
  printf '# <path><TAB><reason>\n' > "$t/bench/perf/corpus/ALLOWLIST.txt"
  cat > "$t/lib/@vibe/compiler/clean_bench.vibe" <<'VIBE'
bench "reads the frozen corpus" {
  let _ = lex(Fs::read_file("bench/perf/corpus/lexer.vibe.txt"))
}
VIBE
}

expect_red() { # <case> <tree> <message>
  if run_gate "$2"; then
    fail "$1: the gate passed"
  fi
  grep -qF -- "$3" "$WORK/out" \
    || { cat "$WORK/out" >&2; fail "$1 failed for the wrong reason (want: $3)"; }
}

# GREEN control. Without it a gate failing for an unrelated reason would make
# every red case below "pass".
build_tree control
if ! run_gate control; then
  cat "$WORK/out" >&2
  fail "the gate does not pass on the unmutated tree; the red cases below would prove nothing"
fi

# RED 1: a snapshot edited without going through the bump script. This is the
# case that matters most -- the corpus is a file anyone can open, and a one-byte
# change silently restates every number in the series.
build_tree r1
cp "$WORK/r1/bench/perf/corpus/lexer.vibe.txt" "$WORK/lexer.orig"
printf '\n// stray edit\n' >> "$WORK/r1/bench/perf/corpus/lexer.vibe.txt"
cmp -s "$WORK/r1/bench/perf/corpus/lexer.vibe.txt" "$WORK/lexer.orig" \
  && fail "RED 1 mutation did not land (the corpus is unchanged)"
expect_red "RED 1" r1 'lexer.vibe.txt does not match its recorded digest'

# RED 2: a snapshot nobody recorded. A digest check that walked only the
# PROVENANCE rows would never see it.
build_tree r2
cp "$WORK/r2/bench/perf/corpus/small.vibe.txt" "$WORK/r2/bench/perf/corpus/extra.vibe.txt"
expect_red "RED 2" r2 'extra.vibe.txt has no PROVENANCE.tsv row'

# RED 3: a recorded snapshot deleted.
build_tree r3
rm "$WORK/r3/bench/perf/corpus/parser.vibe.txt"
expect_red "RED 3" r3 'parser.vibe.txt is recorded but missing'

# RED 4: a PROVENANCE.tsv with no rows. Checking nothing is not a pass.
build_tree r4
grep '^#' bench/perf/corpus/PROVENANCE.tsv > "$WORK/r4/bench/perf/corpus/PROVENANCE.tsv"
rm "$WORK/r4/bench/perf/corpus/"*.vibe.txt
expect_red "RED 4" r4 'records no snapshot'

# RED 5: a bench repointed back at a live source.
build_tree r5
cat > "$WORK/r5/lib/@vibe/compiler/regressed_bench.vibe" <<'VIBE'
bench "reads the live checker" {
  let _ = lex(Fs::read_file("lib/@vibe/compiler/checker/checker.vibe"))
}
VIBE
expect_red "RED 5" r5 'regressed_bench.vibe names a LIVE source path'
# ...a probe is held to the same rule.
rm "$WORK/r5/lib/@vibe/compiler/regressed_bench.vibe"
printf 'let path = "lib/@vibe/parser/parser.vibe"\n' > "$WORK/r5/lib/@vibe/compiler/regressed_probe.vibe"
expect_red "RED 5 (probe)" r5 'regressed_probe.vibe names a LIVE source path'

# RED 6: an allow-list row with no reason. The row is the decision surface; a
# bare path records that someone was exempted and not why.
build_tree r6
printf 'let path = "lib/@vibe/parser/parser.vibe"\n' > "$WORK/r6/lib/@vibe/compiler/live_probe.vibe"
printf 'lib/@vibe/compiler/live_probe.vibe\n' >> "$WORK/r6/bench/perf/corpus/ALLOWLIST.txt"
grep -qxF 'lib/@vibe/compiler/live_probe.vibe' "$WORK/r6/bench/perf/corpus/ALLOWLIST.txt" \
  || fail "RED 6 mutation did not land (the allow-list row was not written)"
expect_red "RED 6" r6 'allow-list row with no reason'
# ...and the control: WITH a reason, the same row exempts it. Without this the
# case above would also pass a gate that rejected every allow-list row.
printf '# <path><TAB><reason>\nlib/@vibe/compiler/live_probe.vibe\tbecause the test says so\n' \
  > "$WORK/r6/bench/perf/corpus/ALLOWLIST.txt"
run_gate r6 || { cat "$WORK/out" >&2; fail "RED 6 control: a row WITH a reason did not exempt the file"; }

# RED 7: a stale allow-list row. It exempts nothing and hides that the corpus
# moved, so it must not pass quietly.
build_tree r7
printf 'lib/@vibe/compiler/no_such_bench.vibe\tgone\n' >> "$WORK/r7/bench/perf/corpus/ALLOWLIST.txt"
expect_red "RED 7" r7 'names a file that does not exist'

# RED 8: no allow-list at all. An absent one is not an empty one.
build_tree r8
rm "$WORK/r8/bench/perf/corpus/ALLOWLIST.txt"
expect_red "RED 8" r8 'an absent allow-list is not an empty one'

# RED 9: no bench files. Silence is "unchecked", not "clean".
build_tree r9
rm "$WORK/r9/lib/@vibe/compiler/clean_bench.vibe"
expect_red "RED 9" r9 'no bench files matched'

# RED 10: `bump_bench_corpus.sh` is ADDITIVE by default (#2878). Adding a corpus
# entry must not re-freeze the ones already there -- the first attempt at the
# fourth entry did exactly that, because `main` had changed `checker.vibe` in
# between, and silently reset two series the change was not about. Only `--all`
# is a bump.
#
# Built in a scratch root so the tree's own corpus is never touched. The paths
# are the ones the script hardcodes.
R10="$WORK/r10"
mkdir -p "$R10/lib/@vibe/compiler/checker" \
         "$R10/lib/@vibe/parser" \
         "$R10/lib/@vibex/url" \
         "$R10/bench/perf/corpus" \
         "$R10/scripts"
cp scripts/bump_bench_corpus.sh "$R10/scripts/"
printf 'fn checker() -> Int {\n  1\n}\n'  > "$R10/lib/@vibe/compiler/checker/checker.vibe"
printf 'fn lexer() -> Int {\n  1\n}\n'    > "$R10/lib/@vibe/parser/lexer.vibe"
printf 'fn parser() -> Int {\n  1\n}\n'   > "$R10/lib/@vibe/parser/parser.vibe"
printf 'fn url() -> Int {\n  1\n}\n'      > "$R10/lib/@vibex/url/url.vibe"
# What the gate needs besides the corpus, so it can verify what the bump wrote.
printf '# <path><TAB><reason>\n' > "$R10/bench/perf/corpus/ALLOWLIST.txt"
printf 'bench "b" {\n  ()\n}\n' > "$R10/lib/@vibe/compiler/scratch_bench.vibe"

VIBE_BENCH_CORPUS_ROOT="$R10" bash scripts/bump_bench_corpus.sh --all >"$WORK/out" 2>&1 \
  || { cat "$WORK/out" >&2; fail "RED 10 setup: the initial --all freeze failed"; }
before="$(cat "$R10/bench/perf/corpus/checker.vibe.txt")"

# The mutation: the SOURCE moves, exactly as a merge from main would move it.
printf 'fn checker() -> Int {\n  2\n}\n' > "$R10/lib/@vibe/compiler/checker/checker.vibe"
if cmp -s "$R10/lib/@vibe/compiler/checker/checker.vibe" /dev/null; then
  fail "RED 10 mutation did not land (the source file is empty)"
fi

VIBE_BENCH_CORPUS_ROOT="$R10" bash scripts/bump_bench_corpus.sh >"$WORK/out" 2>&1 \
  || { cat "$WORK/out" >&2; fail "RED 10: the default (additive) run failed"; }
if [ "$(cat "$R10/bench/perf/corpus/checker.vibe.txt")" != "$before" ]; then
  fail "RED 10: the default run RE-FROZE an existing snapshot; adding an entry would bump the others"
fi
grep -qF 'already frozen at' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 10: the default run did not report keeping the existing snapshot"; }

# ...and the control: --all DOES re-freeze, or "additive" would just mean broken.
VIBE_BENCH_CORPUS_ROOT="$R10" bash scripts/bump_bench_corpus.sh --all >"$WORK/out" 2>&1 \
  || { cat "$WORK/out" >&2; fail "RED 10 control: the --all run failed"; }
if [ "$(cat "$R10/bench/perf/corpus/checker.vibe.txt")" = "$before" ]; then
  fail "RED 10 control: --all did NOT re-freeze a moved source; the bump path is broken"
fi
# Whichever mode ran, the result must still verify against its own record --
# which is also the gate agreeing with the writer about what a digest is.
run_gate r10 \
  || { cat "$WORK/out" >&2; fail "RED 10 control: the gate rejects the corpus the bump script just wrote"; }

# The repository's own tree passes.
bash scripts/vibe_run.sh scripts/check_bench_corpus.vibex >"$WORK/out" 2>&1 \
  || { cat "$WORK/out" >&2; fail "the repository's own corpus and benches were rejected"; }

echo "[bench-corpus-test] ok (11 red cases + 4 controls + the real tree, each mutation verified to land)"
