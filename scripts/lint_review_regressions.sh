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
# #1870: the hook is not the only place this should run. `--cached` is what
# made CI skip it ("with nothing staged it would pass vacuously"), so CI ran
# only the self-test and the rule never met a real diff -- while the hook, the
# sole enforcement point against one, is bypassable with `--no-verify` and
# silently skipped its AST tier wherever the runner could not run. Both holes
# close by letting the same lint read a RANGE, which CI has and the hook does
# not.
#
# Range mode materializes from HEAD rather than the index: in CI, HEAD is the
# PR head, which is the range's right-hand side.
RANGE="${VIBE_REVIEW_LINT_RANGE:-}"
if [ -n "$RANGE" ]; then
  DIFF_SELECTOR=("$RANGE")
  SHOW_REF="HEAD"
else
  DIFF_SELECTOR=(--cached)
  SHOW_REF=""
fi

diff="$({
  git -C "$PROJECT_ROOT" diff "${DIFF_SELECTOR[@]}" --no-ext-diff --no-textconv --unified=0 --diff-filter=ACMR
} || true)"

staged_paths="$(git -C "$PROJECT_ROOT" diff "${DIFF_SELECTOR[@]}" --name-only --diff-filter=ACMR \
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
elif [ -x "$GREP_BIN" ] && grep -qE '^  grep\)' "$GREP_BIN" \
  && "$GREP_BIN" --version >/dev/null 2>&1; then
  grep_available=1
elif [ -x "$GREP_BIN" ] && grep -qE '^  grep\)' "$GREP_BIN"; then
  # #1870: `runtime/vibe` is here but its Rust runner (`bin/viberun`) is not,
  # which is the state of every checkout that has not built one. That is not
  # the same as "this machine cannot run vibe": the repository ships a node
  # runner, and `viberun`'s convention for the CLI is `<wasm> <args...>`
  # against `cli_main`. Adapt to it instead of skipping -- measured, the AST
  # tier then runs here and catches the #1809 drift it exists for.
  #
  # It needs a compiler wasm, and a stage2 built for this checkout is the
  # right one; the pinned seed predates `vibe grep` (#1572).
  stage2_for_grep="$(ls -t "$PROJECT_ROOT"/_build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1 || true)"
  if [ -n "$stage2_for_grep" ] && [ -x "$TOOL_ROOT/scripts/viberun_node.sh" ]; then
    export VIBE_RUNNER="$TOOL_ROOT/scripts/viberun_node.sh"
    export VIBE_CLI_WASM="$stage2_for_grep"
    export VIBE_PREOPEN_DIR="${VIBE_PREOPEN_DIR:-$PROJECT_ROOT}"
    # Probe with the operation that will actually be performed, not with a
    # cheaper one that happens to be nearby. `$GREP_BIN --version` answers
    # "does the dispatcher start", which is not the question: the scan also
    # goes through $RUNNER and the .vibex bootstrap, and those have their own
    # ways to fail. Measured -- under `pkf run`, ensure_seed.sh's `sha256sum`
    # is a broken nix shim, so --version passed, the scan died, and every
    # commit reported "the AST scan did not run" as though the diff had broken
    # something. Running the real entry point against an empty root costs one
    # bootstrap and answers the actual question.
    probe_root="$(mktemp -d "${TMPDIR:-/tmp}/vibe_review_probe.XXXXXX")"
    if (cd "$TOOL_ROOT" && bash "$RUNNER" scripts/review_lint.vibex -- \
          --root "$probe_root" --vibe "$GREP_BIN" >/dev/null 2>&1); then
      grep_available=1
    fi
    rm -rf "$probe_root"
  fi
fi

# Keyed to the OUTCOME, not to one branch of the probe. Setting it inside the
# "runtime/vibe exists but cannot run" branch missed the plainer failure -- no
# runtime/vibe at all -- which fell out of the chain untouched and reported a
# clean `ok`. That is the same silence #1870 is about, one level up.
ast_skipped=0
if [ "$grep_available" -eq 0 ]; then
  ast_skipped=1
  echo "review-regressions lint: AST tier skipped -- no usable \`vibe grep\` ($GREP_BIN)" >&2
  echo "  (build a stage2, or point VIBE_REVIEW_LINT_GREP_BIN at a working one)" >&2
fi

# A skipped tier and a clean tier used to end in the same `ok`, so the one
# place this lint met a real diff could report success having checked nothing
# -- which is how the drift it guards reached main. Callers that must not
# accept that (CI) set VIBE_REVIEW_LINT_REQUIRE_AST=1.
if [ "$ast_skipped" -eq 1 ] && [ "${VIBE_REVIEW_LINT_REQUIRE_AST:-0}" = "1" ]; then
  echo "review-regressions lint: FAIL -- the AST tier is required here and did not run" >&2
  exit 1
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
    git -C "$PROJECT_ROOT" show "$SHOW_REF:$path" > "$tmp_root/$path"
  done <<< "$staged_paths"

  set +e
  ast_output="$(cd "$TOOL_ROOT" && bash "$RUNNER" scripts/review_lint.vibex -- \
    --root "$tmp_root" --vibe "$GREP_BIN" 2>&1)"
  ast_status=$?
  set -e
  if [ "$ast_status" -eq 0 ]; then
    violations=""
  elif [ "$ast_status" -eq 1 ]; then
    if ! printf '%s\n' "$ast_output" | grep -qE '^review-lint: found [0-9]+ structural regression\(s\)$' \
      || ! printf '%s\n' "$ast_output" | grep -qE $'^review-lint:finding\t'; then
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
      # A binder is allowed by a marker on its OWN line or on the line AFTER
      # it, matching is_allowed() in review_lint.vibex -- `pkf run fmt` moves a
      # trailing comment onto the next line, so the documented form never
      # survives in lib/**. Resolving one line late is what the `pending` state
      # is for. Deliberately NOT the line before: that direction would let one
      # marker cover two adjacent binders. Keep these two tiers in step; a
      # bootstrap checkout with no stage2 runs THIS one, and a mismatch means
      # code that commits with a stage2 and is rejected without one.
      function flush_pending() {
        if (pending) {
          printf "%s:%d:%s\n", p_path, p_line, p_text
          pending = 0
        }
      }
      /^\+\+\+ / {
        flush_pending()
        path = $2
        sub(/^[^\/]*\//, "", path)
        next
      }
      /^@@ / {
        flush_pending()
        if (match($0, /\+[0-9]+/)) {
          line = substr($0, RSTART + 1, RLENGTH - 1) + 0
        }
        next
      }
      /^\+/ && !/^\+\+\+/ {
        text = substr($0, 2)
        marked = text ~ /review-lint: allow-fixed-synthetic-name/
        if (pending) {
          if (marked) {
            pending = 0
          } else {
            flush_pending()
          }
        }
        in_transform = path ~ /^lib\/@vibe\/compiler\/(normalize|codegen|loader)\/.*\.vibe$/
        is_binder = in_transform && (text ~ /E(Let|LetMut|LetRec)\("__[A-Za-z0-9_]+"/ \
          || text ~ /PBind\("__[A-Za-z0-9_]+"/ \
          || text ~ /SLet\([^)]*"__[A-Za-z0-9_]+"/)
        if (is_binder && !marked) {
          pending = 1
          p_path = path
          p_line = line
          p_text = text
        }
        line++
      }
      END { flush_pending() }
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

# Say which tiers ran. `ok` must mean the AST tier actually ran. A skipped
# AST tier is still exit 0 (remote sessions must be able to commit) but the
# summary must not claim `ok` -- a caller grepping the last line has to be
# able to tell this from a clean scan (#1988).
if [ "$ast_skipped" -eq 1 ]; then
  echo "review-regressions lint: WARNING -- AST tier skipped (text tier only; this is not a clean scan)"
else
  echo "review-regressions lint: ok"
fi
