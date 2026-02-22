#!/bin/bash
# vibe shell evaluation runner
# Usage: ./run-eval.sh [eval-tasks.json] [output-dir]
#
# Runs each task from eval-tasks.json through vibe shell or vibe run,
# captures output, checks expected results, and generates a report.
#
# Task modes:
#   "shell" - pipe input to vibe shell (REPL, line-by-line)
#   "run"   - write temp .vibe file and run with vibe run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TASKS_FILE="${1:-$SCRIPT_DIR/eval-tasks.json}"
OUTPUT_DIR="${2:-$SCRIPT_DIR/eval-results}"
VIBE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$OUTPUT_DIR/$TIMESTAMP"

mkdir -p "$RESULT_DIR"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install with: brew install jq" >&2
  exit 1
fi

if ! command -v vibe &>/dev/null; then
  echo "Error: vibe not found in PATH" >&2
  exit 1
fi

TOTAL=0
PASS=0
FAIL=0
ERROR=0

echo "=== vibe eval: $TIMESTAMP ==="
echo ""

TASK_COUNT=$(jq length "$TASKS_FILE")

for i in $(seq 0 $((TASK_COUNT - 1))); do
  TASK_ID=$(jq -r ".[$i].id" "$TASKS_FILE")
  TASK_TITLE=$(jq -r ".[$i].title" "$TASKS_FILE")
  TASK_INPUT=$(jq -r ".[$i].input" "$TASKS_FILE")
  TASK_EXPECTED=$(jq -r ".[$i].expected_contains" "$TASKS_FILE")
  TASK_CATEGORY=$(jq -r ".[$i].category" "$TASKS_FILE")
  TASK_MODE=$(jq -r ".[$i].mode // \"shell\"" "$TASKS_FILE")

  TOTAL=$((TOTAL + 1))

  TASK_OUTPUT_FILE="$RESULT_DIR/${TASK_ID}.output"
  TASK_ERROR_FILE="$RESULT_DIR/${TASK_ID}.stderr"

  set +e
  if [ "$TASK_MODE" = "run" ] || [ "$TASK_MODE" = "test" ]; then
    # Write temp file and run with vibe run/test
    TMPFILE=$(mktemp /tmp/vibe_eval_XXXXXX.vibe)
    printf '%s\n' "$TASK_INPUT" > "$TMPFILE"
    cd "$VIBE_ROOT"
    VIBE_CMD="run"
    [ "$TASK_MODE" = "test" ] && VIBE_CMD="test"
    vibe $VIBE_CMD "$TMPFILE" >"$TASK_OUTPUT_FILE" 2>"$TASK_ERROR_FILE" &
    BGPID=$!
    ( sleep 10 && kill $BGPID 2>/dev/null ) &
    WATCHDOG=$!
    wait $BGPID 2>/dev/null
    EXIT_CODE=$?
    kill $WATCHDOG 2>/dev/null || true
    wait $WATCHDOG 2>/dev/null || true
    rm -f "$TMPFILE"
  else
    # Pipe to vibe shell
    cd "$VIBE_ROOT"
    printf '%s\n' "$TASK_INPUT" | vibe shell 2>"$TASK_ERROR_FILE" | \
      grep -v '^vibe-lang>' | grep -v '^$' > "$TASK_OUTPUT_FILE" 2>&1 &
    BGPID=$!
    ( sleep 10 && kill $BGPID 2>/dev/null ) &
    WATCHDOG=$!
    wait $BGPID 2>/dev/null
    EXIT_CODE=$?
    kill $WATCHDOG 2>/dev/null || true
    wait $WATCHDOG 2>/dev/null || true
  fi
  set -e

  OUTPUT=$(cat "$TASK_OUTPUT_FILE" 2>/dev/null || echo "")
  STDERR=$(cat "$TASK_ERROR_FILE" 2>/dev/null || echo "")

  STATUS=""
  if [ -n "$TASK_EXPECTED" ] && echo "$OUTPUT" | grep -qF -- "$TASK_EXPECTED"; then
    STATUS="PASS"
    PASS=$((PASS + 1))
  elif [ -z "$TASK_EXPECTED" ] && [ $EXIT_CODE -eq 0 ]; then
    STATUS="PASS"
    PASS=$((PASS + 1))
  elif [ $EXIT_CODE -ne 0 ] && [ $EXIT_CODE -ne 143 ]; then
    STATUS="ERROR"
    ERROR=$((ERROR + 1))
  else
    STATUS="FAIL"
    FAIL=$((FAIL + 1))
  fi

  printf "  [%-5s] %-40s (%s, %s)\n" "$STATUS" "$TASK_TITLE" "$TASK_CATEGORY" "$TASK_MODE"

  if [ "$STATUS" = "FAIL" ] || [ "$STATUS" = "ERROR" ]; then
    if [ -n "$TASK_EXPECTED" ]; then
      echo "          expected: $TASK_EXPECTED"
    fi
    # Show first 3 non-empty content lines
    CONTENT=$(grep -v '^cwd:' "$TASK_OUTPUT_FILE" | grep -v '^namespace:' | grep -v '^db=' | head -3 | tr '\n' ' ')
    echo "          output:   $CONTENT"
    if [ -n "$STDERR" ]; then
      FIRST_ERR=$(echo "$STDERR" | grep -v '^note:' | grep -v '^$' | head -1)
      [ -n "$FIRST_ERR" ] && echo "          stderr:   $FIRST_ERR"
    fi
  fi

  jq -n \
    --arg id "$TASK_ID" \
    --arg title "$TASK_TITLE" \
    --arg category "$TASK_CATEGORY" \
    --arg mode "$TASK_MODE" \
    --arg status "$STATUS" \
    --arg output "$OUTPUT" \
    --arg stderr "$STDERR" \
    --arg expected "$TASK_EXPECTED" \
    --argjson exit_code "$EXIT_CODE" \
    '{id: $id, title: $title, category: $category, mode: $mode,
      status: $status, exit_code: $exit_code, expected: $expected,
      output: $output, stderr: $stderr}' \
    > "$RESULT_DIR/${TASK_ID}.json"
done

echo ""
echo "--- Summary ---"
echo "Total: $TOTAL  Pass: $PASS  Fail: $FAIL  Error: $ERROR"
echo "Results: $RESULT_DIR"

jq -n \
  --arg timestamp "$TIMESTAMP" \
  --argjson total "$TOTAL" \
  --argjson pass "$PASS" \
  --argjson fail "$FAIL" \
  --argjson error "$ERROR" \
  '{timestamp: $timestamp, total: $total, pass: $pass, fail: $fail, error: $error}' \
  > "$RESULT_DIR/summary.json"

if [ $FAIL -gt 0 ] || [ $ERROR -gt 0 ]; then
  exit 1
fi
