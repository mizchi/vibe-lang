#!/usr/bin/env bash
# Differential compile: two compiler builds must emit byte-identical wasm.
#
# #906 Phase 1 asks for exactly this ("differentially compare the new
# --jobs 1 path with the old compiler"), and every later phase re-asks it:
# the determinism contract in docs/compiler-parallelism.md is byte identity,
# not behavioural equivalence. Restructuring the module walk is only safe if
# the bytes do not move.
#
# Each compile gets its OWN cold VIBE_BUILD_CACHE_DIR. A shared cache would
# let the second run answer from artifacts the first one published, which
# would compare a compiler against itself.
#
# Usage:
#   bash scripts/compiler_differential.sh <old.wasm> <new.wasm> [input[=entry] ...]
#
# Each input may name its entry point explicitly as `path=entry`. Without
# one, `*_test.vibe` uses `__no_entry__` and everything else uses `_start`.
# With no inputs at all, a default corpus spanning the shapes that matter
# (deep import DAG, cache paths, closures, variants) is used.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OLD="${1:-}"
NEW="${2:-}"
shift 2 || true

if [ -z "$OLD" ] || [ ! -s "$OLD" ] || [ -z "$NEW" ] || [ ! -s "$NEW" ]; then
  echo "[differential] usage: bash scripts/compiler_differential.sh <old.wasm> <new.wasm> [inputs...]" >&2
  exit 2
fi

inputs=("$@")
if [ "${#inputs[@]}" -eq 0 ]; then
  inputs=(
    lib/@vibe/compiler/tests/codegen_lexer_test.vibe
    lib/@vibe/compiler/tests/persistent_cache_test.vibe
    lib/@vibe/compiler/tests/loader_persistent_cache_test.vibe
    bench/binary_size/fib.vibe=main
    bench/binary_size/fizzbuzz.vibe=main
    bench/binary_size/closure_indirect.vibe=main
    bench/binary_size/variant_float.vibe=main
  )
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

compile_with() {
  # $1 compiler wasm, $2 input, $3 out, $4 entry
  local cache="$work/cache_$$_$RANDOM"
  rm -rf "$cache"; mkdir -p "$cache"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    VIBE_BUILD_CACHE_DIR="$cache" \
    timeout 900 bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$1" "$2" "$3" "$4" >/dev/null 2>&1 || true
  rm -rf "$cache"
}

status=0
checked=0
for spec in "${inputs[@]}"; do
  input="${spec%%=*}"
  if [ "$spec" = "$input" ]; then
    # No explicit entry: test files have none, everything else uses _start.
    case "$input" in
      *_test.vibe) entry="__no_entry__" ;;
      *) entry="_start" ;;
    esac
  else
    entry="${spec#*=}"
  fi
  if [ ! -f "$input" ]; then
    echo "[differential] FAIL: input not found: $input" >&2
    status=1
    continue
  fi
  base="$(echo "$input" | tr '/.' '__')"
  old_out="$work/old_$base.wasm"
  new_out="$work/new_$base.wasm"
  compile_with "$OLD" "$input" "$old_out" "$entry"
  compile_with "$NEW" "$input" "$new_out" "$entry"

  if [ ! -s "$old_out" ] && [ ! -s "$new_out" ]; then
    # Both refused it -- almost always a wrong entry name, which silently
    # removes the input from the comparison. Treated as a failure rather
    # than a skip: an input that compares nothing must not look like
    # agreement. (This is how bench/binary_size got its `=main` entries.)
    echo "[differential] FAIL: $input compiled by NEITHER build (wrong entry '$entry'?)" >&2
    cat "$new_out.diag" 2>/dev/null >&2 || true
    status=1
    continue
  fi
  if [ ! -s "$old_out" ] || [ ! -s "$new_out" ]; then
    echo "[differential] FAIL: $input compiled by only one build (old=$([ -s "$old_out" ] && echo ok || echo none) new=$([ -s "$new_out" ] && echo ok || echo none))" >&2
    status=1
    continue
  fi
  if cmp -s "$old_out" "$new_out"; then
    echo "[differential] ok $input ($(wc -c < "$new_out") B)"
    checked=$((checked + 1))
  else
    echo "[differential] FAIL: $input differs (old $(wc -c < "$old_out") B vs new $(wc -c < "$new_out") B)" >&2
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  exit 1
fi
if [ "$checked" -eq 0 ]; then
  echo "[differential] FAIL: nothing was actually compared" >&2
  exit 1
fi
echo "[differential] $checked input(s) byte-identical across builds"
