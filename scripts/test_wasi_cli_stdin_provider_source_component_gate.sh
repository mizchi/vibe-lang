#!/usr/bin/env bash
# #1539: compile the public StdinStream API from real source, validate its exact
# component boundary, and run lifecycle/alias/reacquisition scenarios on the
# pinned Wasmtime 47 lane.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"
OUT="$ROOT/_build/bench/wasi_cli_stdin_provider_source"
rm -rf "$OUT"
mkdir -p "$OUT"

COMPILER="${VIBE_STDIN_PROVIDER_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  COMPILER="$(find _build/selfhost/generations -name stage2.wasm -type f 2>/dev/null | sort | tail -1 || true)"
fi
[ -n "$COMPILER" ] && [ -s "$COMPILER" ] || COMPILER="$(find _build/ci-artifacts -name stage2.wasm -type f 2>/dev/null | head -1 || true)"
[ -n "$COMPILER" ] && [ -s "$COMPILER" ] || COMPILER="$ROOT/bootstrap/seed/compiler.wasm"
[ -s "$COMPILER" ] || { echo "stdin provider source gate FAILED: no compiler" >&2; exit 1; }
COMPILER="$(cd "$(dirname "$COMPILER")" && pwd)/$(basename "$COMPILER")"
command -v wasm-tools >/dev/null 2>&1 || { echo "stdin provider source gate FAILED: wasm-tools is required" >&2; exit 1; }
grep -Fq 'type StdinStream' lib/@vibe/console/index.vpkg
grep -Fq 'fn Stdin::read_via_stream() -> StdinStream with Stdin' lib/@vibe/console/index.vpkg
grep -Fq 'fn StdinStream::next(stream: StdinStream) -> Int with Async' lib/@vibe/console/index.vpkg
grep -Fq 'fn StdinStream::close(stream: StdinStream) -> Unit with Async' lib/@vibe/console/index.vpkg
if grep -Fq 'vibe_stdin_provider_' lib/@vibe/console/index.vpkg; then
  echo "stdin provider source gate FAILED: raw names leaked into console contract" >&2
  exit 1
fi

cat >"$OUT/drain.vibe" <<'EOF'
fn run() -> Int with Stdin + Async {
  let stream = Stdin::read_via_stream()
  let alias = stream
  let a = StdinStream::next(alias)
  let b = StdinStream::next(stream)
  let c = StdinStream::next(alias)
  let eof1 = StdinStream::next(stream)
  let eof2 = StdinStream::next(alias)
  StdinStream::close(stream)
  if a == 10 && b == 15 && c == 17 && eof1 == -1 && eof2 == -1 { 42 } else { 0 }
}
EOF
cat >"$OUT/early-alias.vibe" <<'EOF'
fn run() -> Int with Stdin + Async {
  let acquire = Stdin::read_via_stream
  let next = StdinStream::next
  let close = StdinStream::close
  let stream = acquire()
  let alias = stream
  let a = next(alias)
  close(stream)
  close(alias)
  if a == 10 && next(alias) == -1 { 43 } else { 0 }
}
EOF
cat >"$OUT/second.vibe" <<'EOF'
fn run() -> Int with Stdin + Async {
  let first = Stdin::read_via_stream()
  let a = StdinStream::next(first)
  StdinStream::close(first)
  let second = Stdin::read_via_stream()
  let b = StdinStream::next(second)
  StdinStream::close(second)
  if a == 10 && b == 15 { 44 } else { 0 }
}
EOF
cat >"$OUT/multiple-active.vibe" <<'EOF'
fn run() -> Int with Stdin + Async {
  let first = Stdin::read_via_stream()
  let second = Stdin::read_via_stream()
  let a = StdinStream::next(first)
  let b = StdinStream::next(second)
  StdinStream::close(first)
  StdinStream::close(second)
  if a == 10 && b == 15 { 45 } else { 0 }
}
EOF
cat >"$OUT/import-alias.vibe" <<'EOF'
import @vibe/console { StdinStream as S }

fn acquire() -> StdinStream with Stdin { Stdin::read_via_stream() }
fn next_alias(stream: S) -> Int with Async { StdinStream::next(stream) }
fn close_alias(stream: S) -> Unit with Async { StdinStream::close(stream) }

fn run() -> Int with Stdin + Async {
  let stream = acquire()
  let first = next_alias(stream)
  close_alias(stream)
  if first == 10 { 46 } else { 0 }
}
EOF
# Isolated minimal contract fixture: preserve the exact public package spelling
# while avoiding unrelated @vibe/console implementation imports in this
# component-composer test. The type is still compiler-owned (no source body).
mkdir -p "$OUT/pkg/@vibe/console"
cat >"$OUT/pkg/@vibe/console/index.vpkg" <<'EOF'
name = @vibe/console
version = 0.0.1
deps = {}

generated_hash =

type StdinStream
EOF

compile_component() {
  local name="$1" rc="${2:-0}" fs="${3:-0}" isolated="${4:-0}"
  rm -f "$OUT/$name.component.wasm" "$OUT/$name.component.wasm.diag"
  local -a envs=(VIBE_RC="$rc" VIBE_PREOPEN_DIR="$ROOT" VIBE_IMPORT_ABI=raw)
  [ "$fs" != 1 ] || envs+=(VIBE_FS_COMPILE=1)
  if [ "$isolated" = 1 ]; then
    (cd "$OUT" && env "${envs[@]}" VIBE_LIB="$OUT/pkg" \
      bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
      "$COMPILER" "$OUT/$name.vibe" "$OUT/$name.component.wasm" run >/dev/null)
  else
    env "${envs[@]}" bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
      "$COMPILER" "$OUT/$name.vibe" "$OUT/$name.component.wasm" run >/dev/null
  fi
  [ -s "$OUT/$name.component.wasm" ] || { cat "$OUT/$name.component.wasm.diag" >&2 || true; exit 1; }
  [ "$(od -A n -t x1 -N 8 "$OUT/$name.component.wasm" | awk '{print $5}')" = "0d" ]
  wasm-tools validate --features all "$OUT/$name.component.wasm"
}
compile_component drain
compile_component early-alias
compile_component second
compile_component multiple-active
compile_component import-alias 0 1 1
cp "$OUT/drain.vibe" "$OUT/drain-rc.vibe"
compile_component drain-rc 1

WIT="$OUT/drain.wit"
WAT="$OUT/drain.wat"
wasm-tools component wit "$OUT/drain.component.wasm" >"$WIT"
wasm-tools print "$OUT/drain.component.wasm" >"$WAT"
grep -Fq 'import wasi:cli/types@0.3.0;' "$WIT"
grep -Fq 'import wasi:cli/stdin@0.3.0;' "$WIT"
grep -Fq 'read-via-stream: func() -> tuple<stream<u8>, future<result<_, error-code>>>;' "$WIT"
grep -Fq 'stdin_provider_acquire' "$WAT"
grep -Fq 'stdin_provider_read' "$WAT"
grep -Fq 'stdin_provider_close' "$WAT"
if grep -Fq 'host_stream_get$stdin' "$WAT" || grep -Fq 'host_stream_read' "$WAT" || grep -Fq 'host_stream_close' "$WAT"; then
  echo "stdin provider source gate FAILED: generic HostStream route leaked" >&2
  exit 1
fi

actionable_fail() {
  local name="$1" entry="$2" expected="$3" backend="${4:-linear}" fs="${5:-0}"
  rm -f "$OUT/$name.wasm" "$OUT/$name.wasm.diag"
  local -a envs=(VIBE_LIB="$ROOT/lib" VIBE_PREOPEN_DIR="$ROOT" VIBE_IMPORT_ABI=raw)
  [ "$backend" != gc ] || envs+=(VIBE_BACKEND=gc)
  [ "$fs" != 1 ] || envs+=(VIBE_FS_COMPILE=1)
  env "${envs[@]}" bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
    "$COMPILER" "$OUT/$name.vibe" "$OUT/$name.wasm" "$entry" >/dev/null 2>&1 || true
  if [ -s "$OUT/$name.wasm" ]; then
    echo "stdin provider source gate FAILED: negative $name compiled" >&2
    exit 1
  fi
  grep -Fq "$expected" "$OUT/$name.wasm.diag" || { echo "stdin provider source gate FAILED: $name diagnostic" >&2; cat "$OUT/$name.wasm.diag" >&2 || true; exit 1; }
}
cat >"$OUT/raw.vibe" <<'EOF'
fn run() -> Int with Async { vibe_stdin_provider_acquire_raw() }
EOF
actionable_fail raw run 'unknown name: vibe_stdin_provider_acquire_raw'
cat >"$OUT/acquire-effect.vibe" <<'EOF'
fn run() -> Int { let _ = Stdin::read_via_stream(); 0 }
EOF
actionable_fail acquire-effect run 'missing { Stdin::read_via_stream }'
cat >"$OUT/next-effect.vibe" <<'EOF'
fn run() -> Int with Stdin { let s = Stdin::read_via_stream(); StdinStream::next(s) }
EOF
actionable_fail next-effect run 'effectful call outside effectful context: StdinStream::next'
cat >"$OUT/nominal.vibe" <<'EOF'
fn run() -> Int with Async { StdinStream::next(1) }
EOF
actionable_fail nominal run 'expected StdinStream, got Int'
cat >"$OUT/alias-forgery.vibe" <<'EOF'
import @vibe/console { StdinStream as S }
struct Fake { value: Int }
fn consume(stream: S) -> Int with Async { StdinStream::next(stream) }
fn run() -> Int with Async { consume(Fake::{ value: 1 }) }
EOF
actionable_fail alias-forgery run 'expected StdinStream, got Fake' linear 1
cat >"$OUT/reserved.vibe" <<'EOF'
fn run() -> Int with Async { let _ = host_stream_named("stdin"); 0 }
EOF
actionable_fail reserved run 'host_stream_named("stdin") is reserved; use Stdin::read_via_stream()'
cat >"$OUT/mixed.vibe" <<'EOF'
fn run() -> Int with Stdin + Async { let s = Stdin::read_via_stream(); let _ = host_stream_named("body"); StdinStream::close(s); 0 }
EOF
actionable_fail mixed run 'mixing stdin-provider imports with named host future/stream imports is not supported'
cat >"$OUT/noncomponent.vibe" <<'EOF'
fn main() -> Int with Stdin + Async { let s = Stdin::read_via_stream(); StdinStream::close(s); 0 }
EOF
actionable_fail noncomponent main 'requires an Async component entry named run'
cat >"$OUT/gc.vibe" <<'EOF'
fn main() -> Int with Stdin { let _ = Stdin::read_via_stream(); 0 }
EOF
actionable_fail gc main 'StdinStream is unsupported on gc backend' gc
cat >"$OUT/coverage.vibe" <<'EOF'
fn run() -> Int with Stdin + Async {
  let stream = Stdin::read_via_stream()
  StdinStream::close(stream)
  0
}
EOF
rm -f "$OUT/coverage.wasm" "$OUT/coverage.wasm.diag" "$OUT/coverage.log"
VIBE_COVERAGE=1 VIBE_PREOPEN_DIR="$ROOT" VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" "$OUT/coverage.vibe" "$OUT/coverage.wasm" run \
  >"$OUT/coverage.log" 2>&1 || true
if [ -s "$OUT/coverage.wasm" ]; then
  echo "stdin provider source gate FAILED: coverage emitted a standalone artifact" >&2
  exit 1
fi
grep -Fq 'StdinStream is component-only; VIBE_COVERAGE=1 cannot emit' "$OUT/coverage.wasm.diag"
if grep -Fq 'stdin_provider_' "$OUT/coverage.wasm.diag" "$OUT/coverage.log"; then
  echo "stdin provider source gate FAILED: coverage exposed the raw provider ABI" >&2
  exit 1
fi
# The import-resolving file lane is a second preprocess bypass. Exercise it
# against the exact aliased public contract and require the same no-artifact,
# no-raw-ABI result before cli_adapter can write the instrumented core.
rm -f "$OUT/import-alias-coverage.wasm" "$OUT/import-alias-coverage.wasm.diag" "$OUT/import-alias-coverage.log"
(cd "$OUT" && VIBE_COVERAGE=1 VIBE_FS_COMPILE=1 VIBE_LIB="$OUT/pkg" \
  VIBE_PREOPEN_DIR="$ROOT" VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" "$OUT/import-alias.vibe" "$OUT/import-alias-coverage.wasm" run \
  >"$OUT/import-alias-coverage.log" 2>&1 || true)
if [ -s "$OUT/import-alias-coverage.wasm" ]; then
  echo "stdin provider source gate FAILED: FS coverage emitted a standalone artifact" >&2
  exit 1
fi
grep -Fq 'StdinStream is component-only; VIBE_COVERAGE=1 cannot emit' "$OUT/import-alias-coverage.wasm.diag"
if grep -Fq 'stdin_provider_' "$OUT/import-alias-coverage.wasm.diag" "$OUT/import-alias-coverage.log"; then
  echo "stdin provider source gate FAILED: FS coverage exposed the raw provider ABI" >&2
  exit 1
fi

echo "[stdin-provider-source] source compile/structure/negative gates OK"
WT="${WASMTIME_BIN:-$(command -v wasmtime || true)}"
VERSION="$([ -n "$WT" ] && "$WT" --version 2>/dev/null || true)"
if [[ "$VERSION" != "wasmtime 47.0.2"* ]]; then
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = 1 ]; then
    echo "stdin provider source gate FAILED: requires wasmtime 47.0.2, got ${VERSION:-unavailable}" >&2
    exit 1
  fi
  echo "[stdin-provider-source] runtime SKIP: requires wasmtime 47.0.2, got ${VERSION:-unavailable}"
  exit 0
fi
INPUT="$OUT/input.bin"
printf '\012\017\021' >"$INPUT"
FLAGS=(-Sp3 -W component-model-async=y -W component-model-async-stackful=y -W component-model-more-async-builtins=y)
run_lane() {
  local name="$1" expected="$2"
  local actual
  actual="$(timeout 60 "$WT" run "${FLAGS[@]}" --invoke 'run()' "$OUT/$name.component.wasm" <"$INPUT")"
  [ "$actual" = "$expected" ] || { echo "stdin provider source gate FAILED: $name expected $expected, got $actual" >&2; exit 1; }
  echo "[stdin-provider-source] $name: $actual"
}
run_lane drain 42
run_lane early-alias 43
run_lane second 44
run_lane multiple-active 45
run_lane import-alias 46
run_lane drain-rc 42
echo "wasi cli stdin provider source component gate OK (wasmtime 47.0.2)"
