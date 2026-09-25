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
fn main() -> Unit allows Exception {
  throw("shell boom")
}
EOF
cat >"$WORK/handled.vibe" <<'EOF'
fn main() -> Unit {
  let _ = handle { throw("handled") } with Exception { Throw(_) => () }
}
EOF
cat >"$WORK/explicit.vibe" <<'EOF'
fn main() -> Unit allows Process {
  vibe_process_exit_raw(7)
}
EOF

compile_core() {
  # Two statements: bash expands every word of one `local` before assigning
  # any, so `out` would read the caller's `name`/`backend`, not these.
  local backend="$1" name="$2"
  local out="$WORK/${name}_${backend}.wasm"
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

# #3023: `vibe run` (scripts/vibe_run.sh) and the node runner invoke the entry
# export DIRECTLY, without `_start`. The gc lane used to initialize computed
# module-level values only in `_start`, so a direct `main` invoke read zero
# globals: the entry boundary's exception-kind cell was address 0 and the
# uncaught throw below trapped `memory access out of bounds` after `before`
# instead of printing the diagnosis. `entry_module_value` pins the same init without an exception: it
# printed `0` instead of `20`, silently.
cat >"$WORK/entry_uncaught.vibe" <<'EOF'
fn main() -> Unit allows Exception + Console {
  println("before")
  throw("boom")
}
EOF
cat >"$WORK/entry_module_value.vibe" <<'EOF'
let table = [10, 20, 30]

fn main() -> Unit allows Console {
  println("\{Array::get(table, 1)}")
}
EOF

run_entry() {
  local backend="$1" name="$2" expected="$3" want_out="$4" want_err="$5"
  local out="$WORK/${name}_${backend}.entry.stdout" err="$WORK/${name}_${backend}.entry.stderr"
  set +e
  bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$WORK/${name}_${backend}.wasm" >"$out" 2>"$err"
  local code=$?
  set -e
  if [ "$code" -ne "$expected" ] || [ "$(head -n 1 "$out")" != "$want_out" ] ||
    [ "$(head -n 1 "$err")" != "$want_err" ]; then
    echo "[exception-exit] $backend/$name via --invoke main: status=$code (want $expected)" >&2
    echo "  stdout: $(cat "$out")" >&2
    sed -n '1,8p' "$err" >&2 || true
    exit 1
  fi
}

for backend in linear gc; do
  compile_core "$backend" entry_uncaught
  compile_core "$backend" entry_module_value
  run_entry "$backend" entry_uncaught 1 "before" "vibe: uncaught error: boom"
  run_entry "$backend" entry_module_value 0 "20" ""
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

# #3022 review: the self-contained async wrap serves `process_exit` with a
# trapping stub, which is right only for the boundary's failing exit. An exit
# the program writes itself -- here beside its own stderr write, so the import
# section looks exactly like the boundary's -- must be refused at build time
# rather than turn `exit(0)` into a trap.
cat >"$WORK/component_exit.vibe" <<'EOF'
let run: () -> Int with Async + Process + Stderr = () -> {
  if 1 == 2 {
    Stderr::write_stream("bad\n")
  } else {
    ()
  }
  vibe_process_exit_raw(0)
  0
}
EOF
component_exit="$WORK/component_exit.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$COMPILER" \
  "$WORK/component_exit.vibe" "$component_exit" run >/dev/null 2>&1 || true
if [ -s "$component_exit" ]; then
  echo "[exception-exit] async component with a program-written exit was built (its exit would trap)" >&2
  exit 1
fi
if ! grep -q "the program calls the host exit" "$component_exit.diag" 2>/dev/null; then
  echo "[exception-exit] async component exit refusal did not name the edit" >&2
  cat "$component_exit.diag" >&2 2>/dev/null || true
  exit 1
fi

# #3030: a binding the program itself names `vibe_process_exit_raw` is that
# binding, not the host exit, so it does not refuse the build.
cat >"$WORK/component_exit_local.vibe" <<'EOF'
let run: () -> Int with Async = () -> {
  let vibe_process_exit_raw = 3
  vibe_process_exit_raw + 4
}
EOF
component_exit_local="$WORK/component_exit_local.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$COMPILER" \
  "$WORK/component_exit_local.vibe" "$component_exit_local" run >/dev/null 2>&1 || true
if [ ! -s "$component_exit_local" ]; then
  echo "[exception-exit] async component with a local named vibe_process_exit_raw was refused" >&2
  cat "$component_exit_local.diag" >&2 2>/dev/null || true
  exit 1
fi

echo "[exception-exit] ok (linear/gc status+diagnostic via _start and main, handled=0, explicit=7, component non-zero, component user exit refused, local of that name built)"
