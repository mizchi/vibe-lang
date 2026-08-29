#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_CANONICAL_ITERATOR_ROOT:-$(dirname "$SCRIPT_DIR")}"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibe_iterator_calls.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
files="$tmp_dir/files"
findings="$tmp_dir/findings"
: > "$files"
: > "$findings"

if [ -d "$PROJECT_ROOT/book" ]; then
  find "$PROJECT_ROOT/book" -type f -name '*.vibe.md' >> "$files"
fi
if [ -d "$PROJECT_ROOT/examples" ]; then
  find "$PROJECT_ROOT/examples" -type f -name '*.vibe' >> "$files"
fi
sort -u "$files" -o "$files"
while IFS= read -r file; do
  [ -n "$file" ] || continue
  relative="${file#"$PROJECT_ROOT"/}"
  grep -nE 'Array::(map|filter|flatmap|fold|find|any|all)([^A-Za-z0-9_]|$)' "$file" |
    sed "s|^|$relative:|" >> "$findings" || true
done < "$files"

if [ -s "$findings" ]; then
  echo "canonical Iterator calls: tutorials and examples must use Iterator::* and import trait Iterator:" >&2
  cat "$findings" >&2
  exit 1
fi

echo "canonical Iterator calls: ok"
