#!/usr/bin/env bash
# #1539: compile the public StdinStream API from real source, validate its exact
# component boundary, and run lifecycle/wrapper/reacquisition scenarios on the
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
grep -Fq 'fn StdinStream::read_chunk(stream: StdinStream, chunk_size: Int) -> Option[String] with Async' lib/@vibe/console/index.vpkg
if grep -Fq 'fn stdin_stream(' lib/@vibe/console/index.vpkg; then
  echo "stdin provider source gate FAILED: legacy stdin_stream remains public; use StdinStream::read_chunk" >&2
  exit 1
fi
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
cat >"$OUT/early-wrapper.vibe" <<'EOF'
fn acquire() -> StdinStream with Stdin { Stdin::read_via_stream() }
fn next(stream: StdinStream) -> Int with Async { StdinStream::next(stream) }
fn close(stream: StdinStream) -> Unit with Async { StdinStream::close(stream) }

fn run() -> Int with Stdin + Async {
  let stream = acquire()
  let alias = stream
  let a = next(alias)
  close(stream)
  close(alias)
  if a == 10 && next(alias) == -1 { 43 } else { 0 }
}
EOF
cat >"$OUT/top-level-wrappers.vibe" <<'EOF'
fn acquire_wrapper() -> StdinStream with Stdin { Stdin::read_via_stream() }
fn next_wrapper(stream: StdinStream) -> Int with Async { StdinStream::next(stream) }
fn close_wrapper(stream: StdinStream) -> Unit with Async { StdinStream::close(stream) }
fn read_chunk_wrapper(stream: StdinStream, size: Int) -> Option[String] with Async { StdinStream::read_chunk(stream, size) }

fn use_provider() -> Int with Stdin + Async {
  let acquire = acquire_wrapper
  let next = next_wrapper
  let close = close_wrapper
  let read_chunk = read_chunk_wrapper
  let stream = acquire()
  let first = next(stream)
  let chunk = read_chunk(stream, 2)
  close(stream)
  match chunk { Some(s) => if first == 10 && String::length(s) == 2 { 55 } else { 0 }, None => 0 }
}
fn run() -> Int with Stdin + Async { use_provider() }
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
fn next_alias(stream: S) -> Int with Async { S::next(stream) }
fn close_alias(stream: S) -> Unit with Async { S::close(stream) }

fn run() -> Int with Stdin + Async {
  let stream = acquire()
  let first = next_alias(stream)
  close_alias(stream)
  if first == 10 { 46 } else { 0 }
}
EOF
cat >"$OUT/chunk-loop.vibe" <<'EOF'
fn run() -> Int with Stdin + Async {
  let stream = Stdin::read_via_stream()
  let mut index = 0
  let mut ok = true
  let mut done = false
  while done == false {
    match StdinStream::read_chunk(stream, 4) {
      Some(chunk) => {
        if index == 0 {
          ok = ok && String::length(chunk) == 4 && String::char_code_at(chunk, 0) == 0 && String::char_code_at(chunk, 1) == 128 && String::char_code_at(chunk, 2) == 255 && String::char_code_at(chunk, 3) == 65
        } else if index == 1 {
          ok = ok && String::length(chunk) == 1 && String::char_code_at(chunk, 0) == 66
        } else {
          ok = false
        }
        index = index + 1
      },
      None => { done = true }
    }
  }
  let post_eof = StdinStream::read_chunk(stream, 4)
  StdinStream::close(stream)
  StdinStream::close(stream)
  match post_eof {
    None => match StdinStream::read_chunk(stream, 4) {
      None => if ok && index == 2 { 50 } else { 0 },
      Some(_) => 0
    },
    Some(_) => 0
  }
}
EOF
cat >"$OUT/chunk-one-wrapper.vibe" <<'EOF'
fn read_chunk(stream: StdinStream, size: Int) -> Option[String] with Async { StdinStream::read_chunk(stream, size) }

fn run() -> Int with Stdin + Async {
  let stream = Stdin::read_via_stream()
  let a = read_chunk(stream, 1)
  let b = read_chunk(stream, 1)
  let c = read_chunk(stream, 1)
  let d = read_chunk(stream, 1)
  let e = read_chunk(stream, 1)
  let eof1 = read_chunk(stream, 1)
  let eof2 = read_chunk(stream, 1)
  match a {
    Some(sa) => match b {
      Some(sb) => match c {
        Some(sc) => match d {
          Some(sd) => match e {
            Some(se) => match eof1 {
              None => match eof2 {
                None => if String::length(sa) == 1 && String::char_code_at(sa, 0) == 0 && String::char_code_at(sb, 0) == 128 && String::char_code_at(sc, 0) == 255 && String::char_code_at(sd, 0) == 65 && String::char_code_at(se, 0) == 66 { 51 } else { 0 },
                Some(_) => 0
              },
              Some(_) => 0
            },
            None => 0
          },
          None => 0
        },
        None => 0
      },
      None => 0
    },
    None => 0
  }
}
EOF
cat >"$OUT/chunk-zero.vibe" <<'EOF'
fn run() -> Int with Stdin + Async {
  let stream = Stdin::read_via_stream()
  match StdinStream::read_chunk(stream, 0) {
    Some(_) => 0,
    None => match StdinStream::read_chunk(stream, 0) {
      Some(_) => 0,
      None => {
        let first = StdinStream::next(stream)
        StdinStream::close(stream)
        StdinStream::close(stream)
        match StdinStream::read_chunk(stream, 0) { None => if first == 0 { 52 } else { 0 }, Some(_) => 0 }
      }
    }
  }
}
EOF
cat >"$OUT/chunk-negative.vibe" <<'EOF'
fn run() -> Int with Stdin + Async {
  let stream = Stdin::read_via_stream()
  match StdinStream::read_chunk(stream, -7) {
    Some(_) => 0,
    None => {
      let first = StdinStream::next(stream)
      StdinStream::close(stream)
      match StdinStream::read_chunk(stream, -7) { None => if first == 0 { 53 } else { 0 }, Some(_) => 0 }
    }
  }
}
EOF
cat >"$OUT/chunk-early-close.vibe" <<'EOF'
fn run() -> Int with Stdin + Async {
  let stream = Stdin::read_via_stream()
  let first = StdinStream::read_chunk(stream, 4)
  StdinStream::close(stream)
  StdinStream::close(stream)
  match first {
    Some(chunk) => match StdinStream::read_chunk(stream, 4) {
      None => if String::length(chunk) == 4 && String::char_code_at(chunk, 0) == 0 && String::char_code_at(chunk, 3) == 65 { 54 } else { 0 },
      Some(_) => 0
    },
    None => 0
  }
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
fn Stdin::read_via_stream() -> StdinStream with Stdin
fn StdinStream::next(stream: StdinStream) -> Int with Async
fn StdinStream::close(stream: StdinStream) -> Unit with Async
fn StdinStream::read_chunk(stream: StdinStream, chunk_size: Int) -> Option[String] with Async
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
compile_component early-wrapper
compile_component top-level-wrappers
compile_component second
compile_component multiple-active
compile_component import-alias 0 1 1
compile_component chunk-loop
compile_component chunk-one-wrapper
compile_component chunk-zero
compile_component chunk-negative
compile_component chunk-early-close
cp "$OUT/drain.vibe" "$OUT/drain-rc.vibe"
compile_component drain-rc 1
cp "$OUT/chunk-loop.vibe" "$OUT/chunk-loop-rc.vibe"
compile_component chunk-loop-rc 1

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
wasm-tools print "$OUT/chunk-loop.component.wasm" >"$OUT/chunk-loop.wat"
if grep -Fq 'host_stream_get$stdin' "$WAT" "$OUT/chunk-loop.wat" || grep -Fq 'host_stream_read' "$WAT" "$OUT/chunk-loop.wat" || grep -Fq 'host_stream_close' "$WAT" "$OUT/chunk-loop.wat"; then
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
provider_alias_fail() {
  local name="$1" expected="$2"
  actionable_fail "$name" run "$expected" linear 1
  if grep -Fq 'stdin_provider_' "$OUT/$name.wasm.diag"; then
    echo "stdin provider source gate FAILED: $name exposed the raw provider ABI" >&2
    exit 1
  fi
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
cat >"$OUT/read-chunk-effect-direct.vibe" <<'EOF'
fn pure_read_chunk(stream: StdinStream) -> Option[String] {
  StdinStream::read_chunk(stream, 4)
}
fn run() -> Int with Stdin + Async {
  let stream = Stdin::read_via_stream()
  let _ = pure_read_chunk(stream)
  StdinStream::close(stream)
  0
}
EOF
actionable_fail read-chunk-effect-direct run 'effectful call outside effectful context: StdinStream::read_chunk'
cat >"$OUT/read-chunk-effect-alias.vibe" <<'EOF'
fn pure_read_chunk(stream: StdinStream) -> Option[String] {
  let read_chunk = StdinStream::read_chunk
  read_chunk(stream, 4)
}
fn run() -> Int with Stdin + Async {
  let stream = Stdin::read_via_stream()
  let _ = pure_read_chunk(stream)
  StdinStream::close(stream)
  0
}
EOF
actionable_fail read-chunk-effect-alias run 'stdin provider operations are direct-call-only; wrap `StdinStream::read_chunk` in an explicitly effectful function'
cat >"$OUT/top-acquire-value.vibe" <<'EOF'
let acquire_alias = Stdin::read_via_stream
fn run() -> Int { 0 }
EOF
actionable_fail top-acquire-value run 'stdin provider operations are direct-call-only; wrap `Stdin::read_via_stream` in an explicitly effectful function'
for surface in next close read_chunk; do
  case "$surface" in
    next) call='next_alias(stream)'; ret='Int' ;;
    close) call='close_alias(stream)'; ret='Unit' ;;
    read_chunk) call='read_chunk_alias(stream, 4)'; ret='Option[String]' ;;
  esac
  cat >"$OUT/top-$surface-effect-alias.vibe" <<EOF
let ${surface}_alias = StdinStream::$surface
fn pure_alias(stream: StdinStream) -> $ret { $call }
fn run() -> Int with Stdin + Async { let s = Stdin::read_via_stream(); let _ = pure_alias(s); StdinStream::close(s); 0 }
EOF
  actionable_fail "top-$surface-effect-alias" run "stdin provider operations are direct-call-only; wrap \`StdinStream::$surface\` in an explicitly effectful function"
done

# Every opaque transport shape reviewed for the safety blocker must fail in the
# checker with the same actionable direct-call-only diagnostic, before artifact
# creation. The first forbidden provider reference is intentionally identical
# across these fixtures so the assertion also pins deterministic reporting.
cat >"$OUT/value-alias-chain.vibe" <<'EOF'
fn run() -> Int {
  let first = StdinStream::next
  let second = first
  let _ = second
  0
}
EOF
cat >"$OUT/value-conditional.vibe" <<'EOF'
fn run() -> Int {
  let _ = if true { StdinStream::next } else { StdinStream::next }
  0
}
EOF
cat >"$OUT/value-compound.vibe" <<'EOF'
fn run() -> Int {
  let _ = (StdinStream::next, StdinStream::close)
  0
}
EOF
cat >"$OUT/value-return.vibe" <<'EOF'
fn leak() -> (StdinStream) -> Int with Async { StdinStream::next }
fn run() -> Int { 0 }
EOF
cat >"$OUT/value-struct-field.vibe" <<'EOF'
struct Holder { op: (StdinStream) -> Int with Async }
fn run() -> Int {
  let _ = Holder::{ op: StdinStream::next }
  0
}
EOF
cat >"$OUT/value-array-field.vibe" <<'EOF'
fn run() -> Int {
  let _ = [StdinStream::next]
  0
}
EOF
cat >"$OUT/value-map-field.vibe" <<'EOF'
fn run() -> Int {
  let _ = Map::from_pairs([("next", StdinStream::next)])
  0
}
EOF
cat >"$OUT/value-unknown-hof.vibe" <<'EOF'
fn transport(op: (StdinStream) -> Int with Async) -> Int { 0 }
fn run() -> Int { transport(StdinStream::next) }
EOF
for opaque in alias-chain conditional compound return struct-field array-field map-field unknown-hof; do
  actionable_fail "value-$opaque" run 'stdin provider operations are direct-call-only; wrap `StdinStream::next` in an explicitly effectful function'
done

# FS/package merge canonicalizes imported value aliases and qualified type
# heads before the shared compile-boundary validation. Value imports remain
# forbidden even when called directly through their local alias; a type alias
# used as the head of S::next above remains a valid direct call with Async.
cat >"$OUT/fs-type-alias-effect.vibe" <<'EOF'
import @vibe/console { StdinStream as S }
fn run() -> Int with Stdin {
  let stream = Stdin::read_via_stream()
  S::next(stream)
}
EOF
actionable_fail fs-type-alias-effect run 'effectful call outside effectful context: StdinStream::next' linear 1
cat >"$OUT/fs-next-value-alias.vibe" <<'EOF'
import @vibe/console { StdinStream::next as n }
fn run() -> Int with Stdin + Async {
  let stream = Stdin::read_via_stream()
  n(stream)
}
EOF
cat >"$OUT/fs-acquire-value-alias.vibe" <<'EOF'
import @vibe/console { Stdin::read_via_stream as acquire }
fn run() -> Int with Stdin + Async {
  let stream = acquire()
  StdinStream::close(stream)
  0
}
EOF
cat >"$OUT/fs-close-value-alias.vibe" <<'EOF'
import @vibe/console { StdinStream::close as close }
fn run() -> Int with Stdin + Async {
  let stream = Stdin::read_via_stream()
  close(stream)
  0
}
EOF
cat >"$OUT/fs-read-chunk-value-alias.vibe" <<'EOF'
import @vibe/console { StdinStream::read_chunk as read_chunk }
fn run() -> Int with Stdin + Async {
  let stream = Stdin::read_via_stream()
  let _ = read_chunk(stream, 4)
  StdinStream::close(stream)
  0
}
EOF
cat >"$OUT/fs-value-alias-chain.vibe" <<'EOF'
import @vibe/console { StdinStream::next as n }
fn run() -> Int {
  let second = n
  let _ = second
  0
}
EOF
cat >"$OUT/fs-value-alias-container.vibe" <<'EOF'
import @vibe/console { StdinStream::next as n }
fn run() -> Int {
  let _ = [n]
  0
}
EOF
provider_alias_fail fs-next-value-alias 'stdin provider operations are direct-call-only; wrap `StdinStream::next` in an explicitly effectful function'
provider_alias_fail fs-acquire-value-alias 'stdin provider operations are direct-call-only; wrap `Stdin::read_via_stream` in an explicitly effectful function'
provider_alias_fail fs-close-value-alias 'stdin provider operations are direct-call-only; wrap `StdinStream::close` in an explicitly effectful function'
provider_alias_fail fs-read-chunk-value-alias 'stdin provider operations are direct-call-only; wrap `StdinStream::read_chunk` in an explicitly effectful function'
provider_alias_fail fs-value-alias-chain 'stdin provider operations are direct-call-only; wrap `StdinStream::next` in an explicitly effectful function'
provider_alias_fail fs-value-alias-container 'stdin provider operations are direct-call-only; wrap `StdinStream::next` in an explicitly effectful function'

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
cat >"$OUT/chunk-mixed.vibe" <<'EOF'
fn run() -> Int with Stdin + Async { let s = Stdin::read_via_stream(); let _ = host_stream_named("body"); let _ = StdinStream::read_chunk(s, 4); StdinStream::close(s); 0 }
EOF
actionable_fail chunk-mixed run 'mixing stdin-provider imports with named host future/stream imports is not supported'
cat >"$OUT/noncomponent.vibe" <<'EOF'
fn main() -> Int with Stdin + Async { let s = Stdin::read_via_stream(); let _ = StdinStream::read_chunk(s, 4); StdinStream::close(s); 0 }
EOF
actionable_fail noncomponent main 'requires an Async component entry named run'
cat >"$OUT/gc.vibe" <<'EOF'
fn main() -> Int with Stdin + Async { let s = Stdin::read_via_stream(); let _ = StdinStream::read_chunk(s, 4); 0 }
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
# Coverage wins over VIBE_BACKEND. The post-compile boundary must inspect the
# selected lane, not the raw backend selector, or this combination publishes
# the component-private provider core as a standalone artifact.
rm -f "$OUT/import-alias-coverage-gc.wasm" "$OUT/import-alias-coverage-gc.wasm.diag" "$OUT/import-alias-coverage-gc.log"
(cd "$OUT" && VIBE_COVERAGE=1 VIBE_BACKEND=gc VIBE_FS_COMPILE=1 VIBE_LIB="$OUT/pkg" \
  VIBE_PREOPEN_DIR="$ROOT" VIBE_IMPORT_ABI=raw \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" "$OUT/import-alias.vibe" "$OUT/import-alias-coverage-gc.wasm" run \
  >"$OUT/import-alias-coverage-gc.log" 2>&1 || true)
if [ -s "$OUT/import-alias-coverage-gc.wasm" ]; then
  echo "stdin provider source gate FAILED: FS coverage+gc emitted a standalone artifact" >&2
  exit 1
fi
grep -Fq 'StdinStream is component-only; VIBE_COVERAGE=1 cannot emit' "$OUT/import-alias-coverage-gc.wasm.diag"
if grep -Fq 'stdin_provider_' "$OUT/import-alias-coverage-gc.wasm.diag" "$OUT/import-alias-coverage-gc.log"; then
  echo "stdin provider source gate FAILED: FS coverage+gc exposed the raw provider ABI" >&2
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
LEGACY_INPUT="$OUT/legacy-input.bin"
CHUNK_INPUT="$OUT/chunk-input.bin"
printf '\012\017\021' >"$LEGACY_INPUT"
printf '\000\200\377AB' >"$CHUNK_INPUT"
FLAGS=(-Sp3 -W component-model-async=y -W component-model-async-stackful=y -W component-model-more-async-builtins=y)
run_lane() {
  local name="$1" expected="$2" input="${3:-$LEGACY_INPUT}"
  local actual
  actual="$(timeout 60 "$WT" run "${FLAGS[@]}" --invoke 'run()' "$OUT/$name.component.wasm" <"$input")"
  [ "$actual" = "$expected" ] || { echo "stdin provider source gate FAILED: $name expected $expected, got $actual" >&2; exit 1; }
  echo "[stdin-provider-source] $name: $actual"
}
run_lane drain 42
run_lane early-wrapper 43
run_lane top-level-wrappers 55
run_lane second 44
run_lane multiple-active 45
run_lane import-alias 46
run_lane drain-rc 42
run_lane chunk-loop 50 "$CHUNK_INPUT"
run_lane chunk-one-wrapper 51 "$CHUNK_INPUT"
run_lane chunk-zero 52 "$CHUNK_INPUT"
run_lane chunk-negative 53 "$CHUNK_INPUT"
run_lane chunk-early-close 54 "$CHUNK_INPUT"
run_lane chunk-loop-rc 50 "$CHUNK_INPUT"
echo "wasi cli stdin provider source component gate OK (wasmtime 47.0.2)"
