#!/usr/bin/env bash
# Measure allocation volume without warming the measured compile in a shape
# query or changing the checkout's sources. No wall-time or live-set claim.
# VIBE_PRELUDE_SPLIT_CLI_WASM must name the compiler built from this checkout.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CORPUS="${1:-lib/@vibe/compiler/tests/codegen_lexer_test.vibe}"
LEAF="${2:-lib/@vibe/core/default.vibe}"
cli="${VIBE_PRELUDE_SPLIT_CLI_WASM:?set VIBE_PRELUDE_SPLIT_CLI_WASM to the checkout stage2.wasm}"
case "$cli" in /*) ;; *) cli="$ROOT_DIR/$cli" ;; esac
for f in "$CORPUS" "$LEAF"; do
  case "$f" in lib/*) ;; *) echo "prelude-split-memory: use paths under lib/" >&2; exit 2 ;; esac
  case "/$f/" in */../*) echo "prelude-split-memory: parent path segments are not supported" >&2; exit 2 ;; esac
  [ -f "$f" ] || { echo "prelude-split-memory: not found: $f" >&2; exit 2; }
done
[ -f "$cli" ] || { echo "prelude-split-memory: compiler not found: $cli" >&2; exit 2; }
mkdir -p _build
report_dir="$(mktemp -d "$ROOT_DIR/_build/prelude-split-memory.XXXXXX")"
source_dir="$report_dir/source"
mkdir -p "$source_dir" "$report_dir/probe-cache"
cp -RL lib "$source_dir/lib"
cp "$source_dir/$LEAF" "$report_dir/leaf.orig"
runner="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"

# This builds the measurement executable from the current compiler SOURCES.
# Its compiler's cache is separate from every measured process's cache.
VIBE_BUILD_CACHE_DIR="$report_dir/probe-cache" VIBE_CHECKED_MODULE_CACHE=off \
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash "$runner" --invoke cli_main "$cli" scripts/prelude_split_memory.vibex \
  "$report_dir/probe.wasm" main >"$report_dir/probe-build.log" 2>&1 || {
  cat "$report_dir/probe-build.log" >&2
  [ ! -f "$report_dir/probe.wasm.diag" ] || cat "$report_dir/probe.wasm.diag" >&2
  exit 1
}
[ -s "$report_dir/probe.wasm" ] || {
  cat "$report_dir/probe-build.log" >&2
  [ ! -f "$report_dir/probe.wasm.diag" ] || cat "$report_dir/probe.wasm.diag" >&2
  exit 1
}
# Verify that the edit belongs to the closure, outside all measurement caches.
VIBE_BUILD_CACHE_DIR="$report_dir/probe-cache" VIBE_CHECKED_MODULE_CACHE=off \
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_DEPS=1 \
  bash "$runner" --invoke cli_main "$cli" "$CORPUS" "$report_dir/closure.txt" \
  __no_entry__ >"$report_dir/deps.log" 2>&1
if [ "$CORPUS" != "$LEAF" ] && ! grep -qxF -- "$LEAF" "$report_dir/closure.txt"; then
  echo "prelude-split-memory: $LEAF is outside $CORPUS's closure" >&2
  exit 1
fi
printf 'round\ttemperature\tlane\tmodules\theap_delta\twasm_bytes\n' >"$report_dir/report.tsv"
run_one() {
  local round="$1" lane="$2" cache_dir="$3" temperature="$4"
  local stem="$report_dir/$round-$lane-$temperature" line
  (
    cd "$source_dir"
    VIBE_BUILD_CACHE_DIR="$cache_dir" VIBE_CHECKED_MODULE_CACHE=off \
      VIBE_EXPERIMENTAL_AST_CACHE=0 VIBE_PREOPEN_DIR="$source_dir" \
      VIBE_LIB="$source_dir/lib" VIBE_IMPORT_ABI=raw \
      bash "$runner" --invoke _start "$report_dir/probe.wasm" \
      "$CORPUS" __no_entry__ "$lane" "$stem.wasm"
  ) >"$stem.log" 2>&1 || { cat "$stem.log" >&2; return 1; }
  line="$(grep '^prelude-split-memory ' "$stem.log" || true)"
  [ -n "$line" ] && [ -s "$stem.wasm" ] || { cat "$stem.log" >&2; return 1; }
  printf 'round=%s temperature=%s %s\n' "$round" "$temperature" "$line"
  printf '%s\n' "$line" | awk -v round="$round" -v temp="$temperature" \
    '{ sub("lane=", "", $2); sub("modules=", "", $3); sub("heap_delta=", "", $4); sub("wasm_bytes=", "", $5); printf "%s\t%s\t%s\t%s\t%s\t%s\n", round, temp, $2, $3, $4, $5 }' >>"$report_dir/report.tsv"
  # The edit is a comment, so every temperature must preserve this lane's
  # output. Whole and split can already differ in synthetic helper placement.
  cmp "$report_dir/$round-$lane-cold.wasm" "$stem.wasm"
}
for round in 1 2 3; do
  lanes="whole split"
  if [ "$round" -eq 2 ]; then lanes="split whole"; fi
  for lane in $lanes; do
    cp "$report_dir/leaf.orig" "$source_dir/$LEAF"
    cache_dir="$report_dir/cache-$round-$lane"
    mkdir -p "$cache_dir"
    run_one "$round" "$lane" "$cache_dir" cold
    run_one "$round" "$lane" "$cache_dir" warm
    printf '\n// prelude allocation measurement: one source edit\n' >>"$source_dir/$LEAF"
    run_one "$round" "$lane" "$cache_dir" leaf-edited
    run_one "$round" "$lane" "$cache_dir" edited-warm
  done
done
echo "[prelude-split-memory] report=$report_dir/report.tsv"
