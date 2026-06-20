#!/usr/bin/env bash
# Parity gate: host-compiled dist compiler vs self-reproduced stage2 compiler.
#
# Background (#529):
#   The canonical selfhost compiler wasm has two generation entry points that
#   intentionally produce BYTE-DIFFERENT compiler binaries:
#
#     - dist   : `scripts/build_selfhost_dist.sh` — MoonBit host compiles the
#                vibe-written compiler source (`vibe/cli/selfhost_entry.vibe`)
#                straight to `_build/dist/selfhost_compiler.wasm`. This is the
#                fast SHIPPING artifact.
#     - stage2 : `scripts/selfhost_generations.sh build` — stage0(pinned seed)
#                -> stage1 -> stage2, the SELF-REPRODUCED bootstrap candidate
#                recorded in `generation.json` as `stage2_distribution_candidate`.
#
#   Both binaries are the SAME compiler source, only the builder differs (host
#   vs stage1). This gate asserts they behave as the same compiler: compiling
#   the same input must produce equivalent output, including an identical
#   `vibe.abi` artifact-layer contract custom section.
#
#   Note: the compiler binaries themselves are not directly comparable for the
#   `vibe.abi` section — the host (`src/`) codegen does not emit it, the
#   selfhost codegen (`vibe/compiler/codegen/wasi/linked_compile.vibe`) does.
#   The contract therefore lives in the wasm each compiler PRODUCES, which is
#   what this gate compares.
#
# Env:
#   DIST_WASM                          dist compiler wasm (default: _build/dist/selfhost_compiler.wasm)
#   STAGE2_WASM                        stage2 compiler wasm (default: newest generations/*/stage2.wasm)
#   VIBE_DIST_PARITY_SKIP_BUILD=1      do not build missing artifacts; fail instead
#   VIBE_DIST_PARITY_REQUIRE_HASH=0    relax byte-identical output to behavioral equivalence
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_WASM="${DIST_WASM:-$PROJECT_ROOT/_build/dist/selfhost_compiler.wasm}"
STAGE2_WASM="${STAGE2_WASM:-}"
SKIP_BUILD="${VIBE_DIST_PARITY_SKIP_BUILD:-0}"
REQUIRE_HASH="${VIBE_DIST_PARITY_REQUIRE_HASH:-1}"
GEN_ROOT="$PROJECT_ROOT/_build/selfhost/generations"
WORK="$PROJECT_ROOT/_build/selfhost/dist_stage2_parity"

die() { echo "dist/stage2 parity gate: $*" >&2; exit 1; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

# Extract the `vibe.abi` custom section payload from a wasm module, or
# "NO_VIBE_ABI_SECTION" when absent.
extract_abi() {
  node - "$1" <<'NODE'
import fs from "node:fs";
const buf = fs.readFileSync(process.argv[2]);
if (buf.length < 8 || buf.readUInt32LE(0) !== 0x6d736100) {
  console.error("not a wasm module: " + process.argv[2]);
  process.exit(2);
}
let o = 8;
const leb = () => { let r = 0, s = 0, b; do { b = buf[o++]; r |= (b & 0x7f) << s; s += 7; } while (b & 0x80); return r >>> 0; };
let found = null;
while (o < buf.length) {
  const id = buf[o++];
  const size = leb();
  const end = o + size;
  if (id === 0) {
    const nlen = leb();
    const name = buf.toString("utf8", o, o + nlen);
    o += nlen;
    if (name === "vibe.abi") { found = buf.toString("utf8", o, end); break; }
  }
  o = end;
}
process.stdout.write(found === null ? "NO_VIBE_ABI_SECTION" : found);
NODE
}

ensure_dist() {
  if [ -s "$DIST_WASM" ]; then
    echo "[parity] dist: $DIST_WASM (pre-built)"
    return
  fi
  if [ "$SKIP_BUILD" = "1" ]; then
    die "dist wasm missing and VIBE_DIST_PARITY_SKIP_BUILD=1: $DIST_WASM"
  fi
  echo "[parity] dist: building via scripts/build_selfhost_dist.sh"
  bash "$SCRIPT_DIR/build_selfhost_dist.sh"
  [ -s "$DIST_WASM" ] || die "build_selfhost_dist.sh did not produce $DIST_WASM"
}

newest_stage2() {
  ls -t "$GEN_ROOT"/*/stage2.wasm 2>/dev/null | head -n 1 || true
}

ensure_stage2() {
  if [ -z "$STAGE2_WASM" ]; then
    STAGE2_WASM="$(newest_stage2)"
  fi
  if [ -n "$STAGE2_WASM" ] && [ -s "$STAGE2_WASM" ]; then
    echo "[parity] stage2: $STAGE2_WASM (pre-built)"
    return
  fi
  if [ "$SKIP_BUILD" = "1" ]; then
    die "stage2 wasm missing and VIBE_DIST_PARITY_SKIP_BUILD=1 (run scripts/selfhost_generations.sh build)"
  fi
  echo "[parity] stage2: building via scripts/selfhost_generations.sh build"
  bash "$SCRIPT_DIR/selfhost_generations.sh" build
  STAGE2_WASM="$(newest_stage2)"
  [ -n "$STAGE2_WASM" ] && [ -s "$STAGE2_WASM" ] || die "selfhost_generations.sh build did not produce a stage2.wasm"
  echo "[parity] stage2: $STAGE2_WASM"
}

# Compile $WORK/sample.vibe with a selfhost compiler wasm into $2.
compile_sample() {
  local compiler="$1"
  local out_wasm="$2"
  rm -f "$out_wasm"
  VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
    bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" \
      --invoke cli_main \
      "$compiler" \
      "${WORK#$PROJECT_ROOT/}/sample.vibe" \
      "$out_wasm" \
      "answer" >/dev/null 2>&1 || true
  [ -s "$out_wasm" ] || die "compiler did not produce sample wasm: $compiler"
  local magic
  magic="$(od -An -t x1 -N 4 "$out_wasm" | tr -d ' \n')"
  [ "$magic" = "0061736d" ] || die "sample artifact is not valid wasm (compiler: $compiler)"
}

run_sample() {
  local wasm="$1"
  VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
    bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke _start "$wasm" 2>/dev/null \
    | grep -E '^-?[0-9]+$' | tail -n 1 || true
}

main() {
  ensure_dist
  ensure_stage2

  mkdir -p "$WORK"
  cat > "$WORK/sample.vibe" <<'VIBE'
export let answer = () -> Int { 40 + 2 }
VIBE

  local sample_dist="$WORK/sample_dist.wasm"
  local sample_stage2="$WORK/sample_stage2.wasm"
  echo "[parity] compiling sample with dist compiler"
  compile_sample "$DIST_WASM" "$sample_dist"
  echo "[parity] compiling sample with stage2 compiler"
  compile_sample "$STAGE2_WASM" "$sample_stage2"

  # --- Contract check: vibe.abi custom section must match ---
  local abi_dist abi_stage2
  abi_dist="$(extract_abi "$sample_dist")"
  abi_stage2="$(extract_abi "$sample_stage2")"
  echo "[parity] vibe.abi (dist):   $(printf '%s' "$abi_dist" | tr '\n' ';')"
  echo "[parity] vibe.abi (stage2): $(printf '%s' "$abi_stage2" | tr '\n' ';')"
  [ "$abi_dist" != "NO_VIBE_ABI_SECTION" ] || die "dist-compiled sample is missing the vibe.abi custom section"
  [ "$abi_stage2" != "NO_VIBE_ABI_SECTION" ] || die "stage2-compiled sample is missing the vibe.abi custom section"
  [ "$abi_dist" = "$abi_stage2" ] || die "vibe.abi contract mismatch between dist and stage2 output"

  # --- Behavioral check: both samples must run to 42 ---
  local r_dist r_stage2
  r_dist="$(run_sample "$sample_dist")"
  r_stage2="$(run_sample "$sample_stage2")"
  [ "$r_dist" = "42" ] || die "dist-compiled sample returned '$r_dist' (expected 42)"
  [ "$r_stage2" = "42" ] || die "stage2-compiled sample returned '$r_stage2' (expected 42)"

  # --- Output parity: byte-identical (strong) or behavioral (relaxed) ---
  local h_dist h_stage2
  h_dist="$(sha256_file "$sample_dist")"
  h_stage2="$(sha256_file "$sample_stage2")"
  if [ "$h_dist" = "$h_stage2" ]; then
    echo "[parity] OK: byte-identical output ($h_dist)"
  elif [ "$REQUIRE_HASH" = "1" ]; then
    die "output wasm differs (dist=$h_dist stage2=$h_stage2); set VIBE_DIST_PARITY_REQUIRE_HASH=0 to allow behavioral-only parity"
  else
    echo "[parity] OK: behavioral parity (output bytes differ: dist=$h_dist stage2=$h_stage2)"
  fi

  echo "[parity] PASS: dist and stage2 compilers agree (vibe.abi + behavior)"
}

main "$@"
