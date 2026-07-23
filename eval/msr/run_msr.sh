#!/usr/bin/env bash
# eval/msr/run_msr.sh — Modification Survival Rate judge.
# See eval/msr/README.md for the methodology.
#
# usage:
#   bash eval/msr/run_msr.sh <task> <initial_dir> <modified_dir>
#     - judges one task: compiles+tests <initial_dir>/entry.vibe, then
#       <modified_dir>/entry.vibe (only if initial passed), prints
#       "initial: PASS|FAIL" / "modified: PASS|FAIL|SKIP".
#
#   bash eval/msr/run_msr.sh --round <round>
#     - judges every task under attempts/<round>/*/{initial,modified}/
#       and prints a summary table + MSR%.
#
# Each of <initial_dir>/<modified_dir> must contain an `entry.vibe` (the
# compile entry point; it may `import ./other.vibe { ... }` sibling files
# in the same directory for multi-file tasks — see
# tasks/advanced/02_package_module).
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

judge_one() {
  # judge_one <label> <dir> -> prints PASS/FAIL/MISSING, returns 0 for PASS
  local label="$1" dir="$2"
  local entry="$dir/entry.vibe"
  if [ ! -f "$entry" ]; then
    echo "$label: MISSING ($entry not found)"
    return 2
  fi
  local log
  log="$(bash scripts/vibe_test.sh "$entry" 2>&1)"
  if echo "$log" | grep -q '^ok '; then
    echo "$label: PASS"
    return 0
  fi
  echo "$label: FAIL"
  echo "$log" | tail -10 | sed 's/^/    /'
  return 1
}

judge_task() {
  # judge_task <task_name> <initial_dir> <modified_dir>
  local task="$1" idir="$2" mdir="$3"
  echo "== $task =="
  local i_out m_out
  i_out="$(judge_one "  initial" "$idir")"; local i_rc=$?
  echo "$i_out"
  if [ "$i_rc" -ne 0 ]; then
    echo "  modified: SKIP (initial did not pass)"
    printf '%s\t%s\t%s\n' "$task" "fail" "skip" >>"$SUMMARY_TSV"
    return
  fi
  m_out="$(judge_one "  modified" "$mdir")"; local m_rc=$?
  echo "$m_out"
  if [ "$m_rc" -eq 0 ]; then
    printf '%s\t%s\t%s\n' "$task" "pass" "pass" >>"$SUMMARY_TSV"
  else
    printf '%s\t%s\t%s\n' "$task" "pass" "fail" >>"$SUMMARY_TSV"
  fi
}

print_summary() {
  local total_eligible=0 survived=0
  echo
  echo "== summary =="
  printf '%-40s %10s %10s\n' "task" "initial" "modified"
  while IFS=$'\t' read -r task init mod; do
    printf '%-40s %10s %10s\n' "$task" "$init" "$mod"
    if [ "$init" = "pass" ]; then
      total_eligible=$((total_eligible + 1))
      [ "$mod" = "pass" ] && survived=$((survived + 1))
    fi
  done <"$SUMMARY_TSV"
  echo
  if [ "$total_eligible" -eq 0 ]; then
    echo "MSR: n/a (no task's initial implementation passed)"
  else
    awk -v s="$survived" -v t="$total_eligible" \
      'BEGIN { printf "MSR: %d/%d = %.1f%%\n", s, t, (s/t)*100 }'
  fi
}

if [ "${1:-}" = "--round" ]; then
  round="${2:?usage: run_msr.sh --round <round>}"
  ROUND_DIR="eval/msr/attempts/$round"
  [ -d "$ROUND_DIR" ] || { echo "run_msr.sh: no such round dir: $ROUND_DIR" >&2; exit 2; }
  SUMMARY_TSV="$(mktemp)"
  trap 'rm -f "$SUMMARY_TSV"' EXIT
  found=0
  for task_dir in "$ROUND_DIR"/*/; do
    [ -d "$task_dir" ] || continue
    task="$(basename "$task_dir")"
    [ -d "$task_dir/initial" ] || continue
    found=1
    judge_task "$task" "$task_dir/initial" "$task_dir/modified"
  done
  if [ "$found" -eq 0 ]; then
    echo "run_msr.sh: no tasks found under $ROUND_DIR (expected <task>/{initial,modified}/entry.vibe)" >&2
    exit 2
  fi
  print_summary
  exit 0
fi

if [ "$#" -ne 3 ]; then
  echo "usage: run_msr.sh <task> <initial_dir> <modified_dir>" >&2
  echo "       run_msr.sh --round <round>" >&2
  exit 2
fi
SUMMARY_TSV="$(mktemp)"
trap 'rm -f "$SUMMARY_TSV"' EXIT
judge_task "$1" "$2" "$3"
print_summary
