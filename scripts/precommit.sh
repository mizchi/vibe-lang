#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_PRECOMMIT_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
STAGED_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_precommit_index.XXXXXX")"
trap 'rm -rf "$STAGED_ROOT"' EXIT

# Every pre-commit gate must observe the same tree that will be committed.
# `checkout-index` also makes partially staged files independent from unstaged
# working-tree edits.
git -C "$PROJECT_ROOT" checkout-index --all --prefix="$STAGED_ROOT/"

ARCH_RULES="${VIBE_ARCH_LINT_RULES:-$STAGED_ROOT/scripts/architecture_debt_rules.tsv}"
ARCH_ALLOWLIST="${VIBE_ARCH_LINT_ALLOWLIST:-$STAGED_ROOT/scripts/architecture_debt_allowlist.txt}"

VIBE_REVIEW_LINT_PROJECT_ROOT="$PROJECT_ROOT" \
  bash "$SCRIPT_DIR/lint_review_regressions.sh"
VIBE_ARCH_LINT_PROJECT_ROOT="$PROJECT_ROOT" \
  VIBE_ARCH_LINT_ROOT="$STAGED_ROOT" \
  VIBE_ARCH_LINT_RULES="$ARCH_RULES" \
  VIBE_ARCH_LINT_ALLOWLIST="$ARCH_ALLOWLIST" \
  bash "$SCRIPT_DIR/lint_architecture_debt.sh"
VIBE_LOCK_CHECK_ROOT="$STAGED_ROOT" bash "$SCRIPT_DIR/check_lock_clean.sh"
# Docs cite file paths; files move. Run this against the staged tree so a
# commit that renames a file and its citation together still passes, and one
# that renames only the file does not.
VIBE_DOC_CITATION_DOCS_ROOT="$STAGED_ROOT" \
  VIBE_DOC_CITATION_REPO_ROOT="$STAGED_ROOT" \
  bash "$SCRIPT_DIR/check_doc_path_citations.sh"

echo "pre-commit: review-derived lint gates passed"
