#!/usr/bin/env bash
# Build the wasi compile/check entry-points and run wasm-opt -O3 on them.
#
# moonrun runs the raw moon-built wasm without ahead-of-time optimization;
# bench_selfhost_perf.sh / bench_selfhost_memory.sh measured ~5.99x compile
# and ~2.66x check ratios on the unoptimized wasm. Piping release wasm
# through `wasm-opt -O3` drops these to ~3.87x and ~1.77x on the same
# inputs (examples/basics.vibe, single-run hyperfine, May 2026).
#
# Outputs:
#   _build/wasm/opt/vibe_compile_wasi.wasm
#   _build/wasm/opt/vibe_check_wasi.wasm
#
# Env:
#   VIBE_SELFHOST_OPT_WASM_REBUILD  auto|always|never (default: auto)
#   VIBE_SELFHOST_OPT_WASM_PROFILE  release|debug    (default: release)
#                                   wasm-opt benefits both, but release
#                                   yields a slightly smaller artifact
#                                   and tends to be a touch faster.
#   WASM_OPT_BIN                    override wasm-opt binary
#                                   (must be binaryen >= v118; older
#                                    versions fail on selfhost wasm
#                                    feature set)
set -euo pipefail

trap 'trap - EXIT; kill -- -$$ 2>/dev/null || true' INT TERM

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

REBUILD_MODE="${VIBE_SELFHOST_OPT_WASM_REBUILD:-auto}"
WASM_PROFILE="${VIBE_SELFHOST_OPT_WASM_PROFILE:-release}"
WASM_OPT_BIN="${WASM_OPT_BIN:-$(command -v wasm-opt 2>/dev/null || true)}"

case "$REBUILD_MODE" in auto|always|never) ;;
  *) echo "build-selfhost-wasi-opt: VIBE_SELFHOST_OPT_WASM_REBUILD must be auto|always|never" >&2; exit 1 ;;
esac
case "$WASM_PROFILE" in release|debug) ;;
  *) echo "build-selfhost-wasi-opt: VIBE_SELFHOST_OPT_WASM_PROFILE must be release|debug" >&2; exit 1 ;;
esac

if [ -z "$WASM_OPT_BIN" ]; then
  echo "build-selfhost-wasi-opt: wasm-opt not found (need binaryen >= v118)" >&2
  exit 1
fi

# wasm-opt 108 (Ubuntu noble) cannot parse selfhost moonbit wasm.
# Probe the version and fail fast with a clear message.
WASM_OPT_VERSION_LINE="$($WASM_OPT_BIN --version 2>/dev/null | head -n1 || true)"
WASM_OPT_VERSION="$(echo "$WASM_OPT_VERSION_LINE" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { print $i; exit } }')"
if [ -z "$WASM_OPT_VERSION" ] || [ "$WASM_OPT_VERSION" -lt 118 ]; then
  echo "build-selfhost-wasi-opt: wasm-opt version $WASM_OPT_VERSION_LINE is too old (need >= 118)" >&2
  exit 1
fi

OUT_DIR="$ROOT_DIR/_build/wasm/opt"
mkdir -p "$OUT_DIR"

case "$WASM_PROFILE" in
  release) RAW_DIR="$ROOT_DIR/_build/wasm/release/build" ;;
  debug)   RAW_DIR="$ROOT_DIR/_build/wasm/debug/build" ;;
esac

declare -A TARGETS=(
  ["vibe_compile_wasi"]="$RAW_DIR/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm"
  ["vibe_check_wasi"]="$RAW_DIR/cmd/vibe_check_wasi/vibe_check_wasi.wasm"
)

needs_raw_build() {
  local raw="$1"
  if [ "$REBUILD_MODE" = "always" ]; then
    return 0
  fi
  if [ ! -f "$raw" ]; then
    return 0
  fi
  if [ "$REBUILD_MODE" = "never" ]; then
    return 1
  fi
  if find "$ROOT_DIR/src" -type f \( -name '*.mbt' -o -name 'moon.pkg' -o -name 'moon.mod.json' \) -newer "$raw" -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi
  return 1
}

needs_opt() {
  local raw="$1"
  local opt="$2"
  if [ "$REBUILD_MODE" = "always" ]; then
    return 0
  fi
  if [ ! -f "$opt" ]; then
    return 0
  fi
  if [ "$raw" -nt "$opt" ]; then
    return 0
  fi
  return 1
}

build_raw() {
  local pkg="$1"
  echo "[build-selfhost-wasi-opt] moon build --target wasm $WASM_PROFILE src/cmd/$pkg"
  if [ "$WASM_PROFILE" = "release" ]; then
    moon build --target wasm --release "src/cmd/$pkg"
  else
    moon build --target wasm "src/cmd/$pkg"
  fi
}

run_wasm_opt() {
  local raw="$1"
  local opt="$2"
  echo "[build-selfhost-wasi-opt] wasm-opt -O3 $(realpath --relative-to="$ROOT_DIR" "$raw")"
  "$WASM_OPT_BIN" -O3 \
    --enable-gc \
    --enable-reference-types \
    --enable-bulk-memory \
    --enable-multivalue \
    --enable-tail-call \
    --enable-exception-handling \
    --enable-nontrapping-float-to-int \
    --enable-sign-ext \
    --enable-mutable-globals \
    "$raw" -o "$opt"
}

for pkg in "${!TARGETS[@]}"; do
  raw="${TARGETS[$pkg]}"
  opt="$OUT_DIR/${pkg}.wasm"
  if needs_raw_build "$raw"; then
    build_raw "$pkg"
  fi
  if needs_opt "$raw" "$opt"; then
    run_wasm_opt "$raw" "$opt"
  else
    echo "[build-selfhost-wasi-opt] up to date: $(realpath --relative-to="$ROOT_DIR" "$opt")"
  fi
  raw_size="$(wc -c < "$raw")"
  opt_size="$(wc -c < "$opt")"
  printf "  raw: %d B   opt: %d B   delta: %+d B\n" "$raw_size" "$opt_size" "$((opt_size - raw_size))"
done

echo "[build-selfhost-wasi-opt] done"
echo "  $OUT_DIR/vibe_compile_wasi.wasm"
echo "  $OUT_DIR/vibe_check_wasi.wasm"
