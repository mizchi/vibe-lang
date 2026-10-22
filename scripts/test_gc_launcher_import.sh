#!/usr/bin/env bash
set -euo pipefail

# Regression for #2376's public command boundary. The lower-level
# scripts/vibe_test.sh harness already exercises filesystem-aware GC codegen,
# but `vibe test` has its own compile_to environment wiring and can silently
# fall back to direct single-file mode if VIBE_FS_COMPILE is dropped there.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

CLI_WASM="${1:-}"
if [ -z "$CLI_WASM" ]; then
  CLI_WASM="$(ls -t _build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1 || true)"
fi
if [ -z "$CLI_WASM" ] || [ ! -s "$CLI_WASM" ]; then
  echo "gc-launcher-import: compiler wasm not found" >&2
  exit 2
fi

VIBE_RUNNER="${VIBE_GC_LAUNCHER_RUNNER:-$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh}" \
VIBE_CLI_WASM="$CLI_WASM" \
VIBE_TEST_BACKEND=gc \
  bash "$ROOT_DIR/runtime/vibe" test --no-cache \
    fixtures/gc_import_resolution_test.vibe

# #3545: `vibe build` / `vibe run` hard-coded the linear artifact kind, so
# `VIBE_BACKEND=gc vibe run` ran the RC artifact (byte-identical output, trap
# offsets included). The launcher's gc artifact must be the gc lane's own
# compile of the same entry, and the default must not be.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/proj"
cat >"$WORK/proj/prog.vibex" <<'EOF'
fn main() -> Unit allows Console {
  let a = String::from_byte(66)
  let b = String::from_byte(65)
  println("lt=\{a < b}")
}
EOF
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$WORK" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
  "$WORK/proj/prog.vibex" "$WORK/adapter_gc.wasm" main >/dev/null
[ -s "$WORK/adapter_gc.wasm" ] || { echo "gc-launcher-import: adapter gc compile produced nothing" >&2; exit 1; }
VIBE_RUNNER="${VIBE_GC_LAUNCHER_RUNNER:-$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh}" \
VIBE_CLI_WASM="$CLI_WASM" VIBE_BACKEND=gc \
  bash "$ROOT_DIR/runtime/vibe" build "$WORK/proj/prog.vibex" -o "$WORK/launcher_gc.wasm" >/dev/null
VIBE_RUNNER="${VIBE_GC_LAUNCHER_RUNNER:-$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh}" \
VIBE_CLI_WASM="$CLI_WASM" \
  bash "$ROOT_DIR/runtime/vibe" build "$WORK/proj/prog.vibex" -o "$WORK/launcher_default.wasm" >/dev/null
if ! cmp -s "$WORK/adapter_gc.wasm" "$WORK/launcher_gc.wasm"; then
  echo "gc-launcher-import: VIBE_BACKEND=gc vibe build did not produce the gc lane's artifact" >&2
  exit 1
fi
if cmp -s "$WORK/adapter_gc.wasm" "$WORK/launcher_default.wasm"; then
  echo "gc-launcher-import: plain vibe build produced the gc artifact; the comparison above proves nothing" >&2
  exit 1
fi
gc_run="$(VIBE_RUNNER="${VIBE_GC_LAUNCHER_RUNNER:-$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh}" \
  VIBE_CLI_WASM="$CLI_WASM" VIBE_BACKEND=gc \
  bash "$ROOT_DIR/runtime/vibe" run "$WORK/proj/prog.vibex")"
[ "$gc_run" = "lt=false" ] || { echo "gc-launcher-import: VIBE_BACKEND=gc vibe run printed: $gc_run" >&2; exit 1; }
if VIBE_RUNNER="${VIBE_GC_LAUNCHER_RUNNER:-$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh}" \
    VIBE_CLI_WASM="$CLI_WASM" VIBE_BACKEND=bogus \
    bash "$ROOT_DIR/runtime/vibe" run "$WORK/proj/prog.vibex" >/dev/null 2>"$WORK/bogus.err"; then
  echo "gc-launcher-import: VIBE_BACKEND=bogus vibe run was accepted" >&2
  exit 1
fi
grep -qF "VIBE_BACKEND must be 'linear' or 'gc', got: bogus" "$WORK/bogus.err" || {
  echo "gc-launcher-import: VIBE_BACKEND=bogus refusal did not name the edit" >&2
  cat "$WORK/bogus.err" >&2
  exit 1
}
# The gc lane does not apply --allow-* grants to `perform?`; an optional entry
# grant is refused there instead of answering NotGranted where RC says Granted.
cat >"$WORK/proj/optional.vibex" <<'EOF'
fn cached() -> Attempt[String, String] with Fs::read_file? {
  perform? Fs::read_file("prog.vibex")
}

fn main() -> Unit allows Console + Fs? {
  match cached() {
    NotGranted => println("not-granted"),
    Errored(_) => println("errored"),
    Granted(_) => println("granted")
  }
}
EOF
if VIBE_RUNNER="${VIBE_GC_LAUNCHER_RUNNER:-$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh}" \
    VIBE_CLI_WASM="$CLI_WASM" VIBE_BACKEND=gc \
    bash "$ROOT_DIR/runtime/vibe" run --allow-fs --allow-console "$WORK/proj/optional.vibex" >"$WORK/optional.out" 2>"$WORK/optional.err"; then
  echo "gc-launcher-import: VIBE_BACKEND=gc ran an entry with an optional grant: $(cat "$WORK/optional.out")" >&2
  exit 1
fi
grep -qF "declares the optional grant" "$WORK/optional.err" || {
  echo "gc-launcher-import: optional-grant refusal did not name the cause" >&2
  cat "$WORK/optional.err" >&2
  exit 1
}

echo "gc-launcher-import: ok"
