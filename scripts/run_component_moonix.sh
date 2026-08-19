#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <input.vibe> [output.component.wasm] [invoke-signature]" >&2
  echo "example: $0 lib/@vibe/builtin/test_import_test.vibe" >&2
  echo "example: $0 lib/@vibe/builtin/test_import_test.vibe /tmp/out.component.wasm 'run()'" >&2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

INPUT="$1"
OUT="${2:-}"
INVOKE="${3:-run()}"
MOONIX_BIN="${MOONIX_BIN:-moonix}"

if ! command -v "$MOONIX_BIN" >/dev/null 2>&1; then
  if [ "$MOONIX_BIN" = "moonix" ]; then
    # Try local bootstrap from moonix checkout.
    BOOTSTRAPPED_BIN="$("$SCRIPT_DIR/bootstrap_moonix_bin.sh" 2>/dev/null || true)"
    if [ -n "$BOOTSTRAPPED_BIN" ] && [ -x "$BOOTSTRAPPED_BIN" ]; then
      MOONIX_BIN="$BOOTSTRAPPED_BIN"
    fi
  fi
fi

if ! command -v "$MOONIX_BIN" >/dev/null 2>&1 && [ ! -x "$MOONIX_BIN" ]; then
  echo "moonix runner not found: ${MOONIX_BIN}" >&2
  echo "auto-bootstrap failed. check: scripts/bootstrap_moonix_bin.sh" >&2
  echo "or set MOONIX_BIN to your moonix executable path" >&2
  exit 1
fi

if [ -n "$OUT" ]; then
  scripts/component_wkg_stdio.sh "$INPUT" "$OUT"
  COMPONENT="$OUT"
else
  BASE="$(basename "$INPUT")"
  BASE="${BASE%.*}"
  COMPONENT="dist/${BASE}.component.wasm"
  scripts/component_wkg_stdio.sh "$INPUT" "$COMPONENT"
fi

run_with_variants() {
  local component="$1"
  local invoke="$2"
  local -a cmd
  local -a tried
  local status=0

  # moonix CLI shape may differ by version; try common variants.
  local -a variants=(
    "run|${component}|--invoke|${invoke}"
    "run|--invoke|${invoke}|${component}"
    "component|run|${component}|--invoke|${invoke}"
    "component|run|--invoke|${invoke}|${component}"
  )

  for variant in "${variants[@]}"; do
    IFS='|' read -r -a cmd <<< "$variant"
    cmd=("${MOONIX_BIN}" "${cmd[@]}")
    tried+=("$(printf '%q ' "${cmd[@]}")")
    set +e
    "${cmd[@]}"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
      return 0
    fi
  done

  echo "failed to execute component with moonix (exit=${status})" >&2
  echo "tried:" >&2
  for t in "${tried[@]}"; do
    echo "  - ${t}" >&2
  done
  echo "set MOONIX_BIN to choose another moonix binary path" >&2
  return "$status"
}

run_with_variants "$COMPONENT" "$INVOKE"
