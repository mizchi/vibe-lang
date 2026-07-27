#!/usr/bin/env bash
# #906 Phase 2 (real-build wiring): end-to-end proof that
# scripts/parallel_frontend_warm.mjs's cache pre-warm never changes what a
# real compile produces, and that it actually warms the persistent cache
# rather than silently no-op'ing.
#
# This intentionally does NOT go through runtime/vibe (which needs the
# vibewt Rust runner built) -- it drives the exact same VIBE_FS_COMPILE=1
# invocation compile_to() uses, directly against the Node runner, mirroring
# how every other scripts/test_*.sh in this repo exercises the compiler.
#
# Usage: bash scripts/test_parallel_frontend_warm.sh [stage2.wasm]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

COMPILER_WASM="${1:-}"
if [ -z "$COMPILER_WASM" ]; then
  short_sha="$(git rev-parse --short HEAD)"
  compiler_inputs_dirty="$(
    git status --porcelain -- \
      lib/@vibe/compiler \
      lib/@vibe/cli \
      bootstrap/seed.json \
      scripts/generate_bundle.sh \
      scripts/generations.sh
  )"
  if [ -z "$compiler_inputs_dirty" ]; then
    COMPILER_WASM="$(
      find _build/selfhost/generations \
        -path "*_${short_sha}/stage2.wasm" -type f -print 2>/dev/null \
        | head -n 1
    )"
  fi
fi
if [ -z "$COMPILER_WASM" ] || [ ! -s "$COMPILER_WASM" ]; then
  out_dir="$PROJECT_ROOT/_build/parallel_frontend_warm_selfhost"
  echo "[jobs-warm] building current stage2 compiler" >&2
  bash scripts/generations.sh build --out-dir "$out_dir" >/dev/null
  COMPILER_WASM="$out_dir/stage2.wasm"
fi
[ -s "$COMPILER_WASM" ] || { echo "[jobs-warm] compiler not found: $COMPILER_WASM" >&2; exit 1; }
COMPILER_WASM="$(cd "$(dirname "$COMPILER_WASM")" && pwd)/$(basename "$COMPILER_WASM")"

RUNNER="$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh"
DRIVER="$PROJECT_ROOT/scripts/parallel_frontend_warm.mjs"
FIXTURE_DIR="$PROJECT_ROOT/scripts/fixtures/parallel_project_sample"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$FIXTURE_DIR"/*.vibe "$work/"

fail=0
note() { echo "[jobs-warm] $*"; }
die() { echo "[jobs-warm] FAIL: $*" >&2; fail=1; }

# serial_compile <src> <entry> <out> -> sets COMPILE_EXIT, writes <out>.diag on error
serial_compile() {
  local src="$1" entry="$2" out="$3"
  rm -f "$out" "$out.diag"
  set +e
  VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash "$RUNNER" --invoke cli_main "$COMPILER_WASM" "$src" "$out" "$entry" \
    >/dev/null 2>&1
  COMPILE_EXIT=$?
  set -e
}

# --- 1. baseline: plain serial compile, no pre-warm ----------------------
serial_compile "$work/main.vibe" "main_value" "$work/out_serial.wasm"
[ "$COMPILE_EXIT" -eq 0 ] && [ -s "$work/out_serial.wasm" ] || die "serial baseline compile failed"
note "serial baseline ok"

# --- 2. pre-warm via the driver at jobs=4, then compile again ------------
warm_json="$(node "$DRIVER" "$COMPILER_WASM" "$work/main.vibe" 4 "$work" "$RUNNER")"
note "driver summary: $warm_json"
warmed="$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).warmed))' "$warm_json")"
checked="$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).checked))' "$warm_json")"
[ "$checked" -eq 3 ] || die "expected 3 checked modules (leaf/mid/main), got $checked"
[ "$warmed" -eq 3 ] || die "expected 3 warmed cache entries, got $warmed"
note "cache warmed: $warmed modules"

serial_compile "$work/main.vibe" "main_value" "$work/out_jobs4.wasm"
[ "$COMPILE_EXIT" -eq 0 ] && [ -s "$work/out_jobs4.wasm" ] || die "post-warm compile failed"
if cmp -s "$work/out_serial.wasm" "$work/out_jobs4.wasm"; then
  note "byte-identical: serial vs pre-warmed compile"
else
  die "post-warm compile produced DIFFERENT bytes than the serial baseline"
fi

# --- 3. error case: warm must not publish a diagnosed module's cache, and
#        the serial fallback must report the IDENTICAL diagnostic ---------
serial_compile "$work/main_broken.vibe" "main_value" "$work/out_broken_serial.wasm"
[ "$COMPILE_EXIT" -ne 0 ] || die "main_broken.vibe unexpectedly compiled cleanly (serial)"
serial_diag="$(cat "$work/out_broken_serial.wasm.diag" 2>/dev/null || true)"
[ -n "$serial_diag" ] || die "serial error case produced no .diag"

warm_broken_json="$(node "$DRIVER" "$COMPILER_WASM" "$work/main_broken.vibe" 4 "$work" "$RUNNER")"
note "driver summary (broken): $warm_broken_json"
diagnosed="$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).diagnosed))' "$warm_broken_json")"
[ "$diagnosed" -ge 1 ] || die "expected at least 1 diagnosed module for main_broken.vibe, got $diagnosed"

serial_compile "$work/main_broken.vibe" "main_value" "$work/out_broken_jobs4.wasm"
[ "$COMPILE_EXIT" -ne 0 ] || die "main_broken.vibe unexpectedly compiled cleanly (post-warm)"
jobs4_diag="$(cat "$work/out_broken_jobs4.wasm.diag" 2>/dev/null || true)"
if [ "$serial_diag" = "$jobs4_diag" ]; then
  note "identical diagnostic: serial vs post-warm ($serial_diag)"
else
  die "diagnostic mismatch: serial=[$serial_diag] post-warm=[$jobs4_diag]"
fi

if [ "$fail" -eq 0 ]; then
  echo "[jobs-warm] ok"
  exit 0
else
  exit 1
fi
