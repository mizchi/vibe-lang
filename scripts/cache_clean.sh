#!/usr/bin/env bash
# Reclaim the persistent build cache (#631).
#
# The selfhost compiler writes every incremental-build cache entry (dep_list,
# type_env, module_header, source_list, compiled artifact, ...) to
# `.vibe/build/cache/vibe_<prefix>_<token><suffix>` under the project root
# (docs/install.md "Project layout", #2675), where <token> is a content+version
# fingerprint (compact_string_fingerprint, see persistent_cache.vibe). Entries
# are written content-addressed and never deleted in place: a source or codegen
# change yields a NEW token (the `cg-` segment, #630) and the old file is left
# behind as an orphan. Over a long editing session the cache grows
# monotonically. This is the explicit reclaim path for THIS repository -- see
# docs/build-cache.md for the cache layering and GC policy; a user project has
# `vibe clean`.
#
# The committed seed compiler predates #2675 and still writes its rows to
# `_build/vibe_*`, so that root is reclaimed too until the next bootstrap bump.
#
# Usage:
#   scripts/cache_clean.sh            # delete every persistent-cache file
#   scripts/cache_clean.sh --dry-run  # report what WOULD be deleted, delete nothing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) dry_run=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "cache-clean: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# Collect the persistent-cache files (NUL-safe; nothing else under either
# root is touched, so generation builds / fixtures / vpkg type stubs are
# preserved).
# bash 3.2 (macOS stock) has no `mapfile` (#2349). `read -d ''` is the
# NUL-delimited equivalent and is a bash 3 builtin.
files=()
while IFS= read -r -d '' f || [ -n "$f" ]; do
  files+=("$f")
done < <(find .vibe/build/cache _build -maxdepth 1 -type f -name 'vibe_*' -print0 2>/dev/null || true)

count=${#files[@]}
if [ "$count" -eq 0 ]; then
  echo "[cache-clean] no persistent cache files (.vibe/build/cache/vibe_*, _build/vibe_*) to reclaim"
  exit 0
fi

# Total size (bytes) for the report.
total=0
for f in "${files[@]}"; do
  sz=$(wc -c < "$f" 2>/dev/null || echo 0)
  total=$((total + sz))
done
human="$(awk -v b="$total" 'BEGIN{ split("B KB MB GB",u); i=1; while(b>=1024 && i<4){b/=1024;i++} printf("%.1f %s", b, u[i]) }')"

if [ "$dry_run" -eq 1 ]; then
  echo "[cache-clean] DRY RUN: would reclaim $count file(s), $human from .vibe/build/cache/vibe_* and _build/vibe_*"
  exit 0
fi

for f in "${files[@]}"; do
  rm -f "$f"
done
echo "[cache-clean] reclaimed $count file(s), $human from .vibe/build/cache/vibe_* and _build/vibe_*"
