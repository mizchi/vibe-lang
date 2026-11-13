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
#      Since #2499 the same holds for the component tools of the positional
#      protocol (WIT emission, the serve and command lifts, the vfs wraps),
#      plus formatter and LSP server code. The async component composition
#      that user programs reach must still be PRESENT, as must the shared
#      JSON diagnostics.
#   2. REFUSAL. Each switch that selects a dropped lane (VIBE_BACKEND=gc,
#      VIBE_DEBUG_BREAK=1, VIBE_DEBUG=1, VIBE_RC=shadow, VIBE_COVERAGE=1,
#      VIBE_CODEGEN_BODY_CACHE=on) or a dropped tool (VIBE_EMIT_WIT=1,
#      VIBE_SERVE_COMPONENT=1, VIBE_BUILD_COMPONENT=1, VIBE_FMT=1, VIBE_LSP=1)
#      produces no artifact and a diagnostic that names the switch. LSP
#      reports on stderr before the positional output path is read. Silently
#      compiling on another lane, or writing a core module where a component
#      was asked for, is the failure this guards against (policy: never
#      silently wrong).
#   2b. TELEMETRY (#2498). The artifact is flattened without the compiler's
#      `telemetry` cfg flag, so the ingestion-pipeline counters and their JSON
#      encoder are absent (check 1 reads it), and a request for that sidecar
#      (VIBE_INGESTION_PIPELINE_TELEMETRY_OUT) publishes nothing and fails
#      naming VIBE_CFG=telemetry -- never an empty or all-zero observation.
#      The scheduler trace is the same shape: its row encoders are absent, and
#      VIBE_SCHEDULER_TRACE on a compile writes no trace and fails naming
#      VIBE_CFG=telemetry -- an empty trace would read as a run that planned
#      nothing.
#      Heap marks are the same shape: the emitter is absent, and
#      VIBE_PROFILE_MEMORY_MARKS=1 on a compile fails naming VIBE_CFG=telemetry
#      rather than printing no marks, and only after the stale-sidecar cleanup
#      (a planted VIBE_INCREMENTAL_TELEMETRY_OUT file must be gone).
#   3. ACCEPTANCE. The two production lanes still compile, and the default
#      lane's output runs. Cfg, unstable authorization and generated-source
#      trust remain per-compilation inputs to this same artifact.
#
# Usage:
#   bash scripts/check_compile_only_lanes.sh
#       builds the named artifact with scripts/build_compile_only.sh (compiler:
#       COMPILE_ONLY_STAGE2 override, else the generation for HEAD) and runs 1-3
#   bash scripts/check_compile_only_lanes.sh --artifact W --entry NAME
#       runs 1-3 against an existing wasm, invoked through NAME
#   bash scripts/check_compile_only_lanes.sh --scan-only W
#       runs check 1 alone against W (the self-test's mutation probe)
#   bash scripts/check_compile_only_lanes.sh --artifact W --entry NAME --tools-only
#       runs the tool half of check 2 alone (the self-test's probe
#       for it: the full CLI fails the lane half first)
#   bash scripts/check_compile_only_lanes.sh --artifact W --entry NAME --telemetry-only
#       runs check 2b's ingestion-pipeline half alone (the self-test hands it a
#       telemetry-enabled stage2)
#   bash scripts/check_compile_only_lanes.sh --artifact W --entry NAME --scheduler-trace-only
#       runs check 2b's scheduler-trace half alone (likewise)
#   bash scripts/check_compile_only_lanes.sh --artifact W --entry NAME --memory-marks-only
#       runs check 2b's heap-mark half alone (likewise)
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

ARTIFACT=""
ENTRY="cli_main_compile_only"
SCAN_ONLY=""
TOOLS_ONLY=0
TELEMETRY_ONLY=0
SCHEDULER_TRACE_ONLY=0
MEMORY_MARKS_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifact) ARTIFACT="$2"; shift 2 ;;
    --entry) ENTRY="$2"; shift 2 ;;
    --scan-only) SCAN_ONLY="$2"; shift 2 ;;
    --tools-only) TOOLS_ONLY=1; shift ;;
    --telemetry-only) TELEMETRY_ONLY=1; shift ;;
    --scheduler-trace-only) SCHEDULER_TRACE_ONLY=1; shift ;;
    --memory-marks-only) MEMORY_MARKS_ONLY=1; shift ;;
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
# #2497: measured replay, relocation and harvest code. Cache constructors and
# layout fingerprints remain shared with production; they are not cache replay.
ABSENT_PATTERNS="$ABSENT_PATTERNS|codegen_body_cache_(replay|record|filter_fold_sigs|find_at|find_named|set_fold_table)|lc_src_edit_(of|reindex|replayable)|lc_relocate_replayed_strings|lc_string_remap|lc_(types|structs|effects)_agree"
# #2499: the component tools only the full CLI installs (component_tools_full,
# cli_adapter_cli_main_with_lanes.vibe): the three adapters, the WIT generator,
# the serve / command lifts and the vfs wraps they alone reach (#2504's
# inventory of what those arms held).
ABSENT_PATTERNS="$ABSENT_PATTERNS|(^| )adapter_(emit_wit|serve_component|command_component)|codegen_wit_wit_gen_vibe|(^| )wit_from_program|(^| )validate_serve_handler|(^| )comp_emit_component_wasm_(string_handler|stream_handler|command|service_handler)|(^| )comp_emit_string_handler|(^| )comp_generate_vfs_|(^| )comp_generate_serve_stream_adapter_module"
# #2499: the formatter and LSP server. The LSP package also defines shared
# JSON diagnostics, so match server entry points instead of its module path.
ABSENT_PATTERNS="$ABSENT_PATTERNS|(^| )adapter_format|compiler_fmt_|(^| )format_source|(^| )lsp_(main|step|dispatch_request|run_with_handler)"
# What must stay: the async component composition the production compile lanes
# reach for a user program (`maybe_wrap_async_component`,
# `maybe_wrap_stdin_provider_core`). Each pattern must match at least one
# function, so a cut that removed the lane a user program needs fails here
# instead of passing as a smaller artifact.
PRESENT_PATTERNS='comp_emit_component_wasm_async_stdin_provider|comp_emit_component_wasm_async_hostfuture|maybe_wrap_async_component|maybe_wrap_stdin_provider_core|lsp_diagnostics_json'
# #2498: the `#cfg(telemetry)` half of loader/ingestion_pipeline_telemetry.vibe
# -- the counter cells, their reader and the sidecar encoder. Its
# `#cfg(not(telemetry))` twins (`..._refusal`, `..._publish`, the no-op
# `..._add`) keep other names and may remain.
ABSENT_PATTERNS="$ABSENT_PATTERNS|ingestion_pipeline_telemetry_json|ingestion_pipeline_json_string|ingestion_pipeline_counter|ingestion_pipeline_enabled"
# #2498: the scheduler trace's row encoders
# (runtime/typecheck_fs_ensure_fingerprint_fs_impl.vibe). Only the
# `#cfg(telemetry)` trace points reach them; the points' no-op twins
# (`scheduler_trace_planned` / `_published` / `_publish`) and the
# `scheduler_trace_refusal` stub keep other names and may remain.
ABSENT_PATTERNS="$ABSENT_PATTERNS|scheduler_trace_project|scheduler_trace_step"
# #2498: the heap-mark emitter (cli_adapter_cli_main_with_lanes.vibe). Only
# the `#cfg(telemetry)` marks reach it; their no-op twins
# (`profile_memory_mark`, `profile_memory_phase_mark`) and the
# `profile_memory_marks_refusal` stub keep other names and may remain.
ABSENT_PATTERNS="$ABSENT_PATTERNS|profile_memory_mark_emit"

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
  local hits names
  names="$(grep -E '^ *[0-9]+ #' "$listing" | awk '{print $1, $NF}')"
  rm -f "$listing"
  hits="$(printf '%s\n' "$names" | grep -E "$ABSENT_PATTERNS" || true)"
  if [ -n "$hits" ]; then
    echo "compile-only-lanes: FAIL: $wasm still defines functions of a dropped lane:" >&2
    printf '%s\n' "$hits" | sort -rn | head -40 >&2
    exit 1
  fi
  local want
  for want in $(printf '%s' "$PRESENT_PATTERNS" | tr '|' ' '); do
    # A here-string, not a pipe: under pipefail `grep -q` closing the pipe
    # early fails the writer, and a present name would read as missing.
    grep -qE "$want" <<<"$names" \
      || fail "$wasm defines no required function matching '$want'"
  done
  echo "compile-only-lanes: absence ok ($named of $total functions named, none from a dropped lane; the async component lane is present)"
}

if [ -n "$SCAN_ONLY" ]; then
  scan_names "$SCAN_ONLY"
  exit 0
fi

if [ -z "$ARTIFACT" ]; then
  ARTIFACT="$ROOT_DIR/_build/compile_only/vibe_compile_only.names.wasm"
  COMPILE_ONLY_COMPILER="${COMPILE_ONLY_STAGE2:-${VIBE_STAGE2_WASM:-}}" \
    bash scripts/build_compile_only.sh --names --out "$ARTIFACT" >&2 \
    || fail "scripts/build_compile_only.sh failed"
fi
[ -s "$ARTIFACT" ] || fail "artifact not found: $ARTIFACT"

# Private scratch: the gate and its self-test may run side by side.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/compile_only_lanes.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Clear every adapter selector before each probe compile, so an inherited
# `VIBE_CHECK_ONLY=1` cannot turn the compile into another verb. Derived
# from cli_adapter.vibe (scripts/adapter_selector_order.sh); the launcher
# no longer embeds VIBE_SELECTOR_ORDER.
SELECTOR_ORDER="$(bash "$ROOT_DIR/scripts/adapter_selector_order.sh")"
[ -n "$SELECTOR_ORDER" ] || fail "no adapter selectors found in cli_adapter.vibe"
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

compile_input_mode() { # <FS 0/1> <source> <label> <env assignments...>
  local fs_mode="$1" source="$2" label="$3"; shift 3
  PROBE_OUT="$WORK/$label.wasm"
  PROBE_DIAG=""
  rm -f "$PROBE_OUT" "$PROBE_OUT.diag"
  env $CLEAR_ARGS -u VIBE_RC -u VIBE_CODEGEN_BODY_CACHE -u VIBE_CFG -u VIBE_UNSTABLE -u VIBE_INTERNAL_TRUSTED_SOURCE "$@" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE="$fs_mode" VIBE_IMPORT_ABI=raw VIBE_SKIP_RUN_INIT=1 VIBE_RUNNER_EXIT_WITH_RESULT=1 \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke "$ENTRY" "$ARTIFACT" \
    "$source" "$PROBE_OUT" main >"$WORK/$label.log" 2>&1 || true
  if [ -f "$PROBE_OUT.diag" ]; then
    PROBE_DIAG="$(cat "$PROBE_OUT.diag")"
  fi
  return 0
}

compile_input() { compile_input_mode 1 "$@"; }
compile_probe() { compile_input "$WORK/probe.vibe" "$@"; }

require_answer() { # <expected integer>
  [ -s "$PROBE_OUT" ] || fail "the probe did not compile: ${PROBE_DIAG:-<no diag>}"
  local answer
  answer="$(bash scripts/run_wasm_vibe_host_runner.sh "$PROBE_OUT" 2>/dev/null | tail -1 | tr -d '[:space:]')"
  [ "$answer" = "$1" ] || fail "the probe printed '$answer', expected '$1'"
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
# The formatter and component tools come after the FS compile arm. Select
# them without FS compile and check their positional diagnostic sidecar.
refuse_tool() { # <switch NAME=VALUE>
  local switch="$1"
  compile_input_mode 0 "$WORK/probe.vibe" "refuse_${switch%%=*}" "$switch"
  if [ -s "$PROBE_OUT" ]; then
    fail "$switch was ACCEPTED by $ARTIFACT (invoke $ENTRY): it wrote an artifact instead of refusing the tool"
  fi
  case "$PROBE_DIAG" in
    *"has no tool for $switch"*) ;;
    *) fail "$switch produced no output but the diagnostic does not name it: '${PROBE_DIAG:-<none>}'" ;;
  esac
}
refuse_lsp() {
  local rc=0 out="$WORK/refuse_lsp.wasm"
  # LSP takes precedence over FS compile and handles its own streams. Even
  # with an input and output path supplied, it must refuse on stderr.
  env $CLEAR_ARGS -u VIBE_RUNNER_EXIT_WITH_RESULT -u VIBE_RUNNER_QUIET_RESULT \
    VIBE_LSP=1 VIBE_FS_COMPILE=1 VIBE_STDIN_BYTES="" \
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_SKIP_RUN_INIT=1 \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke "$ENTRY" "$ARTIFACT" \
    "$WORK/probe.vibe" "$out" main >"$WORK/lsp.stdout" 2>"$WORK/lsp.stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "VIBE_LSP=1 was ACCEPTED by $ARTIFACT (invoke $ENTRY)"
  [ "$rc" -eq 1 ] || fail "VIBE_LSP=1 exited with $rc instead of 1"
  grep -qF "has no tool for VIBE_LSP=1" "$WORK/lsp.stderr" \
    || fail "VIBE_LSP=1 did not report its refusal on stderr: $(cat "$WORK/lsp.stderr")"
  [ ! -e "$out" ] && [ ! -e "$out.diag" ] \
    || fail "VIBE_LSP=1 touched the positional output"
  [ ! -s "$WORK/lsp.stdout" ] || fail "VIBE_LSP=1 wrote unexpected stdout"
}
refuse_tools() {
  for sw in VIBE_EMIT_WIT=1 VIBE_SERVE_COMPONENT=1 VIBE_BUILD_COMPONENT=1 VIBE_FMT=1; do
    refuse_tool "$sw"
  done
  refuse_lsp
  echo "compile-only-lanes: tool refusal ok (3 component tools, fmt and LSP refused by name)"
}
if [ "$TOOLS_ONLY" = 1 ]; then
  refuse_tools
  exit 0
fi
# 2b. telemetry: a check-only request for the ingestion-pipeline sidecar.
# The positive control is the generation's stage2, flattened WITH the flag:
# scripts/ingestion_pipeline_telemetry_integration.mjs reads its sidecar, and
# this gate's self-test hands it to --telemetry-only, which must fail.
refuse_telemetry() {
  local sidecar="$WORK/ingestion_pipeline.json"
  rm -f "$sidecar"
  compile_probe refuse_ingestion_pipeline VIBE_CHECK_ONLY=1 \
    VIBE_INGESTION_PIPELINE_TELEMETRY_OUT="$sidecar" VIBE_INGESTION_PIPELINE_TELEMETRY_NONCE=compile-only-2498
  if [ -e "$sidecar" ]; then
    fail "VIBE_INGESTION_PIPELINE_TELEMETRY_OUT was ACCEPTED by $ARTIFACT (invoke $ENTRY): it published '$(head -c 160 "$sidecar")'"
  fi
  if [ -s "$PROBE_OUT" ] && grep -qx ok "$PROBE_OUT"; then
    fail "VIBE_INGESTION_PIPELINE_TELEMETRY_OUT was ignored by $ARTIFACT: the check answered ok without the sidecar it was asked for"
  fi
  grep -qF "VIBE_CFG=telemetry" "$WORK/refuse_ingestion_pipeline.log" \
    || fail "VIBE_INGESTION_PIPELINE_TELEMETRY_OUT was refused, but not by naming VIBE_CFG=telemetry: '$(tail -3 "$WORK/refuse_ingestion_pipeline.log")'"
}
# The scheduler trace rides a compile, not a check: the walk it records is the
# FS compile lane's import-DAG walk. The generation's stage2 writes it even for
# this one-module probe (a `project` and a `step` row).
#
# The refusal must come AFTER the CLI's shared stale-sidecar cleanup: a sibling
# observation requested on the same run (here VIBE_INCREMENTAL_TELEMETRY_OUT,
# which a compile accepts) whose file is left over from an earlier run would
# otherwise survive the refused invocation and read as its result. So the
# probe plants a stale sibling sidecar and requires it gone.
refuse_scheduler_trace() {
  local trace="$WORK/scheduler.trace" stale="$WORK/stale_incremental_telemetry.json"
  rm -f "$trace"
  printf 'stale sidecar from an earlier run\n' >"$stale"
  compile_probe refuse_scheduler_trace VIBE_SCHEDULER_TRACE="$trace" VIBE_INCREMENTAL_TELEMETRY_OUT="$stale"
  if [ -e "$trace" ]; then
    fail "VIBE_SCHEDULER_TRACE was ACCEPTED by $ARTIFACT (invoke $ENTRY): it wrote '$(head -c 160 "$trace")'"
  fi
  if grep -qF "stale sidecar from an earlier run" "$stale" 2>/dev/null; then
    fail "VIBE_SCHEDULER_TRACE was refused before the stale-sidecar cleanup by $ARTIFACT (invoke $ENTRY): the earlier run's VIBE_INCREMENTAL_TELEMETRY_OUT sidecar survived the refused invocation"
  fi
  if [ -s "$PROBE_OUT" ]; then
    fail "VIBE_SCHEDULER_TRACE was ignored by $ARTIFACT: it compiled the probe without the trace it was asked for"
  fi
  # A here-string, not a pipe: under pipefail `grep -q` closing the pipe early
  # fails the writer, and a refusal that names the flag would read as one
  # that does not.
  grep -qF "VIBE_CFG=telemetry" <<<"$(cat "$WORK/refuse_scheduler_trace.log")
$PROBE_DIAG" \
    || fail "VIBE_SCHEDULER_TRACE was refused, but not by naming VIBE_CFG=telemetry: '$(tail -3 "$WORK/refuse_scheduler_trace.log") ${PROBE_DIAG}'"
}
if [ "$TELEMETRY_ONLY" = 1 ]; then
  refuse_telemetry
  echo "compile-only-lanes: telemetry refusal ok"
  exit 0
fi
# Heap marks ride a compile too. The generation's stage2 compiles the probe
# and prints its marks; a build without them must refuse by name, after the
# same stale-sidecar cleanup as the scheduler trace above.
refuse_memory_marks() {
  local stale="$WORK/stale_incremental_telemetry.json"
  printf 'stale sidecar from an earlier run\n' >"$stale"
  compile_probe refuse_memory_marks VIBE_PROFILE_MEMORY_MARKS=1 VIBE_INCREMENTAL_TELEMETRY_OUT="$stale"
  if [ -s "$PROBE_OUT" ]; then
    fail "VIBE_PROFILE_MEMORY_MARKS=1 was ACCEPTED by $ARTIFACT (invoke $ENTRY): it compiled the probe"
  fi
  if grep -qF "stale sidecar from an earlier run" "$stale" 2>/dev/null; then
    fail "VIBE_PROFILE_MEMORY_MARKS=1 was refused before the stale-sidecar cleanup by $ARTIFACT (invoke $ENTRY): the earlier run's VIBE_INCREMENTAL_TELEMETRY_OUT sidecar survived the refused invocation"
  fi
  grep -qF "VIBE_CFG=telemetry" <<<"$(cat "$WORK/refuse_memory_marks.log")
$PROBE_DIAG" \
    || fail "VIBE_PROFILE_MEMORY_MARKS=1 was refused, but not by naming VIBE_CFG=telemetry: '$(tail -3 "$WORK/refuse_memory_marks.log") ${PROBE_DIAG}'"
}
if [ "$SCHEDULER_TRACE_ONLY" = 1 ]; then
  refuse_scheduler_trace
  echo "compile-only-lanes: scheduler trace refusal ok"
  exit 0
fi
if [ "$MEMORY_MARKS_ONLY" = 1 ]; then
  refuse_memory_marks
  echo "compile-only-lanes: heap-mark refusal ok"
  exit 0
fi

for sw in VIBE_BACKEND=gc VIBE_DEBUG_BREAK=1 VIBE_DEBUG=1 VIBE_RC=shadow VIBE_COVERAGE=1 VIBE_CODEGEN_BODY_CACHE=on; do
  refuse "$sw"
done
echo "compile-only-lanes: refusal ok (6 switches refused by name)"
refuse_tools
refuse_telemetry
echo "compile-only-lanes: telemetry refusal ok (VIBE_INGESTION_PIPELINE_TELEMETRY_OUT refused, no sidecar)"
refuse_scheduler_trace
echo "compile-only-lanes: telemetry refusal ok (VIBE_SCHEDULER_TRACE refused, no trace)"
refuse_memory_marks
echo "compile-only-lanes: telemetry refusal ok (VIBE_PROFILE_MEMORY_MARKS=1 refused after the sidecar cleanup)"

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

# The editor protocol and positional JSON diagnostics share an encoder. A
# malformed program must still produce structured diagnostics without LSP.
printf 'fn main() -> Int { "a" }\n' > "$WORK/diagnostics.vibe"
compile_input_mode 0 "$WORK/diagnostics.vibe" diagnostics VIBE_DIAGNOSTICS=1 VIBE_DIAGNOSTICS_JSON=1
node -e '
  const rows = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (!rows.some((row) => row.severity === 1 && row.range.start.line === 0 &&
      row.message.includes("return type mismatch"))) process.exit(1);
' "$PROBE_OUT" || fail "JSON diagnostics did not report the return type mismatch"
echo "compile-only-lanes: JSON diagnostics ok"

# Specializing the compiler's cache policy must not bake the target program's
# cfg or authorization into that compiler. Reuse one artifact and cache while
# switching each input in both directions.
cat > "$WORK/cfg.vibe" <<'VIBE'
#cfg(alpha)
fn choose() -> Int { 42 }
#cfg(beta)
fn choose() -> Int { 43 }
fn main() -> Int { choose() }
VIBE
for flag in alpha beta alpha; do
  compile_input "$WORK/cfg.vibe" cfg VIBE_CFG="$flag" VIBE_BUILD_CACHE_DIR="$WORK/cache"
  if [ "$flag" = alpha ]; then require_answer 42; else require_answer 43; fi
done
cat > "$WORK/unstable.vibe" <<'VIBE'
import @vibe/concurrent/experimental { TaskGroup }
fn main() -> Int allows Exception {
  TaskGroup::run((g) -> {
    let _t = TaskGroup::spawn(g, f = () -> { 7 })
    0
  })
}
VIBE
for optin in 0 1 0; do
  compile_input "$WORK/unstable.vibe" unstable VIBE_UNSTABLE="$optin" VIBE_BUILD_CACHE_DIR="$WORK/cache"
  if [ "$optin" = 1 ]; then
    [ -s "$PROBE_OUT" ] || fail "VIBE_UNSTABLE=1 did not enable the experimental import: $PROBE_DIAG"
  else
    [ ! -s "$PROBE_OUT" ] || fail "the experimental import was accepted without VIBE_UNSTABLE=1"
    case "$PROBE_DIAG" in *VIBE_UNSTABLE=1*) ;; *) fail "the unstable refusal did not name the opt-in: $PROBE_DIAG" ;; esac
  fi
done
echo "compile-only-lanes: per-compilation cfg and unstable inputs ok"

# This reserved import is a real serialized provenance carrier. Only the
# single-source generated-input lane may accept it; source text cannot grant
# itself that authority. The FS loader always validates user modules first.
cat > "$WORK/trusted.vibe" <<'VIBE'
import @vibe/compiler/internal/iterator_boundary { }
fn main() -> Int { 42 }
VIBE
for allocator in 1 0; do
  for trusted in 0 1 0; do
    compile_input_mode 0 "$WORK/trusted.vibe" trusted VIBE_RC="$allocator" VIBE_INTERNAL_TRUSTED_SOURCE="$trusted"
    if [ "$trusted" = 1 ]; then
      require_answer 42
    else
      [ ! -s "$PROBE_OUT" ] || fail "reserved provenance was accepted without generated-source trust"
      case "$PROBE_DIAG" in *'remove reserved compiler import'*) ;; *) fail "the untrusted refusal lost its diagnostic: $PROBE_DIAG" ;; esac
    fi
  done
done
echo "compile-only-lanes: per-compilation generated-source trust ok (RC and bump)"

# 1. absence, last: it needs the name section and says so when it is missing.
scan_names "$ARTIFACT"
echo "compile-only-lanes: ok ($ARTIFACT, $(wc -c <"$ARTIFACT") bytes with names)"
