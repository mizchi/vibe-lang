#!/usr/bin/env bash
set -euo pipefail

BIN_PATH="${1:-_build/native/debug/build/cmd/vibe/vibe.exe}"

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "parallel cleanup e2e: missing executable: ${BIN_PATH}" >&2
  exit 1
fi

tmp_dir="$(mktemp -d /tmp/vibe_test_parallel_cleanup_e2e.XXXXXX)"
slow_test_path="${tmp_dir}/slow_test.vibe"
fast_test_path="${tmp_dir}/fast_test.vibe"

cat >"${slow_test_path}" <<'EOF'
test "slow" {
  let run = () -> Unit with {Async} {
    sleep(4000)
  }
  run()
  assert(true)
}
EOF

cat >"${fast_test_path}" <<'EOF'
test "fast" {
  assert(true)
}
EOF

parent_pid=""
children=""

cleanup() {
  if [[ -d "${tmp_dir}" ]]; then
    rm -rf "${tmp_dir}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${parent_pid}" ]] && ps -p "${parent_pid}" >/dev/null 2>&1; then
    kill -KILL "${parent_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${children}" ]]; then
    for pid in ${children}; do
      if ps -p "${pid}" >/dev/null 2>&1; then
        kill -KILL "${pid}" >/dev/null 2>&1 || true
      fi
    done
  fi
}
trap cleanup EXIT

wait_for_children() {
  children=""
  for _ in $(seq 1 30); do
    if ! ps -p "${parent_pid}" >/dev/null 2>&1; then
      break
    fi
    children="$(pgrep -P "${parent_pid}" || true)"
    if [[ -n "${children}" ]]; then
      break
    fi
    sleep 0.2
  done
}

wait_for_children_exit() {
  for _ in $(seq 1 6); do
    alive=0
    for pid in ${children}; do
      if ps -p "${pid}" >/dev/null 2>&1; then
        alive=$((alive + 1))
      fi
    done
    if [[ "${alive}" -eq 0 ]]; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

check_orphaned() {
  orphaned=""
  for pid in ${children}; do
    if ps -p "${pid}" >/dev/null 2>&1; then
      orphaned="${orphaned} ${pid}"
    fi
  done

  if [[ -n "${orphaned}" ]]; then
    echo "parallel cleanup e2e: orphan workers detected:${orphaned}" >&2
    ps -o pid=,ppid=,command= -p ${orphaned} >&2 || true
    return 1
  fi
  return 0
}

run_case() {
  local sig="$1"
  "${BIN_PATH}" test --unstable-async --jobs 2 "${slow_test_path}" "${fast_test_path}" \
    >/tmp/vibe_test_parallel_cleanup_e2e_${sig}.log 2>&1 &
  parent_pid=$!

  wait_for_children
  if [[ -z "${children}" ]]; then
    echo "parallel cleanup e2e: failed to observe worker children under pid=${parent_pid}" >&2
    return 1
  fi

  # Let workers enter test body. The slow test should still be running when parent dies.
  sleep 0.3
  kill -"${sig}" "${parent_pid}" >/dev/null 2>&1 || true
  wait "${parent_pid}" >/dev/null 2>&1 || true

  if ! wait_for_children_exit; then
    :
  fi

  check_orphaned
}

run_case TERM
# SIGKILL path is important because parent signal handler cannot run.
for _ in $(seq 1 5); do
  run_case KILL
done

echo "parallel cleanup e2e: ok"
