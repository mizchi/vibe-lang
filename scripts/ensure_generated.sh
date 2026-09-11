#!/usr/bin/env bash
# Make the generated compiler artifacts present and current, cheaply.
#
# These five files are pure functions of (pinned seed, compiler source):
#
#   lib/@vibe/compiler/compiler_sources_bundle.vibe        source text, embedded
#   lib/@vibe/compiler/cli_adapter_bundle.vibe             ditto (adapter)
#   lib/@vibe/compiler/selfbuild_runtime_entry_bundle.vibe ditto (runtime entry)
#   lib/@vibe/compiler/_cli_adapter_module_source.vibe     merged+DCE'd flat program
#   lib/@vibe/compiler/cache/codegen_fingerprint.vibe      codegen fingerprint
#
# They used to be tracked in git. That cost more than it bought:
#
#   - EVERY pull request touching the compiler conflicted on all five, and
#     neither side's version was correct -- only a regeneration from the merged
#     source was. Parallel work needed a ritual (resolve_generated_conflicts.sh)
#     that existed solely to undo the tracking.
#   - ~30% of the packfile was their history (476MB of 1.6GB across 159 of the
#     last 200 commits), for content reproducible in minutes.
#   - Tracking them created a staleness trap: the build silently preferred the
#     committed copy, so an unregenerated source edit produced a compiler
#     without that edit and still reported success.
#   - CI paid for regeneration ANYWAY, purely to assert the committed copies
#     matched (check_module_source_sync.sh). Generating instead of comparing is
#     the same work minus the failure mode.
#
# Only bootstrap/seed/compiler.wasm stays tracked. That one is irreducible: it
# is the fixed point the whole chain starts from.
#
# Usage:
#   bash scripts/ensure_generated.sh            # regenerate iff stale
#   bash scripts/ensure_generated.sh --force    # regenerate unconditionally
#   bash scripts/ensure_generated.sh --check    # exit 1 if stale, generate nothing
#   bash scripts/ensure_generated.sh --print-fingerprint   # for CI cache keys
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

COMPILER_DIR="lib/@vibe/compiler"
MANIFEST="$COMPILER_DIR/compiler_sources_manifest.tsv"
SEED="bootstrap/seed/compiler.wasm"
STAMP="$COMPILER_DIR/.generated.stamp"
# The input list the stamp's digest was taken over. Kept beside the stamp so it
# travels with it (CI ships both in the compiler-build artifact), and named
# without a .vibe extension so the fingerprint's own `find` cannot see it.
INPUTS="$COMPILER_DIR/.generated.inputs"

ARTIFACTS=(
  "$COMPILER_DIR/compiler_sources_bundle.vibe"
  "$COMPILER_DIR/cli_adapter_bundle.vibe"
  "$COMPILER_DIR/selfbuild_runtime_entry_bundle.vibe"
  "$COMPILER_DIR/_cli_adapter_module_source.vibe"
  "$COMPILER_DIR/cache/codegen_fingerprint.vibe"
)

MODE="ensure"
for arg in "$@"; do
  case "$arg" in
    --force) MODE="force" ;;
    --check) MODE="check" ;;
    --print-fingerprint) MODE="print" ;;
    *) echo "usage: $0 [--force|--check|--print-fingerprint]" >&2; exit 2 ;;
  esac
done

# The fingerprint covers everything the generation reads: the seed, the manifest
# that selects the inputs, and the content of every input it names. A path that
# the manifest lists but that is missing hashes as its own name, so a deletion
# still moves the fingerprint rather than being silently skipped.
# The LIST, so a staleness decision can name what moved. compute_fingerprint is
# its digest and nothing else -- keeping them one function is what made the
# "regenerated with a different fingerprint 1.1s later" case (run 34579840316,
# and the same on 34567587111 before this job layout existed) unanswerable: the
# only evidence was two hashes.
fingerprint_inputs() {
    # The seed wasm, not just bootstrap/seed.json that pins it: a bootstrap bump
    # (generations.sh adopt) swaps the wasm in place, and that has to move the
    # fingerprint.
    #
    # ensure_seed runs UNCONDITIONALLY first, not just when the file is absent.
    # The wasm is gitignored, so pulling a branch that bumped the pin leaves a
    # stale wasm on disk that an existence check happily accepts -- and then the
    # generation runs against a seed that predates the syntax the source now
    # uses, failing with a parse error that points at the source rather than at
    # the seed. (Measured: exactly that, one merge after the effect-row
    # migration landed with its bump.) ensure_seed verifies the sha against the
    # pin and is a no-op when they agree, so this costs nothing and removes a
    # staleness trap of the same shape as the one this file replaces.
    #
    # It also makes the fingerprint independent of whether the seed happened to
    # be fetched yet: a value that changed after the download would miss every
    # CI cache it was used to key.
    bash "$SCRIPT_DIR/ensure_seed.sh" >&2
    sha256sum "$SEED" 2>/dev/null || echo "MISSING $SEED"
    sha256sum "$MANIFEST" 2>/dev/null || echo "MISSING $MANIFEST"
    # #1443 review (Codex P2): the GENERATOR is an input too. Without it, editing
    # generate_bundle.sh leaves the fingerprint unmoved, so an already-stamped
    # tree (or a warm CI cache) skips regeneration and keeps bundles the old
    # generator produced -- the same stale-artifact failure this script exists to
    # remove, just relocated. This file counts as well: it decides what gets
    # hashed and how the artifacts are produced.
    sha256sum "$SCRIPT_DIR/generate_bundle.sh" 2>/dev/null || echo "MISSING generate_bundle.sh"
    sha256sum "${BASH_SOURCE[0]}" 2>/dev/null || echo "MISSING ensure_generated.sh"
    # Column 2 of the manifest is the path, relative to $COMPILER_DIR, with
    # ../../../ meaning repo root (see generate_bundle.sh).
    #
    # Three manifest rows name GENERATED files (cli_adapter_bundle,
    # selfbuild_runtime_entry_bundle, cache/codegen_fingerprint): the compiler
    # imports them, so they are legitimately compiler sources, but hashing them
    # would make the fingerprint depend on the output it is supposed to key --
    # "absent" and "present" would never agree and every run would look stale.
    # They are skipped here for the same reason the find below skips them.
    awk -F'\t' '!/^#/ && NF>=2 {print $2}' "$MANIFEST" 2>/dev/null | while IFS= read -r rel; do
      case "$(basename "$rel")" in
        compiler_sources_bundle.vibe|cli_adapter_bundle.vibe|selfbuild_runtime_entry_bundle.vibe|_cli_adapter_module_source.vibe|codegen_fingerprint.vibe) continue ;;
      esac
      case "$rel" in
        ../../../*) p="${rel#../../../}" ;;
        *) p="$COMPILER_DIR/$rel" ;;
      esac
      if [ -f "$p" ]; then sha256sum "$p"; else echo "MISSING $p"; fi
    done
    # The flatten walks cli_adapter.vibe's whole import closure, which reaches
    # past the manifest rows (@vibe/core, parser, ...). Rather than reimplement
    # import resolution here, over-approximate: hash every library .vibe.
    # Over-approximating costs an occasional needless regeneration;
    # under-approximating reintroduces exactly the staleness this replaces.
    #
    # Two exclusions are safe by construction rather than by convention:
    # the five outputs (they live in the tree they are hashed from, so
    # including them would make the fingerprint unstable), and tests/benches
    # (nothing the compiler imports is a test -- the dependency runs the other
    # way, e.g. tests/s5_test_support.vibe imports the bundles).
    find lib/@vibe lib/@vibex -name '*.vibe' -type f \
      ! -path '*/tests/*' ! -name '*_test.vibe' ! -name '*_bench.vibe' \
      ! -name 'compiler_sources_bundle.vibe' \
      ! -name 'cli_adapter_bundle.vibe' \
      ! -name 'selfbuild_runtime_entry_bundle.vibe' \
      ! -name '_cli_adapter_module_source.vibe' \
      ! -name 'codegen_fingerprint.vibe' \
      -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 sha256sum
}

compute_fingerprint() {
  fingerprint_inputs | sha256sum | cut -d' ' -f1
}

INPUTS_LIST="$(fingerprint_inputs)"
FP="$(printf '%s\n' "$INPUTS_LIST" | sha256sum | cut -d' ' -f1)"

if [ "$MODE" = "print" ]; then
  printf '%s\n' "$FP"
  exit 0
fi

all_present() {
  local f
  for f in "${ARTIFACTS[@]}"; do
    [ -s "$f" ] || return 1
  done
  return 0
}

is_current() {
  all_present || return 1
  [ -f "$STAMP" ] || return 1
  [ "$(cat "$STAMP" 2>/dev/null)" = "$FP" ] || return 1
  return 0
}

if [ "$MODE" = "check" ]; then
  if is_current; then
    echo "[ensure-generated] current ($FP)"
    exit 0
  fi
  echo "[ensure-generated] STALE or missing -- run: bash scripts/ensure_generated.sh" >&2
  exit 1
fi

if [ "$MODE" = "ensure" ] && is_current; then
  echo "[ensure-generated] up to date ($FP)"
  exit 0
fi

# SAY WHAT MOVED. A regeneration costs ~130s, and twice now CI has taken that
# cost inside a job that had just been told the artifacts were current -- once
# 1.1 seconds after an `up to date` line, with no edit in between (runs
# 34567587111 and 34579840316). All the evidence was two different hashes,
# which is not enough to act on. If the stamped input list is present, the
# difference against it IS the answer, so print it rather than leaving the next
# person to reconstruct it from timestamps.
if [ "$MODE" != "check" ] && [ -s "$INPUTS" ] && all_present; then
  echo "[ensure-generated] inputs differ from the stamped set:" >&2
  if diff_out="$(printf '%s\n' "$INPUTS_LIST" | diff "$INPUTS" - 2>/dev/null)"; then
    echo "  (none -- the list is identical, so the digest moved for another reason;" >&2
    echo "   that is a bug in compute_fingerprint, not a stale tree)" >&2
  else
    printf '%s\n' "$diff_out" | head -20 >&2
    changed="$(printf '%s\n' "$diff_out" | grep -c '^[<>]' || true)"
    echo "  ($changed differing line(s); < stamped, > now)" >&2
  fi
fi

if [ ! -f "$SEED" ]; then
  bash "$SCRIPT_DIR/ensure_seed.sh"
fi

echo "[ensure-generated] regenerating 5 artifacts (fingerprint $FP)"
# The stamp is removed FIRST so an interrupted or failed run cannot leave a
# stamp that vouches for half-written artifacts.
rm -f "$STAMP"
VIBE_REGEN_MODULE_SOURCE=1 \
  VIBE_ADAPTER_MODULE_SOURCE_OUT="$COMPILER_DIR/_cli_adapter_module_source.vibe" \
  bash "$SCRIPT_DIR/generate_bundle.sh"

missing=0
for f in "${ARTIFACTS[@]}"; do
  if [ ! -s "$f" ]; then
    echo "[ensure-generated] FAIL: $f was not produced" >&2
    missing=1
  fi
done
[ "$missing" = "0" ] || exit 1

# Re-hash rather than reusing $FP: generation writes into the same tree the
# fingerprint covers, so anything that perturbed an input mid-run must be caught
# here instead of being stamped as current.
FP_AFTER_LIST="$(fingerprint_inputs)"
FP_AFTER="$(printf '%s\n' "$FP_AFTER_LIST" | sha256sum | cut -d' ' -f1)"
if [ "$FP_AFTER" != "$FP" ]; then
  echo "[ensure-generated] FAIL: inputs changed during generation ($FP -> $FP_AFTER)" >&2
  exit 1
fi
printf '%s\n' "$FP_AFTER_LIST" > "$INPUTS"
printf '%s\n' "$FP" > "$STAMP"
echo "[ensure-generated] ok"
