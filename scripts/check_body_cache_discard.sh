#!/usr/bin/env bash
# #2873: a compile that will not READ its body cache must say so.
#
# `compile_wasi_module_linked_impl_with_split` records into `body_cache_out`
# unconditionally -- per user function a body, three meta counts, its lambda /
# funcref-slot / blind-reference slices, and since #2199 one row per
# `vibe.linemap` site. A caller that passes a fresh cache for BOTH parameters
# never reads any of it, and on the bump lane none of those arrays are ever
# reclaimed. #2867 added `codegen_body_cache_discard()` -- a cache whose
# `record` is a no-op -- and used it on the `vibe run` / `vibe test` lane for
# -9.05 MiB of the selfcompile KPI heap from ONE call site.
#
# THE INVARIANT: `codegen_body_cache_new(), codegen_body_cache_new()` does not
# appear in production compiler source. The convention is `body_cache_in,
# body_cache_out` adjacent and in that order, so the second of a doubled inline
# `new()` is the OUT cache -- and an INLINE `new()` in the out position is
# provably unread, because the caller never bound it to a name. That is what
# makes this decidable lexically instead of by dataflow.
#
# Measured on the coverage lane (one of the 21 sites this rule cleared),
# isolated cold cache, two runs each, byte-identical within each column:
#
#   input                                    before          after
#   lib/@vibe/compiler/checker/checker.vibe  361,431,568     360,861,680
#   .../tests/codegen_lexer_test.vibe        977,731,744     976,561,864
#
# and the selfcompile KPI -- the lane that ALREADY discarded -- moved
# 1,015,266,344 -> 1,015,258,768, which is the control: the rule is inert where
# the work was already done.
#
# TESTS ARE EXEMPT, deliberately. A test that passes two fresh caches is
# exercising the RECORDING path; switching it to `discard()` would delete that
# coverage rather than save anything, and the four such tests
# (`codegen_body_cache_persist_test`, `body_cache_pruned_test`,
# `linked_compile_prov_inert_test`, `const_bool_params_test`, `inline_wasm_test`)
# are what would catch a cache someone DOES read being switched by accident.
#
# Usage:
#   bash scripts/check_body_cache_discard.sh
set -euo pipefail
ROOT_DIR="${VIBE_BODY_CACHE_DISCARD_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT_DIR"

# Overridable so the self-test can point the gate at a mutated copy.
SCAN_ROOT="${VIBE_BODY_CACHE_DISCARD_ROOT_DIR:-lib}"
NEEDLE='codegen_body_cache_new(), codegen_body_cache_new()'

# `found` counts every .vibe file, `scanned` only the non-exempt ones. The
# emptiness guard below reads `found`: RED 2 of the self-test hands the gate a
# tree whose files are ALL exempt, and counting only the scanned ones reported
# "no .vibe files scanned" -- turning a correct exemption into a failure, and
# conflating "nothing to look at" with "everything was excused".
found=0
scanned=0
bad=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  found=$((found + 1))
  case "$f" in
    */tests/*) continue ;;
    *_cli_adapter_module_source.vibe|*_bundle.vibe) continue ;;
  esac
  scanned=$((scanned + 1))
  hits="$(grep -nF "$NEEDLE" "$f" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "[body-cache-discard] FAIL: $f passes a fresh cache as the OUT parameter (#2873)" >&2
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    bad=1
  fi
done <<EOF
$(find "$SCAN_ROOT" -name '*.vibe' -type f 2>/dev/null | sort)
EOF

if [ "$found" -eq 0 ]; then
  # Silence is "unchecked", not "clean".
  echo "[body-cache-discard] FAIL: no .vibe files scanned under $SCAN_ROOT" >&2
  exit 1
fi

if [ "$bad" != 0 ]; then
  echo "  The OUT cache is the SECOND of the pair. Pass codegen_body_cache_discard()" >&2
  echo "  when nothing reads it; leave codegen_body_cache_new() on caches someone does." >&2
  exit 1
fi

echo "[body-cache-discard] ok ($scanned production file(s) of $found; no unread OUT cache records)"
