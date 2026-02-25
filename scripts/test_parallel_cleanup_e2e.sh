#!/usr/bin/env bash
set -euo pipefail

BIN_PATH="${1:-_build/native/debug/build/cmd/vibe/vibe.exe}"

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "parallel cleanup e2e: missing executable: ${BIN_PATH}" >&2
  exit 1
fi

parent_pid=""
children=""

cleanup() {
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

"${BIN_PATH}" test --unstable-async --jobs 4 examples vibe/builtin vibe/io vibe/fs \
  >/tmp/vibe_test_parallel_cleanup_e2e.log 2>&1 &
parent_pid=$!

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

if [[ -z "${children}" ]]; then
  echo "parallel cleanup e2e: failed to observe worker children under pid=${parent_pid}" >&2
  exit 1
fi

kill -TERM "${parent_pid}" >/dev/null 2>&1 || true
wait "${parent_pid}" >/dev/null 2>&1 || true

for _ in $(seq 1 20); do
  alive=0
  for pid in ${children}; do
    if ps -p "${pid}" >/dev/null 2>&1; then
      alive=$((alive + 1))
    fi
  done
  if [[ "${alive}" -eq 0 ]]; then
    break
  fi
  sleep 0.2
done

orphaned=""
for pid in ${children}; do
  if ps -p "${pid}" >/dev/null 2>&1; then
    orphaned="${orphaned} ${pid}"
  fi
done

if [[ -n "${orphaned}" ]]; then
  echo "parallel cleanup e2e: orphan workers detected:${orphaned}" >&2
  ps -o pid=,ppid=,command= -p ${orphaned} >&2 || true
  exit 1
fi

echo "parallel cleanup e2e: ok"
