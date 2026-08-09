#!/usr/bin/env bash
# Protocol test for measure_fs_heap.sh. This uses a fake runner so it checks
# cache isolation, fail-closed mark parsing, optional parity, and the page
# threshold without running the expensive real full-CLI compile.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/measure_fs_heap.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibe_measure_fs_heap.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

BASE="$TMP_DIR/base.wasm"
printf '\0asm\1\0\0\0' > "$BASE"
RUNNER="$TMP_DIR/fake_runner.sh"
CACHE_LOG="$TMP_DIR/cache.log"

cat > "$RUNNER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "--invoke" ] && [ "$2" = "cli_main" ] || exit 2
out="$5"
printf '%s\t%s\n' "${VIBE_PROFILE_MEMORY_MARKS:-unset}" "$VIBE_BUILD_CACHE_DIR" >> "$FAKE_CACHE_LOG"
mkdir -p "$(dirname "$out")"
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

# An ambient cache override must not leak into cold measurements. The fake
# marked/unmarked outputs are identical, so --verify-parity must pass.
FAKE_CACHE_LOG="$CACHE_LOG" \
VIBE_FS_HEAP_RUNNER="$RUNNER" \
VIBE_FS_HEAP_OUT_DIR="$TMP_DIR/out" \
VIBE_BUILD_CACHE_DIR="$TMP_DIR/ambient-cache-must-not-be-used" \
  bash "$SCRIPT" --cold --base "$BASE" --verify-parity > "$TMP_DIR/ok.stdout"

grep -q '^\[fs-heap\] parity=ok mode=cold ' "$TMP_DIR/ok.stdout"
grep -q '^\[fs-heap\] mode=cold boundary=fs_compile_complete ' "$TMP_DIR/ok.stdout"
grep -q "^1[[:space:]]$TMP_DIR/out/cache_cold_marked$" "$CACHE_LOG"
grep -q "^0[[:space:]]$TMP_DIR/out/cache_cold_unmarked$" "$CACHE_LOG"
if grep -q 'ambient-cache-must-not-be-used' "$CACHE_LOG"; then
  echo "measure_fs_heap test: ambient cache leaked into measurement" >&2
  exit 1
fi

# The default --gate limit is 57344 pages (3.5 GiB), and exceeding it must
# fail rather than report a plausible measurement.
set +e
FAKE_CACHE_LOG="$CACHE_LOG" \
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
FAKE_CACHE_LOG="$CACHE_LOG" \
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

echo "measure_fs_heap self-test: ok"
