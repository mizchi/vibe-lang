#!/usr/bin/env bash
# Protocol test for measure_fs_heap.sh. This uses a fake runner so it checks
# env/cache isolation, unique run directories and cleanup, fail-closed mark
# parsing, optional parity/locking, and the page threshold without running the
# expensive real full-CLI compile.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/measure_fs_heap.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibe_measure_fs_heap.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

BASE="$TMP_DIR/base.wasm"
printf '\0asm\1\0\0\0' > "$BASE"
RUNNER="$TMP_DIR/fake_runner.sh"
RUN_LOG="$TMP_DIR/run.log"

cat > "$RUNNER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "--invoke" ] && [ "$2" = "cli_main" ] || exit 2
out="$5"
printf 'marks=%s cache=%s pre_grow=%s host_alloc=%s host_guard=%s entry_testmeta=%s testmeta=%s rc_heap_start=%s wasm_names=%s ingestion_stamp=%s import_abi=%s coverage=%s\n' \
  "${VIBE_PROFILE_MEMORY_MARKS:-unset}" \
  "${VIBE_BUILD_CACHE_DIR:-unset}" \
  "${VIBE_WASM_PRE_GROW_PAGES:-unset}" \
  "${VIBE_WASM_HOST_ALLOC_MODE:-unset}" \
  "${VIBE_WASM_HOST_ARENA_GUARD_BYTES:-unset}" \
  "${VIBE_ENTRY_TESTMETA_OUT:-unset}" \
  "${VIBE_TESTMETA_OUT:-unset}" \
  "${VIBE_RC_HEAP_START:-unset}" \
  "${VIBE_WASM_NAMES:-unset}" \
  "${VIBE_EXPERIMENTAL_PERSISTENT_INGESTION_STAMP:-unset}" \
  "${VIBE_IMPORT_ABI:-unset}" \
  "${VIBE_COVERAGE:-unset}" >> "$FAKE_RUN_LOG"
mkdir -p "$(dirname "$out")"
sleep_pid=""
trap '[ -z "$sleep_pid" ] || kill "$sleep_pid" 2>/dev/null || true; [ -z "$sleep_pid" ] || wait "$sleep_pid" 2>/dev/null || true; printf "terminated\\n" >> "$FAKE_RUN_LOG"; exit 143' TERM
if [ "${FAKE_SLEEP:-0}" != 0 ]; then
  sleep "$FAKE_SLEEP" &
  sleep_pid=$!
  wait "$sleep_pid"
  sleep_pid=""
fi
printf '\0asm\1\0\0\0' > "$out"
if [ "${VIBE_PROFILE_MEMORY_MARKS:-}" = "1" ]; then
  pages="${FAKE_PAGES:-100}"
  for name in start source_groups prepared_db merged_stmts codegen_rc write_output fs_compile_complete; do
    if [ "${FAKE_MISSING_BOUNDARY:-}" = "$name" ]; then
      continue
    fi
    printf '[profile-memory] mark=0 pages=%s bytes=%s heap_ptr=1048576 host_alloc_ptr=0 rss=2097152 name=%s\n' \
      "$pages" "$((pages * 65536))" "$name" >&2
  done
fi
EOF
chmod +x "$RUNNER"

# Ambient runner/compiler controls must not change the lane or its measured
# guest pages. The marked/unmarked outputs are identical, so parity must pass.
FAKE_RUN_LOG="$RUN_LOG" \
VIBE_FS_HEAP_RUNNER="$RUNNER" \
VIBE_FS_HEAP_OUT_DIR="$TMP_DIR/out" \
VIBE_BUILD_CACHE_DIR="$TMP_DIR/ambient-cache-must-not-be-used" \
VIBE_WASM_PRE_GROW_PAGES=999 \
VIBE_WASM_HOST_ALLOC_MODE=arena \
VIBE_WASM_HOST_ARENA_GUARD_BYTES=123 \
VIBE_WASM_MEMORY_STATS=1 \
VIBE_WASM_NAMES=1 \
VIBE_ENTRY_TESTMETA_OUT="$TMP_DIR/ambient-entry-meta" \
VIBE_TESTMETA_OUT="$TMP_DIR/ambient-test-meta" \
VIBE_RC_HEAP_START=123456 \
VIBE_EXPERIMENTAL_PERSISTENT_INGESTION_STAMP=1 \
  bash "$SCRIPT" --cold --base "$BASE" --verify-parity > "$TMP_DIR/ok.stdout"

grep -q '^\[fs-heap\] parity=ok mode=cold$' "$TMP_DIR/ok.stdout"
grep -q '^\[fs-heap\] mode=cold boundary=fs_compile_complete ' "$TMP_DIR/ok.stdout"
grep -Eq "^marks=1 cache=$TMP_DIR/out/run\.[^/]*/cache_marked pre_grow=unset host_alloc=unset host_guard=unset entry_testmeta=unset testmeta=unset rc_heap_start=unset wasm_names=unset ingestion_stamp=unset import_abi=raw coverage=0$" "$RUN_LOG"
grep -Eq "^marks=0 cache=$TMP_DIR/out/run\.[^/]*/cache_unmarked pre_grow=unset host_alloc=unset host_guard=unset entry_testmeta=unset testmeta=unset rc_heap_start=unset wasm_names=unset ingestion_stamp=unset import_abi=raw coverage=0$" "$RUN_LOG"
if grep -q 'ambient-cache-must-not-be-used' "$RUN_LOG"; then
  echo "measure_fs_heap test: ambient cache leaked into measurement" >&2
  exit 1
fi
if find "$TMP_DIR/out" -mindepth 1 -maxdepth 1 -type d -name 'run.*' | grep -q .; then
  echo "measure_fs_heap test: successful run directory was not cleaned" >&2
  exit 1
fi

# The default --gate limit is 57344 pages (3.5 GiB), and exceeding it must
# fail rather than report a plausible measurement.
set +e
FAKE_RUN_LOG="$RUN_LOG" \
FAKE_PAGES=57345 \
VIBE_FS_HEAP_RUNNER="$RUNNER" \
VIBE_FS_HEAP_OUT_DIR="$TMP_DIR/gate" \
  bash "$SCRIPT" --cold --base "$BASE" --gate > "$TMP_DIR/gate.stdout" 2> "$TMP_DIR/gate.stderr"
status=$?
set -e
if [ "$status" -eq 0 ]; then
  echo "measure_fs_heap test: expected 3.5 GiB page gate to fail" >&2
  exit 1
fi
grep -q 'GATE FAIL: peak_pages 57345 > limit 57344' "$TMP_DIR/gate.stderr"

# A successful runner exit without every documented mark is an invalid sample,
# not a partial measurement that can look healthy.
set +e
FAKE_RUN_LOG="$RUN_LOG" \
FAKE_MISSING_BOUNDARY=fs_compile_complete \
VIBE_FS_HEAP_RUNNER="$RUNNER" \
VIBE_FS_HEAP_OUT_DIR="$TMP_DIR/missing" \
  bash "$SCRIPT" --cold --base "$BASE" > "$TMP_DIR/missing.stdout" 2> "$TMP_DIR/missing.stderr"
status=$?
set -e
if [ "$status" -eq 0 ]; then
  echo "measure_fs_heap test: expected missing boundary to fail closed" >&2
  exit 1
fi
grep -q 'missing required boundary mark: fs_compile_complete' "$TMP_DIR/missing.stderr"

# Warm runs serialize only the persistent warm-cache snapshot. A pre-held lock
# must fail rather than let two runs race that snapshot.
mkdir -p "$TMP_DIR/warm/.warm-cache.lock"
set +e
FAKE_RUN_LOG="$RUN_LOG" \
VIBE_FS_HEAP_RUNNER="$RUNNER" \
VIBE_FS_HEAP_OUT_DIR="$TMP_DIR/warm" \
  bash "$SCRIPT" --warm --base "$BASE" > "$TMP_DIR/lock.stdout" 2> "$TMP_DIR/lock.stderr"
status=$?
set -e
if [ "$status" -eq 0 ]; then
  echo "measure_fs_heap test: expected pre-held warm lock to fail" >&2
  exit 1
fi
grep -q 'another measurement holds lock:' "$TMP_DIR/lock.stderr"
rmdir "$TMP_DIR/warm/.warm-cache.lock"

# A signal must terminate the active runner promptly, preserve a signal exit
# status, and still clean the unique run directory.
set +e
FAKE_RUN_LOG="$RUN_LOG" \
FAKE_SLEEP=30 \
VIBE_FS_HEAP_RUNNER="$RUNNER" \
VIBE_FS_HEAP_OUT_DIR="$TMP_DIR/signal" \
  bash "$SCRIPT" --cold --base "$BASE" > "$TMP_DIR/signal.stdout" 2> "$TMP_DIR/signal.stderr" &
measure_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '^marks=1 .*cache=.*/signal/run\.' "$RUN_LOG" && break
  sleep 0.1
done
kill -TERM "$measure_pid"
wait "$measure_pid"
status=$?
set -e
if [ "$status" -ne 143 ]; then
  echo "measure_fs_heap test: TERM exit was $status, expected 143" >&2
  exit 1
fi
grep -q '^terminated$' "$RUN_LOG"
if find "$TMP_DIR/signal" -mindepth 1 -maxdepth 1 -type d -name 'run.*' | grep -q .; then
  echo "measure_fs_heap test: interrupted run directory was not cleaned" >&2
  exit 1
fi

echo "measure_fs_heap self-test: ok"
