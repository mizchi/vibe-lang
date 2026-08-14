#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

bash "$SCRIPT_DIR/lint_review_regressions.sh"
bash "$SCRIPT_DIR/lint_architecture_debt.sh"
bash "$SCRIPT_DIR/check_lock_clean.sh"

echo "pre-commit: review-derived lint gates passed"
