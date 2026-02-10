#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="$ROOT_DIR/target/native/release/build/cmd/xsh/xsh.exe"
OUT_DIR="$ROOT_DIR/target/bench"
WORKLOAD="$OUT_DIR/bench_scratch_workflow_run.sh"

WARMUP="${XSH_BENCH_WARMUP:-3}"
RUNS="${XSH_BENCH_RUNS:-10}"

mkdir -p "$OUT_DIR"
moon build --target native --release src/cmd/xsh

cat >"$WORKLOAD" <<EOF_SCRIPT
#!/usr/bin/env bash
set -euo pipefail

CLI_BIN="$CLI_BIN"
TMP_DIR="\$(mktemp -d /tmp/xsh_bench_scratch_XXXXXX)"
DB_PATH="\$TMP_DIR/tmp1.db"
OUT_PATH="\$TMP_DIR/main.xsh"
trap 'rm -rf "\$TMP_DIR"' EXIT

"\$CLI_BIN" eval --db="\$DB_PATH" "let base = 40" >/dev/null
"\$CLI_BIN" eval --db="\$DB_PATH" "let inc = (x: Int) -> Int { x + base }" >/dev/null
"\$CLI_BIN" eval --db="\$DB_PATH" "let answer = inc(2)" >/dev/null
"\$CLI_BIN" eval --db="\$DB_PATH" "answer" >/dev/null
"\$CLI_BIN" eval --db="\$DB_PATH" "export { answer }" >/dev/null
"\$CLI_BIN" finalize --db="\$DB_PATH" --library --export="\$OUT_PATH" >/dev/null
EOF_SCRIPT
chmod +x "$WORKLOAD"

if command -v hyperfine >/dev/null 2>&1; then
  hyperfine --warmup "$WARMUP" --runs "$RUNS" "$WORKLOAD"
else
  echo "hyperfine not found; using /usr/bin/time (${RUNS} runs)"
  for _ in $(seq 1 "$RUNS"); do
    /usr/bin/time -p "$WORKLOAD"
  done
fi
