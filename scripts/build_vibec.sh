#!/usr/bin/env bash
# build_vibec.sh — build the vibec.wasm compiler-core component (#1107 Phase 5,
# the implementation shape of #857).
#
# Produces:
#   _build/vibec/vibec.core.wasm       — plain core module (string ABI)
#   _build/vibec/vibec.component.wasm  — canonical-ABI component exporting
#                                        `compile: func(source, request) -> string`
#   _build/vibec/vibec.wit             — the world it implements
#
# The core is lib/@vibe/compiler/cli_direct_component_entry.vibe compiled as a
# library (`__no_entry__`): its `compile_cli_request(source, request)` takes
# every source file inline (hex payload of NUL-separated path/source pairs) and
# hands the compiled wasm back in hex chunks — no filesystem imports, which is
# exactly what makes the component runnable in a browser via jco
# (scripts/vibec_browser_poc.sh). The vfs-callback face for FS-backed hosts is
# designed in docs/vibec-component.md but not yet emitted here.
#
# Compiler used, in priority order:
#   $VIBE_VIBEC_COMPILER > $VIBE_STAGE2_WASM > bootstrap/seed/compiler.wasm
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$ROOT/_build/vibec}"
COMPILER="${VIBE_VIBEC_COMPILER:-${VIBE_STAGE2_WASM:-$ROOT/bootstrap/seed/compiler.wasm}}"
RUN="bash $ROOT/scripts/run_wasm_vibe_host_runner.sh"

[ -f "$COMPILER" ] || { echo "build_vibec: compiler wasm not found: $COMPILER" >&2; exit 1; }
mkdir -p "$OUT_DIR"
CORE="$OUT_DIR/vibec.core.wasm"
COMPONENT="$OUT_DIR/vibec.component.wasm"
HOSTED_CORE="$OUT_DIR/vibec.hosted.core.wasm"
HOSTED_COMPONENT="$OUT_DIR/vibec.hosted.component.wasm"
WIT="$OUT_DIR/vibec.wit"
HOSTED_WIT="$OUT_DIR/vibec-hosted.wit"
TOOL="$OUT_DIR/vibec_componentize.wasm"

cd "$ROOT"

# 1. compiler core (library mode: exports compile_cli_request, ADR-0077 strip
#    does not touch __no_entry__ builds so the export survives).
rm -f "$CORE" "$CORE.diag"
env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  $RUN --invoke cli_main "$COMPILER" \
  lib/@vibe/compiler/cli_direct_component_entry.vibe "$CORE" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$CORE" ]; then
  [ -s "$CORE.diag" ] && cat "$CORE.diag" >&2
  echo "build_vibec: core compile failed" >&2
  exit 1
fi
rm -f "$CORE.diag" "$CORE.funcmap" "$CORE.testmeta"

# 2. componentizer tool (a .vibex script-tool, like vibe-opt).
rm -f "$TOOL" "$TOOL.diag"
env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  $RUN --invoke cli_main "$COMPILER" \
  scripts/vibec_componentize.vibex "$TOOL" main >/dev/null 2>&1 || true
if [ ! -s "$TOOL" ]; then
  [ -s "$TOOL.diag" ] && cat "$TOOL.diag" >&2
  echo "build_vibec: componentizer tool compile failed" >&2
  exit 1
fi
rm -f "$TOOL.diag" "$TOOL.funcmap"

# 3. shrink each face's core (#1109): the library build keeps every sibling
#    export's call graph alive (~5MB); filtering exports down to one face +
#    {memory, __heap_ptr} and running vibe-opt's true DCE drops ~23%.
#    --per-pass because a whole round over a module this size exhausts the
#    4GB wasm space under the bump allocator. Verified: both minified
#    components pass their full jco PoCs (in-memory compile -> run 42).
#    VIBE_VIBEC_NO_MINIFY=1 skips (e.g. while debugging the optimizer itself).
cp "$CORE" "$HOSTED_CORE"
if [ "${VIBE_VIBEC_NO_MINIFY:-}" != "1" ]; then
  bash "$ROOT/scripts/minify_wasm.sh" "$CORE" "$CORE" \
    --keep-exports compile_cli_request,memory,__heap_ptr --per-pass
  bash "$ROOT/scripts/minify_wasm.sh" "$HOSTED_CORE" "$HOSTED_CORE" \
    --keep-exports compile_file_request,memory,__heap_ptr --per-pass
fi

# 4. wrap the cores into the two components: the pure compile face and the
#    vfs-hosted face (#1109-2 — fs imports lifted to the WIT vfs interface).
$RUN "$TOOL" "$CORE" "$COMPONENT"
[ -s "$COMPONENT" ] || { echo "build_vibec: componentize failed" >&2; exit 1; }
$RUN "$TOOL" --vfs "$HOSTED_CORE" "$HOSTED_COMPONENT"
[ -s "$HOSTED_COMPONENT" ] || { echo "build_vibec: hosted componentize failed" >&2; exit 1; }

# 5. WIT sidecar — the world the component implements (compile face only;
#    the vfs face is future work, see docs/vibec-component.md).
cat > "$WIT" <<'EOF'
package vibe:vibec@0.1.0;

world vibec {
  /// Compile vibe source(s) to wasm, fully in-memory.
  ///
  /// `source`  — lowercase-hex encoding of a NUL-separated payload:
  ///             main_path \0 main_source [\0 extra_path \0 extra_source]...
  /// `request` — one of:
  ///   "probe-part-count"                     -> number of payload parts
  ///   "probe-main-source-len"                -> length of the main source
  ///   "len-mode:<mode>:<entry>"              -> compiled byte length
  ///   "hex-chunk-mode:<mode>:<entry>:<n>"    -> n-th 1024-byte hex chunk
  /// Returns "" on any error.
  export compile: func(source: string, request: string) -> string;
}
EOF

cat > "$HOSTED_WIT" <<'EOF'
package vibe:vibec@0.1.0;

world vibec-hosted {
  /// Host-provided virtual filesystem (#1109-2). The core's Fs host imports
  /// are lifted here, so the HOST decides what a path means: the real
  /// filesystem under wasmtime, an in-memory map in a browser IDE.
  import read-file:  func(path: string) -> string;        // traps if missing
  import exists:     func(path: string) -> bool;
  import read-dir:   func(path: string) -> string;        // "\n"-joined names
  import stat-token: func(path: string) -> s64;           // stable content token; -1 = non-regular

  /// Same request protocol as world vibec's `compile`, but the first
  /// argument is a real PATH resolved through the vfs imports above:
  ///   "len-mode:<mode>:<entry>"            -> compiled byte length
  ///   "hex-chunk-mode:<mode>:<entry>:<n>"  -> n-th 1024-byte hex chunk
  /// Returns "" on any error.
  export compile-file: func(input-path: string, request: string) -> string;
}
EOF

echo "vibec core             -> $CORE ($(wc -c <"$CORE") bytes)"
echo "vibec component        -> $COMPONENT ($(wc -c <"$COMPONENT") bytes)"
echo "vibec hosted component -> $HOSTED_COMPONENT ($(wc -c <"$HOSTED_COMPONENT") bytes)"
echo "vibec wit              -> $WIT / $HOSTED_WIT"
