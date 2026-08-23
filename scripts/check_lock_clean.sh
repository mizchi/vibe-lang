#!/bin/bash
# Ensure index.lock does not keep temporary probe/debug path entries.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_LOCK_CHECK_ROOT:-$(dirname "$SCRIPT_DIR")}"
cd "$PROJECT_ROOT"

LOCK_FILES=()
if git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS= read -r file; do
    LOCK_FILES+=("$file")
  done < <(git -C "$PROJECT_ROOT" ls-files '**/index.lock')
else
  while IFS= read -r file; do
    LOCK_FILES+=("$file")
  done < <(find . -type f -name index.lock | sed 's|^\./||')
fi

if [ "${#LOCK_FILES[@]}" -eq 0 ]; then
  echo "lock-check: no index.lock files found"
  exit 0
fi

# Keep this allowlist strict: probes/tmp entries must never ship in lock files.
matches=$(
  grep -noE \
    -e '"[^"]*\.vibe_test_wasm_[^"]*"' \
    -e '"\./\.tmp[^"]*"' \
    -e '"\./_build/[^"]*"' \
    -e '"\./(_probe|_tmp|review_)[^"]*"' \
    -e '"\./tmp_probe/[^"]*"' \
    "${LOCK_FILES[@]}" || true
)
if [ -n "$matches" ]; then
  echo "$matches" >&2
  echo "lock-check: found temporary entries in index.lock" >&2
  echo "lock-check: remove .tmp/.vibe_test_wasm/_build/_probe/_tmp/review_ keys before commit" >&2
  exit 1
fi

echo "lock-check: scanned ${#LOCK_FILES[@]} index.lock files"

missing_manifest=()
invalid_manifest=()

for lock_path in "${LOCK_FILES[@]}"; do
  case "$lock_path" in
    vibe/*) ;;
    *) continue ;;
  esac

  lock_dir="$(dirname "$lock_path")"
  manifest_path="$lock_dir/index.vibe"

  if [ ! -f "$manifest_path" ]; then
    missing_manifest+=("$manifest_path")
  else
    if ! grep -qE '^[[:space:]]*export[[:space:]]+let[[:space:]]+version([[:space:]]*:[[:space:]]*[^=]+)?[[:space:]]*=[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"[[:space:]]*$' "$manifest_path"; then
      invalid_manifest+=("$manifest_path")
    fi
  fi
done

if [ "${#missing_manifest[@]}" -gt 0 ]; then
  printf '%s\n' "${missing_manifest[@]}" >&2
  echo "lock-check: missing index.vibe for vibe modules" >&2
  exit 1
fi

if [ "${#invalid_manifest[@]}" -gt 0 ]; then
  printf '%s\n' "${invalid_manifest[@]}" >&2
  echo 'lock-check: index.vibe must include export let version = "x.y.z"' >&2
  exit 1
fi

echo "lock-check: vibe module metadata synchronized"
