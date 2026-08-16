#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Source the driver helpers without requiring a real corpus.
source scripts/coverage_drivers.sh
COMPILER_COV="$TMP/compiler_cov.wasm"
printf wasm > "$COMPILER_COV"

# Stub global stat and local merge tools so validation can be exercised without
# compiling wasm. Their paths are selected by the scripts under test.
mkdir -p "$TMP/bin"
printf '{}\n' > "$TMP/acc.json"
printf '{}\n' > "$TMP/run.json"

# Valid merge: stable positive denominator, monotone hits, and post-write stat.
# First stat must be 3/10, then post-merge 4/10; use a stateful bash stub.
cat > "$TMP/bin/bash" <<'SH'
#!/bin/bash
if [[ "$*" == *"coverage_acc_tool_run.sh stat"* ]]; then
  count=0; [ -f "$FAKE_COUNT_FILE" ] && count=$(cat "$FAKE_COUNT_FILE")
  count=$((count + 1)); printf '%s' "$count" > "$FAKE_COUNT_FILE"
  if [ "$count" = 1 ]; then printf '%b\n' "${FAKE_BEFORE_STAT:-3 10}"; else printf '%b\n' "${FAKE_AFTER_STAT:-4 10}"; fi
  exit "${FAKE_STAT_STATUS:-0}"
fi
if [[ "$*" == *"coverage_local_merge_run.sh merge"* ]]; then
  printf '%b\n' "${FAKE_MERGE_OUTPUT:-3 4 10}"
  exit "${FAKE_MERGE_STATUS:-0}"
fi
exec /bin/bash "$@"
SH
chmod +x "$TMP/bin/bash"
export PATH="$TMP/bin:$PATH"
export FAKE_COUNT_FILE="$TMP/count"
rm -f "$FAKE_COUNT_FILE"
[ "$(coverage_driver_merge_checked "$TMP/acc.json" "$TMP/run.json")" = '3 4 10' ]

# Merge failure, malformed schema, zero/changed total, decreasing hits, and a
# post-write stat mismatch all fail closed.
expect_reject() {
  rm -f "$FAKE_COUNT_FILE"
  if coverage_driver_merge_checked "$TMP/acc.json" "$TMP/run.json" >/dev/null 2>&1; then
    echo "coverage_pipeline_contract_test: expected rejection: $1" >&2
    exit 1
  fi
}
FAKE_MERGE_STATUS=7 expect_reject 'merge status'
FAKE_MERGE_STATUS=0 FAKE_MERGE_OUTPUT='not stats' expect_reject 'malformed output'
FAKE_MERGE_OUTPUT='3 4 10\n9 9 9' expect_reject 'trailing merge record'
FAKE_MERGE_OUTPUT='3 4 10 extra' expect_reject 'trailing merge field'
FAKE_MERGE_OUTPUT='3 3 0' expect_reject 'zero total'
FAKE_MERGE_OUTPUT='3 4 11' expect_reject 'changed total'
FAKE_MERGE_OUTPUT='3 2 10' expect_reject 'decreasing hits'
FAKE_MERGE_OUTPUT='3 4 10' FAKE_AFTER_STAT='5 10' expect_reject 'post-write mismatch'
FAKE_MERGE_OUTPUT='3 4 10' FAKE_BEFORE_STAT='3 10\n9 9' expect_reject 'trailing pre-merge stat record'
FAKE_BEFORE_STAT='3 10' FAKE_AFTER_STAT='4 10\n9 9' expect_reject 'trailing post-merge stat record'
FAKE_BEFORE_STAT='3 10' FAKE_AFTER_STAT='4 10' FAKE_STAT_STATUS=7 expect_reject 'valid stat data with nonzero status'
unset FAKE_MERGE_STATUS FAKE_MERGE_OUTPUT FAKE_BEFORE_STAT FAKE_AFTER_STAT FAKE_STAT_STATUS

# Source corpus freshness helpers without running the corpus.
source scripts/coverage_corpus.sh
TEST_FLAT="$TMP/flat.vibe"
printf flat >"$TEST_FLAT"
mkdir -p "$TMP/fresh/bin"
for required in bootstrap/seed/compiler.wasm lib/@vibe/compiler/compiler_sources_manifest.tsv scripts/generate_bundle.sh scripts/ensure_generated.sh; do
  mkdir -p "$TMP/fresh/$(dirname "$required")"
  printf x >"$TMP/fresh/$required"
done
mkdir -p "$TMP/fresh/lib/@vibe" "$TMP/fresh/lib/@vibex"
touch "$TEST_FLAT"
(
  cd "$TMP/fresh"
  coverage_require_fresh_flat "$TEST_FLAT"
  rm bootstrap/seed/compiler.wasm
  if coverage_require_fresh_flat "$TEST_FLAT" >/dev/null 2>&1; then
    echo 'coverage_pipeline_contract_test: missing required input was accepted' >&2
    exit 1
  fi
  printf x > bootstrap/seed/compiler.wasm
  cat > bin/find <<SH
#!/bin/sh
printf '%s\n' 'lib/@vibe/plausible.vibe'
exit 9
SH
  chmod +x bin/find
  if PATH="$PWD/bin:$PATH" coverage_require_fresh_flat "$TEST_FLAT" >/dev/null 2>&1; then
    echo 'coverage_pipeline_contract_test: failing find producer was accepted' >&2
    exit 1
  fi
)

# Library-only environment variables must not bypass direct production entry.
# Missing prerequisites make both direct invocations fail before doing work.
if VIBE_COVERAGE_CORPUS_LIB_ONLY=1 VIBE_COV_SEED="$TMP/missing-seed.wasm" \
    bash scripts/coverage_corpus.sh >/dev/null 2>&1; then
  echo 'coverage_pipeline_contract_test: corpus direct invocation bypassed prerequisites' >&2
  exit 1
fi
rm -rf "$TMP/direct-drivers"
if VIBE_COVERAGE_DRIVERS_LIB_ONLY=1 \
    VIBE_COV_DIR="$TMP/direct-drivers" \
    bash scripts/coverage_drivers.sh >/dev/null 2>&1; then
  echo 'coverage_pipeline_contract_test: drivers direct invocation bypassed prerequisites' >&2
  exit 1
fi
[ ! -e "$TMP/direct-drivers" ] || {
  echo 'coverage_pipeline_contract_test: drivers modified output before prerequisite checks' >&2
  exit 1
}

# The local tool defaults to the current corpus compiler, not the pinned seed,
# and includes compiler freshness in its cache invalidation condition.
grep -Fq 'VIBE_COVERAGE_LOCAL_MERGE_COMPILER:-_build/coverage/selfhost-corpus/compiler_cov.wasm' scripts/coverage_local_merge_run.sh
grep -Fq '[ "$compiler" -nt "$tool" ]' scripts/coverage_local_merge_run.sh

# Corpus paths and freshness checks are portable on BSD/macOS: no GNU-only
# realpath/hash/NUL-sort path is invoked, stale flat input fails closed, and
# paths are containment checked.
! grep -Fq 'realpath --relative-to' scripts/coverage_corpus.sh
! grep -Eq '^[[:space:]]*bash scripts/ensure_generated[.]sh' scripts/coverage_corpus.sh
grep -Fq 'coverage_require_fresh_flat' scripts/coverage_corpus.sh
grep -Fq 'if [ "$input" -nt "$flat_abs" ]' scripts/coverage_corpus.sh
grep -Fq 'os.path.commonpath' scripts/coverage_corpus.sh
grep -Fq 'export VIBE_COVERAGE_ACC_TOOL_COMPILER="$COMPILER_COV"' scripts/coverage_corpus.sh

echo 'coverage_pipeline_contract_test: ok'
