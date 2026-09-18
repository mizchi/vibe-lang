#!/usr/bin/env bash
# The "say what moved" report in `ensure_generated.sh` must not be able to kill
# the regeneration it explains.
#
# The report slices the stamped-vs-current input diff to 20 lines. Spelled with
# `head -20`, that slice EXITS after its 20th line; a diff longer than the
# 64KiB pipe buffer leaves `printf` still writing, so `printf` takes SIGPIPE,
# `pipefail` makes 141 the pipeline's status, and `set -e` ends the script --
# BEFORE the `regenerating 5 artifacts` line. Measured 2026-09-18 on a tree
# whose stamped list differed by 869 lines: `bash scripts/ensure_generated.sh`
# exited 141, wrote no artifacts, and printed only the diff.
#
# It fails only in the LARGE case, which is the fresh-clone and seed-bump case
# -- exactly when regeneration is needed and when nobody is reading the exit
# status of a step that just printed a plausible-looking report.
#
# This gate is LEXICAL on purpose. Reproducing the real abort needs a tree with
# a stale stamp and a ~120KiB diff, which is minutes of setup for a property
# that is decided by one token. What it checks instead is the property itself
# and not a proxy: the reporting pipeline must not end in a reader that closes
# its input early. The RED case is `scripts/check_generated_stamp_report_test.sh`,
# which rewrites the line back to `head` and asserts this gate rejects it -- and
# separately DEMONSTRATES the abort in a standalone harness, so the reason the
# token matters is measured rather than asserted.
#
# Usage:
#   bash scripts/check_generated_stamp_report.sh
set -euo pipefail
ROOT_DIR="${VIBE_GENERATED_STAMP_REPORT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT_DIR"

TARGET="${VIBE_GENERATED_STAMP_REPORT_TARGET:-scripts/ensure_generated.sh}"

if [ ! -f "$TARGET" ]; then
  echo "[generated-stamp-report] FAIL: $TARGET does not exist" >&2
  exit 1
fi

# Readers that exit before draining their input. `head` is the one that was
# there; the others are the same hazard spelled differently.
EARLY_CLOSERS='head|sed -n[[:space:]]+.[0-9,]+q|awk[^|]*[[:space:]]exit[[:space:]]*}'

# Only pipelines that carry the diff report. Naming the variable keeps this
# from becoming a repo-wide ban on `head`, which would be a different rule.
found=0
while IFS= read -r line; do
  # An empty command substitution still feeds the heredoc ONE blank line, which
  # would count as a pipeline and make the gate green about a script it never
  # found. RED 2 of the self-test is what caught that.
  [ -n "$line" ] || continue
  found=$((found + 1))
  if printf '%s\n' "$line" | grep -qE "\|[[:space:]]*($EARLY_CLOSERS)"; then
    echo "[generated-stamp-report] FAIL: the stamped-diff report pipes into a reader that closes early" >&2
    echo "  $line" >&2
    echo "  Such a reader makes printf take SIGPIPE; with pipefail + set -e that" >&2
    echo "  ABORTS the regeneration (exit 141) whenever the diff exceeds the pipe" >&2
    echo "  buffer. Use a slicer that drains its input, e.g. sed -n '1,20p'." >&2
    exit 1
  fi
done <<EOF
$(grep -nE '\$diff_out' "$TARGET" | grep -F '|')
EOF

if [ "$found" -eq 0 ]; then
  # Silence is "unchecked", not "clean".
  echo "[generated-stamp-report] FAIL: no \$diff_out pipeline found in $TARGET" >&2
  exit 1
fi

echo "[generated-stamp-report] ok ($found \$diff_out pipeline(s), none closes its input early)"
