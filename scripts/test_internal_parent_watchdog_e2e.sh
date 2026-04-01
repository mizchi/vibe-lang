#!/usr/bin/env bash
set -euo pipefail

BIN_PATH="${1:-_build/native/debug/build/cmd/vibe/vibe.exe}"

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "internal parent watchdog e2e: missing executable: ${BIN_PATH}" >&2
  exit 1
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "${project_root}/_build"
tmp_dir="$(mktemp -d "${project_root}/_build/vibe_internal_parent_watchdog.XXXXXX")"
test_path="${tmp_dir}/watchdog_test.vibe"
fake_wasmtime_path="${tmp_dir}/fake_wasmtime.sh"
started_marker="${tmp_dir}/started.log"
orphan_marker="${tmp_dir}/orphan.log"
worker_pid=""
dummy_parent_pid=""

cat >"${test_path}" <<'EOF'
test "watchdog" { assert(true) }
EOF

cat >"${fake_wasmtime_path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" >> "${VIBE_TEST_RUNNER_STARTED}"
(
  sleep 2
  printf '%s\n' "$$" >> "${VIBE_TEST_ORPHAN_MARKER}"
) &
sleep 30 &
wait "$!"
EOF
chmod +x "${fake_wasmtime_path}"

cleanup_pids_from_file() {
  local file_path="$1"
  [[ -f "${file_path}" ]] || return 0
  local pid
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    kill -KILL "-${pid}" >/dev/null 2>&1 || true
    kill -KILL "${pid}" >/dev/null 2>&1 || true
  done <"${file_path}"
}

cleanup() {
  if [[ -n "${worker_pid}" ]] && kill -0 "${worker_pid}" >/dev/null 2>&1; then
    kill -KILL "${worker_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${dummy_parent_pid}" ]] && kill -0 "${dummy_parent_pid}" >/dev/null 2>&1; then
    kill -KILL "${dummy_parent_pid}" >/dev/null 2>&1 || true
  fi
  cleanup_pids_from_file "${started_marker}"
  cleanup_pids_from_file "${orphan_marker}"
  rm -rf "${tmp_dir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_runner_start() {
  for _ in $(seq 1 150); do
    if [[ -s "${started_marker}" ]]; then
      return 0
    fi
    if [[ -n "${worker_pid}" ]] && ! kill -0 "${worker_pid}" >/dev/null 2>&1; then
      return 1
    fi
    sleep 0.2
  done
  return 1
}

check_orphaned() {
  if [[ -s "${orphan_marker}" ]]; then
    echo "internal parent watchdog e2e: orphan descendants wrote marker" >&2
    cat "${orphan_marker}" >&2
    return 1
  fi
  return 0
}

: >"${started_marker}"
: >"${orphan_marker}"
sleep 30 &
dummy_parent_pid=$!

VIBE_INTERNAL_PARENT_PID="${dummy_parent_pid}" \
  WASMTIME_BIN="${fake_wasmtime_path}" \
  VIBE_TEST_RUNNER_STARTED="${started_marker}" \
  VIBE_TEST_ORPHAN_MARKER="${orphan_marker}" \
  "${BIN_PATH}" test --report-json "${test_path}" \
  >/tmp/vibe_internal_parent_watchdog.log 2>&1 &
worker_pid=$!

if ! wait_for_runner_start; then
  echo "internal parent watchdog e2e: failed to observe compiled runner start" >&2
  sed -n '1,200p' /tmp/vibe_internal_parent_watchdog.log >&2 || true
  exit 1
fi

kill -KILL "${dummy_parent_pid}" >/dev/null 2>&1 || true
wait "${dummy_parent_pid}" >/dev/null 2>&1 || true
sleep 3

check_orphaned
echo "internal parent watchdog e2e: ok"
