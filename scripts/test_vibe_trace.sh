#!/usr/bin/env bash
# Integration test for debugger テーマ3 / M2: runtime traps point at the SOURCE
# LINE. A program that traps inside a user function must, via `vibe run`, produce
# a backtrace whose frame for that function is annotated with `(file:line)` —
# e.g. `<unknown>!boom (prog.vibex:1)`.
#
# How it works (no codegen/runner changes):
#   * the wasm "name" custom section (debugger P0) already names trap frames after
#     the user function (`<unknown>!boom`),
#   * the FS compile writes a `<out>.funcmap` sidecar mapping each entry-file
#     top-level function to its 1-based source line (selfhost adapter +
#     build_funcmap_from_source),
#   * `vibe run` captures the runner's stderr and appends ` (<basename>:<line>)`
#     to each frame that names a funcmap function.
#
# Installs a FRESH CLI wasm (the committed seed predates the funcmap sidecar) into
# a throwaway VIBE_HOME/VIBE_BIN_DIR so it never touches a real install. Mirrors
# tests/integration/install/install_test.sh's install pattern.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# 1. runner
RT="$ROOT_DIR/runtime/viberun/target/release/viberun"
# Rebuild the runner if it is missing OR older than any runner source (a stale
# local binary would lack newly added host imports like vibe::dbg_break).
if [ ! -x "$RT" ] || [ -n "$(find runtime/viberun/src -name "*.rs" -newer "$RT" 2>/dev/null | head -1)" ]; then
  cargo build --release --manifest-path runtime/viberun/Cargo.toml >/dev/null
fi

# 2. a fresh CLI wasm carrying the funcmap sidecar support
cli="$(bash scripts/build_cli_wasm.sh)"
[ -s "$cli" ] || { echo "FAIL: no CLI wasm built" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
# Keep the runner from dumping its own multi-line Rust backtrace so the assertion
# scans only the wasm trap frames.
unset RUST_BACKTRACE || true

echo "[test] installing fresh CLI into $VIBE_HOME"
bash install/install.sh --cli-wasm "$cli" >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }

proj="$WORK/proj"
mkdir -p "$proj"
# `boom` is defined on line 1, traps on integer divide-by-zero; main calls it.
cat > "$proj/prog.vibex" <<'EOF'
let boom = (x: Int) -> Int { x / 0 }
fn main with () { let _ = boom(3); () }
EOF

# Run; it must trap (non-zero exit) and the stderr trace must annotate the `boom`
# frame with (prog.vibex:1).
set +e
err="$("$VIBE" run "$proj/prog.vibex" 2>&1 >/dev/null)"
status=$?
set -e

echo "----- captured stderr -----"
printf '%s\n' "$err"
echo "---------------------------"

if [ "$status" -eq 0 ]; then
  echo "FAIL: trapping program exited 0 (expected non-zero)" >&2
  exit 1
fi

# Primary assertion: the boom frame is annotated with its source line.
want="boom (prog.vibex:1)"
if printf '%s\n' "$err" | grep -qF "$want"; then
  echo "ok: trap backtrace annotates trapping function with source line: '$want'"
else
  echo "FAIL: expected stderr to contain '$want'" >&2
  echo "      (the wasm name section must name the frame and the .funcmap sidecar must map boom->1)" >&2
  exit 1
fi

echo "[test_vibe_trace] passed"
