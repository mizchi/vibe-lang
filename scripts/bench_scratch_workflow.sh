#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="$ROOT_DIR/target/native/release/build/cmd/xsh/xsh.exe"
OUT_DIR="$ROOT_DIR/target/bench"
RUN_EVAL="$OUT_DIR/bench_scratch_eval.sh"
RUN_FINALIZE="$OUT_DIR/bench_scratch_finalize.sh"
RUN_EXPORT_APPLY="$OUT_DIR/bench_scratch_export_apply.sh"
RUN_FULL="$OUT_DIR/bench_scratch_full.sh"
SEED_SOURCE="$OUT_DIR/bench_scratch_seed.xsh"

WARMUP="${XSH_BENCH_WARMUP:-3}"
RUNS="${XSH_BENCH_RUNS:-10}"
CHAIN="${XSH_BENCH_CHAIN:-40}"
SCENARIOS="${XSH_BENCH_SCENARIOS:-all}"
EXPORT_JSON="${XSH_BENCH_EXPORT_JSON:-$OUT_DIR/bench_scratch_workflow.hyperfine.json}"

mkdir -p "$OUT_DIR"
moon build --target native --release src/cmd/xsh

write_seed_source() {
  local out_path="$1"
  {
    echo "let v0 = 0"
    for i in $(seq 1 "$CHAIN"); do
      local prev=$((i - 1))
      echo "let v$i = v$prev + 1"
    done
    echo "v$CHAIN"
    echo "test \"v$CHAIN\" { assert(v$CHAIN == $CHAIN) }"
    echo "export { v$CHAIN }"
  } >"$out_path"
}

write_seed_source "$SEED_SOURCE"

cat >"$RUN_EVAL" <<EOF_SCRIPT
#!/usr/bin/env bash
set -euo pipefail

CLI_BIN="$CLI_BIN"
TMP_DIR="\$(mktemp -d /tmp/xsh_bench_scratch_XXXXXX)"
DB_PATH="\$TMP_DIR/tmp1.db"
trap 'rm -rf "\$TMP_DIR"' EXIT

"\$CLI_BIN" eval --db="\$DB_PATH" "let v0 = 0" >/dev/null
for i in \$(seq 1 "$CHAIN"); do
  prev=\$((i - 1))
  "\$CLI_BIN" eval --db="\$DB_PATH" "let v\$i = v\$prev + 1" >/dev/null
done
"\$CLI_BIN" eval --db="\$DB_PATH" "v$CHAIN" >/dev/null
"\$CLI_BIN" eval --db="\$DB_PATH" "export { v$CHAIN }" >/dev/null
EOF_SCRIPT

cat >"$RUN_FINALIZE" <<EOF_SCRIPT
#!/usr/bin/env bash
set -euo pipefail

CLI_BIN="$CLI_BIN"
SEED_SOURCE="$SEED_SOURCE"
TMP_DIR="\$(mktemp -d /tmp/xsh_bench_scratch_XXXXXX)"
DB_PATH="\$TMP_DIR/tmp1.db"
trap 'rm -rf "\$TMP_DIR"' EXIT

cp "\$SEED_SOURCE" "\$DB_PATH"
"\$CLI_BIN" finalize --db="\$DB_PATH" --library >/dev/null
EOF_SCRIPT

cat >"$RUN_EXPORT_APPLY" <<EOF_SCRIPT
#!/usr/bin/env bash
set -euo pipefail

CLI_BIN="$CLI_BIN"
SEED_SOURCE="$SEED_SOURCE"
TMP_DIR="\$(mktemp -d /tmp/xsh_bench_scratch_XXXXXX)"
DB_PATH="\$TMP_DIR/tmp1.db"
OUT_PATH="\$TMP_DIR/main.xsh"
trap 'rm -rf "\$TMP_DIR"' EXIT

cp "\$SEED_SOURCE" "\$DB_PATH"
"\$CLI_BIN" finalize --db="\$DB_PATH" --library --export="\$OUT_PATH" >/dev/null
"\$CLI_BIN" fetch "\$OUT_PATH" >/dev/null
"\$CLI_BIN" apply "\$OUT_PATH" >/dev/null
EOF_SCRIPT

cat >"$RUN_FULL" <<EOF_SCRIPT
#!/usr/bin/env bash
set -euo pipefail

CLI_BIN="$CLI_BIN"
TMP_DIR="\$(mktemp -d /tmp/xsh_bench_scratch_XXXXXX)"
DB_PATH="\$TMP_DIR/tmp1.db"
OUT_PATH="\$TMP_DIR/main.xsh"
trap 'rm -rf "\$TMP_DIR"' EXIT

"\$CLI_BIN" eval --db="\$DB_PATH" "let v0 = 0" >/dev/null
for i in \$(seq 1 "$CHAIN"); do
  prev=\$((i - 1))
  "\$CLI_BIN" eval --db="\$DB_PATH" "let v\$i = v\$prev + 1" >/dev/null
done
"\$CLI_BIN" eval --db="\$DB_PATH" "export { v$CHAIN }" >/dev/null
"\$CLI_BIN" finalize --db="\$DB_PATH" --library --export="\$OUT_PATH" >/dev/null
"\$CLI_BIN" fetch "\$OUT_PATH" >/dev/null
"\$CLI_BIN" apply "\$OUT_PATH" >/dev/null
EOF_SCRIPT

chmod +x "$RUN_EVAL" "$RUN_FINALIZE" "$RUN_EXPORT_APPLY" "$RUN_FULL"

declare -a bench_names
declare -a bench_cmds

append_case() {
  local name="$1"
  local cmd="$2"
  bench_names+=("$name")
  bench_cmds+=("$cmd")
}

select_case() {
  local key="$1"
  case "$key" in
    eval)
      append_case "scratch-eval" "$RUN_EVAL"
      ;;
    finalize)
      append_case "scratch-finalize" "$RUN_FINALIZE"
      ;;
    export_apply)
      append_case "scratch-export-apply" "$RUN_EXPORT_APPLY"
      ;;
    full)
      append_case "scratch-full" "$RUN_FULL"
      ;;
    *)
      echo "unknown scenario: $key" >&2
      echo "valid scenarios: eval, finalize, export_apply, full, all" >&2
      exit 1
      ;;
  esac
}

if [ "$SCENARIOS" = "all" ]; then
  select_case "eval"
  select_case "finalize"
  select_case "export_apply"
  select_case "full"
else
  IFS=',' read -r -a requested <<<"$SCENARIOS"
  for key in "${requested[@]}"; do
    select_case "$key"
  done
fi

if [ "${#bench_cmds[@]}" -eq 0 ]; then
  echo "no benchmark scenario selected" >&2
  exit 1
fi

if command -v hyperfine >/dev/null 2>&1; then
  hyperfine_args=(--warmup "$WARMUP" --runs "$RUNS")
  if [ -n "$EXPORT_JSON" ]; then
    hyperfine_args+=(--export-json "$EXPORT_JSON")
  fi
  for i in "${!bench_cmds[@]}"; do
    hyperfine_args+=(-n "${bench_names[$i]}" "${bench_cmds[$i]}")
  done
  hyperfine "${hyperfine_args[@]}"
  if [ -n "$EXPORT_JSON" ]; then
    echo "saved: $EXPORT_JSON"
  fi
else
  echo "hyperfine not found; using /usr/bin/time (${RUNS} runs)"
  for i in "${!bench_cmds[@]}"; do
    echo "[${bench_names[$i]}]"
    for _ in $(seq 1 "$RUNS"); do
      /usr/bin/time -p "${bench_cmds[$i]}"
    done
  done
fi
