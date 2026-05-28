#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/lint_architecture_debt.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_arch_lint_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/src"

cat > "$TMP_ROOT/rules.tsv" <<'EOF'
# id	severity	scope	regex	message	issue
ARCH999	error	**/*.vibe	String::concat\(acc,	use StringBuilder for unbounded accumulators	#999
EOF

: > "$TMP_ROOT/allowlist.tsv"

cat > "$TMP_ROOT/src/hot.vibe" <<'EOF'
let slow = String::concat(acc, "x")
EOF

if VIBE_ARCH_LINT_ROOT="$TMP_ROOT" \
  VIBE_ARCH_LINT_RULES="$TMP_ROOT/rules.tsv" \
  VIBE_ARCH_LINT_ALLOWLIST="$TMP_ROOT/allowlist.tsv" \
  "$CHECK_SCRIPT" >"$TMP_ROOT/fail.stdout" 2>"$TMP_ROOT/fail.stderr"; then
  echo "architecture-debt lint self-test: expected violation" >&2
  exit 1
fi

if ! rg -q 'src/hot.vibe:1: error ARCH999' "$TMP_ROOT/fail.stderr"; then
  echo "architecture-debt lint self-test: missing violation location" >&2
  cat "$TMP_ROOT/fail.stderr" >&2
  exit 1
fi

cat > "$TMP_ROOT/allowlist.tsv" <<'EOF'
ARCH999	src/hot.vibe	1
EOF

VIBE_ARCH_LINT_ROOT="$TMP_ROOT" \
  VIBE_ARCH_LINT_RULES="$TMP_ROOT/rules.tsv" \
  VIBE_ARCH_LINT_ALLOWLIST="$TMP_ROOT/allowlist.tsv" \
  "$CHECK_SCRIPT" >/dev/null

cat > "$TMP_ROOT/src/other.vibe" <<'EOF'
let slow2 = String::concat(acc, "y")
EOF

if VIBE_ARCH_LINT_ROOT="$TMP_ROOT" \
  VIBE_ARCH_LINT_RULES="$TMP_ROOT/rules.tsv" \
  VIBE_ARCH_LINT_ALLOWLIST="$TMP_ROOT/allowlist.tsv" \
  "$CHECK_SCRIPT" >"$TMP_ROOT/new.stdout" 2>"$TMP_ROOT/new.stderr"; then
  echo "architecture-debt lint self-test: expected new unallowlisted violation" >&2
  exit 1
fi

if ! rg -q 'src/other.vibe:1: error ARCH999' "$TMP_ROOT/new.stderr"; then
  echo "architecture-debt lint self-test: missing new violation location" >&2
  cat "$TMP_ROOT/new.stderr" >&2
  exit 1
fi

cat > "$TMP_ROOT/allowlist.tsv" <<'EOF'
ARCH999	src/hot.vibe	1
ARCH999	src/other.vibe	*
EOF

VIBE_ARCH_LINT_ROOT="$TMP_ROOT" \
  VIBE_ARCH_LINT_RULES="$TMP_ROOT/rules.tsv" \
  VIBE_ARCH_LINT_ALLOWLIST="$TMP_ROOT/allowlist.tsv" \
  "$CHECK_SCRIPT" >/dev/null

echo "architecture-debt lint self-test: ok"
