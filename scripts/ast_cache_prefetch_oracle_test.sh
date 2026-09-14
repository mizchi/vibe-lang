#!/usr/bin/env bash
# Red self-test for scripts/ast_cache_prefetch_oracle.mjs (#2248 / Codex on #2771).
#
# The oracle's real input is the telemetry a compile produces, so that is what
# this mutates: a scripted runner stands in for the compiler and emits one
# telemetry document per named build, and each case perturbs ONE row and
# asserts the oracle rejects it with the assertion that owns that row. A green
# case runs first, so a harness that rejected everything would be caught.
#
# Scripted cases alone would leave one regression invisible: an oracle that
# stops driving the REAL compiler, cache layout or environment correctly still
# satisfies a scripted runner (Codex on #2771, P1). So the last two cases use
# the actual compiler -- one unmutated run that must pass, and one where a
# wrapper lets the real compile happen and then perturbs ONE field of its real
# telemetry, which must fail.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/resolve_stage2.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0

# The scripted runner. It ignores the compiler entirely and answers from a
# table keyed by the output name the oracle asked for.
cat > "$WORK/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
set -uo pipefail
out=""
for arg in "$@"; do
  case "$arg" in *.wasm) out="$arg" ;; esac
done
name="$(basename "$out" .wasm)"
row="$(grep -E "^${name}[[:space:]]" "$AST_CACHE_ORACLE_FAKE_TABLE" | head -1 | cut -f2-)"
if [ -z "$row" ]; then
  echo "fake runner: no table row for $name" >&2
  exit 3
fi
printf 'wasm' > "$out"
printf '%s' "$row" > "${VIBE_INCREMENTAL_TELEMETRY_OUT}"
RUNNER
chmod +x "$WORK/runner.sh"

# One tab-separated row per build the oracle performs, in the order it does.
tel() { # planned rechecked reused parse non_walk prefetch [artifact]
  local extra=""
  [ -n "${7:-}" ] && extra=",\"modules_reused_checked_module_artifact\":$7"
  printf '{"schema":%s,"modules_planned":%s,"modules_rechecked":%s,"modules_reused":%s,"parse_operations":%s,"modules_failed_or_blocked":0,"current_source_parse_executions":0,"checker_executions":0,"modules_reused_conservative_fingerprint":0,"modules_reused_dependency_transport_env":0%s,"non_walk_parse_operations":%s,"ast_cache_prefetches":%s}' \
    "$([ -n "${7:-}" ] && echo 5 || echo 4)" "$1" "$2" "$3" "$4" "$extra" "$5" "$6"
}

write_table() { # cold_nonwalk warmoff_nonwalk warmon_nonwalk warmon_prefetch artifact_hits artifact_prefetch edit_reused edit_prefetch edit_nonwalk control_nonwalk
  local f="$WORK/table.tsv"
  {
    printf 'cold-on\t%s\n'                 "$(tel 3 3 0 3 "$1" 0)"
    printf 'warm-on\t%s\n'                 "$(tel 3 0 3 0 "$3" "$4")"
    printf 'warm-off\t%s\n'                "$(tel 3 0 3 0 "$2" 0)"
    printf 'artifact-cold\t%s\n'           "$(tel 3 3 0 3 0 0 0)"
    printf 'artifact-warm\t%s\n'           "$(tel 3 0 3 0 0 "$6" "$5")"
    printf 'split-cold\t%s\n'              "$(tel 3 3 0 3 0 0)"
    printf 'split-edit\t%s\n'              "$(tel 3 2 "$7" 2 "$9" "$8")"
    printf 'split-edit-no-artifacts\t%s\n' "$(tel 3 2 1 2 "${10}" 0)"
    printf 'verify-cold\t%s\n'              "$(tel 3 3 0 3 0 0)"
    printf 'verify-warm\t%s\n'              "$(tel 3 "${11}" 0 "${11}" 0 "${12}")"
  } > "$f"
  echo "$f"
}

# The table path travels WITHOUT a VIBE_ prefix on purpose: the oracle drops
# every VIBE_* variable from the child environment, which is the whole point of
# that filter -- the first version of this self-test used VIBE_ORACLE_FAKE_TABLE
# and the scripted runner came up with it unset.
run_oracle() { # table -> exit code, stderr in $WORK/err
  VIBE_AST_CACHE_ORACLE_RUNNER="$WORK/runner.sh" AST_CACHE_ORACLE_FAKE_TABLE="$1" \
    node scripts/ast_cache_prefetch_oracle.mjs "$WORK/fake-stage2.wasm" >"$WORK/out" 2>"$WORK/err"
}

expect_pass() {
  local table="$1" label="$2"
  if run_oracle "$table"; then
    echo "ok   $label"
  else
    echo "FAIL $label: expected the oracle to pass"; sed -n '1,6p' "$WORK/err"; fails=$((fails + 1))
  fi
}

expect_fail() { # table label needle
  local table="$1" label="$2" needle="$3"
  if run_oracle "$table"; then
    echo "FAIL $label: the oracle PASSED on a mutated input"; fails=$((fails + 1))
  elif grep -qF "$needle" "$WORK/err"; then
    echo "ok   $label"
  else
    echo "FAIL $label: failed, but not on the expected assertion (wanted: $needle)"; sed -n '1,6p' "$WORK/err"; fails=$((fails + 1))
  fi
}

printf 'stage2' > "$WORK/fake-stage2.wasm"

#              cold warmoff warmon wprefetch ahits aprefetch ereused eprefetch enonwalk cnonwalk vrechecked vprefetch
GOOD="$(write_table 0 3 0 3 3 0 1 2 0 1 3 3)"
expect_pass "$GOOD" "the scripted-good table passes"

expect_fail "$(write_table 0 0 0 3 3 0 1 2 0 1 3 3)" \
  "warm-off parsing no more than cold is refused as vacuous" \
  "the comparison below would be vacuous"

expect_fail "$(write_table 0 3 0 0 3 0 1 2 0 1 3 3)" \
  "a warm build that prefetched nothing is refused" \
  "prefetched no stored AST"

expect_fail "$(write_table 0 3 2 3 3 0 1 2 0 1 3 3)" \
  "a warm build that still parsed in the merge lane is refused" \
  "sources in the merge lane"

expect_fail "$(write_table 0 3 0 3 3 2 1 2 0 1 3 3)" \
  "prefetching under the checked-module artifact cache is refused" \
  "consumed by nothing"

expect_fail "$(write_table 0 3 0 3 0 0 1 2 0 1 3 3)" \
  "a stand-down claim with no artifact hits is refused as vacuous" \
  "served nothing on a warm build"

expect_fail "$(write_table 0 3 0 3 3 0 1 0 0 1 3 3)" \
  "an incremental build reporting zero prefetches is refused" \
  "reported ast_cache_prefetches=0"

expect_fail "$(write_table 0 3 0 3 3 0 0 2 0 1 3 3)" \
  "an edit that reused nothing is refused as proving nothing" \
  "no stored AST could have served the merge"

expect_fail "$(write_table 0 3 0 3 3 0 1 2 1 1 3 3)" \
  "an incremental build that parsed in the merge lane is refused" \
  "sources in the merge lane with the AST cache on"

expect_fail "$(write_table 0 3 0 3 3 0 1 2 0 0 3 3)" \
  "deleting the artifacts without the parser running is refused" \
  "did not make the merge lane parse"

expect_fail "$(write_table 0 3 0 3 3 0 1 2 0 1 3 0)" \
  "standing down under verify is refused" \
  "stood down under VIBE_CHECKED_MODULE_CACHE=verify"

expect_fail "$(write_table 0 3 0 3 3 0 1 2 0 1 0 3)" \
  "a verify run that rechecked nothing is refused as vacuous" \
  "rechecked nothing"

# Calls the real runner, then perturbs ONE field of the telemetry it really
# produced. Named without a VIBE_ prefix: the oracle drops that whole namespace.
cat > "$WORK/mutating_runner.sh" <<'MUTRUNNER'
#!/usr/bin/env bash
set -uo pipefail
bash "$AST_CACHE_ORACLE_REAL_RUNNER" "$@" || exit $?
out=""
for arg in "$@"; do case "$arg" in *.wasm) out="$arg" ;; esac; done
[ "$(basename "$out" .wasm)" = "$AST_CACHE_ORACLE_MUTATE_BUILD" ] || exit 0
# The mutation must APPLY: a field that no longer exists exits non-zero rather
# than no-opping, because a silent no-op looks exactly like a passing gate.
python3 -c '
import json, sys
path, field, value = sys.argv[1], sys.argv[2], int(sys.argv[3])
doc = json.load(open(path))
if field not in doc:
    raise SystemExit("mutating runner: %s absent from the real telemetry" % field)
doc[field] = value
open(path, "w").write(json.dumps(doc))
' "$VIBE_INCREMENTAL_TELEMETRY_OUT" "$AST_CACHE_ORACLE_MUTATE_FIELD" "$AST_CACHE_ORACLE_MUTATE_VALUE"
MUTRUNNER
chmod +x "$WORK/mutating_runner.sh"

# ---- the real compiler ----------------------------------------------------
STAGE2="$(resolve_stage2 ast-cache-prefetch-oracle-test "${AST_CACHE_ORACLE_STAGE2:-${VIBE_STAGE2_WASM:-}}")" || {
  echo "FAIL no compiler to run the real cases against" >&2; exit 1; }
case "$STAGE2" in /*) STAGE2_ABS="$STAGE2" ;; *) STAGE2_ABS="$ROOT_DIR/$STAGE2" ;; esac

# A compiler older than schema 4/5 has no `ast_cache_prefetches` at all, and the
# oracle would then fail on its schema check -- red for a reason that is not
# this gate's subject (#2252). Say so instead of running it.
probe_dir="$WORK/probe"; mkdir -p "$probe_dir"
printf 'fn main() -> Int { 1 }\n' > "$probe_dir/app.vibe"
( cd "$probe_dir" && env VIBE_RC=0 VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    VIBE_PREOPEN_DIR="$probe_dir" VIBE_HOME="$probe_dir/.home" \
    VIBE_BUILD_CACHE_DIR="$probe_dir/cache" VIBE_INCREMENTAL_TELEMETRY_OUT="probe.json" \
    bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke cli_main "$STAGE2_ABS" \
    app.vibe probe.wasm main >/dev/null 2>&1 ) || true
if ! grep -q 'ast_cache_prefetches' "$probe_dir/probe.json" 2>/dev/null; then
  echo "FAIL the resolved compiler ($STAGE2) emits no ast_cache_prefetches counter." >&2
  echo "     It predates schema 4/5, so the real cases below would fail on the schema" >&2
  echo "     check rather than on anything this gate is about. Build a generation for" >&2
  echo "     HEAD, or pass VIBE_STAGE2_WASM / AST_CACHE_ORACLE_STAGE2." >&2
  exit 1
fi

if node scripts/ast_cache_prefetch_oracle.mjs "$STAGE2_ABS" >"$WORK/out" 2>"$WORK/err"; then
  echo "ok   the real compiler passes the oracle unmutated"
else
  echo "FAIL the real compiler does not pass the oracle unmutated"; sed -n '1,8p' "$WORK/err"; fails=$((fails + 1))
fi

if AST_CACHE_ORACLE_REAL_RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
   AST_CACHE_ORACLE_MUTATE_BUILD="warm-on" \
   AST_CACHE_ORACLE_MUTATE_FIELD="ast_cache_prefetches" \
   AST_CACHE_ORACLE_MUTATE_VALUE="0" \
   VIBE_AST_CACHE_ORACLE_RUNNER="$WORK/mutating_runner.sh" \
   node scripts/ast_cache_prefetch_oracle.mjs "$STAGE2_ABS" >"$WORK/out" 2>"$WORK/err"; then
  echo "FAIL the oracle PASSED on real telemetry with ast_cache_prefetches zeroed"; fails=$((fails + 1))
elif grep -qF "prefetched no stored AST" "$WORK/err"; then
  echo "ok   zeroing ast_cache_prefetches in REAL telemetry is refused"
else
  echo "FAIL real-telemetry mutation failed on the wrong assertion"; sed -n '1,8p' "$WORK/err"; fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then
  echo "ast-cache-prefetch-oracle self-test: ok (1 green + 11 red scripted, 1 green + 1 red against $STAGE2)"
else
  echo "ast-cache-prefetch-oracle self-test: $fails case(s) failed" >&2
  exit 1
fi
