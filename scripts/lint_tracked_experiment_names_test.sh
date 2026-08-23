#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/lint_tracked_experiment_names.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_experiment_name_lint_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

git -C "$TMP_ROOT" init -q
mkdir -p "$TMP_ROOT/lib/@vibe/compiler" "$TMP_ROOT/scripts"

# These fixtures sat under lib/ and lib/ is not in the lint's scope, so BOTH
# the "allowed" and the "violation" case were vacuous: the lint never looked at
# either file, and the test failed with "missing new probe violation" against a
# lint that was behaving correctly (#2252). A fixture outside the scanned scope
# proves nothing about the scan.
cat > "$TMP_ROOT/scripts/cache_probe_gate.sh" <<'EOF'
echo allowed legacy probe
EOF

cat > "$TMP_ROOT/scripts/new_probe_gate.sh" <<'EOF'
echo new probe
EOF

# Out of scope on purpose: a probe-named file under lib/ must NOT be reported,
# which is what makes the scope a claim and not a coincidence.
cat > "$TMP_ROOT/lib/@vibe/compiler/cache_probe_test.vibe" <<'EOF'
test "out of scope" { assert(true) }
EOF

cat > "$TMP_ROOT/scripts/.tmp_probe.sh" <<'EOF'
echo tmp
EOF

git -C "$TMP_ROOT" add .

cat > "$TMP_ROOT/allowlist.txt" <<'EOF'
# path category reason
scripts/cache_probe_gate.sh gate legacy probe fixture
EOF

if VIBE_EXPERIMENT_NAME_LINT_ROOT="$TMP_ROOT" \
  VIBE_EXPERIMENT_NAME_LINT_ALLOWLIST="$TMP_ROOT/allowlist.txt" \
  bash "$CHECK_SCRIPT" >"$TMP_ROOT/fail.stdout" 2>"$TMP_ROOT/fail.stderr"; then
  echo "experiment-name lint self-test: expected unallowlisted probe failure" >&2
  exit 1
fi

if ! grep -qE 'scripts/new_probe_gate\.sh' "$TMP_ROOT/fail.stderr"; then
  echo "experiment-name lint self-test: missing new probe violation" >&2
  cat "$TMP_ROOT/fail.stderr" >&2
  exit 1
fi

if ! grep -qE 'scripts/.tmp_probe.sh' "$TMP_ROOT/fail.stderr"; then
  echo "experiment-name lint self-test: missing .tmp violation" >&2
  cat "$TMP_ROOT/fail.stderr" >&2
  exit 1
fi

# The scope is a claim: a probe-named file OUTSIDE it must not be reported.
# Without this, widening the scope to the whole tree would pass every case
# above and quietly demand an allowlist entry for 16 compiler fixtures.
if grep -qE 'lib/@vibe/compiler/cache_probe_test\.vibe' "$TMP_ROOT/fail.stderr"; then
  echo "experiment-name lint self-test: reported a file outside the scanned scope" >&2
  cat "$TMP_ROOT/fail.stderr" >&2
  exit 1
fi

cat >> "$TMP_ROOT/allowlist.txt" <<'EOF'
scripts/new_probe_gate.sh gate new gate fixture
scripts/.tmp_probe.sh manual-experiment temporary script fixture
EOF

VIBE_EXPERIMENT_NAME_LINT_ROOT="$TMP_ROOT" \
  VIBE_EXPERIMENT_NAME_LINT_ALLOWLIST="$TMP_ROOT/allowlist.txt" \
  bash "$CHECK_SCRIPT" >/dev/null

cat > "$TMP_ROOT/allowlist.txt" <<'EOF'
scripts/cache_probe_gate.sh invalid-category bad category
scripts/missing_probe_gate.sh gate stale entry
EOF

if VIBE_EXPERIMENT_NAME_LINT_ROOT="$TMP_ROOT" \
  VIBE_EXPERIMENT_NAME_LINT_ALLOWLIST="$TMP_ROOT/allowlist.txt" \
  bash "$CHECK_SCRIPT" >"$TMP_ROOT/invalid.stdout" 2>"$TMP_ROOT/invalid.stderr"; then
  echo "experiment-name lint self-test: expected invalid allowlist failure" >&2
  exit 1
fi

if ! grep -qE 'invalid category' "$TMP_ROOT/invalid.stderr"; then
  echo "experiment-name lint self-test: missing invalid category error" >&2
  cat "$TMP_ROOT/invalid.stderr" >&2
  exit 1
fi

if ! grep -qE 'stale allowlist entry' "$TMP_ROOT/invalid.stderr"; then
  echo "experiment-name lint self-test: missing stale allowlist error" >&2
  cat "$TMP_ROOT/invalid.stderr" >&2
  exit 1
fi

echo "experiment-name lint self-test: ok"
