#!/usr/bin/env bash
# pre-commit: format staged MoonBit sources with `moon fmt` and re-stage them,
# so every commit lands already formatted. Only files staged for the commit are
# touched — unrelated working-tree changes and moon.pkg import ordering are left
# alone. Wired via `pkf hooks install` (delegates to `pkf run pre-commit`).
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

# Format just those files in place.
moon fmt "${staged[@]}" >/dev/null

# Re-stage the formatted versions. (A partially-staged file gets fully staged —
# the usual formatter-hook caveat.)
for f in "${staged[@]}"; do
  [ -f "$f" ] && git add -- "$f"
done
