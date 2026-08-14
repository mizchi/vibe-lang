#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="${VIBE_REVIEW_LINT_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
GREP_BIN="${VIBE_REVIEW_LINT_GREP_BIN:-$PROJECT_ROOT/runtime/vibe}"

if ! git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "review-regressions lint: project root is not a git repository: $PROJECT_ROOT" >&2
  exit 1
fi

# Review audit 2026-08-14: lexical hygiene was the largest recurring class
# (27/101 automated findings in the latest 100 merged PRs). A literal synthetic
# binder can capture a user-authored name. References to reserved builtins such
# as EIdent("__to_string", ...) are deliberately not binders and remain legal.
#
# This is staged-diff-only: the repository has historical fixed binders. New
# ones must be minted by a freshness helper and passed as a variable. `vibe
# grep` scans an exact materialization of the index, so unstaged working-tree
# edits cannot hide or invent a finding. A truly reserved ABI binding may opt
# out on the call's first source line with the marker below.
diff="$({
  git -C "$PROJECT_ROOT" diff --cached --no-ext-diff --no-textconv --unified=0 --diff-filter=ACMR
} || true)"

staged_paths="$(git -C "$PROJECT_ROOT" diff --cached --name-only --diff-filter=ACMR \
  | awk '/^lib\/@vibe\/compiler\/(normalize|codegen|loader)\/.*\.vibe$/')"

grep_available=0
if [ -n "${VIBE_REVIEW_LINT_GREP_BIN:-}" ]; then
  grep_available=1
elif [ -x "$GREP_BIN" ] && rg -q '^  grep\)' "$GREP_BIN"; then
  grep_available=1
fi

violations=""
if [ -n "$staged_paths" ] && [ "$grep_available" -eq 1 ]; then
  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/vibe_review_grep.XXXXXX")"
  trap 'rm -rf "$tmp_root"' EXIT
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    mkdir -p "$tmp_root/$(dirname "$path")"
    git -C "$PROJECT_ROOT" show ":$path" > "$tmp_root/$path"
  done <<< "$staged_paths"

  set +e
  ast_output="$(cd "$TOOL_ROOT" && bash scripts/vibe_run.sh scripts/review_lint.vibex -- \
    --root "$tmp_root" --vibe "$GREP_BIN" 2>&1)"
  ast_status=$?
  set -e
  if [ "$ast_status" -eq 0 ]; then
    violations=""
  else
    violations="$ast_output"
  fi
else
  # Bootstrap fallback for branches predating `vibe grep` (#1572). Once such a
  # branch merges main, the AST backend above takes over automatically.
  violations="$(printf '%s\n' "$diff" \
  | awk '
      /^\+\+\+ / {
        path = $2
        sub(/^[^\/]*\//, "", path)
        next
      }
      /^@@ / {
        if (match($0, /\+[0-9]+/)) {
          line = substr($0, RSTART + 1, RLENGTH - 1) + 0
        }
        next
      }
      /^\+/ && !/^\+\+\+/ {
        text = substr($0, 2)
        in_transform = path ~ /^lib\/@vibe\/compiler\/(normalize|codegen|loader)\/.*\.vibe$/
        is_binder = in_transform && (text ~ /E(Let|LetMut|LetRec)\("__[A-Za-z0-9_]+"/ \
          || text ~ /PBind\("__[A-Za-z0-9_]+"/ \
          || text ~ /SLet\([^)]*"__[A-Za-z0-9_]+"/)
        allowed = text ~ /review-lint: allow-fixed-synthetic-name/
        if (is_binder && !allowed) {
          printf "%s:%d:%s\n", path, line, text
        }
        line++
      }
    ')"
fi

if [ -n "$violations" ]; then
  echo "review-regressions lint: fixed synthetic binder(s) added" >&2
  printf '%s\n' "$violations" >&2
  echo "Mint a fresh name from the source-expression binding census and pass the resulting variable to ELet/PBind/SLet." >&2
  echo "For a genuinely reserved ABI name, add 'review-lint: allow-fixed-synthetic-name' with a reason on the same line." >&2
  exit 1
fi

echo "review-regressions lint: ok"
