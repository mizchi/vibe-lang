#!/usr/bin/env bash
# `.vpkg` formatter lint (#1435): every tracked lib/**/*.vpkg file must be a
# fixpoint of scripts/vpkg_fmt.sh. Mirrors scripts/check_vibe_fmt.sh's
# intent but loops scripts/vpkg_fmt.sh --check per file (unbatched) since
# there are ~75 .vpkg files today versus ~750+ .vibe files -- not worth a
# dedicated batch entry yet.
#
# Deliberately NOT wired into `pkf run release-check` / `full-gate` --
# same posture as scripts/wasm_feature_levels.vibex's --check (see
# docs/wasm/feature-levels.md): a brand new checker earns required-gate
# status after it's been run manually for a while, not on day one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SCAN_ROOT="${VIBE_VPKG_FMT_LINT_ROOT:-lib}"
cd "$PROJECT_ROOT"

mapfile -t files < <(git ls-files "$SCAN_ROOT/**/*.vpkg" "$SCAN_ROOT/*.vpkg" | sort -u)

if [ "${#files[@]}" -eq 0 ]; then
  echo "vpkg-fmt lint: no tracked .vpkg files under $SCAN_ROOT" >&2
  exit 1
fi

violations=()
for f in "${files[@]}"; do
  if ! bash scripts/vpkg_fmt.sh --check "$f" >/dev/null 2>/tmp/vpkg_fmt_lint_err.$$; then
    violations+=("$f")
  fi
  rm -f /tmp/vpkg_fmt_lint_err.$$
done

status=0
if [ "${#violations[@]}" -gt 0 ]; then
  echo "vpkg-fmt lint: ${#violations[@]} file(s) not formatted (or failed to parse):" >&2
  printf '  %s\n' "${violations[@]}" >&2
  echo "vpkg-fmt lint: run \`bash scripts/vpkg_fmt.sh <file>\` to format" >&2
  status=1
fi

echo "vpkg-fmt lint: checked ${#files[@]} file(s) under $SCAN_ROOT (${#violations[@]} violations)"
exit "$status"
