#!/bin/bash
# Ensure index.lock does not keep temporary probe/debug path entries.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_LOCK_CHECK_ROOT:-$(dirname "$SCRIPT_DIR")}"
cd "$PROJECT_ROOT"

LOCK_FILES=()
while IFS= read -r file; do
  LOCK_FILES+=("$file")
done < <(rg --files -g '**/index.lock')

if [ "${#LOCK_FILES[@]}" -eq 0 ]; then
  echo "lock-check: no index.lock files found"
  exit 0
fi

# Keep this allowlist strict: probes/tmp entries must never ship in lock files.
matches=$(
  rg -n --no-heading --only-matching \
    -e '"\./(_probe|_tmp|review_)[^"]*"' \
    -e '"\./tmp_probe/[^"]*"' \
    "${LOCK_FILES[@]}" || true
)
if [ -n "$matches" ]; then
  echo "$matches" >&2
  echo "lock-check: found temporary entries in index.lock" >&2
  echo "lock-check: remove _probe/_tmp/review_ keys before commit" >&2
  exit 1
fi

echo "lock-check: ${#LOCK_FILES[@]} index.lock files clean"
