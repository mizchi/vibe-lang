#!/usr/bin/env bash
# Red test for the edit rows of scripts/checked_module_cache_parity.mjs (#1959).
#
# The rows assert which modules keep their checked-module artifact across an
# edit. That is an assertion about the COMPILER, so the honest mutation is a
# compiler change -- and a stage2 build per case is far too slow for a gate.
# What is cheap and still real is the other input: the three-module project the
# rows compile. Each mutation below makes one row's expectation false, and the
# row must say so by name. A mutation that changed nothing would leave the
# oracle green and prove nothing, so every case checks that the bytes on disk
# really moved before it runs the oracle.
#
# Portability (#2252): this test must not inherit the corpus override from the
# environment that runs it, or every case would silently probe the same tree.
set -euo pipefail
cd "$(dirname "$0")/.."
unset VIBE_CHECKED_MODULE_EDIT_CORPUS

. scripts/resolve_stage2.sh
stage2="$(resolve_stage2 checked-module-parity-test "${VIBE_STAGE2_WASM:-}")"
case "$stage2" in
  bootstrap/seed/*|*/bootstrap/seed/*)
    echo 'checked-module-parity-test: build a current stage2 first; the seed cannot answer for this change' >&2
    exit 1 ;;
esac

work="$(mktemp -d "${TMPDIR:-/tmp}/vibe_checked_module_parity_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
corpus_source="bench/incremental/checked_module_edit"

failures=0
# $1 case name, $2 expected substring of the failure, $3 file under the corpus,
# $4 replacement contents.
expect_red() {
  local name="$1" expected="$2" target="$3" replacement="$4"
  local corpus="$work/$name"
  rm -rf "$corpus"
  cp -R "$corpus_source" "$corpus"
  local before after
  before="$(cat "$corpus/$target")"
  printf '%s' "$replacement" > "$corpus/$target"
  after="$(cat "$corpus/$target")"
  if [ "$before" = "$after" ]; then
    echo "[checked-module-parity-test] FAIL: mutation $name changed nothing in $target" >&2
    failures=$((failures + 1))
    return
  fi
  local log="$work/$name.log"
  if VIBE_CHECKED_MODULE_EDIT_CORPUS="$corpus" \
     node scripts/checked_module_cache_parity.mjs "$stage2" --only-edits >"$log" 2>&1; then
    echo "[checked-module-parity-test] FAIL: $name was accepted; the row cannot fail" >&2
    failures=$((failures + 1))
    return
  fi
  if ! grep -qF "$expected" "$log"; then
    echo "[checked-module-parity-test] FAIL: $name failed for the wrong reason (wanted \"$expected\")" >&2
    sed -n '1,20p' "$log" >&2
    failures=$((failures + 1))
    return
  fi
  echo "[checked-module-parity-test] red ok: $name"
}

# 1. A "private body" edit that is really a public one. The consumer must now
#    be rechecked, so the 1-rechecked/2-reused row is false.
expect_red private-body-is-public "edit private_body decision shape" edits/private_body.vibe \
'export fn leaf_value(v: Int) -> Int {
  v + 1
}

export fn leaf_also_public() -> Int {
  3
}
'

# 2. An "additive public" edit that adds nothing public. The row that says a
#    public edit reaches the direct consumer and stops there is only a test
#    while the edit really does change the leaf's public environment.
expect_red additive-is-private "edit public_additive decision shape" edits/public_additive.vibe \
'export fn leaf_value(v: Int) -> Int {
  (v + 2) - 1
}
'

# 3. A "breaking" edit that does not break. The strongest row -- stale consumer
#    reuse shows up as a wasm where a clean build diagnoses -- is only a test
#    while the edited tree really is ill-typed.
expect_red breaking-is-valid "expected a diagnosed tree" edits/public_breaking.vibe \
'export fn leaf_value(v: Int) -> Int {
  v + 1
}
'

# 4. A closure that is not three modules. The planned-count row is what keeps
#    the reuse counts above being read against the graph they were measured on.
expect_red closure-is-two "planned 2 of 3 modules" mid.vibe \
'export fn mid_value(v: Int) -> Int {
  v + 3
}
'

# 5. #2875: the tree moved under the run. The rows above ask the compiler;
#    this one asks whether the gate notices that its INPUT changed while it was
#    comparing. It used to not: a session editing `lib/@vibe/compiler/**` while
#    a gate ran got `parity mismatch: fixtures/contract_conformance_test.vibe`,
#    and an hour went into the cache before the artifacts showed every baked-in
#    source offset shifted by a constant.
#
#    `--only-edits` compiles the three-module edit corpus with a prebuilt
#    stage2, so a `lib/` edit changes NOTHING about what this run computes --
#    the only thing that can fail is the guard. The victim is restored whatever
#    happens, and the mutation is verified to have landed before the verdict is
#    read (an edit that changed nothing would prove nothing, #2248).
tree_victim="lib/@vibe/compiler/contract/contract.vibe"
tree_log="$work/tree-moved.log"
tree_backup="$work/tree-victim.bak"
cp "$tree_victim" "$tree_backup"
restore_victim() { cp "$tree_backup" "$tree_victim"; }
trap 'restore_victim; rm -rf "$work"' EXIT
node scripts/checked_module_cache_parity.mjs "$stage2" --only-edits >"$tree_log" 2>&1 &
tree_pid=$!
sleep 2
printf '\n// #2875 self-test: this line is appended and removed by scripts/checked_module_cache_parity_test.sh\n' >> "$tree_victim"
if cmp -s "$tree_victim" "$tree_backup"; then
  echo "[checked-module-parity-test] FAIL: the tree mutation changed nothing" >&2
  failures=$((failures + 1))
fi
if wait "$tree_pid"; then
  echo "[checked-module-parity-test] FAIL: the run was accepted although its input moved" >&2
  failures=$((failures + 1))
elif ! grep -qF "the source tree changed during the run" "$tree_log"; then
  echo "[checked-module-parity-test] FAIL: the run failed for the wrong reason (wanted the tree refusal)" >&2
  sed -n '1,20p' "$tree_log" >&2
  failures=$((failures + 1))
elif ! grep -qF "$tree_victim" "$tree_log"; then
  echo "[checked-module-parity-test] FAIL: the refusal does not name $tree_victim" >&2
  sed -n '1,20p' "$tree_log" >&2
  failures=$((failures + 1))
else
  echo "[checked-module-parity-test] red ok: tree-moved"
fi
restore_victim

# The green control. Without it a red test that always fails would pass here.
# It runs LAST on purpose: the victim above is restored by now, so a guard that
# fired on its own restore would show up here rather than passing unnoticed.
if ! node scripts/checked_module_cache_parity.mjs "$stage2" --only-edits >"$work/green.log" 2>&1; then
  echo "[checked-module-parity-test] FAIL: the unmutated corpus was rejected" >&2
  sed -n '1,20p' "$work/green.log" >&2
  failures=$((failures + 1))
else
  echo "[checked-module-parity-test] green ok: unmutated corpus"
fi

if [ "$failures" -ne 0 ]; then
  echo "[checked-module-parity-test] FAIL: $failures case(s)" >&2
  exit 1
fi
echo "[checked-module-parity-test] ok"
