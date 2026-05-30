#!/usr/bin/env bash
# pre-commit: format staged MoonBit sources with `moon fmt` and re-stage them,
# so every commit lands already formatted. Wired via `pkf hooks install`
# (delegates to `pkf run pre-commit`).
#
# A file that is *partially* staged (staged hunks + further unstaged edits in
# the same file) is left untouched and reported: re-staging it would pull the
# unstaged WIP hunks into the commit. Such files are formatted on a later
# fully-staged commit. Only files whose staged content matches the worktree are
# formatted + re-staged, so no unrelated working-tree change is ever committed.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

# Staged .mbt files (Added/Copied/Modified), NUL-safe for odd paths.
mapfile -d '' -t staged < <(
  git diff --cached --name-only --diff-filter=ACM -z -- '*.mbt'
)
if [ "${#staged[@]}" -eq 0 ]; then
  exit 0
fi

# .mbt files that also have unstaged worktree edits (→ partially staged).
declare -A has_unstaged=()
while IFS= read -r -d '' f; do
  has_unstaged["$f"]=1
done < <(git diff --name-only -z -- '*.mbt')

fmt=()
skipped=()
for f in "${staged[@]}"; do
  if [ -n "${has_unstaged["$f"]:-}" ]; then
    skipped+=("$f")
  else
    fmt+=("$f")
  fi
done

if [ "${#fmt[@]}" -gt 0 ]; then
  moon fmt "${fmt[@]}" >/dev/null
  for f in "${fmt[@]}"; do
    [ -f "$f" ] && git add -- "$f"
  done
fi

if [ "${#skipped[@]}" -gt 0 ]; then
  echo "pre-commit: skipped moon fmt for partially-staged files (commit them" \
    "fully or run 'moon fmt' yourself):" >&2
  for f in "${skipped[@]}"; do
    echo "  - $f" >&2
  done
fi
