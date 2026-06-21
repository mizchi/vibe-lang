#!/usr/bin/env bash
# Compiler wasm artifact-layer parity gate (#529).
#
# Two builders produce a vibe compiler wasm from the *same* source:
#
#   dist   — scripts/build_selfhost_dist.sh
#            MoonBit host-compiled shipping artifact
#            (_build/dist/selfhost_compiler.wasm)
#   stage2 — scripts/selfhost_generations.sh build
#            self-reproduced candidate
#            (_build/selfhost/generations/<ts>/stage2.wasm)
#
# Because the builders differ (host MoonBit codegen vs selfhost wasm codegen),
# the two compiler binaries are NOT byte-identical by design. Equivalence is a
# *contract*, not byte unification: both compilers, given the same input, must
# agree on
#
#   1. the `vibe.abi` custom section they embed in emitted program wasm
#      (version + host_import_abi — see docs/selfhost-bootstrap.md), and
#   2. observable behaviour (the emitted program returns the same answer), and
#   3. by default, the byte image of the emitted program wasm.
#
# (3) is the strict form. Relax it to behavioural parity (1)+(2) with
# VIBE_DIST_PARITY_REQUIRE_HASH=0 when host/selfhost codegen differences are
# expected on a given input but the ABI contract must still hold.
#
# Self-test:
#   scripts/test_selfhost_dist_stage2_parity.sh --self-test
#     validates the vibe.abi extractor against the committed pinned seed wasm
#     (bootstrap/selfhost/seed/selfhost_compiler.wasm) without any build.
#
# Env:
#   VIBE_DIST_PARITY_REQUIRE_HASH  — 1 (default) strict byte parity of output
#                                    wasm; 0 = behavioural + ABI parity only.
#   VIBE_DIST_PARITY_KEEP          — 1 to keep the scratch dir for inspection.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
REQUIRE_HASH="${VIBE_DIST_PARITY_REQUIRE_HASH:-1}"
KEEP="${VIBE_DIST_PARITY_KEEP:-0}"

die() {
  echo "[dist-parity] FAIL: $*" >&2
  exit 1
}

need_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    die "python3 is required to parse the vibe.abi custom section"
  fi
}

# Print the payload of the first custom section named "vibe.abi", or nothing.
# Parses the wasm section table properly (does not string-search the binary),
# so source-embedded "vibe.abi" string literals are never mistaken for the
# section.
extract_vibe_abi() {
  local wasm="$1"
  need_python
  python3 - "$wasm" <<'PY'
import sys

def leb(data, i):
    result = 0
    shift = 0
    while True:
        b = data[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    return result, i

data = open(sys.argv[1], "rb").read()
if data[:4] != b"\x00asm":
    sys.exit("not a wasm module")
i = 8  # magic(4) + version(4)
n = len(data)
while i < n:
    sec_id = data[i]; i += 1
    size, i = leb(data, i)
    body = data[i:i + size]
    i += size
    if sec_id == 0:  # custom section
        name_len, j = leb(body, 0)
        name = body[j:j + name_len]
        payload = body[j + name_len:]
        if name == b"vibe.abi":
            sys.stdout.buffer.write(payload)
            break
PY
}

self_test() {
  local seed="$PROJECT_ROOT/bootstrap/selfhost/seed/selfhost_compiler.wasm"
  [ -f "$seed" ] || die "pinned seed wasm not found: $seed"
  local abi
  abi="$(extract_vibe_abi "$seed")"
  echo "[dist-parity] self-test: seed vibe.abi ="
  printf '%s\n' "$abi" | sed 's/^/    /'
  case "$abi" in
    *"version=1"*"host_import_abi="*) ;;
    *) die "seed vibe.abi missing version/host_import_abi: [$abi]" ;;
  esac
  echo "[dist-parity] self-test OK"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit 0
fi

# --- locate / build the two compilers ----------------------------------------

DIST_WASM="$PROJECT_ROOT/_build/dist/selfhost_compiler.wasm"

echo "[dist-parity] building dist compiler..."
bash "$SCRIPT_DIR/build_selfhost_dist.sh"
[ -f "$DIST_WASM" ] || die "dist compiler not produced: $DIST_WASM"

echo "[dist-parity] building stage2 compiler..."
bash "$SCRIPT_DIR/selfhost_generations.sh" build
STAGE2_WASM="$(ls -t "$PROJECT_ROOT"/_build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -n 1 || true)"
[ -n "$STAGE2_WASM" ] && [ -f "$STAGE2_WASM" ] || die "stage2 compiler not produced under _build/selfhost/generations"
echo "[dist-parity] stage2: $STAGE2_WASM"

# --- compile the same sample with both ---------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dist-parity.XXXXXX")"
cleanup() { [ "$KEEP" = "1" ] || rm -rf "$WORK"; }
trap cleanup EXIT

SAMPLE="$WORK/sample.vibe"
cat > "$SAMPLE" <<'VIBE'
export let answer = () -> Int { 40 + 2 }
VIBE

OUT_DIST="$WORK/out_dist.wasm"
OUT_STAGE2="$WORK/out_stage2.wasm"

compile_with() {
  local compiler="$1" out="$2"
  VIBE_PREOPEN_DIR="$WORK" \
    bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
      --invoke cli_main \
      "$compiler" \
      "${SAMPLE#$WORK/}" \
      "${out#$WORK/}" \
      "answer" >/dev/null 2>&1 || true
  [ -f "$out" ] || die "compiler did not emit output: $compiler"
}

echo "[dist-parity] compiling sample with dist..."
compile_with "$DIST_WASM" "$OUT_DIST"
echo "[dist-parity] compiling sample with stage2..."
compile_with "$STAGE2_WASM" "$OUT_STAGE2"

# --- (1) ABI contract --------------------------------------------------------

ABI_DIST="$(extract_vibe_abi "$OUT_DIST")"
ABI_STAGE2="$(extract_vibe_abi "$OUT_STAGE2")"
echo "[dist-parity] dist   vibe.abi: $(printf '%s' "$ABI_DIST" | tr '\n' ' ')"
echo "[dist-parity] stage2 vibe.abi: $(printf '%s' "$ABI_STAGE2" | tr '\n' ' ')"
[ -n "$ABI_DIST" ] || die "dist output has no vibe.abi custom section"
[ "$ABI_DIST" = "$ABI_STAGE2" ] || die "vibe.abi mismatch: dist=[$ABI_DIST] stage2=[$ABI_STAGE2]"
echo "[dist-parity] (1) vibe.abi contract: OK"

# --- (2) behavioural parity --------------------------------------------------

run_answer() {
  local prog="$1"
  VIBE_PREOPEN_DIR="$WORK" \
    bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
      --invoke _start "$prog" 2>/dev/null | grep -E '^-?[0-9]+$' | tail -n 1 || true
}

ANS_DIST="$(run_answer "$OUT_DIST")"
ANS_STAGE2="$(run_answer "$OUT_STAGE2")"
[ "$ANS_DIST" = "42" ] || die "dist output returned '$ANS_DIST' (expected 42)"
[ "$ANS_STAGE2" = "42" ] || die "stage2 output returned '$ANS_STAGE2' (expected 42)"
echo "[dist-parity] (2) behavioural parity: OK (both return 42)"

# --- (3) optional byte parity of emitted program -----------------------------

if [ "$REQUIRE_HASH" = "1" ]; then
  sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | awk '{print $1}'; fi
  }
  H_DIST="$(sha "$OUT_DIST")"
  H_STAGE2="$(sha "$OUT_STAGE2")"
  if [ "$H_DIST" != "$H_STAGE2" ]; then
    die "emitted program wasm differs (dist=$H_DIST stage2=$H_STAGE2). Set VIBE_DIST_PARITY_REQUIRE_HASH=0 to gate on behaviour+ABI only."
  fi
  echo "[dist-parity] (3) byte parity of emitted wasm: OK ($H_DIST)"
else
  echo "[dist-parity] (3) byte parity: skipped (VIBE_DIST_PARITY_REQUIRE_HASH=0)"
fi

echo "[dist-parity] OK: dist and stage2 compilers agree on the artifact contract"
