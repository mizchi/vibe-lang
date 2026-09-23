#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${JEV_LINT_CLI:-$ROOT/../jev-lint/src/cli.ts}"

case "${1:-}" in
  parser)
    mkdir -p "$ROOT/.jev-lint/parsers"
    cd "$ROOT/integrations/treesitter-vibe"
    tree-sitter build --output "$ROOT/.jev-lint/parsers/vibe.dylib"
    ;;
  plan)
    node --experimental-strip-types "$CLI" check \
      --config "$ROOT/.jev-lint.yaml" --dry-run "$ROOT/lib"
    ;;
  *)
    echo "usage: $0 parser|plan" >&2
    exit 2
    ;;
esac
