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
if [ "$missing_cov_code" -eq 0 ] || ! rg -q 'FAIL \(coverage\)' "$missing_cov_out"; then
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
  if ! rg -q --fixed-strings "failing test: $want" "$out"; then
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

# #1946 leftover: quoted names can appear percent-encoded in a frame
# (`test "has spaces"` → `__test_has%20spaces`). The old
# `__test_[A-Za-z0-9_]+` match stops at `%` and prints `has`. Both
# condensers must decode `%XX` so the FAIL line shows the source name.
# runtime/vibe is not sourceable (it is the user-facing launcher); extract
# condense_test_trap the same way as vt_fail_detail.
eval "$(sed -n '/^condense_test_trap() {/,/^}$/p' "$ROOT_DIR/runtime/vibe")"
assert_canned_failing_name node_pct "has spaces" <<'EOF'
RuntimeError: unreachable
    at __test_has%20spaces (wasm://wasm/00000000:wasm-function[3]:0x42)
    at _start (wasm://wasm/00000000:wasm-function[1]:0x10)
EOF
assert_canned_failing_name wasmtime_pct "has spaces" <<'EOF'
error while executing at wasm backtrace:
    0: 0x42 - <unknown>!__test_has%20spaces
    1: 0x10 - <unknown>!_start
   wasm trap: wasm `unreachable` instruction executed
EOF
assert_condense_failing_name() {
  local label="$1" want="$2" errf out
  errf="$WORK/canned_condense_${label}.err"
  cat > "$errf"
  out="$(condense_test_trap "$errf" "" "canned.vibe")"
  if ! printf '%s\n' "$out" | rg -q --fixed-strings "failing test: $want"; then
    echo "[vibe-test-smoke] FAIL: condense $label expected 'failing test: $want'" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}
assert_condense_failing_name node_space "has spaces" <<'EOF'
RuntimeError: unreachable
    at __test_has spaces (wasm://wasm/00000000:wasm-function[3]:0x42)
    at _start (wasm://wasm/00000000:wasm-function[1]:0x10)
EOF
assert_condense_failing_name node_pct "has spaces" <<'EOF'
RuntimeError: unreachable
    at __test_has%20spaces (wasm://wasm/00000000:wasm-function[3]:0x42)
    at _start (wasm://wasm/00000000:wasm-function[1]:0x10)
EOF
assert_condense_failing_name wasmtime_pct "has spaces" <<'EOF'
error while executing at wasm backtrace:
    0: 0x42 - <unknown>!__test_has%20spaces
    1: 0x10 - <unknown>!_start
   wasm trap: wasm `unreachable` instruction executed
EOF
echo "[vibe-test-smoke] ok (percent-encoded quoted names decode on FAIL)"

# #1946 leftover: vt_fail_detail must surface the assert_eq diagnostic that
# the guest writes to stderr (vibe test discards stdout).
assert_canned_assert_eq_diag() {
  local errf="$WORK/canned_assert_eq.err" out
  cat > "$errf" <<'EOF'
assert_eq failed
  expected: 2
  actual:   1
RuntimeError: unreachable
    at __test_bad (wasm://wasm/00000000:wasm-function[3]:0x42)
    at _start (wasm://wasm/00000000:wasm-function[1]:0x10)
EOF
  out="$(vt_fail_detail "$errf" "" "canned.vibe")"
  if ! printf '%s\n' "$out" | rg -q --fixed-strings "assert_eq failed"; then
    echo "[vibe-test-smoke] FAIL: canned assert_eq missing 'assert_eq failed'" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$out" | rg -q --fixed-strings "expected: 2"; then
    echo "[vibe-test-smoke] FAIL: canned assert_eq missing expected value" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$out" | rg -q --fixed-strings "actual:   1"; then
    echo "[vibe-test-smoke] FAIL: canned assert_eq missing actual value" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  # #2202: the assert's own abort trap must NOT be echoed after the assert
  # block -- it read as a second, unexplained failure.
  if printf '%s\n' "$out" | rg -q --fixed-strings "trap:"; then
    echo "[vibe-test-smoke] FAIL: assert_eq failure still echoes its own abort trap (#2202)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}
assert_canned_assert_eq_diag
echo "[vibe-test-smoke] ok (assert_eq expected/actual surfaced on FAIL)"

# #2202 boundary: a trap with NO assert diagnostic (a real crash) must still
# print its reason -- the suppression is only for the assert's own abort.
assert_bare_trap_still_reported() {
  local errf="$WORK/canned_bare_trap.err" out
  cat > "$errf" <<'EOF'
RuntimeError: unreachable
    at __test_bad (wasm://wasm/00000000:wasm-function[3]:0x42)
    at _start (wasm://wasm/00000000:wasm-function[1]:0x10)
EOF
  out="$(vt_fail_detail "$errf" "" "canned.vibe")"
  if ! printf '%s\n' "$out" | rg -q --fixed-strings "trap: RuntimeError: unreachable"; then
    echo "[vibe-test-smoke] FAIL: bare trap (no assert diag) lost its trap: line" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}
assert_bare_trap_still_reported

# #2202 boundary (Codex P2 on #2213): user output that IMITATES the assert
# block, followed by other output and then a REAL unrelated trap, must not
# have that trap suppressed -- suppression requires the block to directly
# precede the trap (only crash-debug / blank lines between).
assert_imitated_block_keeps_real_trap() {
  local errf="$WORK/canned_fake_assert.err" out
  cat > "$errf" <<'EOF'
assert_eq failed
  expected: 2
  actual:   1
some ordinary println output after the fake block
RuntimeError: unreachable
    at __test_bad (wasm://wasm/00000000:wasm-function[3]:0x42)
    at _start (wasm://wasm/00000000:wasm-function[1]:0x10)
EOF
  out="$(vt_fail_detail "$errf" "" "canned.vibe")"
  if ! printf '%s\n' "$out" | rg -q --fixed-strings "trap: RuntimeError: unreachable"; then
    echo "[vibe-test-smoke] FAIL: real trap after an imitated assert block was suppressed (#2202)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}
assert_imitated_block_keeps_real_trap

# #2202: the real abort shape has the host's crash-debug dump (and a blank
# line) between the assert block and the trap reason -- those must not break
# the adjacency, or the suppression never fires on a real failure.
assert_real_shape_with_crash_debug_suppressed() {
  local errf="$WORK/canned_real_assert.err" out
  cat > "$errf" <<'EOF'
assert_eq failed
  expected: 5
  actual:   4

[crash debug] heap_ptr=480 (0x1e0), memory_size=4194304 (64 pages) / unreachable
[crash debug] mem[0..32]: 00 00 00 00
RuntimeError: unreachable
    at __test_bad (wasm://wasm/00000000:wasm-function[3]:0x42)
    at _start (wasm://wasm/00000000:wasm-function[1]:0x10)
EOF
  out="$(vt_fail_detail "$errf" "" "canned.vibe")"
  if printf '%s\n' "$out" | rg -q --fixed-strings "trap:"; then
    echo "[vibe-test-smoke] FAIL: real assert abort (with crash-debug between) still echoed its trap (#2202)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}
assert_real_shape_with_crash_debug_suppressed

# #2202 (Codex round 2 on #2213): a rendered value may contain newlines, so
# the block is not always consecutive -- the generated abort therefore prints
# a machine marker (`assert failed: aborting`) as its final line, and the
# recognizer trusts the marker. The marker itself must not appear in the
# report.
assert_multiline_value_with_marker_suppressed() {
  local errf="$WORK/canned_multiline_assert.err" out
  cat > "$errf" <<'EOF'
assert_eq failed
  expected: a
c
  actual:   a
b
assert failed: aborting
[crash debug] heap_ptr=496 (0x1f0), memory_size=4194304 (64 pages) / unreachable
RuntimeError: unreachable
    at __test_bad (wasm://wasm/00000000:wasm-function[3]:0x42)
    at _start (wasm://wasm/00000000:wasm-function[1]:0x10)
EOF
  out="$(vt_fail_detail "$errf" "" "canned.vibe")"
  if printf '%s\n' "$out" | rg -q --fixed-strings "trap:"; then
    echo "[vibe-test-smoke] FAIL: multiline assert abort (with marker) still echoed its trap (#2202)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if printf '%s\n' "$out" | rg -q --fixed-strings "assert failed: aborting"; then
    echo "[vibe-test-smoke] FAIL: the assert abort marker leaked into the report (#2202)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}
assert_multiline_value_with_marker_suppressed

# ...and a marker that is NOT adjacent to the trap (other output after it)
# must not suppress: the trap is then something else.
assert_stale_marker_keeps_real_trap() {
  local errf="$WORK/canned_stale_marker.err" out
  cat > "$errf" <<'EOF'
assert failed: aborting
some unrelated output afterwards
RuntimeError: unreachable
    at __test_bad (wasm://wasm/00000000:wasm-function[3]:0x42)
EOF
  out="$(vt_fail_detail "$errf" "" "canned.vibe")"
  if ! printf '%s\n' "$out" | rg -q --fixed-strings "trap: RuntimeError: unreachable"; then
    echo "[vibe-test-smoke] FAIL: real trap after a stale abort marker was suppressed (#2202)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}
assert_stale_marker_keeps_real_trap

# #2199 (Codex on #2220): the OOB message capture is EXACT-match only --
# the generated Array::get/set lines are kept in the condensed report, but
# a user-printed line that merely ends the same way must not be promoted
# into the diagnostic.
assert_oob_message_capture_is_exact() {
  local errf="$WORK/canned_oob.err" out
  cat > "$errf" <<'EOF'
my thing: index out of bounds
Array::get: index out of bounds
[crash debug] heap_ptr=500 (0x1f4), memory_size=4194304 (64 pages) / unreachable
RuntimeError: unreachable
    at __test_bad (wasm://wasm/00000000:wasm-function[3]:0x42)
EOF
  out="$(vt_fail_detail "$errf" "" "canned.vibe")"
  if ! printf '%s\n' "$out" | rg -q --fixed-strings "Array::get: index out of bounds"; then
    echo "[vibe-test-smoke] FAIL: generated OOB message lost from the condensed report (#2199)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if printf '%s\n' "$out" | rg -q --fixed-strings "my thing: index out of bounds"; then
    echo "[vibe-test-smoke] FAIL: user output masquerading as an OOB diagnostic was promoted (#2199)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$out" | rg -q --fixed-strings "trap: RuntimeError: unreachable"; then
    echo "[vibe-test-smoke] FAIL: OOB trap reason lost (#2199)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}
assert_oob_message_capture_is_exact
echo "[vibe-test-smoke] ok (assert abort trap suppressed; bare/imitated traps still reported; OOB capture exact)"

# Directory input: scripts/vibe_test.sh already expands *_test.vibe; lock it.
mkdir -p "$WORK/dir_in"
printf 'test "in dir" {\n  assert_eq(1, 1)\n}\n' > "$WORK/dir_in/foo_test.vibe"
if ! VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash "$ROOT_DIR/scripts/vibe_test.sh" "$WORK/dir_in" >/dev/null 2>&1; then
  echo "[vibe-test-smoke] FAIL: vibe_test.sh did not accept a directory" >&2
  exit 1
fi
echo "[vibe-test-smoke] ok (directory input expands *_test.vibe)"

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
