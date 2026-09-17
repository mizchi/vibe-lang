#!/usr/bin/env bash
# #2778: nested binders are threaded. The type-less erased-interp walk is gone,
# so the old `lambda_bound_erased_interp_*_refused.vibe` corpus must stay
# deleted. Nested `"\{a}"` shims rewrite at the call site (#2468) and compile.
set -euo pipefail
ROOT_DIR="${VIBE_LAMBDA_BOUND_REFUSAL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT_DIR"

. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2 lambda-bound-refusal "${LAMBDA_BOUND_REFUSAL_STAGE2:-}")" || exit 1

ERASED_GLOB="${LAMBDA_BOUND_ERASED_GLOB:-fixtures/lambda_bound_erased_interp*refused.vibe}"
NESTED_OK="${LAMBDA_BOUND_NESTED_OK:-fixtures/lambda_bound_nested_shim_ok.vibe}"

shopt -s nullglob
erased=($ERASED_GLOB)
if [ ${#erased[@]} -ne 0 ]; then
  echo "[lambda-bound-refusal] FAIL: type-less erased-interp refusal fixtures must not return:" >&2
  printf '  %s\n' "${erased[@]}" >&2
  exit 1
fi

[ -f "$NESTED_OK" ] || {
  echo "[lambda-bound-refusal] FAIL: nested shim control missing: $NESTED_OK" >&2
  exit 1
}

WORK="$ROOT_DIR/_build/_lambda_bound_refusal"
rm -rf "$WORK"; mkdir -p "$WORK"
out="$WORK/nested_shim_ok.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
  "$NESTED_OK" "$out" _start >/dev/null 2>&1 || true
if [ ! -s "$out" ]; then
  echo "[lambda-bound-refusal] FAIL: nested shim control did not compile: $NESTED_OK" >&2
  cat "$out.diag" >&2 2>/dev/null || true
  exit 1
fi

echo "[lambda-bound-refusal] ok (erased-interp walk gone, nested shim compiles)"
