#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_wasi_http_boundary}"
SRC_PATH="$OUT_DIR/http_boundary_probe.vibe"
OUT_COMPONENT="$OUT_DIR/http_boundary_probe.component.wasm"
OUT_WIT="$OUT_DIR/http_boundary_probe.component.wit"

run_stage() {
  local name="$1"
  shift
  local start end elapsed
  start="$(date +%s)"
  echo "[http-boundary] $name"
  "$@"
  end="$(date +%s)"
  elapsed="$((end - start))"
  echo "[http-boundary] done: $name (${elapsed}s)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- "- %s: %ss\n" "$name" "$elapsed" >> "$GITHUB_STEP_SUMMARY" || true
  fi
}

mkdir -p "$OUT_DIR"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Selfhost WASI HTTP Boundary Timings"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

cat >"$SRC_PATH" <<'EOF'
let run = () -> Int with {Net} {
  let req = http_request("GET", "https://example.com", "", "")
  let status = http_response_status(req)
  http_close(req)
  status
}
run()
EOF

run_stage "stage0 (wasm compiler cli) -> component compile" \
  moon run --target wasm src/cmd/vibe_compile_wasi -- --component --http-host-imports "$SRC_PATH" -o "$OUT_COMPONENT"

run_stage "stage0 (wasm compiler cli) -> component wit compile" \
  moon run --target wasm src/cmd/vibe_compile_wasi -- --wit-component "$SRC_PATH" -o "$OUT_WIT"

if ! rg -n "import wasi:http/types@0\\.3\\.0-draft;" "$OUT_WIT" >/dev/null; then
  echo "http boundary gate failed: missing wasi:http/types import in component WIT" >&2
  exit 1
fi
if ! rg -n "import wasi:http/handler@0\\.3\\.0-draft;" "$OUT_WIT" >/dev/null; then
  echo "http boundary gate failed: missing wasi:http/handler import in component WIT" >&2
  exit 1
fi
if ! rg -n "export run: func\\(\\) -> s64;" "$OUT_WIT" >/dev/null; then
  echo "http boundary gate failed: missing run export in component WIT" >&2
  exit 1
fi

if command -v wasm-tools >/dev/null 2>&1; then
  echo "[http-boundary] validate component wasm"
  wasm-tools validate --features all "$OUT_COMPONENT"
  COMPONENT_TEXT="$(wasm-tools print "$OUT_COMPONENT" 2>/dev/null || true)"
  if ! printf '%s' "$COMPONENT_TEXT" | rg -n "^\(component" >/dev/null; then
    echo "http boundary gate failed: output is not printable as a component module" >&2
    exit 1
  fi
  if ! printf '%s' "$COMPONENT_TEXT" | rg -n '^\s*\(import "import-0" \(func' >/dev/null; then
    echo "http boundary gate failed: missing lowered function import placeholders in component" >&2
    exit 1
  fi
  if ! printf '%s' "$COMPONENT_TEXT" | rg -n '^\s*\(with "vibe:http" \(instance' >/dev/null; then
    echo "http boundary gate failed: missing instantiate binding for vibe:http instance" >&2
    exit 1
  fi
  if printf '%s' "$COMPONENT_TEXT" | rg -n 'core-import-' >/dev/null; then
    echo "http boundary gate failed: legacy core-import-* names must not appear" >&2
    exit 1
  fi
else
  echo "warning: wasm-tools not found, skipping component validation/print checks" >&2
fi

echo "http boundary gate passed: component=$OUT_COMPONENT wit=$OUT_WIT"
