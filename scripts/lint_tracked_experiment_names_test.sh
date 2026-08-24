#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/lint_tracked_experiment_names.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_experiment_name_lint_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

git -C "$TMP_ROOT" init -q
mkdir -p "$TMP_ROOT/eval/book-review/probes" "$TMP_ROOT/lib/@vibe/compiler" "$TMP_ROOT/scripts"

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

# Out of scope on purpose. `lib/` used to be the example here and stopped being
# one when main's ab0190c5 brought lib/ into scope, so the control moved to a
# directory that is genuinely outside it. `eval/book-review/probes/` is the
# real instance: 31 tracked probe-named files that the lint must not demand
# entries for.
cat > "$TMP_ROOT/eval/book-review/probes/p01_probe_out_of_scope.vibe" <<'EOF'
fn main() -> Int { 0 }
EOF

# In scope, and the reason main's ab0190c5 widened the scan: without a fixture
# under lib/ nothing pins that lib/ is scanned at all, and narrowing the scope
# back would pass every other case in this file.
cat > "$TMP_ROOT/lib/@vibe/compiler/lexer_hotspot_probe.vibe" <<'EOF'
fn main() -> Int { 0 }
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

if ! grep -qE 'lib/@vibe/compiler/lexer_hotspot_probe\.vibe' "$TMP_ROOT/fail.stderr"; then
  echo "experiment-name lint self-test: missing lib/ violation (is lib/ still in scope?)" >&2
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
if grep -qE 'eval/book-review/probes/p01_probe_out_of_scope\.vibe' "$TMP_ROOT/fail.stderr"; then
  echo "experiment-name lint self-test: reported a file outside the scanned scope" >&2
  cat "$TMP_ROOT/fail.stderr" >&2
  exit 1
fi

cat >> "$TMP_ROOT/allowlist.txt" <<'EOF'
scripts/new_probe_gate.sh gate new gate fixture
scripts/.tmp_probe.sh manual-experiment temporary script fixture
lib/@vibe/compiler/lexer_hotspot_probe.vibe bench-fixture lexer hotspot corpus
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

# A linked git worktree stores `.git` as a FILE, not a directory. The lint is a
# release-check dependency, so a filesystem test for `.git` aborted every
# `pkf run` made from a worktree (#2248 review). Skipped only where `git
# worktree` itself is unavailable -- and that skip is announced, because a
# silent skip and a pass are the same line otherwise.
WT_ROOT="$TMP_ROOT/linked_worktree"
# Its own allowlist: the last case above deliberately left an INVALID one in
# place, and reusing it here would make this case fail for that reason instead
# of for the worktree.
cat > "$TMP_ROOT/wt_allowlist.txt" <<'EOF'
scripts/cache_probe_gate.sh gate legacy probe fixture
scripts/new_probe_gate.sh gate new gate fixture
scripts/.tmp_probe.sh manual-experiment temporary script fixture
lib/@vibe/compiler/lexer_hotspot_probe.vibe bench-fixture lexer hotspot corpus
EOF
git -C "$TMP_ROOT" config user.email test@example.com
git -C "$TMP_ROOT" config user.name test
git -C "$TMP_ROOT" commit -qm base >/dev/null 2>&1 || true
if git -C "$TMP_ROOT" worktree add -q --detach "$WT_ROOT" HEAD >/dev/null 2>&1; then
  if [ -d "$WT_ROOT/.git" ]; then
    echo "experiment-name lint self-test: this git makes .git a DIRECTORY in a linked worktree; the case proves nothing" >&2
    exit 1
  fi
  if ! VIBE_EXPERIMENT_NAME_LINT_ROOT="$WT_ROOT" \
    VIBE_EXPERIMENT_NAME_LINT_ALLOWLIST="$TMP_ROOT/wt_allowlist.txt" \
    bash "$CHECK_SCRIPT" >/dev/null 2>"$TMP_ROOT/wt.stderr"; then
    echo "experiment-name lint self-test: rejected a linked git worktree" >&2
    cat "$TMP_ROOT/wt.stderr" >&2
    exit 1
  fi
  git -C "$TMP_ROOT" worktree remove --force "$WT_ROOT" >/dev/null 2>&1 || true
else
  echo "experiment-name lint self-test: NOTE git worktree unavailable; worktree case not run" >&2
fi

echo "experiment-name lint self-test: ok"
