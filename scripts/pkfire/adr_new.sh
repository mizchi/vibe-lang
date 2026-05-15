#!/usr/bin/env bash
# Create a new ADR — extracted from justfile `adr` recipe.
# Usage: scripts/pkfire/adr_new.sh "タイトル slug"
set -euo pipefail

title="${1:?missing ADR title}"
dir="docs/adr"
last=$(ls "$dir"/[0-9]*.md 2>/dev/null | sort -r | head -1 | sed 's|.*/0*\([0-9][0-9]*\).*|\1|' || echo "")
if [ -z "$last" ]; then last="-1"; fi
next=$(printf "%04d" $(( last + 1 )))
slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
file="$dir/${next}-${slug}.md"
today=$(date +%Y-%m-%d)
sed -e "s/NNNN/${next}/g" -e "s/YYYY-MM-DD/${today}/g" -e "s/タイトル/${title}/g" "$dir/TEMPLATE.md" > "$file"
echo "Created: $file"
