#!/usr/bin/env bash
# The compile-only artifact (#2497) has exactly the lanes it claims, asked of
# the WASM rather than of the source.
#
# scripts/build_compile_only.sh roots the module-source DCE at
# `main_compile_only`, whose lane tables name only the production compiles.
# Two things must then hold, and each is checked where it can be seen:
#
#   1. ABSENCE. The wasm defines no function from the gc backend
#      (codegen/gc, entry/source_compile/gc_only), no instrumentation compile
#      (coverage / trace / break), no rc-shadow, body-cache, heap-marked,
#      testmeta or artifact-input-trace twin. Read from the name section, so
#      the artifact is built with VIBE_WASM_NAMES=1 -- and a wasm whose
#      functions are mostly UNNAMED fails here: a scanner that cannot see is
#      unchecked, not safe.
#   2. REFUSAL. Each switch that selects a dropped lane (VIBE_BACKEND=gc,
#      VIBE_DEBUG_BREAK=1, VIBE_DEBUG=1, VIBE_RC=shadow, VIBE_COVERAGE=1,
#      VIBE_CODEGEN_BODY_CACHE=on) produces no wasm and a diagnostic that names
#      the switch. Silently compiling on another lane is the failure this
#      guards against (policy: never silently wrong).
#   3. ACCEPTANCE. The two production lanes still compile, and the default
#      lane's output runs.
#
# Usage:
#   bash scripts/check_compile_only_lanes.sh
#       builds the named artifact with scripts/build_compile_only.sh (compiler:
#       COMPILE_ONLY_STAGE2 override, else the generation for HEAD) and runs 1-3
#   bash scripts/check_compile_only_lanes.sh --artifact W --entry NAME
#       runs 1-3 against an existing wasm, invoked through NAME
#   bash scripts/check_compile_only_lanes.sh --scan-only W
#       runs check 1 alone against W (the self-test's mutation probe)
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

ARTIFACT=""
ENTRY="cli_main_compile_only"
SCAN_ONLY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifact) ARTIFACT="$2"; shift 2 ;;
    --entry) ENTRY="$2"; shift 2 ;;
    --scan-only) SCAN_ONLY="$2"; shift 2 ;;
    *) echo "check-compile-only-lanes: unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "compile-only-lanes: FAIL: $*" >&2; exit 1; }

# Function-name fragments of the dropped lanes. Each is a source-level name
# (the flatten keeps it as a prefix of the mangled wasm name) or a module path
# fragment (`<file>_vibe` suffixes carry the module). Measured on the CLI
# stage2 they match 190 functions / 158 KB; on the compile-only artifact, 0.
#
# The last two are #2497 unit 2's witnesses: `emit_shadow_mark_freed` and
# `emit_str_operand_guard` are called only from the `rc_shadow` arms of the
# builtin body generators (`gen_rc_drop_body`, `gen_str_concat_body`), whose
# `rc_shadow` parameter every remaining caller passes as `false`, so the fold
# (`fold_const_bool_params`) removes the arms and the pruner the helpers. They
# were present in the unit-1 artifact, which dropped lanes by reachability
# only.
ABSENT_PATTERNS='emit_shadow_mark_freed|emit_str_operand_guard|codegen_gc_backend|source_compile_gc_only|compile_file_fs_mode_gc|compile_file_fs_mode_break|compile_file_fs_mode_trace|compile_file_fs_mode_coverage|compile_file_fs_mode_rc_shadow|compile_file_fs_mode_rc_body_cached|compile_file_fs_mode_testmeta|heap_marked|artifact_input_trace|sources_coverage_impl|sources_trace_impl|sources_break_impl|rc_shadow_impl|gc_only_impl|wasi_only_coverage|wasi_only_rc_shadow'

scan_names() { # <wasm>
  local wasm="$1" listing
  listing="$(mktemp "${TMPDIR:-/tmp}/compile_only_names.XXXXXX")"
  node scripts/wasm_func_sizes.mjs "$wasm" --top 1000000 >"$listing" 2>/dev/null \
    || { rm -f "$listing"; fail "could not read $wasm (scripts/wasm_func_sizes.mjs)"; }
  local summary total named
  summary="$(grep -E '^-- code section:' "$listing" || true)"
  total="$(printf '%s\n' "$summary" | sed -n 's/.* across \([0-9]*\) functions.*/\1/p')"
  named="$(printf '%s\n' "$summary" | sed -n 's/.*(\([0-9]*\) named).*/\1/p')"
  [ -n "$total" ] && [ -n "$named" ] || { rm -f "$listing"; fail "no code-section summary for $wasm"; }
  # The strip drops the name section; a stripped artifact must be reported as
  # unreadable, never as clean. 90% is far below any named build (measured
  # 5617/6003 = 93.6%; the unnamed rest are runtime and generated helpers) and
  # far above a stripped one (0).
  if [ "$total" -eq 0 ] || [ $((named * 100 / total)) -lt 90 ]; then
    rm -f "$listing"
    fail "$wasm names only $named of $total functions; build it with VIBE_WASM_NAMES=1 (scripts/build_compile_only.sh --names) so the lane check can see"
  fi
  local hits
  hits="$(grep -E '^ *[0-9]+ #' "$listing" | awk '{print $1, $NF}' | grep -E "$ABSENT_PATTERNS" || true)"
  rm -f "$listing"
  if [ -n "$hits" ]; then
    echo "compile-only-lanes: FAIL: $wasm still defines functions of a dropped lane:" >&2
    printf '%s\n' "$hits" | sort -rn | head -40 >&2
    exit 1
  fi
  echo "compile-only-lanes: absence ok ($named of $total functions named, none from a dropped lane)"
}

if [ -n "$SCAN_ONLY" ]; then
  scan_names "$SCAN_ONLY"
  exit 0
fi

if [ -z "$ARTIFACT" ]; then
  ARTIFACT="$ROOT_DIR/_build/compile_only/vibe_compile_only.names.wasm"
  COMPILE_ONLY_COMPILER="${COMPILE_ONLY_STAGE2:-}" \
    bash scripts/build_compile_only.sh --names --out "$ARTIFACT" >&2 \
    || fail "scripts/build_compile_only.sh failed"
fi
[ -s "$ARTIFACT" ] || fail "artifact not found: $ARTIFACT"

# Private scratch: the gate and its self-test may run side by side.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/compile_only_lanes.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Clear every CLI selector the launcher knows before each probe compile, so an
# inherited one (`VIBE_CHECK_ONLY=1` in the caller's environment) cannot turn
# the compile into another verb. Same source as scripts/build_compile_only.sh:
# runtime/vibe's VIBE_SELECTOR_ORDER, kept in sync with cli_adapter.vibe by
# scripts/check_selector_precedence.sh.
SELECTOR_ORDER="$(sed -n '/^VIBE_SELECTOR_ORDER="/,/"$/p' "$ROOT_DIR/runtime/vibe" | tr -d '"' | sed 's/^VIBE_SELECTOR_ORDER=//')"
[ -n "$SELECTOR_ORDER" ] || fail "runtime/vibe has no VIBE_SELECTOR_ORDER"
CLEAR_ARGS=""
for s in $SELECTOR_ORDER; do CLEAR_ARGS="$CLEAR_ARGS -u $s"; done
# Allocating, so the RC and bump lanes have something to differ on.
cat > "$WORK/probe.vibe" <<'VIBE'
fn main() -> Int {
  let xs = [1, 2, 3]
  let ys = [Array::length(xs), 4]
  Array::length(ys) + Array::length(xs) + 37
}
VIBE

compile_probe() { # <label> <env assignments...>; sets PROBE_OUT / PROBE_DIAG
  local label="$1"; shift
  PROBE_OUT="$WORK/$label.wasm"
  PROBE_DIAG=""
  rm -f "$PROBE_OUT" "$PROBE_OUT.diag"
  env $CLEAR_ARGS -u VIBE_RC -u VIBE_CODEGEN_BODY_CACHE "$@" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke "$ENTRY" "$ARTIFACT" \
    "$WORK/probe.vibe" "$PROBE_OUT" main >"$WORK/$label.log" 2>&1 || true
  if [ -f "$PROBE_OUT.diag" ]; then
    PROBE_DIAG="$(cat "$PROBE_OUT.diag")"
  fi
  return 0
}

# 2. refusal, one switch at a time, each on top of the cleared env above (so
# a caller's exported VIBE_RC / VIBE_BACKEND cannot leak in either).
refuse() { # <switch NAME=VALUE>
  local switch="$1"
  compile_probe "refuse_${switch%%=*}" "$switch"
  if [ -s "$PROBE_OUT" ]; then
    fail "$switch was ACCEPTED by $ARTIFACT (invoke $ENTRY): it compiled the probe instead of refusing the lane"
  fi
  case "$PROBE_DIAG" in
    *"has no lane for $switch"*) ;;
    *) fail "$switch produced no wasm but the diagnostic does not name it: '${PROBE_DIAG:-<none>}'" ;;
  esac
}
for sw in VIBE_BACKEND=gc VIBE_DEBUG_BREAK=1 VIBE_DEBUG=1 VIBE_RC=shadow VIBE_COVERAGE=1 VIBE_CODEGEN_BODY_CACHE=on; do
  refuse "$sw"
done
echo "compile-only-lanes: refusal ok (6 switches refused by name)"

# 3. acceptance: the default (RC) lane and the bump lane compile; they differ;
# the default output runs.
compile_probe default
[ -s "$PROBE_OUT" ] || fail "the default lane did not compile the probe: ${PROBE_DIAG:-<no diag>}"
DEFAULT_OUT="$PROBE_OUT"
compile_probe bump VIBE_RC=0
[ -s "$PROBE_OUT" ] || fail "the bump lane (VIBE_RC=0) did not compile the probe: ${PROBE_DIAG:-<no diag>}"
cmp -s "$DEFAULT_OUT" "$PROBE_OUT" && fail "the default and VIBE_RC=0 outputs are identical, so the probe cannot tell the two lanes apart"
got="$(bash scripts/run_wasm_vibe_host_runner.sh "$DEFAULT_OUT" 2>/dev/null | tail -1 | tr -d '[:space:]')"
[ "$got" = "42" ] || fail "the default lane's output printed '$got', expected 42"
echo "compile-only-lanes: acceptance ok (RC and bump lanes compile, default runs)"

# 1. absence, last: it needs the name section and says so when it is missing.
scan_names "$ARTIFACT"
echo "compile-only-lanes: ok ($ARTIFACT, $(wc -c <"$ARTIFACT") bytes with names)"
