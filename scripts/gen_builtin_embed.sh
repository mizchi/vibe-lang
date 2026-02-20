#!/usr/bin/env bash
# Generate src/checker/builtin_modules.mbt from vibe/builtin/*.vibe
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

OUT="src/checker/builtin_modules.mbt"

# Modules to auto-load (order matters: traits first, then types, then primitives)
MODULES=(
  builtin_traits
  option
  result
  cmp
  bool
  int
  float
  double
  char
  string
  array
)

{
  echo '///|'
  echo '/// Auto-generated builtin module sources for prelude injection.'
  echo '/// Do not edit manually. Regenerate with: scripts/gen_builtin_embed.sh'
  echo ''

  for mod in "${MODULES[@]}"; do
    varname="builtin_${mod}_source"
    file="vibe/builtin/${mod}.vibe"
    if [ ! -f "$file" ]; then
      echo "WARN: $file not found, skipping" >&2
      continue
    fi
    echo "///|"
    echo "let ${varname} : String ="
    # Each line becomes a #| line. Empty lines become #| (empty string line)
    while IFS= read -r line || [ -n "$line" ]; do
      echo "  #|${line}"
    done < "$file"
    echo ""
  done

  echo "///|"
  echo "pub let builtin_module_sources : Array[(String, String)] = ["
  for mod in "${MODULES[@]}"; do
    file="vibe/builtin/${mod}.vibe"
    if [ ! -f "$file" ]; then continue; fi
    varname="builtin_${mod}_source"
    echo "  (\"builtin/${mod}\", ${varname}),"
  done
  echo "]"

} > "$OUT"

echo "Generated $OUT ($(wc -l < "$OUT") lines)"
