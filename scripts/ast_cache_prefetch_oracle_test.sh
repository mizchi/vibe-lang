#!/usr/bin/env bash
# Red self-test for scripts/ast_cache_prefetch_oracle.mjs (#2248 / Codex on #2771).
#
# The oracle's real input is the telemetry a compile produces, so that is what
# this mutates: a scripted runner stands in for the compiler and emits one
# telemetry document per named build, and each case perturbs ONE row and
# asserts the oracle rejects it with the assertion that owns that row. A green
# case runs first, so a harness that rejected everything would be caught.
#
# The compiler-level red test is recorded here rather than run here, because it
# costs a stage2 build: against the pre-fix compiler f334680 (count kept at the
# planner) this oracle fails with "an incremental build reported
# ast_cache_prefetches=0"; against 37175d0 it passes. This file covers the part
# that rots without a rebuild -- the assertions themselves.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

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

#              cold warmoff warmon wprefetch ahits aprefetch ereused eprefetch enonwalk cnonwalk
GOOD="$(write_table 0 3 0 3 3 0 1 2 0 1)"
expect_pass "$GOOD" "the scripted-good table passes"

expect_fail "$(write_table 0 0 0 3 3 0 1 2 0 1)" \
  "warm-off parsing no more than cold is refused as vacuous" \
  "the comparison below would be vacuous"

expect_fail "$(write_table 0 3 0 0 3 0 1 2 0 1)" \
  "a warm build that prefetched nothing is refused" \
  "prefetched no stored AST"

expect_fail "$(write_table 0 3 2 3 3 0 1 2 0 1)" \
  "a warm build that still parsed in the merge lane is refused" \
  "sources in the merge lane"

expect_fail "$(write_table 0 3 0 3 3 2 1 2 0 1)" \
  "prefetching under the checked-module artifact cache is refused" \
  "consumed by nothing"

expect_fail "$(write_table 0 3 0 3 0 0 1 2 0 1)" \
  "a stand-down claim with no artifact hits is refused as vacuous" \
  "served nothing on a warm build"

expect_fail "$(write_table 0 3 0 3 3 0 1 0 0 1)" \
  "an incremental build reporting zero prefetches is refused" \
  "reported ast_cache_prefetches=0"

expect_fail "$(write_table 0 3 0 3 3 0 0 2 0 1)" \
  "an edit that reused nothing is refused as proving nothing" \
  "no stored AST could have served the merge"

expect_fail "$(write_table 0 3 0 3 3 0 1 2 1 1)" \
  "an incremental build that parsed in the merge lane is refused" \
  "sources in the merge lane with the AST cache on"

expect_fail "$(write_table 0 3 0 3 3 0 1 2 0 0)" \
  "deleting the artifacts without the parser running is refused" \
  "did not make the merge lane parse"

if [ "$fails" -eq 0 ]; then
  echo "ast-cache-prefetch-oracle self-test: ok (1 green, 9 red)"
else
  echo "ast-cache-prefetch-oracle self-test: $fails case(s) failed" >&2
  exit 1
fi
