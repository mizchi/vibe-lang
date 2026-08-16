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

# The seed-compiler notice. A green run through the committed seed says nothing
# about a compiler change in this checkout, and the two are indistinguishable
# from the result -- so the run has to say which compiler answered whenever the
# checkout is ahead of the seed under lib/@vibe/compiler|cli. It goes to stderr
# so nothing parsing stdout is affected, and it must not turn a passing file
# into a failing one.
seed_src_commit="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1]))["seed"].get("source_commit", ""))
except Exception:
    print("")' "$ROOT_DIR/bootstrap/seed.json" 2>/dev/null || true)"
ahead=0
if [ -n "$seed_src_commit" ] && git cat-file -e "$seed_src_commit^{commit}" 2>/dev/null; then
  n="$(git rev-list --count "$seed_src_commit"..HEAD -- lib/@vibe/compiler lib/@vibe/cli 2>/dev/null || echo 0)"
  [ "${n:-0}" != "0" ] && ahead=1
fi
if [ "$(git status --porcelain -- lib/@vibe/compiler lib/@vibe/cli 2>/dev/null | wc -l | tr -d ' ')" != "0" ]; then
  ahead=1
fi

notice_err="$WORK/notice.stderr"
if ! bash "$ROOT_DIR/scripts/vibe_test.sh" "$WORK/pass_test.vibe" >/dev/null 2>"$notice_err"; then
  echo "[vibe-test-smoke] FAIL: the compiler notice must not fail a passing file" >&2
  cat "$notice_err" >&2
  exit 1
fi
if [ "$ahead" = "1" ]; then
  if ! rg -q "compiler: the committed seed" "$notice_err"; then
    echo "[vibe-test-smoke] FAIL: checkout is ahead of the seed but no compiler notice was printed" >&2
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
  echo "[vibe-test-smoke] ok (seed notice present, suppressed on explicit compiler/quiet)"
else
  # A checkout sitting exactly on the seed's compiler sources has nothing to
  # warn about, and warning anyway would train the reader to ignore it.
  if rg -q "compiler: the committed seed" "$notice_err"; then
    echo "[vibe-test-smoke] FAIL: checkout matches the seed but the notice was printed" >&2
    cat "$notice_err" >&2
    exit 1
  fi
  echo "[vibe-test-smoke] ok (checkout matches the seed; no notice, as expected)"
fi
