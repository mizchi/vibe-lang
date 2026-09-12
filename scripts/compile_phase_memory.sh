#!/usr/bin/env bash
# #2510 criterion 5: where a compile's ALLOCATION goes, by phase, at three
# temperatures.
#
#   bash scripts/compile_phase_memory.sh [corpus] [leaf]
#
# This is a MEASUREMENT, not a gate: it prints numbers and always exits 0, so
# there is no pass/fail property for a `_test.sh` to red-test -- the same
# reason `prelude_split_memory.sh` is not named `check_*`.
#
# The instrument is the #1553 heap-mark lane: under VIBE_PROFILE_MEMORY_MARKS=1
# the CLI adapter takes `compile_file_fs_mode_rc_heap_marked`, which calls
# `fs_heap_mark` between the phases, and the node runner prints the bump-heap
# pointer at each. A DELTA between two marks is bytes ALLOCATED in that phase
# -- the allocator never frees, so no instrument here reports a live set.
#
# One temperature per process, all three sharing one VIBE_BUILD_CACHE_DIR:
# warm reuse is the thing being measured, so the directory is created fresh
# here and nothing else is allowed to warm it first (#2393).
#
# Phases do not partition the work cleanly, and the output says so rather than
# implying they do: the parse happens inside whichever phase first needs a
# statement list, so it moves between `prepared_db` and `merged_stmts`
# depending on what the caches hold. Read the TOTAL as the comparable figure
# and a phase row as "where this temperature paid".
#
# The leaf must really be in the corpus's import closure -- a leaf outside it
# makes every edited row equal the unchanged one, a vacuous experiment that
# looks like a result.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CORPUS="${1:-lib/@vibe/compiler/tests/codegen_lexer_test.vibe}"
LEAF="${2:-lib/@vibe/core/defaults.vibe}"

for f in "$CORPUS" "$LEAF"; do
  if [ ! -f "$f" ]; then
    echo "compile_phase_memory.sh: not found: $f" >&2
    exit 2
  fi
done

cli="${VIBE_PHASE_MEMORY_CLI_WASM:-}"
if [ -z "$cli" ]; then
  cli="$(ls -d _build/selfhost/generations/*/ 2>/dev/null | tail -1)stage2.wasm"
fi
if [ ! -f "$cli" ]; then
  echo "compile_phase_memory.sh: no compiler wasm; set VIBE_PHASE_MEMORY_CLI_WASM" >&2
  exit 2
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibe_phase_memory.XXXXXX")"
trap 'cp "$tmp_dir/leaf.orig" "$LEAF" 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT

closure="$tmp_dir/closure.txt"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_DEPS=1 \
  bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
  --invoke cli_main "$cli" "$CORPUS" "$closure" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$closure" ]; then
  echo "compile_phase_memory.sh: could not resolve the closure of $CORPUS" >&2
  exit 2
fi
if ! grep -qx -- "$LEAF" "$closure"; then
  echo "compile_phase_memory.sh: $LEAF is NOT in the import closure of $CORPUS." >&2
  exit 2
fi
echo "[phase-memory] corpus=$CORPUS closure=$(grep -c . "$closure") leaf=$LEAF"

cp "$LEAF" "$tmp_dir/leaf.orig"
cache_dir="$tmp_dir/cache"
mkdir -p "$cache_dir"

run_one() {
  local label="$1"
  local marks="$tmp_dir/$label.marks"
  VIBE_PROFILE_MEMORY_MARKS=1 VIBE_BUILD_CACHE_DIR="$cache_dir" \
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke cli_main "$cli" \
    "$CORPUS" "$tmp_dir/out.wasm" __no_entry__ 2>&1 | grep 'profile-memory' > "$marks" || true
  if [ ! -s "$marks" ]; then
    echo "[phase-memory] $label: no marks -- is this compiler built with the heap-mark lane?" >&2
    exit 1
  fi
  awk -v label="$label" '
    {
      name = ""
      ptr = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^name=/) { name = substr($i, 6) }
        if ($i ~ /^heap_ptr=/) { ptr = substr($i, 10) }
      }
      if (ptr == "" || ptr == "missing") { next }
      if (prev_name != "") {
        printf "%-16s %-22s %12d\n", label, prev_name " -> " name, ptr - prev_ptr
      }
      prev_name = name
      prev_ptr = ptr
      last = ptr
      if (first == "") { first = ptr }
    }
    END { printf "%-16s %-22s %12d\n", label, "TOTAL", last - first }
  ' "$marks"
}

run_one "cold"
run_one "unchanged"
printf '\n// compile_phase_memory.sh measurement touch\n' >> "$LEAF"
run_one "leaf-edited"
cp "$tmp_dir/leaf.orig" "$LEAF"
