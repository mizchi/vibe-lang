#!/usr/bin/env bash
# Guest future primitives must fail with an actionable GC-lane diagnosis.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
. scripts/resolve_stage2.sh
STAGE2="$(resolve_stage2 gc-future-refusal "${VIBE_STAGE2_WASM:-}")"
TMP="$(mktemp -d "$ROOT_DIR/_build/gc_future_refusal.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

compile_gc() {
  local src="$1" out="$2" entry="${3:-main}"
  rm -f "$out" "$out.diag"
  env VIBE_FS_COMPILE=1 VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    "${src#"$ROOT_DIR"/}" "${out#"$ROOT_DIR"/}" "$entry" >/dev/null 2>&1 || true
}

expect_refusal() {
  local name="$1" source="$2" needle="$3"
  local src="$TMP/$name.vibe" out="$TMP/$name.wasm"
  printf '%s\n' "$source" > "$src"
  compile_gc "$src" "$out"
  if [ -s "$out" ] || ! grep -qF 'compile with the linear or RC backend' "$out.diag" || ! grep -qF "$needle" "$out.diag"; then
    echo "gc-future-refusal: FAIL ($name): expected a GC-lane future diagnostic" >&2
    cat "$out.diag" >&2 2>/dev/null || true
    exit 1
  fi
}

expect_refusal ready 'fn main() -> Int { let _ = Future::ready(42); 0 }' 'Future::ready'
expect_refusal pending 'fn main() -> Int { let _: Future[Int] = Future::pending(); 0 }' 'Future::pending'
expect_refusal resolve 'fn complete(f: Future[Int]) -> Int { Future::resolve(f, 42); 0 }
fn main() -> Int { 0 }' 'Future::resolve'
expect_refusal await 'fn take(f: Future[Int]) -> Int with Async { await(f) }
fn main() -> Int { 0 }' 'await'
expect_refusal lambda_ready 'fn main() -> Int { let f = () -> { let _ = Future::ready(42); 0 }; f() }' 'Future::ready'
expect_refusal lambda_await 'fn take(f: Future[Int]) -> Int with Async {
  let g = () -> Int with Async { await(f) }
  g()
}
fn main() -> Int { 0 }' 'await'

# A user's own spelling is a normal call, even when it matches a builtin name.
src="$TMP/user_names.vibe"
out="$TMP/user_names.wasm"
cat > "$src" <<'VIBE'
fn Future::ready(x: Int) -> Int { x + 1 }
fn through_match() -> Int {
  match Some((x: Int) -> x + 1) {
    Some(await) => await(0),
    None => 0
  }
}
fn main() -> Int {
  let await = (x: Int) -> x + 1
  through_match() + await(Future::ready(39))
}
VIBE
compile_gc "$src" "$out"
if [ ! -s "$out" ]; then
  echo 'gc-future-refusal: FAIL: user-defined names were rejected' >&2
  cat "$out.diag" >&2 2>/dev/null || true
  exit 1
fi
got="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$out" 2>/dev/null | tr -dc '0-9')"
if [ "$got" != 42 ]; then
  echo "gc-future-refusal: FAIL: user-defined names returned $got (want 42)" >&2
  exit 1
fi
echo 'gc-future-refusal: ok'
