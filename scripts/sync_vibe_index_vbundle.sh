#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_LOCK_SYNC_ROOT:-$(dirname "$SCRIPT_DIR")}"
cd "$PROJECT_ROOT"

LOCK_FILES=()
if git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS= read -r file; do
    LOCK_FILES+=("$file")
  done < <(git -C "$PROJECT_ROOT" ls-files '**/index.lock')
else
  while IFS= read -r file; do
    LOCK_FILES+=("$file")
  done < <(rg --files -g '**/index.lock')
fi

if [ "${#LOCK_FILES[@]}" -eq 0 ]; then
  echo "sync-vbundle: no index.lock files found"
  exit 0
fi

synced=0
scanned=0

for lock_path in "${LOCK_FILES[@]}"; do
  case "$lock_path" in
    vibe/*) ;;
    *) continue ;;
  esac

  scanned=$((scanned + 1))
  lock_dir="$(dirname "$lock_path")"
  vbundle_path="$lock_dir/index.vbundle"
  tmp_path="$(mktemp "${TMPDIR:-/tmp}/vibe_index_vbundle.XXXXXX")"
  next_lock_norm="$(jq -cS . "$lock_path")"

  if [ -f "$vbundle_path" ]; then
    current_lock_norm="$(jq -cS '.lock // null' "$vbundle_path")"
    if [ "$current_lock_norm" = "$next_lock_norm" ]; then
      rm -f "$tmp_path"
      continue
    fi
    jq --slurpfile lock "$lock_path" '.lock = $lock[0]' "$vbundle_path" >"$tmp_path"
  else
    jq -n --slurpfile lock "$lock_path" '{lock: $lock[0]}' >"$tmp_path"
  fi

  if [ ! -f "$vbundle_path" ] || ! cmp -s "$tmp_path" "$vbundle_path"; then
    mv "$tmp_path" "$vbundle_path"
    synced=$((synced + 1))
  else
    rm -f "$tmp_path"
  fi
done

echo "sync-vbundle: scanned $scanned vibe modules, updated $synced index.vbundle files"
