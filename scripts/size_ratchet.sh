#!/usr/bin/env bash
# Compiler OUTPUT size ratchet (#1109-4).
#
# Compiles every bench/binary_size/*.vibe sample with the given stage2 and
# compares each result against bench/perf/size_baseline.txt. Sizes here are
# byte-deterministic for a fixed (stage2, sample) pair, so this gates CI
# without flakes — unlike wall time, and unlike the compiler's own artifact
# sizes (which grow legitimately with every feature; see the baseline file's
# header for why those are tracked but not gated).
#
# Usage:
#   bash scripts/size_ratchet.sh <stage2.wasm>            # gate
#   bash scripts/size_ratchet.sh <stage2.wasm> --print    # emit baseline lines
#
# Env:
#   VIBE_SIZE_TOLERANCE_PCT   allowed growth per sample (default 2)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

STAGE2="${1:-}"
MODE="${2:-gate}"
if [ -z "$STAGE2" ] || [ ! -s "$STAGE2" ]; then
  echo "[size-ratchet] usage: bash scripts/size_ratchet.sh <stage2.wasm> [--print]" >&2
  exit 2
fi

BASELINE_FILE="bench/perf/size_baseline.txt"
TOLERANCE_PCT="${VIBE_SIZE_TOLERANCE_PCT:-2}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

measured="$work/measured.txt"; : > "$measured"
for src in bench/binary_size/*.vibe; do
  name="$(basename "$src" .vibe)"
  out="$work/$name.wasm"
  rm -f "$out" "$out.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    "$src" "$out" main >/dev/null 2>&1 || true
  if [ ! -s "$out" ]; then
    echo "[size-ratchet] FAIL: binary_size sample did not compile: $src" >&2
    cat "$out.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  printf '%s %s\n' "$name" "$(wc -c < "$out")" >> "$measured"
done

if [ "$MODE" = "--print" ]; then
  cat "$measured"
  exit 0
fi

if [ ! -f "$BASELINE_FILE" ]; then
  echo "[size-ratchet] FAIL: missing $BASELINE_FILE" >&2
  exit 1
fi

# Baseline entries, comments/blanks stripped.
baseline="$work/baseline.txt"
grep -vE '^\s*(#|$)' "$BASELINE_FILE" > "$baseline"

status=0
while read -r name bytes; do
  [ -n "$name" ] || continue
  want="$(awk -v n="$name" '$1 == n { print $2 }' "$baseline")"
  if [ -z "$want" ]; then
    echo "[size-ratchet] FAIL: no baseline entry for sample '$name' (add it to $BASELINE_FILE)" >&2
    status=1
    continue
  fi
  max=$(( want * (100 + TOLERANCE_PCT) / 100 ))
  if [ "$bytes" -gt "$max" ]; then
    pct=$(( (bytes - want) * 100 / want ))
    echo "[size-ratchet] FAIL: $name is $bytes B, baseline $want B (+${pct}%, max $max B at +${TOLERANCE_PCT}%)" >&2
    status=1
  else
    delta=$(( bytes - want ))
    echo "[size-ratchet] ok: $name $bytes B (baseline $want B, ${delta:+$delta} B)"
  fi
done < "$measured"

# A baseline entry with no matching sample means the corpus lost a file
# without the baseline being updated — catch it rather than silently
# gating fewer things than the table claims.
while read -r name _bytes; do
  [ -n "$name" ] || continue
  if ! awk -v n="$name" '$1 == n { found = 1 } END { exit !found }' "$measured"; then
    echo "[size-ratchet] FAIL: baseline lists '$name' but bench/binary_size has no such sample" >&2
    status=1
  fi
done < "$baseline"

if [ "$status" -ne 0 ]; then
  echo "[size-ratchet] output sizes regressed -- fix the codegen change, or rebaseline per $BASELINE_FILE's header if the growth is intentional" >&2
  exit 1
fi
echo "[size-ratchet] all samples within +${TOLERANCE_PCT}% of baseline"
