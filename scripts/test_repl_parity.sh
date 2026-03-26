#!/usr/bin/env bash
# REPL parity test: verify vibe shell-stdin produces expected outputs.
# Reads test cases from tests/repl/repl_cases.txt and compares actual
# output against expected values.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Build native CLI
source "$SCRIPT_DIR/ensure_native_cli.sh"
CLI="$VIBE_CLI_BIN"

CASES_FILE="$ROOT_DIR/tests/repl/repl_cases.txt"
if [[ ! -f "$CASES_FILE" ]]; then
  echo "ERROR: $CASES_FILE not found" >&2
  exit 1
fi

pass=0
fail=0
skip=0
errors=()

while IFS= read -r line; do
  # Skip empty lines and comments
  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue

  # Parse "input >>> expected"
  if [[ "$line" != *" >>> "* ]]; then
    echo "SKIP (bad format): $line"
    skip=$((skip + 1))
    continue
  fi

  input="${line%% >>> *}"
  expected="${line##* >>> }"

  # Run the expression through shell-stdin
  actual_raw=$(echo "$input" | "$CLI" shell-stdin --no-prompt 2>&1 || true)

  # Extract relevant output line (skip namespace: line)
  actual=""
  while IFS= read -r out_line; do
    # Skip namespace info line
    [[ "$out_line" =~ ^namespace: ]] && continue
    # Take the first meaningful line
    if [[ -n "$out_line" ]]; then
      actual="$out_line"
      break
    fi
  done <<< "$actual_raw"

  # Compare
  if [[ "$expected" == "error:" ]]; then
    # Error case: actual should start with "error:"
    if [[ "$actual" == error:* ]]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      errors+=("FAIL: input='$input' expected error but got '$actual'")
    fi
  else
    if [[ "$actual" == "$expected" ]]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      errors+=("FAIL: input='$input' expected='$expected' actual='$actual'")
    fi
  fi
done < "$CASES_FILE"

# Report
echo ""
echo "=== REPL parity test results ==="
echo "pass: $pass  fail: $fail  skip: $skip"

if [[ ${#errors[@]} -gt 0 ]]; then
  echo ""
  echo "--- Failures ---"
  for e in "${errors[@]}"; do
    echo "  $e"
  done
  echo ""
  exit 1
fi

echo "All tests passed."
