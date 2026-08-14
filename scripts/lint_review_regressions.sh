#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="${VIBE_REVIEW_LINT_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
GREP_BIN="${VIBE_REVIEW_LINT_GREP_BIN:-$PROJECT_ROOT/runtime/vibe}"
RUNNER="${VIBE_REVIEW_LINT_RUNNER:-$TOOL_ROOT/scripts/vibe_run.sh}"

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
  | awk '/^lib\/@vibe\/compiler\/.*\.vibe$/')"

# `runtime/vibe` is a dispatcher script, so "executable and mentions a grep
# verb" is satisfied by a checkout that cannot run anything: the script is
# there, `bin/viberun` is not. The probe passed, every `vibe grep` failed at
# run time, and the failure came back out as `structural regression(s) added`
# against whatever was being committed. Actually invoke it -- one cheap call
# answers "can this run" instead of "does this file look like it could".
grep_available=0
if [ -n "${VIBE_REVIEW_LINT_GREP_BIN:-}" ]; then
  grep_available=1
elif [ -x "$GREP_BIN" ] && rg -q '^  grep\)' "$GREP_BIN" \
  && "$GREP_BIN" --version >/dev/null 2>&1; then
  grep_available=1
elif [ -x "$GREP_BIN" ] && rg -q '^  grep\)' "$GREP_BIN"; then
  echo "review-regressions lint: AST tier skipped -- $GREP_BIN cannot run here" >&2
  echo "  (build the runner, or point VIBE_REVIEW_LINT_GREP_BIN at a working one)" >&2
fi

violations=""
ast_tool_error=0
if [ -n "$staged_paths" ] && [ "$grep_available" -eq 1 ]; then
  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/vibe_review_grep.XXXXXX")"
  trap 'rm -rf "$tmp_root"' EXIT
  added_lines="$tmp_root/.added-lines.tsv"
  printf '%s\n' "$diff" | awk '
    BEGIN { print "#\t0" }
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
      printf "%s\t%d\n", path, line
      line++
      next
    }
    /^ / { line++ }
  ' > "$added_lines"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    mkdir -p "$tmp_root/$(dirname "$path")"
    git -C "$PROJECT_ROOT" show ":$path" > "$tmp_root/$path"
  done <<< "$staged_paths"

  set +e
  ast_output="$(cd "$TOOL_ROOT" && bash "$RUNNER" scripts/review_lint.vibex -- \
    --root "$tmp_root" --vibe "$GREP_BIN" 2>&1)"
  ast_status=$?
  set -e
  if [ "$ast_status" -eq 0 ]; then
    violations=""
  elif [ "$ast_status" -eq 1 ]; then
    if ! printf '%s\n' "$ast_output" | rg -q '^review-lint: found [0-9]+ structural regression\(s\)$' \
      || ! printf '%s\n' "$ast_output" | rg -q '^review-lint:finding\t'; then
      # The runner also uses exit 1 for bootstrap and compile failures. Only a
      # completed lint result with machine-identifiable findings is filterable.
      ast_tool_error=1
      violations="$ast_output"
    else
      # `vibe grep` sees the complete staged file so it can match multiline AST
      # shapes. A finding is new when any added line intersects its full span;
      # historical findings elsewhere in an edited file are ignored.
      violations="$(awk -v prefix="$tmp_root/" -F '\t' '
        NR == FNR { added[$1 SUBSEP $2] = 1; next }
        $1 == "review-lint:finding" && index($2, prefix) == 1 {
          path = substr($2, length(prefix) + 1)
          start_line = $3 + 0
          end_line = $4 + 0
          intersects = 0
          for (line = start_line; line <= end_line; line++) {
            if (added[path SUBSEP line]) intersects = 1
          }
          if (intersects) {
            message = $5
            for (field = 6; field <= NF; field++) message = message FS $field
            printf "%s:%d-%d: %s\n", path, start_line, end_line, message
          }
        }
      ' "$added_lines" - <<< "$ast_output")"
    fi
  else
    # Preserve backend/bootstrap errors instead of accidentally treating them
    # as filtered historical findings. review_lint.vibex reserves exit 2 for
    # "the scan did not run", which is a different claim from "the scan found
    # something" -- report it as one, or the author reads that their own diff
    # added a regression it had nothing to do with.
    ast_tool_error=1
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

if [ -n "$violations" ] || [ "$ast_tool_error" -eq 1 ]; then
  if [ "$ast_tool_error" -eq 1 ]; then
    echo "review-regressions lint: the AST scan did not run (no finding was made)" >&2
  else
    echo "review-regressions lint: structural regression(s) added" >&2
  fi
  printf '%s\n' "$violations" >&2
  exit 1
fi

echo "review-regressions lint: ok"
