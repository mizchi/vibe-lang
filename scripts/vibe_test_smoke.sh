#!/usr/bin/env bash
# Smoke test for selfhost `vibe test` (scripts/vibe_test.sh): a file of passing
# tests must succeed (exit 0) and a file with a failing assert must fail.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK="$ROOT_DIR/_build/vibe_test_smoke"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

printf 'test "arith" {\n  assert_eq(1 + 1, 2)\n}\ntest "bool" {\n  assert(true)\n}\n' \
  > "$WORK/pass_test.vibe"
printf 'test "bad" {\n  assert_eq(1 + 1, 3)\n}\n' > "$WORK/fail_test.vibe"

if ! bash "$ROOT_DIR/scripts/vibe_test.sh" "$WORK/pass_test.vibe" >/dev/null 2>&1; then
  echo "[vibe-test-smoke] FAIL: passing test file did not succeed" >&2; exit 1
fi
if bash "$ROOT_DIR/scripts/vibe_test.sh" "$WORK/fail_test.vibe" >/dev/null 2>&1; then
  echo "[vibe-test-smoke] FAIL: failing test file did not fail" >&2; exit 1
fi

echo "[vibe-test-smoke] ok (pass-file=0, fail-file!=0)"

# #3505: a `./`-spelled path (and every path `find ./dir` prints) flattened to
# a result file starting with `.`, which the summary's `*.res` glob skipped: a
# failing `./fail_test.vibe` printed FAIL, then `0 passed, 0 failed` and exit
# 0. The summary line is asserted too, so a dropped result cannot hide behind a
# right exit code.
work_rel="${WORK#"$ROOT_DIR"/}"
assert_dot_spelling() {
  local want_rc="$1" want_summary="$2" out rc; shift 2
  out="$WORK/dot_spelling.out"
  set +e
  VIBE_TEST_QUIET_COMPILER_NOTE=1 bash "$ROOT_DIR/scripts/vibe_test.sh" "$@" >"$out" 2>&1
  rc=$?
  set -e
  if { [ "$want_rc" = 0 ] && [ "$rc" -ne 0 ]; } || { [ "$want_rc" != 0 ] && [ "$rc" -eq 0 ]; } \
     || ! grep -qF "$want_summary" "$out"; then
    echo "[vibe-test-smoke] FAIL: vibe_test.sh $* -- expected exit ${want_rc/1/non-zero} and '$want_summary', got exit $rc:" >&2
    cat "$out" >&2
    exit 1
  fi
}
assert_dot_spelling 1 "[vibe-test] 0 passed, 1 failed (1 files" "./$work_rel/fail_test.vibe"
assert_dot_spelling 1 "[vibe-test] 0 passed, 1 failed (1 files" "$work_rel/./fail_test.vibe"
assert_dot_spelling 0 "[vibe-test] 1 passed, 0 failed (1 files, 2 tests)" "./$work_rel/pass_test.vibe"
assert_dot_spelling 1 "[vibe-test] 1 passed, 1 failed (2 files" "./$work_rel"
echo "[vibe-test-smoke] ok (./ and /./ spellings keep their results, #3505)"

# #2153: coverage success means this invocation wrote a report. Simulate a
# compiler and runner that both return success without writing their outputs;
# a stale report from an earlier run must be removed and cannot satisfy the
# coverage gate. "cache" keeps this fixture in vibe_test.sh's sequential tail,
# so its worker runs in this shell while PATH supplies the fake nested bash.
missing_cov_src="$WORK/cache_missing_coverage_test.vibe"
printf 'test { assert(true) }\n' > "$missing_cov_src"
fake_bin="$WORK/fake-bin"
mkdir -p "$fake_bin" "$ROOT_DIR/_build/vibe_test/coverage"
cat > "$fake_bin/bash" <<'EOF'
#!/usr/bin/env sh
# Make the compile invocation look successful while leaving runtime coverage
# absent. Arguments: runner --invoke cli_main CLI SRC OUT ENTRY.
if [ "${2:-}" = "--invoke" ] && [ "${3:-}" = "cli_main" ]; then
  printf 'not-a-real-wasm' > "$6"
fi
exit 0
EOF
chmod +x "$fake_bin/bash"
fake_cli="$WORK/fake-compiler.wasm"
: > "$fake_cli"
missing_cov_flat="$(printf '%s' "${missing_cov_src#"$ROOT_DIR/"}" | tr '/' '_' | sed 's/\.vibe$//')"
stale_cov="$ROOT_DIR/_build/vibe_test/coverage/$missing_cov_flat.json"
printf '{"hit":99,"total":99}\n' > "$stale_cov"
missing_cov_out="$WORK/missing-coverage.out"
set +e
PATH="$fake_bin:$PATH" VIBE_TEST_CLI_WASM="$fake_cli" \
  /bin/bash "$ROOT_DIR/scripts/vibe_test.sh" --coverage "$missing_cov_src" \
  >"$missing_cov_out" 2>&1
missing_cov_code=$?
set -e
if [ "$missing_cov_code" -eq 0 ] || ! grep -qE 'FAIL \(coverage\)' "$missing_cov_out"; then
  echo "[vibe-test-smoke] FAIL: missing fresh coverage did not fail" >&2
  cat "$missing_cov_out" >&2
  exit 1
fi
if [ -e "$stale_cov" ]; then
  echo "[vibe-test-smoke] FAIL: stale coverage report survived the run" >&2
  exit 1
fi
echo "[vibe-test-smoke] ok (fresh coverage required)"

# #1946: a quoted test name must appear in full on FAIL. The runner used to
# match `__test_[A-Za-z0-9_]+` and cut the name at the first space (and drop
# Unicode). Exit status stays non-zero; the line is still `failing test: ...`.
printf 'test "has a space" {\n  assert(false)\n}\n' > "$WORK/space_name_test.vibe"
printf 'test "café 日本語" {\n  assert(false)\n}\n' > "$WORK/unicode_name_test.vibe"
assert_full_failing_name() {
  local src="$1" want="$2" out rc
  out="$WORK/name_$(basename "$src" .vibe).out"
  set +e
  VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash "$ROOT_DIR/scripts/vibe_test.sh" "$src" >"$out" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "[vibe-test-smoke] FAIL: '$want' did not fail (exit 0)" >&2
    cat "$out" >&2
    exit 1
  fi
  if ! grep -qF "failing test: $want" "$out"; then
    echo "[vibe-test-smoke] FAIL: expected 'failing test: $want' in the FAIL output" >&2
    cat "$out" >&2
    exit 1
  fi
}
assert_full_failing_name "$WORK/space_name_test.vibe" "has a space"
assert_full_failing_name "$WORK/unicode_name_test.vibe" "café 日本語"
# #1946 leftover: live file with a space in the quoted name, via assert_eq.
# Decode of `%20` is pinned on canned dumps below; this run still has to
# print the full source name and stay non-zero.
printf 'test "has spaces" {\n  assert_eq(1, 0)\n}\n' > "$WORK/has_spaces_test.vibe"
assert_full_failing_name "$WORK/has_spaces_test.vibe" "has spaces"
echo "[vibe-test-smoke] ok (quoted test names preserved on FAIL)"

# Guest stderr that happens to contain `__test_!!!` must not become the
# reported name. The unanchored `__test_` match used to consume that
# line first and print `failing test: !!!` instead of the later frame.
printf 'test "real name" {\n  Stderr::write_stream("__test_!!!\\n")\n  assert(false)\n}\n' \
  > "$WORK/guest_prefix_test.vibe"
assert_full_failing_name "$WORK/guest_prefix_test.vibe" "real name"
if grep -qF "failing test: !!!" "$WORK/name_guest_prefix_test.out"; then
  echo "[vibe-test-smoke] FAIL: guest stderr __test_!!! was reported as the failing test" >&2
  cat "$WORK/name_guest_prefix_test.out" >&2
  exit 1
fi

# The canned Node / wasmtime dumps that pinned the two awk condensers --
# guest `__test_` decoys, percent-encoded names, the 7-space indent, funcmap
# annotation, the assert-abort adjacency rules, exact runtime-check capture --
# are tests of @vibe/testreport now, the one implementation both runners use
# (#3674). Run them here so this smoke still fails when the report does.
if ! VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash "$ROOT_DIR/scripts/vibe_test.sh" "$ROOT_DIR/lib/@vibe/testreport/report_test.vibe" > "$WORK/testreport.out" 2>&1; then
  echo "[vibe-test-smoke] FAIL: @vibe/testreport report tests failed" >&2
  cat "$WORK/testreport.out" >&2
  exit 1
fi
echo "[vibe-test-smoke] ok (failure report: names, frames, assert-abort rules, runtime-check capture)"

# Directory input: scripts/vibe_test.sh already expands *_test.vibe; lock it.
mkdir -p "$WORK/dir_in"
printf 'test "in dir" {\n  assert_eq(1, 1)\n}\n' > "$WORK/dir_in/foo_test.vibe"
if ! VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash "$ROOT_DIR/scripts/vibe_test.sh" "$WORK/dir_in" >/dev/null 2>&1; then
  echo "[vibe-test-smoke] FAIL: vibe_test.sh did not accept a directory" >&2
  exit 1
fi
echo "[vibe-test-smoke] ok (directory input expands *_test.vibe)"

# #2870: and a directory scan that FAILED must not be reported as a directory
# that held nothing. `find | sort` runs two system binaries; when one of them
# dies the pipeline produces an empty list, and the old code answered
# `no test files found` -- the same words a genuinely empty directory gets.
# That is how a one-variable environment fault (the `pkf` wrapper exports an
# LD_LIBRARY_PATH that kills /usr/bin/sort) read as an ordinary outcome, and it
# took six steps to tell the two apart.
#
# Broken portably, by a `sort` earlier on PATH that exits non-zero -- the real
# trigger is a store path specific to one machine, and a case that can only run
# there is a case that does not run (#2252).
assert_dir_scan_failure_is_not_empty() {
  local bin="$WORK/fakebin" out
  mkdir -p "$bin" "$WORK/dir_scan"
  printf 'test "in dir" {\n  assert_eq(1, 1)\n}\n' > "$WORK/dir_scan/foo_test.vibe"
  printf '#!/bin/sh\nexit 3\n' > "$bin/sort"
  chmod +x "$bin/sort"
  out="$(PATH="$bin:$PATH" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash "$ROOT_DIR/scripts/vibe_test.sh" "$WORK/dir_scan" 2>&1)" && {
    echo "[vibe-test-smoke] FAIL: a directory scan whose sort failed still exited 0 (#2870)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  if ! printf '%s\n' "$out" | grep -qF "could not list"; then
    echo "[vibe-test-smoke] FAIL: a failed directory scan is reported as an empty directory (#2870)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  rm -rf "$bin"
  # The control: a genuinely empty directory still gets the other message. It is
  # what would catch the distinction collapsing the other way -- every scan
  # reported as a failure is as useless as every failure reported as empty.
  mkdir -p "$WORK/dir_empty"
  out="$(VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash "$ROOT_DIR/scripts/vibe_test.sh" "$WORK/dir_empty" 2>&1)" || true
  if ! printf '%s\n' "$out" | grep -qF "no test files found"; then
    echo "[vibe-test-smoke] FAIL: an empty directory no longer reports 'no test files found' (#2870)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}
assert_dir_scan_failure_is_not_empty
echo "[vibe-test-smoke] ok (a failed directory scan is distinguished from an empty one, #2870)"

# The seed-compiler notice. A green run through the committed seed says nothing
# about a compiler change in this checkout, and the two are indistinguishable
# from the result -- so the run has to say which compiler answered whenever the
# checkout is ahead of the seed. It goes to stderr so nothing parsing stdout is
# affected, and it must not turn a passing file into a failing one.
#
# Probed BEHAVIOURALLY, with a file that makes the checkout ahead, rather than
# by recomputing "is this checkout ahead?" here. An earlier version of this
# test did recompute it, duplicating vibe_test.sh's path list -- which meant
# the test agreed with the script by construction and could not catch the
# script checking the wrong paths. It was checking lib/@vibe/compiler|cli only,
# and a compiler change confined to lib/@vibe/parser (a compiler source: see
# lib/@vibe/compiler/compiler_sources_manifest.tsv) went unwarned.
#
# So the probe lives in lib/@vibe/parser on purpose: it is the case the
# narrower predicate missed.
PROBE="$ROOT_DIR/lib/@vibe/parser/_seed_gap_probe.tmp"
cleanup_probe() { rm -f "$PROBE"; }
trap 'cleanup_probe; rm -rf "$WORK"' EXIT
# Deliberately NOT a .vibe file. The pathspec filters by directory, not by
# extension, so a .tmp exercises the same predicate -- while staying invisible
# to every *.vibe glob in the tree (vibe-fmt-check lints lib/**/*.vibe), so a
# task running beside this one cannot trip over it.
printf 'transient: scripts/vibe_test_smoke.sh seed-gap probe\n' > "$PROBE"

notice_err="$WORK/notice.stderr"
if ! bash "$ROOT_DIR/scripts/vibe_test.sh" "$WORK/pass_test.vibe" >/dev/null 2>"$notice_err"; then
  echo "[vibe-test-smoke] FAIL: the compiler notice must not fail a passing file" >&2
  cat "$notice_err" >&2
  exit 1
fi
if ! grep -qE "compiler: the committed seed" "$notice_err"; then
  echo "[vibe-test-smoke] FAIL: a compiler source is modified but no seed notice was printed" >&2
  echo "  (probe: ${PROBE#"$ROOT_DIR"/})" >&2
  cat "$notice_err" >&2
  exit 1
fi
# Assert on the UNCOMMITTED clause, not merely on the notice appearing. Any
# checkout past a seed bump is already some commits ahead, so the notice fires
# with or without the probe -- asserting its presence proves nothing about
# which paths are checked. Only the uncommitted count can distinguish them:
# the probe is the sole uncommitted file, and a predicate that does not cover
# lib/@vibe/parser reports zero of them.
if ! grep -qE "uncommitted file" "$notice_err"; then
  echo "[vibe-test-smoke] FAIL: a modified compiler source outside lib/@vibe/compiler was not counted" >&2
  echo "  (probe: ${PROBE#"$ROOT_DIR"/} -- it is a compiler source; see lib/@vibe/compiler/compiler_sources_manifest.tsv)" >&2
  cat "$notice_err" >&2
  exit 1
fi
# Naming the file is not the point -- `[ensure-seed]` already does that. The
# notice exists to say the seed is BEHIND, and to give the way out.
if ! grep -qE "CANNOT observe" "$notice_err" || ! grep -qE "VIBE_TEST_CLI_WASM=" "$notice_err"; then
  echo "[vibe-test-smoke] FAIL: the notice must state the consequence and the override" >&2
  cat "$notice_err" >&2
  exit 1
fi
# An explicit choice of compiler is not a mistake, and neither is an explicit
# request for quiet.
for silent_env in "VIBE_TEST_CLI_WASM=$ROOT_DIR/bootstrap/seed/compiler.wasm" \
                  "VIBE_TEST_QUIET_COMPILER_NOTE=1"; do
  if env "$silent_env" bash "$ROOT_DIR/scripts/vibe_test.sh" "$WORK/pass_test.vibe" \
      2>&1 >/dev/null | grep -qE "compiler: the committed seed"; then
    echo "[vibe-test-smoke] FAIL: notice printed despite $silent_env" >&2
    exit 1
  fi
done
cleanup_probe

echo "[vibe-test-smoke] ok (seed notice fires on a compiler source outside lib/@vibe/compiler, suppressed on explicit compiler/quiet)"

# #2886: `vibe test --update` works here, and an unrecognised option does not
# borrow the MISSING-FILE wording.
#
# `--update` used to fall through the flag loop into the positional list and
# come back as `not found: --update`, which reads as a typo in a filename. The
# flag is real everywhere else (`runtime/vibe` documents `vibe test --update`),
# and CLAUDE.md sends a compiler change through THIS wrapper because it is the
# only lane that honours VIBE_TEST_CLI_WASM -- so the two instructions could
# not both be followed. It is implemented here now, and the wording defect is
# fixed for every OTHER flag.
#
# The capability is asserted by OUTCOME, not by exit code: a stale snapshot is
# patched to the value the run printed and the file then passes, a file that is
# already correct is left byte-identical, and a failure that is not an inspect
# mismatch still FAILS with the source untouched (a `--update` that "fixes"
# anything by rewriting a source is worse than one that does not exist).
assert_update_patches_stale_snapshots() {
  local out rc d
  d="$ROOT_DIR/_build/_smoke_2886"
  rm -rf "$d"; mkdir -p "$d"

  # (1) A stale snapshot is brought to the value the run printed, and the
  #     unrelated literal with a different spelling is not disturbed.
  cat > "$d/stale_test.vibe" <<'VEOF'
let label = "keep"

test "smoke" {
  inspect(10 + 1, "stale")
  assert(label == "keep")
}
VEOF
  out="$(VIBE_TEST_QUIET_COMPILER_NOTE=1 bash "$ROOT_DIR/scripts/vibe_test.sh" \
    --update _build/_smoke_2886/stale_test.vibe 2>&1)" && rc=0 || rc=$?
  if [ "${rc:-0}" -ne 0 ]; then
    echo "[vibe-test-smoke] FAIL: --update did not bring a stale snapshot to green (#2886)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if ! grep -qF 'inspect(10 + 1, "11")' "$d/stale_test.vibe"; then
    echo "[vibe-test-smoke] FAIL: --update did not patch the stale literal (#2886)" >&2
    cat "$d/stale_test.vibe" >&2
    exit 1
  fi
  if ! grep -qF 'let label = "keep"' "$d/stale_test.vibe"; then
    echo "[vibe-test-smoke] FAIL: --update disturbed an unrelated literal (#2886)" >&2
    cat "$d/stale_test.vibe" >&2
    exit 1
  fi
  if ! printf '%s\n' "$out" | grep -qF "updated 1 snapshot(s)"; then
    echo "[vibe-test-smoke] FAIL: --update did not report the patch it made (#2886)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi

  # (2) Idempotent: a second run has nothing to do and must not rewrite.
  cp "$d/stale_test.vibe" "$d/stale_test.vibe.was"
  out="$(VIBE_TEST_QUIET_COMPILER_NOTE=1 bash "$ROOT_DIR/scripts/vibe_test.sh" \
    --update _build/_smoke_2886/stale_test.vibe 2>&1)" && rc=0 || rc=$?
  if [ "${rc:-0}" -ne 0 ]; then
    echo "[vibe-test-smoke] FAIL: --update failed on an already-correct file (#2886)" >&2
    exit 1
  fi
  if ! cmp -s "$d/stale_test.vibe" "$d/stale_test.vibe.was"; then
    echo "[vibe-test-smoke] FAIL: --update rewrote an already-correct file (#2886)" >&2
    exit 1
  fi
  if printf '%s\n' "$out" | grep -qF "updated"; then
    echo "[vibe-test-smoke] FAIL: --update claimed a patch it did not make (#2886)" >&2
    exit 1
  fi

  # (3) The control. A failure that is NOT an inspect mismatch cannot be
  #     patched away: it stays a FAIL and the source is untouched.
  # assert_eq, not a bare assert: it PRINTS on failure, so the patcher is
  # actually handed a non-empty capture and has to decide that none of it is
  # an inspect mismatch. A bare assert prints nothing, the patch step never
  # runs, and this case would assert nothing about it.
  cat > "$d/hard_test.vibe" <<'VEOF'
test "hard" {
  assert_eq(1, 2)
}
VEOF
  cp "$d/hard_test.vibe" "$d/hard_test.vibe.was"
  out="$(VIBE_TEST_QUIET_COMPILER_NOTE=1 bash "$ROOT_DIR/scripts/vibe_test.sh" \
    --update _build/_smoke_2886/hard_test.vibe 2>&1)" && rc=0 || rc=$?
  if [ "${rc:-0}" -eq 0 ]; then
    echo "[vibe-test-smoke] FAIL: --update turned a genuine failure green (#2886)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if ! cmp -s "$d/hard_test.vibe" "$d/hard_test.vibe.was"; then
    echo "[vibe-test-smoke] FAIL: --update rewrote a source on a non-snapshot failure (#2886)" >&2
    exit 1
  fi
  # ... and it must not have SPUN doing it. A patch that writes the source
  # back unchanged is not progress; counting it as progress terminates only on
  # the depth bound, which leaves the file untouched (so the check above stays
  # green) after 50 recompiles. The patch count on the FAIL line is what makes
  # that visible.
  if printf '%s\n' "$out" | grep -qF "snapshot patch(es)"; then
    echo "[vibe-test-smoke] FAIL: --update retried on a patch that changed nothing (#2886)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi

  # (4) A run WITHOUT --update never patches, whatever is stale.
  cat > "$d/nostale_test.vibe" <<'VEOF'
test "smoke" {
  inspect(10 + 1, "stale")
}
VEOF
  cp "$d/nostale_test.vibe" "$d/nostale_test.vibe.was"
  out="$(VIBE_TEST_QUIET_COMPILER_NOTE=1 bash "$ROOT_DIR/scripts/vibe_test.sh" \
    _build/_smoke_2886/nostale_test.vibe 2>&1)" && rc=0 || rc=$?
  if [ "${rc:-0}" -eq 0 ]; then
    echo "[vibe-test-smoke] FAIL: a stale snapshot passed without --update (#2886)" >&2
    exit 1
  fi
  if ! cmp -s "$d/nostale_test.vibe" "$d/nostale_test.vibe.was"; then
    echo "[vibe-test-smoke] FAIL: a run without --update patched a source (#2886)" >&2
    exit 1
  fi

  rm -rf "$d"
}
assert_update_patches_stale_snapshots

echo "[vibe-test-smoke] ok (--update patches stale inspect snapshots and nothing else, #2886)"

# The wording half of #2886. Two assertions, because the fix has to be narrow:
# any other `-flag` says it is unrecognised, and a genuinely missing PATH still
# gets `not found` -- that last one is what a too-wide fix would break.
assert_unrecognised_option_is_not_a_missing_file() {
  local out rc

  out="$(VIBE_TEST_QUIET_COMPILER_NOTE=1 bash "$ROOT_DIR/scripts/vibe_test.sh" \
    --bogus fixtures/bit_not_test.vibe 2>&1)" && rc=0 || rc=$?
  if [ "${rc:-0}" -eq 0 ]; then
    echo "[vibe-test-smoke] FAIL: an unrecognised flag was accepted (#2886)" >&2
    exit 1
  fi
  if printf '%s\n' "$out" | grep -qF "not found: --bogus"; then
    echo "[vibe-test-smoke] FAIL: an unrecognised flag still reported with the missing-file wording (#2886)" >&2
    exit 1
  fi
  if ! printf '%s\n' "$out" | grep -qF "unrecognised option"; then
    echo "[vibe-test-smoke] FAIL: an unrecognised flag did not say so (#2886)" >&2
    exit 1
  fi

  # The control. A missing PATH is a different fact and keeps its own wording.
  out="$(VIBE_TEST_QUIET_COMPILER_NOTE=1 bash "$ROOT_DIR/scripts/vibe_test.sh" \
    no_such_file_2886.vibe 2>&1)" && rc=0 || rc=$?
  if [ "${rc:-0}" -eq 0 ]; then
    echo "[vibe-test-smoke] FAIL: a missing path was accepted" >&2
    exit 1
  fi
  if ! printf '%s\n' "$out" | grep -qF "not found: no_such_file_2886.vibe"; then
    echo "[vibe-test-smoke] FAIL: a missing path lost its own message (#2886 fix is too wide)" >&2
    exit 1
  fi
}
assert_unrecognised_option_is_not_a_missing_file

echo "[vibe-test-smoke] ok (an unrecognised option is not reported as a missing file, #2886)"
