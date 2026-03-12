#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

OUT_DIR="${VIBE_WASM_SOURCE_COVERAGE_DIR:-$PROJECT_ROOT/_build/coverage/wasm-source}"
MODE="${VIBE_WASM_SOURCE_COVERAGE_MODE:-wasm}"
NO_DCE="${VIBE_WASM_SOURCE_COVERAGE_NO_DCE:-0}"
RUN_TESTS="${VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS:-0}"
ALLOW_TRAP="${VIBE_WASM_SOURCE_COVERAGE_ALLOW_TRAP:-0}"
SUMMARY_ONLY_REPORT="${VIBE_WASM_SOURCE_COVERAGE_REPORT_SUMMARY_ONLY:-0}"
REUSE_CACHE="${VIBE_WASM_SOURCE_COVERAGE_REUSE_CACHE:-1}"
INVOKE_EXPORTS="${VIBE_WASM_SOURCE_COVERAGE_INVOKE:-}"
MIN_POINT_RATE="${VIBE_WASM_SOURCE_COVERAGE_MIN_POINT_RATE:-}"
MIN_LINE_RATE="${VIBE_WASM_SOURCE_COVERAGE_MIN_LINE_RATE:-}"
MIN_BRANCH_RATE="${VIBE_WASM_SOURCE_COVERAGE_MIN_BRANCH_RATE:-}"

resolve_vibe_cmd() {
  local candidates=()
  if [ -n "${VIBE_BIN:-}" ] && [ -x "$VIBE_BIN" ]; then
    VIBE_CMD=("$VIBE_BIN")
    return 0
  fi
  candidates+=(
    "$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
    "$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe"
    "$PROJECT_ROOT/target/native/release/build/cmd/vibe/vibe.exe"
    "$PROJECT_ROOT/target/native/debug/build/cmd/vibe/vibe.exe"
  )
  for candidate in "${candidates[@]}"; do
    if [ ! -x "$candidate" ]; then
      continue
    fi
    if [ "$PROJECT_ROOT/moon.mod.json" -nt "$candidate" ]; then
      continue
    fi
    if find "$PROJECT_ROOT/src" -type f \( -name '*.mbt' -o -name 'moon.pkg' \) -newer "$candidate" -print -quit 2>/dev/null | grep -q .; then
      continue
    fi
    VIBE_CMD=("$candidate")
    return 0
  done
  VIBE_CMD=(moon run src/cmd/vibe/main.mbt --target native --)
}

resolve_node_runner_cmd() {
  NODE_RUNNER_CMD=(node)
  if command -v node >/dev/null 2>&1; then
    if node --experimental-wasm-exnref -e "" >/dev/null 2>&1; then
      NODE_RUNNER_CMD+=(--experimental-wasm-exnref)
    fi
  fi
}

cache_key_equals() {
  local path="$1"
  local expected="$2"
  if [ ! -f "$path" ]; then
    return 1
  fi
  [ "$(cat "$path")" = "$expected" ]
}

build_source_dep_signature() {
  node - "$ENTRY_PATH" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const entryPath = path.resolve(process.argv[2]);
const seen = new Set();
const relImportPatterns = [
  /\bimport\s+(\.[^\s{]+)\s*\{/g,
  /\bexport\s+(\.[^\s{]+)\s*\{/g,
];

function stripStringsAndComments(source) {
  let out = "";
  let mode = "code";
  for (let i = 0; i < source.length; i += 1) {
    const ch = source[i];
    const next = i + 1 < source.length ? source[i + 1] : "";
    if (mode === "code") {
      if (ch === "\"") {
        mode = "string";
        out += " ";
        continue;
      }
      if (ch === "/" && next === "/") {
        mode = "line_comment";
        out += "  ";
        i += 1;
        continue;
      }
      out += ch;
      continue;
    }
    if (mode === "string") {
      if (ch === "\\" && i + 1 < source.length) {
        out += "  ";
        i += 1;
        continue;
      }
      if (ch === "\"") {
        mode = "code";
      }
      out += ch === "\n" ? "\n" : " ";
      continue;
    }
    if (mode === "line_comment") {
      if (ch === "\n") {
        mode = "code";
        out += "\n";
      } else {
        out += " ";
      }
    }
  }
  return out;
}

function visit(filePath) {
  const absPath = path.resolve(filePath);
  if (seen.has(absPath)) return;
  let source = "";
  try {
    source = fs.readFileSync(absPath, "utf8");
  } catch {
    return;
  }
  seen.add(absPath);
  const scanSource = stripStringsAndComments(source);
  const baseDir = path.dirname(absPath);
  for (const pattern of relImportPatterns) {
    pattern.lastIndex = 0;
    for (;;) {
      const match = pattern.exec(scanSource);
      if (!match) break;
      const rel = match[1];
      if (!rel) continue;
      const depPath = path.resolve(baseDir, rel);
      visit(depPath);
    }
  }
}

visit(entryPath);
for (const filePath of Array.from(seen).sort()) {
  const stat = fs.statSync(filePath);
  console.log(`${filePath}\t${stat.mtimeMs}\t${stat.size}`);
}
NODE
}

target_is_stale_against_paths() {
  local target="$1"
  shift
  local dep
  for dep in "$@"; do
    if [ -n "$dep" ] && [ -e "$dep" ] && [ "$dep" -nt "$target" ]; then
      return 0
    fi
  done
  return 1
}

load_source_deps() {
  SOURCE_DEP_SIGNATURE=""
  SOURCE_DEPS_READY=0
  if ! SOURCE_DEP_SIGNATURE="$(build_source_dep_signature 2>/dev/null)"; then
    return 0
  fi
  SOURCE_DEPS_READY=1
}

compile_cache_valid() {
  if [ "$REUSE_CACHE" != "1" ] || [ "$SOURCE_DEPS_READY" != "1" ]; then
    return 1
  fi
  if [ ! -f "$wasm_path" ] || [ ! -f "$cov_map_path" ] || [ ! -f "$compile_meta_path" ]; then
    return 1
  fi
  if ! cache_key_equals "$compile_meta_path" "$compile_cache_key"; then
    return 1
  fi
  if [ "$wasm_path" -nt "$cov_map_path" ]; then
    return 1
  fi
  if [ "${VIBE_CMD[0]}" = "moon" ]; then
    if [ "$PROJECT_ROOT/moon.mod.json" -nt "$wasm_path" ]; then
      return 1
    fi
    if find "$PROJECT_ROOT/src" -type f \( -name '*.mbt' -o -name 'moon.pkg' \) -newer "$wasm_path" -print -quit 2>/dev/null | grep -q .; then
      return 1
    fi
  else
    if [ -e "${VIBE_CMD[0]}" ] && [ "${VIBE_CMD[0]}" -nt "$wasm_path" ]; then
      return 1
    fi
  fi
  return 0
}

collect_cache_valid() {
  if [ "$REUSE_CACHE" != "1" ]; then
    return 1
  fi
  if [ ! -f "$report_json_path" ] || [ ! -f "$summary_path" ] || [ ! -f "$collect_meta_path" ]; then
    return 1
  fi
  if ! cache_key_equals "$collect_meta_path" "$collect_cache_key"; then
    return 1
  fi
  if target_is_stale_against_paths "$report_json_path" "$wasm_path" "$cov_map_path" "$SCRIPT_DIR/coverage_wasm_source.mjs"; then
    return 1
  fi
  if target_is_stale_against_paths "$summary_path" "$wasm_path" "$cov_map_path" "$SCRIPT_DIR/coverage_wasm_source.mjs"; then
    return 1
  fi
  return 0
}

if [ "$#" -lt 1 ]; then
  echo "usage: coverage_wasm_source.sh <entry.vibe>" >&2
  echo "env: VIBE_WASM_SOURCE_COVERAGE_MODE=wasm|wasm-js-string VIBE_WASM_SOURCE_COVERAGE_NO_DCE=0|1 VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS=0|1 VIBE_WASM_SOURCE_COVERAGE_ALLOW_TRAP=0|1 VIBE_WASM_SOURCE_COVERAGE_INVOKE=<export[,export...]> VIBE_WASM_SOURCE_COVERAGE_MIN_POINT_RATE=<0-100> VIBE_WASM_SOURCE_COVERAGE_MIN_LINE_RATE=<0-100> VIBE_WASM_SOURCE_COVERAGE_MIN_BRANCH_RATE=<0-100> VIBE_WASM_SOURCE_COVERAGE_DIR=<dir>" >&2
  exit 1
fi

ENTRY_PATH="$1"
if [ ! -f "$ENTRY_PATH" ]; then
  echo "[wasm source coverage] entry not found: $ENTRY_PATH" >&2
  exit 1
fi

case "$MODE" in
  wasm|wasm-js-string) ;;
  *)
    echo "[wasm source coverage] invalid mode: $MODE (expected: wasm|wasm-js-string)" >&2
    exit 1
    ;;
esac

case "$RUN_TESTS" in
  0|1) ;;
  *)
    echo "[wasm source coverage] invalid run-tests flag: $RUN_TESTS (expected: 0|1)" >&2
    exit 1
    ;;
esac

case "$ALLOW_TRAP" in
  0|1) ;;
  *)
    echo "[wasm source coverage] invalid allow-trap flag: $ALLOW_TRAP (expected: 0|1)" >&2
    exit 1
    ;;
esac

case "$SUMMARY_ONLY_REPORT" in
  0|1) ;;
  *)
    echo "[wasm source coverage] invalid summary-only flag: $SUMMARY_ONLY_REPORT (expected: 0|1)" >&2
    exit 1
    ;;
esac

case "$REUSE_CACHE" in
  0|1) ;;
  *)
    echo "[wasm source coverage] invalid reuse-cache flag: $REUSE_CACHE (expected: 0|1)" >&2
    exit 1
    ;;
esac

mkdir -p "$OUT_DIR"
cd "$PROJECT_ROOT"
resolve_vibe_cmd
resolve_node_runner_cmd

entry_norm="${ENTRY_PATH#./}"
if [[ "$entry_norm" == "$PROJECT_ROOT/"* ]]; then
  entry_norm="${entry_norm#$PROJECT_ROOT/}"
fi
entry_stem="${entry_norm%.*}"
entry_slug="${entry_stem//\//__}"
wasm_path="$OUT_DIR/$entry_slug.wasm"
cov_map_path="$wasm_path.cov.json"
report_json_path="$OUT_DIR/$entry_slug.report.json"
summary_path="$OUT_DIR/$entry_slug.summary.txt"
compile_meta_path="$OUT_DIR/$entry_slug.compile.meta"
collect_meta_path="$OUT_DIR/$entry_slug.collect.meta"

load_source_deps

compile_args=(compile "--$MODE" --coverage -o "$wasm_path" "$ENTRY_PATH")
if [ "$NO_DCE" = "1" ]; then
  compile_args=(compile "--$MODE" --no-dce --coverage -o "$wasm_path" "$ENTRY_PATH")
fi
if [ "$RUN_TESTS" = "1" ]; then
  compile_args=(compile "--$MODE" --coverage --coverage-run-tests -o "$wasm_path" "$ENTRY_PATH")
  if [ "$NO_DCE" = "1" ]; then
    compile_args=(compile "--$MODE" --no-dce --coverage --coverage-run-tests -o "$wasm_path" "$ENTRY_PATH")
  fi
fi

compile_cache_key="$(printf 'entry=%s\nmode=%s\nno_dce=%s\nrun_tests=%s\nvibe_cmd=%s\nsource_dep_signature=\n%s' "$ENTRY_PATH" "$MODE" "$NO_DCE" "$RUN_TESTS" "${VIBE_CMD[*]}" "$SOURCE_DEP_SIGNATURE")"
collect_cache_key="$(printf 'allow_trap=%s\nsummary_only=%s\ninvoke=%s\nmin_point=%s\nmin_line=%s\nmin_branch=%s\n' "$ALLOW_TRAP" "$SUMMARY_ONLY_REPORT" "$INVOKE_EXPORTS" "$MIN_POINT_RATE" "$MIN_LINE_RATE" "$MIN_BRANCH_RATE")"

if compile_cache_valid; then
  echo "[wasm source coverage] reuse compile cache: mode=$MODE no_dce=$NO_DCE run_tests=$RUN_TESTS entry=$ENTRY_PATH"
else
  echo "[wasm source coverage] compile: mode=$MODE no_dce=$NO_DCE run_tests=$RUN_TESTS allow_trap=$ALLOW_TRAP entry=$ENTRY_PATH"
  VIBE_TEST_COVERAGE=1 "${VIBE_CMD[@]}" "${compile_args[@]}"
  printf '%s' "$compile_cache_key" >"$compile_meta_path"
fi

if [ ! -f "$cov_map_path" ]; then
  echo "[wasm source coverage] missing coverage map: $cov_map_path" >&2
  exit 1
fi

node_args=(
  "$SCRIPT_DIR/coverage_wasm_source.mjs"
  "$wasm_path"
  "$cov_map_path"
  --json "$report_json_path"
  --summary "$summary_path"
)
if [ "$ALLOW_TRAP" = "1" ]; then
  node_args+=(--allow-trap)
fi
if [ -n "$INVOKE_EXPORTS" ]; then
  IFS=',' read -r -a invoke_list <<< "$INVOKE_EXPORTS"
  for invoke_name in "${invoke_list[@]}"; do
    trimmed="${invoke_name#"${invoke_name%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [ -n "$trimmed" ]; then
      node_args+=(--invoke "$trimmed")
    fi
  done
fi
if [ -n "$MIN_POINT_RATE" ]; then
  node_args+=(--min-point-rate "$MIN_POINT_RATE")
fi
if [ -n "$MIN_LINE_RATE" ]; then
  node_args+=(--min-line-rate "$MIN_LINE_RATE")
fi
if [ -n "$MIN_BRANCH_RATE" ]; then
  node_args+=(--min-branch-rate "$MIN_BRANCH_RATE")
fi
if collect_cache_valid; then
  echo "[wasm source coverage] reuse coverage report cache: entry=$ENTRY_PATH"
  cat "$summary_path"
else
  echo "[wasm source coverage] execute + collect"
  "${NODE_RUNNER_CMD[@]}" "${node_args[@]}"
  printf '%s' "$collect_cache_key" >"$collect_meta_path"
fi

echo "[wasm source coverage] reports:"
echo "  - $summary_path"
echo "  - $report_json_path"
echo "  - $cov_map_path"
