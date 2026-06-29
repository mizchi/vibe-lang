#!/usr/bin/env bash
# Reclaim the persistent build cache (#631).
#
# The selfhost compiler writes every incremental-build cache entry (dep_list,
# type_env, module_header, source_list, compiled artifact, ...) to
# `_build/vibe_<prefix>_<token><suffix>`, where <token> is a content+version
# fingerprint (compact_string_fingerprint, see persistent_cache.vibe). Entries
# are written content-addressed and never deleted in place: a source or codegen
# change yields a NEW token (the `cg-` segment, #630) and the old file is left
# behind as an orphan. Over a long editing session `_build/vibe_*` grows
# monotonically. This is the explicit reclaim path — see docs/build-cache.md for
# the cache layering and GC policy.
#
# Usage:
#   scripts/cache_clean.sh            # delete every _build/vibe_* cache file
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

# Collect the persistent-cache files (NUL-safe; nothing else under _build is
# touched, so generation builds / fixtures are preserved).
mapfile -d '' -t files < <(find _build -maxdepth 1 -type f -name 'vibe_*' -print0 2>/dev/null || true)

count=${#files[@]}
if [ "$count" -eq 0 ]; then
  echo "[cache-clean] no persistent cache files (_build/vibe_*) to reclaim"
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
  echo "[cache-clean] DRY RUN: would reclaim $count file(s), $human from _build/vibe_*"
  exit 0
fi

for f in "${files[@]}"; do
  rm -f "$f"
done
echo "[cache-clean] reclaimed $count file(s), $human from _build/vibe_*"
