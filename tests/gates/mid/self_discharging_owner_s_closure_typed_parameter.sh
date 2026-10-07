#!/usr/bin/env bash
# Sourced by this lane's run.sh; shares its resolved compiler and gate state.
# 40ar. #1070 (general case, second slice -- docs/internal/design/effect-evidence-passing.md
#       追記25): a SELF-DISCHARGING owner -- a function with NO `with Ask`
#       row that establishes its own `handle .. with Ask` and calls its
#       closure-typed parameter inside that handle's body. Never "needing"
#       (no row), so 40ap's edp_own_closure_params path can't see it; was
#       the exact shape #1077's original lsp_run_with_handler trapped on
#       under real wasmtime. Fixed by edp_handle_owner_cps
#       (inline_direct_perform.vibe): same universal call-site proof as
#       40ap plus the two extra guards a missing row makes necessary (no
#       value references to the owner; every param use is a direct call
#       inside the owner's own Ask-handle bodies).
echo "[compiler-gate] 40ar/40 self-discharging owner's closure-typed parameter (#1070 general case, second slice)"
edphdir="_build/_gate_edp_handle_owner_param"
rm -rf "$edphdir"; mkdir -p "$edphdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/effect_local_closure_handle_owner_param.vibe "$edphdir/out.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$edphdir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: effect_local_closure_handle_owner_param.vibe did not compile" >&2
  cat "$edphdir/out.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! edph_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edphdir/out.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: effect_local_closure_handle_owner_param.vibe got '$edph_out' (want 285) -- #1070 self-discharging-owner closure-param fix regressed" >&2
  echo "$edph_out" >&2
  exit 1
fi
rm -rf "$edphdir"
echo "[compiler-gate] self-discharging owner's closure-typed parameter ok (285)"

# MOVED HERE FROM THE LATE LANE (#2650). Sections 114 and 127 build a split
# CLI core and then use it; the build is one compile of lib/@vibe/cli/main.vibex
# and it is the most cache-sensitive thing either lane does. Measured on the
# same PR, same runners, same caches:
#
#   late lane, suite present (run 34591255553)   section 114:  15.8s
#   late lane, suite moved out (run 34593676188) section 114: 150.7s
#
# Nothing about section 114 changed. The gate self-test suite that used to run
# ahead of it in the late lane compiled things on its way through
# (check_compile_only_lanes_test.sh, check_freeze_surface_test.sh,
# check_book_console.sh) and left the persistent build cache warm; without it
# the same compile pays cold. That coupling was invisible and nobody chose it.
#
# So the two sections move to the lane with room for them rather than being
# propped up by a side effect of an unrelated section running first. Measured
# lane durations before the move: late 363s, mid 58s. They move together
# because 127 uses the artifact 114 builds, and they are otherwise
# self-contained -- both take only $stage2_wasm, and 114 builds its own input.

# 114/114. The ADR-0068 gate exists in the SPLIT CLI, and its cached lane
#          cannot be used to get around it (#2305).
# Gate 108 covers the boundary on the shipped adapter, but it drives stage2
# through VIBE_CLI_WASM, so it cannot see lib/@vibe/cli/ by construction --
# stage2 is compiled from the flat adapter source and contains none of it.
# Measured before this landed, on a stage1 CLI core built from the tree:
# `check` returned 0 with no diagnostic both when the ENTRY imports
# @vibe/concurrent and when a SIBLING does, while the adapter refuses both.
#
# The cached lane is the sharp half. `compile_file_fs_mode_cached` returns on
# a persistent-artifact hit before it loads anything, so the closure record is
# empty and the gate answers "clean" -- build once WITH the opt-in, drop it,
# and the artifact came out anyway. That is why the warm case below is not
# redundant with the cold one: a port that only passes the cold case is
# silently permissive, which is worse than no gate.
echo "[compiler-gate] 114/114 the ADR-0068 gate exists in the split CLI, cold and warm (#2305)"
# WHICH compiler is this gate asking? The answer used to be "whatever
# `_build/bench/selfhost_cli_core/index_stage1.wasm` happens to hold", with no
# link to the stage2 the rest of the lane exercises. That path is written by
# other tooling, so on a reused workspace this gate silently questioned a CLI
# built from different sources -- twice in one session, and both times the
# result said nothing about the tree under test:
#
#   - an artifact predating the `allows` landing could not parse the gate's
#     OWN fixture, and answered `expected { but got ident` instead of the
#     ADR-0068 diagnostic: a false RED;
#   - the same mechanism can as easily produce a false GREEN, which is the
#     dangerous direction -- a stale CLI that still refuses correctly while
#     the current sources no longer do.
#
# CLAUDE.md states the rule this broke: a gate that asks the compiler a
# question has to be TOLD which compiler, and the ones that pick for
# themselves all pick the same wrong way.
#
# `VIBE_SPLIT_CLI_WASM` still overrides, because a caller naming an artifact
# explicitly has taken responsibility for its provenance.
sc_cache_dir="_build/_gate_split_cli_core"
sc_cli="${VIBE_SPLIT_CLI_WASM:-}"
if [ -z "$sc_cli" ]; then
  sc_cli="$sc_cache_dir/index_stage1.wasm"
  if gate_split_cli_cache_is_current "$ROOT_DIR/$sc_cache_dir" "$stage2_wasm"; then
    echo "[compiler-gate] 114/114 reusing the split CLI core built from THIS stage2 (#2305)"
  fi
fi
if [ ! -s "$ROOT_DIR/$sc_cli" ] && [ ! -s "$sc_cli" ]; then
  # BUILD it rather than skip (Codex review on #2313). The first version of
  # this section skipped when no split CLI core was present -- and `ci.yml`
  # never builds one, so the required late shard took the skip branch every
  # time and this regression tested nothing where it mattered. A skip branch
  # with an honest message is still a skip branch if it is the only one CI
  # ever reaches.
  #
  # The lane already has a stage2, which is all `build_cli_core.sh` needs as a
  # base compiler, so the gate can supply its own input: one compile of
  # lib/@vibe/cli/main.vibex, not a bootstrap.
  echo "[compiler-gate] 114/114 building the split CLI core (no artifact at $sc_cli) (#2305)"
  sc_built="_build/_gate_split_cli_core"
  rm -rf "$sc_built"
  if ! VIBE_CLI_CORE_BASE_COMPILER="$stage2_wasm" \
       VIBE_CLI_CORE_STAGE_TIMEOUT_SEC="${VIBE_CLI_CORE_STAGE_TIMEOUT_SEC:-1500}" \
       VIBE_CLI_CORE_OUT_DIR="$sc_built" \
       bash scripts/build_cli_core.sh >"$sc_built.log" 2>&1; then
    echo "[compiler-gate] FAIL: could not build the split CLI core for the #2305 gate" >&2
    tail -20 "$sc_built.log" >&2 || true
    exit 1
  fi
  sc_cli="$sc_built/index_stage1.wasm"
  if [ ! -s "$ROOT_DIR/$sc_cli" ] && [ ! -s "$sc_cli" ]; then
    echo "[compiler-gate] FAIL: split CLI core build produced no artifact for the #2305 gate" >&2
    exit 1
  fi
  # The provenance record the reuse check above reads. Written only after the
  # build succeeded, so a half-built cache is never mistaken for a match.
  cp "$stage2_wasm" "$ROOT_DIR/$sc_built/base_stage2.wasm"
fi
if true; then
  case "$sc_cli" in /*) sc_abs="$sc_cli" ;; *) sc_abs="$ROOT_DIR/$sc_cli" ;; esac
  scdir="_build/_gate_split_cli_unstable"
  rm -rf "$scdir"; mkdir -p "$scdir"
  cat > "$scdir/worker.vibe" <<'SCEOF'
import @vibe/concurrent/experimental { TaskGroup }

export fn work() -> Int {
  7
}
SCEOF
  cat > "$scdir/main.vibex" <<'SCEOF'
import ./worker.vibe { work }

fn main() -> Unit allows Console {
  println(Int::to_string(work()))
}
SCEOF
  sc_run() {
    env -u VIBE_UNSTABLE "$@" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$sc_abs" \
      build "$scdir/main.vibex" -o "$scdir/b.wasm" 2>&1 || true
  }
  # 1. cold, no opt-in: refused, and it must name the SIBLING that spells the
  #    import -- the entry pre-check alone cannot see that file.
  rm -f "$scdir/b.wasm"
  sc_cold="$(sc_run)"
  if [ -s "$scdir/b.wasm" ]; then
    echo "[compiler-gate] FAIL: the split CLI built an unstable dependency with no opt-in (#2305)" >&2
    printf '%s\n' "$sc_cold" >&2
    exit 1
  fi
  if ! printf '%s\n' "$sc_cold" | grep -qF 'worker.vibe'; then
    echo "[compiler-gate] FAIL: the split CLI's rejection does not name the sibling that imports it (#2305)" >&2
    printf '%s\n' "$sc_cold" >&2
    exit 1
  fi
  # 2. WITH the opt-in it builds, and warms whatever cache the lane keeps.
  rm -f "$scdir/b.wasm"
  sc_optin="$(env VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$sc_abs" \
    build "$scdir/main.vibex" -o "$scdir/b.wasm" 2>&1 || true)"
  if [ ! -s "$scdir/b.wasm" ]; then
    echo "[compiler-gate] FAIL: VIBE_UNSTABLE=1 did not let the split CLI build (#2305)" >&2
    printf '%s\n' "$sc_optin" >&2
    exit 1
  fi
  # 3. warm, opt-in removed: still refused. This is the case a naive port
  #    passes cold and fails here.
  rm -f "$scdir/b.wasm"
  sc_warm="$(sc_run)"
  if [ -s "$scdir/b.wasm" ]; then
    echo "[compiler-gate] FAIL: a warm artifact cache let the split CLI skip the ADR-0068 gate (#2305)" >&2
    printf '%s\n' "$sc_warm" >&2
    exit 1
  fi
  # 4. ...and a program with no unstable import still builds, cold and warm,
  #    so the guard is not simply refusing everything.
  printf 'fn main() -> Unit allows Console {\n  println("ok")\n}\n' > "$scdir/clean.vibex"
  for round in cold warm; do
    rm -f "$scdir/c.wasm"
    sc_clean="$(env -u VIBE_UNSTABLE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$sc_abs" \
      build "$scdir/clean.vibex" -o "$scdir/c.wasm" 2>&1 || true)"
    if [ ! -s "$scdir/c.wasm" ]; then
      echo "[compiler-gate] FAIL: the split CLI stopped building a clean program ($round) (#2305)" >&2
      printf '%s\n' "$sc_clean" >&2
      exit 1
    fi
  done
  rm -rf "$scdir"
  echo "[compiler-gate] the split CLI refuses an unstable dependency cold AND warm, and still builds clean programs ok (#2305)"
fi

# 127/127 (#2513). The #cfg flag set reaches IMPORTED modules through the split
# CLI. This dispatcher (lib/@vibe/cli/dispatch.vibe) never passes through
# cli_adapter's cli_main, so the process-wide flag configuration has to be made
# in both entries: gate 40g (mid lane) covers the adapter, this covers the
# dispatcher, on the split CLI core section 114 just built or was handed.
# Three builds on one cache directory -- dev, release, dev -- the third proving
# that a flag switch is a cache miss, not a replay; then a no-flag build must be
# refused (the guarded `f` is then in neither arm), so the section also fails
# if something starts enabling every flag.
echo "[compiler-gate] 127/127 #cfg flags reach imported modules through the split CLI (#2513)"
cfsdir="_build/_gate_split_cli_cfg"
rm -rf "$cfsdir"; mkdir -p "$cfsdir"
cat > "$cfsdir/dep.vibe" <<'SCEOF'
#cfg(dev)
export fn f(x: Int) -> Int { x + 100 }

#cfg(release)
export fn f(x: Int) -> Int { x + 1 }
SCEOF
cat > "$cfsdir/main.vibex" <<'SCEOF'
import ./dep.vibe { f }

fn main() -> Unit allows Console {
  println(Int::to_string(f(1)))
}
SCEOF
cfs_got=""
for cfs_flag in dev release dev; do
  rm -f "$cfsdir/b.wasm"
  env VIBE_CFG="$cfs_flag" VIBE_BUILD_CACHE_DIR="$cfsdir/cache" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$sc_abs" \
    build "$cfsdir/main.vibex" -o "$cfsdir/b.wasm" >/dev/null 2>&1 || true
  if [ -s "$cfsdir/b.wasm" ]; then
    cfs_got="$cfs_got $(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$cfsdir/b.wasm" 2>&1 | tail -1)"
  else
    cfs_got="$cfs_got nocompile"
  fi
done
if [ "$cfs_got" != " 101 2 101" ]; then
  echo "[compiler-gate] FAIL: #cfg through the split CLI (dev, release, warm dev) answered '$cfs_got', want ' 101 2 101' (#2513)" >&2
  exit 1
fi
rm -f "$cfsdir/b.wasm"
env -u VIBE_CFG VIBE_BUILD_CACHE_DIR="$cfsdir/cache" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$sc_abs" \
  build "$cfsdir/main.vibex" -o "$cfsdir/b.wasm" >/dev/null 2>&1 || true
if [ -s "$cfsdir/b.wasm" ]; then
  echo "[compiler-gate] FAIL: with no VIBE_CFG the split CLI built a program whose only f is #cfg-guarded (#2513)" >&2
  exit 1
fi
rm -rf "$cfsdir"
echo "[compiler-gate] #cfg flags reach imported modules through the split CLI, and a flag switch is a cache miss ok (#2513)"

# #3173: a kinded enum re-export publishes its alias as a constructor
# qualifier. The checker accepted PublicChoice::First before this fix, but
# normalization lost the facade alias and codegen saw an unresolved name.
echo "[compiler-gate] 130/130 re-exported enum alias constructors (#3173)"
for enum_alias_lane in bump shadow gc; do
  case "$enum_alias_lane" in
    bump) enum_alias_rc=0; enum_alias_backend=linear ;;
    shadow) enum_alias_rc=shadow; enum_alias_backend=linear ;;
    gc) enum_alias_rc=0; enum_alias_backend=gc ;;
  esac
  if ! VIBE_RC="$enum_alias_rc" VIBE_TEST_BACKEND="$enum_alias_backend" \
      VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/reexport_enum_alias_ctor_test.vibe fixtures/reexport_enum_alias_isolation_test.vibe \
      fixtures/reexport_enum_alias_chain_test.vibe fixtures/reexport_enum_alias_aggregate_test.vibe \
      fixtures/reexport_enum_alias_local_shadow_test.vibe fixtures/reexport_enum_alias_transparent_test.vibe \
      fixtures/reexport_enum_alias_generic_test.vibe fixtures/reexport_enum_alias_imported_test.vibe \
      fixtures/reexport_enum_alias_sibling_private_test.vibe \
      fixtures/reexport_enum_alias_local_effect_test.vibe \
      fixtures/reexport_enum_alias_effect_aggregate_test.vibe \
      fixtures/reexport_enum_alias_private_origin_test.vibe \
      >"$ROOT_DIR/_build/_gate_reexport_enum_alias.log" 2>&1; then
    echo "[compiler-gate] FAIL: re-exported enum alias constructor on $enum_alias_lane (#3173)" >&2
    tail -20 "$ROOT_DIR/_build/_gate_reexport_enum_alias.log" >&2
    exit 1
  fi
done
for private_pat_lane in bump shadow gc; do
  case "$private_pat_lane" in
    bump) private_pat_rc=0; private_pat_backend=linear ;;
    shadow) private_pat_rc=shadow; private_pat_backend=linear ;;
    gc) private_pat_rc=0; private_pat_backend=gc ;;
  esac
  for private_pat_fixture in \
    fixtures/reexport_enum_alias_private_effect_pattern_test.vibe \
    fixtures/reexport_enum_alias_private_same_target_test.vibe \
    fixtures/reexport_enum_alias_private_qualified_payload_test.vibe \
    fixtures/reexport_enum_alias_private_local_type_alias_test.vibe \
    fixtures/reexport_enum_alias_private_applied_type_alias_test.vibe \
    fixtures/reexport_enum_alias_private_dependency_type_alias_test.vibe \
    fixtures/reexport_enum_alias_private_handler_or_test.vibe; do
    # GC does not lower algebraic effect handlers. The struct and record
    # payload fixtures are typecheck rows since #3371 refused their payload
    # patterns (reexport_enum_alias_private_{struct,record}_payload_reject).
    if [ "$private_pat_lane" = gc ] && [ "$private_pat_fixture" = fixtures/reexport_enum_alias_private_handler_or_test.vibe ]; then
      continue
    fi
    if ! VIBE_RC="$private_pat_rc" VIBE_TEST_BACKEND="$private_pat_backend" \
        VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
        bash scripts/vibe_test.sh "$private_pat_fixture" \
        >"$ROOT_DIR/_build/_gate_private_enum_effect_pattern.log" 2>&1; then
      echo "[compiler-gate] FAIL: $private_pat_fixture on $private_pat_lane (#3238)" >&2
      tail -20 "$ROOT_DIR/_build/_gate_private_enum_effect_pattern.log" >&2
      exit 1
    fi
  done
done
rm -f "$ROOT_DIR/_build/_gate_private_enum_effect_pattern.log"
# The GC backend currently rejects the provider's nominal struct return
# through a type alias; the rename-plan unit test pins this origin, and the
# executable fixture covers the linear lanes.
for enum_alias_lane in bump shadow; do
  case "$enum_alias_lane" in
    bump) enum_alias_rc=0 ;;
    shadow) enum_alias_rc=shadow ;;
  esac
  if ! VIBE_RC="$enum_alias_rc" VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/reexport_enum_alias_local_struct_test.vibe \
      >"$ROOT_DIR/_build/_gate_reexport_enum_alias_struct.log" 2>&1; then
    echo "[compiler-gate] FAIL: provider-local struct shadows an enum on $enum_alias_lane (#3173)" >&2
    tail -20 "$ROOT_DIR/_build/_gate_reexport_enum_alias_struct.log" >&2
    exit 1
  fi
done
rm -f "$ROOT_DIR/_build/_gate_reexport_enum_alias_struct.log"
rm -f "$ROOT_DIR/_build/_gate_reexport_enum_alias.log"
echo "[compiler-gate] re-exported enum alias constructors resolve on bump, shadow and gc ok (#3173)"
for enum_alias_lane in bump shadow gc; do
  case "$enum_alias_lane" in
    bump) enum_alias_rc=0; enum_alias_backend=linear ;;
    shadow) enum_alias_rc=shadow; enum_alias_backend=linear ;;
    gc) enum_alias_rc=0; enum_alias_backend=gc ;;
  esac
  if VIBE_RC="$enum_alias_rc" VIBE_TEST_BACKEND="$enum_alias_backend" \
      VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/reexport_enum_alias_sibling_collision_refused.vibe \
      fixtures/reexport_enum_alias_sibling_collision_reverse_refused.vibe \
      >"$ROOT_DIR/_build/_gate_reexport_enum_alias_refused.log" 2>&1; then
    echo "[compiler-gate] FAIL: a duplicate enum origin compiled on $enum_alias_lane (#3173)" >&2
    exit 1
  fi
  if [ "$(grep -c 'rename one of the enums named `Choice`' "$ROOT_DIR/_build/_gate_reexport_enum_alias_refused.log" || true)" != 2 ]; then
    echo "[compiler-gate] FAIL: duplicate enum origins lacked the actionable refusal on $enum_alias_lane (#3173)" >&2
    tail -20 "$ROOT_DIR/_build/_gate_reexport_enum_alias_refused.log" >&2
    exit 1
  fi
done
rm -f "$ROOT_DIR/_build/_gate_reexport_enum_alias_refused.log"
echo "[compiler-gate] duplicate enum origins refuse on bump, shadow and gc ok (#3173)"

echo "[compiler-gate] 134/134 private enum alias patterns (#3238)"
for private_pat_lane in bump shadow gc; do
  case "$private_pat_lane" in
    bump) private_pat_rc=0; private_pat_backend=linear ;;
    shadow) private_pat_rc=shadow; private_pat_backend=linear ;;
    gc) private_pat_rc=0; private_pat_backend=gc ;;
  esac
  if ! VIBE_RC="$private_pat_rc" VIBE_TEST_BACKEND="$private_pat_backend" \
      VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/reexport_enum_alias_private_origin_test.vibe \
      fixtures/reexport_enum_alias_private_prefixed_variant_test.vibe \
      fixtures/reexport_enum_alias_private_entry_local_variant_test.vibe \
      >"$ROOT_DIR/_build/_gate_private_enum_pattern.log" 2>&1; then
    echo "[compiler-gate] FAIL: private enum alias pattern on $private_pat_lane (#3238)" >&2
    tail -20 "$ROOT_DIR/_build/_gate_private_enum_pattern.log" >&2
    exit 1
  fi
  if VIBE_RC="$private_pat_rc" VIBE_TEST_BACKEND="$private_pat_backend" \
      VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/reexport_enum_alias_private_pattern_collision_refused.vibe \
      fixtures/reexport_enum_alias_private_handler_nested_collision_refused.vibe \
      >"$ROOT_DIR/_build/_gate_private_enum_pattern_refused.log" 2>&1; then
    echo "[compiler-gate] FAIL: ambiguous private enum alias pattern compiled on $private_pat_lane (#3238)" >&2
    exit 1
  fi
  if [ "$(grep -c 'rename one of the variants named `A`' "$ROOT_DIR/_build/_gate_private_enum_pattern_refused.log" || true)" != 2 ]; then
    echo "[compiler-gate] FAIL: ambiguous private enum alias pattern lacked an actionable refusal on $private_pat_lane (#3238)" >&2
    tail -20 "$ROOT_DIR/_build/_gate_private_enum_pattern_refused.log" >&2
    exit 1
  fi
  if VIBE_RC="$private_pat_rc" VIBE_TEST_BACKEND="$private_pat_backend" \
      VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
      bash scripts/vibe_test.sh fixtures/reexport_enum_alias_private_local_variant_refused.vibe \
      >"$ROOT_DIR/_build/_gate_private_enum_pattern_local_refused.log" 2>&1; then
    echo "[compiler-gate] FAIL: imported pattern collided with a dependency-local private variant on $private_pat_lane (#3238)" >&2
    exit 1
  fi
  if ! grep -q 'rename this module.s private variant `A`' "$ROOT_DIR/_build/_gate_private_enum_pattern_local_refused.log"; then
    echo "[compiler-gate] FAIL: imported/local private variant collision lacked an actionable refusal on $private_pat_lane (#3238)" >&2
    tail -20 "$ROOT_DIR/_build/_gate_private_enum_pattern_local_refused.log" >&2
    exit 1
  fi
done
rm -f "$ROOT_DIR/_build/_gate_private_enum_pattern.log" "$ROOT_DIR/_build/_gate_private_enum_pattern_refused.log" "$ROOT_DIR/_build/_gate_private_enum_pattern_local_refused.log"
echo "[compiler-gate] private enum alias patterns resolve or refuse safely on bump, shadow and gc ok (#3238)"

echo "[compiler-gate] 135/135 Option closure payload ownership (#3240)"
if ! VIBE_RC=shadow VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash scripts/vibe_test.sh fixtures/rc_option_payload_return_test.vibe \
    >"$ROOT_DIR/_build/_gate_option_payload_rc.log" 2>&1; then
  echo "[compiler-gate] FAIL: Option closure payload was not released after its callback escaped (#3240)" >&2
  tail -20 "$ROOT_DIR/_build/_gate_option_payload_rc.log" >&2
  exit 1
fi
rm -f "$ROOT_DIR/_build/_gate_option_payload_rc.log"
echo "[compiler-gate] Option closure payload stays live and bounded in shadow RC ok (#3240)"

# A callback parameter or immutable rebinding shadows an effectful source.
# The entry lane's independent opaque-call rule still rejects these calls,
# but the mutable-alias diagnostic must not attribute them to that source.
for shadowed_callback in \
    handle_callee_mutable_shadowed_callback_opaque_reject \
    handle_callee_mutable_shadowed_labeled_callback_opaque_reject \
    handle_callee_mutable_shadowed_labeled_alias_opaque_reject \
    handle_callee_mutable_outer_copied_shadowed_opaque_reject; do
  shadowed_callback_diag="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check "fixtures/$shadowed_callback.vibe" 2>&1 || true)"
  case "$shadowed_callback_diag" in
    *"handle of effect 'Ask' cannot be compiled here"*) ;;
    *) echo "[compiler-gate] FAIL: $shadowed_callback changed the independent opaque-call diagnostic (#3196): $shadowed_callback_diag" >&2; exit 1 ;;
  esac
  case "$shadowed_callback_diag" in
    *'cannot compile a call through mutable local'*) echo "[compiler-gate] FAIL: $shadowed_callback was attributed to a top-level effectful function (#3196)" >&2; exit 1 ;;
    *) ;;
  esac
  shadowed_callback_flat="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check --single-file "fixtures/$shadowed_callback.vibe" 2>&1 || true)"
  if [ -n "$shadowed_callback_flat" ]; then
    echo "[compiler-gate] FAIL: flat checker rejected $shadowed_callback (#3196): $shadowed_callback_flat" >&2
    exit 1
  fi
done

for outer_mutable_fixture in \
    handle_callee_mutable_outer_with_direct_perform_reject \
    handle_callee_mutable_outer_copied_alias_reject \
    handle_callee_mutable_outer_annotated_chain_reject \
    handle_callee_mutable_outer_recursive_alias_reject; do
  outer_mutable_diag="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check --single-file \
    "fixtures/typecheck/$outer_mutable_fixture.vibe" 2>&1 || true)"
  case "$outer_mutable_diag" in
    *'cannot compile a call through mutable local `f`'*) ;;
    *) echo "[compiler-gate] FAIL: $outer_mutable_fixture lost its mutable source inside a nested handle (#3196): $outer_mutable_diag" >&2; exit 1 ;;
  esac
done
