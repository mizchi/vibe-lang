#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="$ROOT_DIR/target/native/release/build/xsh_cli/xsh_cli.exe"
OUT_DIR="$ROOT_DIR/target/bench/audit"

is_expected_failure() {
  local backend="$1"
  local rel_path="$2"
  case "$backend:$rel_path" in
    "wasm-gc:bench/bench_builder.xsh")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

expected_failure_reason() {
  local backend="$1"
  local rel_path="$2"
  case "$backend:$rel_path" in
    "wasm-gc:bench/bench_builder.xsh")
      echo "gc type support is not implemented for array-builder benchmark"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

run_compile_check() {
  local backend="$1"
  local src="$2"
  local rel_path="$3"
  local out="$4"

  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/xsh-bench-audit.XXXXXX")"

  local rc=0
  set +e
  perl -e '
    my $rc = system @ARGV;
    if ($rc == -1) {
      exit 127;
    }
    if ($rc & 127) {
      exit 128 + ($rc & 127);
    }
    exit($rc >> 8);
  ' \
    "$CLI_BIN" \
    compile \
    "--$backend" \
    -o \
    "$out" \
    "$src" \
    >"$log_file" 2>&1
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    if is_expected_failure "$backend" "$rel_path"; then
      echo "[$backend] unexpected success: $rel_path"
      echo "  remove from expected-failure list:"
      echo "  scripts/bench_audit_backends.sh"
      rm -f "$log_file"
      return 2
    fi
    echo "[$backend] ok: $rel_path"
    rm -f "$log_file"
    return 0
  fi

  if is_expected_failure "$backend" "$rel_path"; then
    echo "[$backend] expected-fail: $rel_path"
    echo "  reason: $(expected_failure_reason "$backend" "$rel_path")"
    rm -f "$log_file"
    return 0
  fi

  echo "[$backend] fail: $rel_path"
  sed -n '1,120p' "$log_file"
  rm -f "$log_file"
  return 1
}

mkdir -p "$OUT_DIR"

moon build --target native --release src/xsh_cli

status=0
for src in "$ROOT_DIR"/bench/*.xsh; do
  rel_path="bench/$(basename "$src")"
  stem="$(basename "$src" .xsh)"
  js_out="$OUT_DIR/${stem}_js_string.wasm"
  gc_out="$OUT_DIR/${stem}_gc.wasm"

  echo "== $rel_path =="
  if ! run_compile_check "wasm-js-string" "$src" "$rel_path" "$js_out"; then
    status=1
  fi
  if ! run_compile_check "wasm-gc" "$src" "$rel_path" "$gc_out"; then
    status=1
  fi
  echo
done

if [ "$status" -ne 0 ]; then
  echo "bench backend audit: failed"
  exit 1
fi

echo "bench backend audit: ok"
