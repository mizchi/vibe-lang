#!/usr/bin/env bash
# #2832: the async slot/request bands are load-bearing magic numbers split
# across two files, and nothing read them together.
#
# component_codegen.vibe packs four per-handle slot regions back to back:
#
#   comp_hf_value_base  + cap*4 + 4 == comp_hf_state_base
#   comp_hf_state_base  + cap*4 + 4 == comp_hs_value_base
#   comp_hs_value_base  + cap*4 + 4 == comp_hs_closed_base
#
# Every adjacency is EXACTLY full today (margin zero), so raising the handle
# cap without moving the bases overruns into the next region -- silently, by
# writing a future's state where a stream's value lives.
#
# The fourth relation spans FILES. linked_compile.vibe's `__entry_settle`
# dispatches a suspend request by band: [2, 2+cap] is a host-future waitable
# and [lc_hs_req_base, ..] is a host-stream read. Its own comment says the two
# are disjoint "by construction, not by runtime discipline" -- and the
# construction is `comp_hf_max_handles` in one file against `lc_hs_req_base`
# in another. Raising the cap past 2046 makes a future request land in the
# stream band and read the wrong handle table.
#
# This gate asserts the ARITHMETIC, not the constants: moving a base on
# purpose keeps it green, breaking the packing does not.
#
# A constant this cannot read is a FAILURE, not a skip. An unreadable
# constant and a satisfied one are indistinguishable from silence, and the
# whole point of the gate is that nobody was checking.
#
# Usage:
#   bash scripts/check_async_band_contract.sh
#   ASYNC_BAND_COMPONENT_CODEGEN=<path> ASYNC_BAND_LINKED_COMPILE=<path> \
#     bash scripts/check_async_band_contract.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CC="${ASYNC_BAND_COMPONENT_CODEGEN:-lib/@vibe/compiler/entry/source_compile/wasi_only/component_codegen.vibe}"
LC="${ASYNC_BAND_LINKED_COMPILE:-lib/@vibe/compiler/codegen/wasi/linked_compile.vibe}"

for f in "$CC" "$LC"; do
  if [ ! -f "$f" ]; then
    echo "[async-band] FAIL: source not found: $f" >&2
    exit 1
  fi
done

# The body of a zero-argument Int constant function: the first non-blank,
# non-comment line after its `fn NAME() -> Int {`, which must be a bare
# integer. Anything else (a computed body, a renamed function, a missing one)
# yields the empty string and fails below rather than defaulting.
read_const() {
  awk -v want="$1" '
    $0 ~ ("^fn " want "\\(\\) -> Int \\{") { grab = 1; next }
    grab == 1 {
      line = $0
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "" || line ~ /^\/\//) { next }
      if (line ~ /^-?[0-9]+$/) { print line }
      exit
    }
  ' "$2"
}

hf_value="$(read_const comp_hf_value_base "$CC")"
hf_state="$(read_const comp_hf_state_base "$CC")"
hs_value="$(read_const comp_hs_value_base "$CC")"
hs_closed="$(read_const comp_hs_closed_base "$CC")"
cap="$(read_const comp_hf_max_handles "$CC")"
req_base="$(read_const lc_hs_req_base "$LC")"

fail=0
for pair in \
  "comp_hf_value_base=$hf_value" \
  "comp_hf_state_base=$hf_state" \
  "comp_hs_value_base=$hs_value" \
  "comp_hs_closed_base=$hs_closed" \
  "comp_hf_max_handles=$cap" \
  "lc_hs_req_base=$req_base"; do
  name="${pair%%=*}"
  val="${pair#*=}"
  if [ -z "$val" ]; then
    echo "[async-band] FAIL: could not read \`$name\` as a bare Int constant." >&2
    echo "  It was renamed, its body stopped being a literal, or it moved file." >&2
    echo "  Point this gate at the new spelling; do not delete the check." >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1

# Each slot region holds `cap + 1` handles at 4 bytes, plus a 4-byte guard.
span=$(( cap * 4 + 4 ))

check_adj() {
  # $1 lower name, $2 lower value, $3 upper name, $4 upper value
  want=$(( $2 + span ))
  if [ "$want" -ne "$4" ]; then
    echo "[async-band] FAIL: $1 + cap*4 + 4 = $want, but $3 = $4." >&2
    echo "  The slot regions are packed exactly; a mismatch means one region" >&2
    echo "  writes into the next. Move the bases together, or change the cap" >&2
    echo "  and every base below it (component_codegen.vibe:5738-5781)." >&2
    return 1
  fi
  return 0
}

rc=0
check_adj comp_hf_value_base "$hf_value" comp_hf_state_base "$hf_state" || rc=1
check_adj comp_hf_state_base "$hf_state" comp_hs_value_base "$hs_value" || rc=1
check_adj comp_hs_value_base "$hs_value" comp_hs_closed_base "$hs_closed" || rc=1

# The cross-file one. The future request band is [2, 2 + cap]; the stream band
# starts at lc_hs_req_base. They must not touch.
future_top=$(( 2 + cap ))
if [ "$future_top" -ge "$req_base" ]; then
  echo "[async-band] FAIL: the future request band tops out at $future_top" >&2
  echo "  (2 + comp_hf_max_handles, component_codegen.vibe) but the stream band" >&2
  echo "  starts at $req_base (lc_hs_req_base, linked_compile.vibe). A future" >&2
  echo "  wait would be dispatched as a stream read against the wrong handle" >&2
  echo "  table. Raise lc_hs_req_base, or lower the handle cap." >&2
  rc=1
fi

[ "$rc" -eq 0 ] || exit 1

echo "[async-band] ok (cap=$cap span=$span; slot bases $hf_value/$hf_state/$hs_value/$hs_closed packed exactly; future band tops at $future_top, stream band starts at $req_base)"
