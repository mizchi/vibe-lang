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
  if ! rg -q --fixed-strings "failing test: $want" "$out"; then
    echo "[vibe-test-smoke] FAIL: expected 'failing test: $want' in the FAIL output" >&2
    cat "$out" >&2
    exit 1
  fi
}
assert_full_failing_name "$WORK/space_name_test.vibe" "has a space"
assert_full_failing_name "$WORK/unicode_name_test.vibe" "café 日本語"
echo "[vibe-test-smoke] ok (quoted test names preserved on FAIL)"

# Guest stderr that happens to contain `__test_!!!` must not become the
# reported name. The unanchored `__test_` match used to consume that
# line first and print `failing test: !!!` instead of the later frame.
printf 'test "real name" {\n  Stderr::write_stream("__test_!!!\\n")\n  assert(false)\n}\n' \
  > "$WORK/guest_prefix_test.vibe"
assert_full_failing_name "$WORK/guest_prefix_test.vibe" "real name"
if rg -q --fixed-strings "failing test: !!!" "$WORK/name_guest_prefix_test.out"; then
  echo "[vibe-test-smoke] FAIL: guest stderr __test_!!! was reported as the failing test" >&2
  cat "$WORK/name_guest_prefix_test.out" >&2
  exit 1
fi

# Same contract on canned Node / wasmtime dumps, so wasmtime is pinned
# without a second backend compile. Drive vt_fail_detail directly —
# vibe_test.sh is not sourceable (it runs tests on load).
eval "$(sed -n '/^vt_fail_detail() {/,/^export -f vt_fail_detail$/p' \
  "$ROOT_DIR/scripts/vibe_test.sh")"
assert_canned_failing_name() {
  local label="$1" want="$2" errf out
  errf="$WORK/canned_${label}.err"
  cat > "$errf"
  out="$(vt_fail_detail "$errf" "" "canned.vibe")"
  if ! printf '%s\n' "$out" | rg -q --fixed-strings "failing test: $want"; then
    echo "[vibe-test-smoke] FAIL: canned $label expected 'failing test: $want'" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if printf '%s\n' "$out" | rg -q --fixed-strings "failing test: !!!"; then
    echo "[vibe-test-smoke] FAIL: canned $label reported guest stderr as the name" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}
assert_canned_failing_name node "real name" <<'EOF'
__test_!!!
RuntimeError: unreachable
    at __test_real name (wasm://wasm/00000000:wasm-function[3]:0x42)
    at _start (wasm://wasm/00000000:wasm-function[1]:0x10)
EOF
assert_canned_failing_name wasmtime "real name" <<'EOF'
__test_!!!
error while executing at wasm backtrace:
    0: 0x42 - <unknown>!__test_real name
    1: 0x10 - <unknown>!_start
   wasm trap: wasm `unreachable` instruction executed
EOF
echo "[vibe-test-smoke] ok (guest __test_ prefix is not the failing-test name)"

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
if ! rg -q "compiler: the committed seed" "$notice_err"; then
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
if ! rg -q "uncommitted file" "$notice_err"; then
  echo "[vibe-test-smoke] FAIL: a modified compiler source outside lib/@vibe/compiler was not counted" >&2
  echo "  (probe: ${PROBE#"$ROOT_DIR"/} -- it is a compiler source; see lib/@vibe/compiler/compiler_sources_manifest.tsv)" >&2
  cat "$notice_err" >&2
  exit 1
fi
# Naming the file is not the point -- `[ensure-seed]` already does that. The
# notice exists to say the seed is BEHIND, and to give the way out.
if ! rg -q "CANNOT observe" "$notice_err" || ! rg -q "VIBE_TEST_CLI_WASM=" "$notice_err"; then
  echo "[vibe-test-smoke] FAIL: the notice must state the consequence and the override" >&2
  cat "$notice_err" >&2
  exit 1
fi
# An explicit choice of compiler is not a mistake, and neither is an explicit
# request for quiet.
for silent_env in "VIBE_TEST_CLI_WASM=$ROOT_DIR/bootstrap/seed/compiler.wasm" \
                  "VIBE_TEST_QUIET_COMPILER_NOTE=1"; do
  if env "$silent_env" bash "$ROOT_DIR/scripts/vibe_test.sh" "$WORK/pass_test.vibe" \
      2>&1 >/dev/null | rg -q "compiler: the committed seed"; then
    echo "[vibe-test-smoke] FAIL: notice printed despite $silent_env" >&2
    exit 1
  fi
done
cleanup_probe

echo "[vibe-test-smoke] ok (seed notice fires on a compiler source outside lib/@vibe/compiler, suppressed on explicit compiler/quiet)"
