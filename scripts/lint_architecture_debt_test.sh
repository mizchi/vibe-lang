#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/lint_architecture_debt.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_arch_lint_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/src"

cat > "$TMP_ROOT/rules.tsv" <<'EOF'
# id	severity	scope	regex	message	issue
ARCH999	error	**/*.vibe	String::concat\(acc,	use StringBuilder for unbounded accumulators	#999
EOF

run_lint() {
  VIBE_ARCH_LINT_ROOT="$TMP_ROOT" \
    VIBE_ARCH_LINT_RULES="$TMP_ROOT/rules.tsv" \
    VIBE_ARCH_LINT_ALLOWLIST="$TMP_ROOT/allowlist.tsv" \
    "$CHECK_SCRIPT" "$@"
}

fail() {
  echo "architecture-debt lint self-test: $1" >&2
  [ -f "$TMP_ROOT/out.stderr" ] && cat "$TMP_ROOT/out.stderr" >&2
  exit 1
}

expect_ok() {
  run_lint "$@" >"$TMP_ROOT/out.stdout" 2>"$TMP_ROOT/out.stderr" \
    || fail "expected success: $*"
}

expect_fail() {
  if run_lint >"$TMP_ROOT/out.stdout" 2>"$TMP_ROOT/out.stderr"; then
    fail "expected failure but the lint passed"
  fi
}

: > "$TMP_ROOT/allowlist.tsv"

cat > "$TMP_ROOT/src/hot.vibe" <<'EOF'
let slow = String::concat(acc, "x")
EOF

# An unallowlisted match fails, and says where.
expect_fail
rg -q 'src/hot.vibe:1: error ARCH999' "$TMP_ROOT/out.stderr" \
  || fail "missing violation location"

cat > "$TMP_ROOT/allowlist.tsv" <<'EOF'
ARCH999	src/hot.vibe	1	let slow = String::concat(acc, "x")
EOF
expect_ok

# #1729: the allowlist is keyed by matched text, not line number, so editing
# ABOVE known debt must not turn it into a new violation. The line-number
# baseline this replaced went stale on exactly this edit and failed 11 clean
# findings on main, which stopped every commit through the pre-commit hook.
cat > "$TMP_ROOT/src/hot.vibe" <<'EOF'
// a comment added above the debt
// and another one
let untouched = 1
let slow = String::concat(acc, "x")
EOF
expect_ok
rg -q 'ok' "$TMP_ROOT/out.stdout" || fail "drifted debt should report ok"

# The ratchet still bites: a SECOND occurrence of the same shape in the same
# file exceeds the recorded count, and the reported line is the new one.
cat > "$TMP_ROOT/src/hot.vibe" <<'EOF'
// a comment added above the debt
// and another one
let untouched = 1
let slow = String::concat(acc, "x")
let slow_again = String::concat(acc, "x")
EOF
expect_fail
rg -q 'src/hot.vibe:5: error ARCH999' "$TMP_ROOT/out.stderr" \
  || fail "a repeated occurrence of an allowlisted shape must fail"

# ... and a different shape in the same file is a violation on its own, even
# though that file already has an allowlist entry.
cat > "$TMP_ROOT/src/hot.vibe" <<'EOF'
// a comment added above the debt
// and another one
let untouched = 1
let slow = String::concat(acc, "x")
let other = String::concat(acc, "DIFFERENT")
EOF
expect_fail
rg -q 'src/hot.vibe:5: error ARCH999' "$TMP_ROOT/out.stderr" \
  || fail "a different matched text must not be covered by another entry"

cat > "$TMP_ROOT/src/hot.vibe" <<'EOF'
// a comment added above the debt
let slow = String::concat(acc, "x")
EOF

# A new file is never covered by another file's entry.
cat > "$TMP_ROOT/src/other.vibe" <<'EOF'
let slow2 = String::concat(acc, "y")
EOF
expect_fail
rg -q 'src/other.vibe:1: error ARCH999' "$TMP_ROOT/out.stderr" \
  || fail "missing new violation location"

# `*` is still a file-wide exception (generated files).
cat > "$TMP_ROOT/allowlist.tsv" <<'EOF'
ARCH999	src/hot.vibe	1	let slow = String::concat(acc, "x")
ARCH999	src/other.vibe	*
EOF
expect_ok

# An entry that no longer covers anything is reported, but does not fail --
# removing debt must not require a baseline edit in the same change.
cat > "$TMP_ROOT/allowlist.tsv" <<'EOF'
ARCH999	src/hot.vibe	4	let slow = String::concat(acc, "x")
ARCH999	src/other.vibe	*
EOF
expect_ok
rg -q 'stale allowlist entry' "$TMP_ROOT/out.stderr" \
  || fail "an over-wide entry should be reported as stale"

# --update rewrites the generated section and leaves the notes above it alone.
cat > "$TMP_ROOT/allowlist.tsv" <<'EOF'
# a hand-written note that must survive
ARCH999	src/other.vibe	*
EOF
expect_ok --update
rg -q '^# a hand-written note that must survive$' "$TMP_ROOT/allowlist.tsv" \
  || fail "--update dropped hand-written content"
rg -q '^ARCH999\tsrc/other\.vibe\t\*$' "$TMP_ROOT/allowlist.tsv" \
  || fail "--update dropped a file-wide exception"
rg -q '^ARCH999\tsrc/hot\.vibe\t1\tlet slow = String::concat\(acc, "x"\)$' "$TMP_ROOT/allowlist.tsv" \
  || fail "--update did not baseline the outstanding violation"
expect_ok
rg -q 'ok' "$TMP_ROOT/out.stdout" || fail "the regenerated baseline should be green"

# --update is idempotent: a second run reports no change and rewrites nothing.
before="$(cat "$TMP_ROOT/allowlist.tsv")"
expect_ok --update
rg -q 'baseline already current' "$TMP_ROOT/out.stdout" \
  || fail "--update should be a no-op when the baseline is current"
[ "$before" = "$(cat "$TMP_ROOT/allowlist.tsv")" ] \
  || fail "--update rewrote an already-current baseline"

# A leftover line-number row is rejected outright. Silently ignoring it would
# reintroduce #1729 as a *quiet* under-report instead of a loud false failure.
cat > "$TMP_ROOT/allowlist.tsv" <<'EOF'
ARCH999	src/hot.vibe	2
EOF
if run_lint >"$TMP_ROOT/out.stdout" 2>"$TMP_ROOT/out.stderr"; then
  fail "a line-number row must be rejected"
fi
rg -q 'bad allowlist row' "$TMP_ROOT/out.stderr" \
  || fail "a line-number row should name itself as the problem"
rg -q '#1729' "$TMP_ROOT/out.stderr" \
  || fail "the rejection should point at the issue that removed line keys"

echo "architecture-debt lint self-test: ok"
