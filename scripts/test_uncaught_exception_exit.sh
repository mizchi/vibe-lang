#!/usr/bin/env bash
# Shell-level regression for #1945. The boundary must survive launchers that
# execute result-less `_start`, and it must agree across linear, wasm-gc, and
# the basic async Component Model wrapper.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

newest_stage2_artifact() {
  local generations_dir="$1"
  ls -t "$generations_dir"/*/stage2.wasm 2>/dev/null | head -1 || true
}

# A bootstrap may leave a newer directory before it publishes stage2.wasm.
# Pin selection to artifact mtimes, not generation-directory mtimes.
selector_regression() {
  local fixture expected got
  fixture="$(mktemp -d "$ROOT_DIR/_build/exception_exit_selector.XXXXXX")"
  mkdir -p "$fixture/old" "$fixture/new" "$fixture/interrupted"
  : >"$fixture/old/stage2.wasm"
  : >"$fixture/new/stage2.wasm"
  touch -t 202601010101 "$fixture/old/stage2.wasm"
  touch -t 202601020101 "$fixture/new/stage2.wasm"
  touch -t 202601030101 "$fixture/interrupted"
  expected="$fixture/new/stage2.wasm"
  got="$(newest_stage2_artifact "$fixture")"
  rm -rf "$fixture"
  if [ "$got" != "$expected" ]; then
    echo "[exception-exit] stage2 selection got '$got', expected '$expected'" >&2
    exit 1
  fi
}

mkdir -p "$ROOT_DIR/_build"
selector_regression

COMPILER="${1:-${VIBE_EXCEPTION_EXIT_COMPILER:-}}"
if [ -z "$COMPILER" ]; then
  COMPILER="$(newest_stage2_artifact "$ROOT_DIR/_build/selfhost/generations")"
fi
[ -f "$COMPILER" ] || { echo "[exception-exit] missing stage2 compiler: $COMPILER" >&2; exit 2; }

WORK="$ROOT_DIR/_build/exception_exit"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/uncaught.vibe" <<'EOF'
fn main() -> Unit with Exception {
  throw("shell boom")
}
EOF
cat >"$WORK/handled.vibe" <<'EOF'
fn main() -> Unit {
  let _ = handle { throw("handled") } with Exception { Throw(_) => () }
}
EOF
cat >"$WORK/explicit.vibe" <<'EOF'
fn main() -> Unit with Process {
  vibe_process_exit_raw(7)
}
EOF

compile_core() {
  local backend="$1" name="$2" out="$WORK/${name}_${backend}.wasm"
  if [ "$backend" = "gc" ]; then
    env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_BACKEND=gc \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$COMPILER" \
      "$WORK/$name.vibe" "$out" main >/dev/null
  else
    env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_FS_COMPILE=1 \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$COMPILER" \
      "$WORK/$name.vibe" "$out" main >/dev/null
  fi
}

run_core() {
  local backend="$1" name="$2" expected="$3"
  local out="$WORK/${name}_${backend}.stdout" err="$WORK/${name}_${backend}.stderr"
  set +e
  bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$WORK/${name}_${backend}.wasm" >"$out" 2>"$err"
  local code=$?
  set -e
  if [ "$code" -ne "$expected" ]; then
    echo "[exception-exit] $backend/$name status=$code, expected $expected" >&2
    sed -n '1,8p' "$err" >&2 || true
    exit 1
  fi
  if [ "$name" = "uncaught" ] && [ "$(head -n 1 "$err")" != "vibe: uncaught error: shell boom" ]; then
    echo "[exception-exit] $backend uncaught diagnostic mismatch" >&2
    sed -n '1,8p' "$err" >&2 || true
    exit 1
  fi
}

for backend in linear gc; do
  for name in uncaught handled explicit; do
    compile_core "$backend" "$name"
  done
  run_core "$backend" uncaught 1
  run_core "$backend" handled 0
  run_core "$backend" explicit 7
done

if command -v wasmtime >/dev/null 2>&1; then
  cat >"$WORK/component.vibe" <<'EOF'
let run: () -> Int with Async + Exception = () -> {
  throw("component boom")
}
EOF
  component="$WORK/component.wasm"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$COMPILER" \
    "$WORK/component.vibe" "$component" run >/dev/null
  set +e
  wasmtime -W exceptions=y -W concurrency-support=y -W component-model-async=y \
    -W component-model-async-stackful=y --invoke 'run()' "$component" \
    >"$WORK/component.stdout" 2>"$WORK/component.stderr"
  component_code=$?
  set -e
  if [ "$component_code" -eq 0 ]; then
    echo "[exception-exit] component uncaught exception exited 0" >&2
    exit 1
  fi
fi

echo "[exception-exit] ok (linear/gc status+diagnostic, handled=0, explicit=7, component non-zero)"
