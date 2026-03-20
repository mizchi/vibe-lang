#!/usr/bin/env bash
set -euo pipefail

BIN_PATH="${1:-_build/native/debug/build/cmd/vibe/vibe.exe}"

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "parallel cleanup e2e: missing executable: ${BIN_PATH}" >&2
  exit 1
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "${project_root}/_build"
tmp_dir="$(mktemp -d "${project_root}/_build/vibe_test_parallel_cleanup_e2e.XXXXXX")"
slow_test_path="${tmp_dir}/slow_test.vibe"
fast_test_path="${tmp_dir}/fast_test.vibe"
fake_wasmtime_path="${tmp_dir}/fake_wasmtime.sh"
started_marker="${tmp_dir}/started.log"
orphan_marker="${tmp_dir}/orphan.log"

cat >"${slow_test_path}" <<'EOF'
test "slow" {
  assert(true)
}
EOF

cat >"${fast_test_path}" <<'EOF'
test "fast" {
  assert(true)
}
EOF

parent_pid=""

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
  if [[ -n "${parent_pid}" ]] && kill -0 "${parent_pid}" >/dev/null 2>&1; then
    kill -KILL "${parent_pid}" >/dev/null 2>&1 || true
  fi
  cleanup_pids_from_file "${started_marker}"
  cleanup_pids_from_file "${orphan_marker}"
  if [[ -d "${tmp_dir}" ]]; then
    rm -rf "${tmp_dir}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_runner_start() {
  for _ in $(seq 1 150); do
    if [[ -n "${parent_pid}" ]] && ! kill -0 "${parent_pid}" >/dev/null 2>&1; then
      break
    fi
    if [[ -s "${started_marker}" ]]; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

check_orphaned() {
  if [[ -s "${orphan_marker}" ]]; then
    echo "parallel cleanup e2e: orphan descendants wrote marker" >&2
    cat "${orphan_marker}" >&2
    return 1
  fi
  return 0
}

run_case() {
  local sig="$1"
  : >"${started_marker}"
  : >"${orphan_marker}"
  WASMTIME_BIN="${fake_wasmtime_path}" \
    VIBE_TEST_RUNNER_STARTED="${started_marker}" \
    VIBE_TEST_ORPHAN_MARKER="${orphan_marker}" \
    "${BIN_PATH}" test --jobs 2 "${slow_test_path}" "${fast_test_path}" \
    >/tmp/vibe_test_parallel_cleanup_e2e_${sig}.log 2>&1 &
  parent_pid=$!

  if ! wait_for_runner_start; then
    echo "parallel cleanup e2e: failed to observe compiled runner start under pid=${parent_pid}" >&2
    return 1
  fi

  kill -"${sig}" "${parent_pid}" >/dev/null 2>&1 || true
  wait "${parent_pid}" >/dev/null 2>&1 || true
  sleep 3

  check_orphaned
}

run_case TERM
# SIGKILL path is important because parent signal handler cannot run.
for _ in $(seq 1 5); do
  run_case KILL
done

echo "parallel cleanup e2e: ok"
