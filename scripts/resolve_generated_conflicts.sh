#!/usr/bin/env bash
# Resolve merge/rebase conflicts in the committed generated compiler artifacts.
#
# lib/@vibe/compiler/ carries five build outputs that are committed so a clone
# can build without first building (the seed-only bootstrap contract):
#
#   compiler_sources_bundle.vibe
#   cli_adapter_bundle.vibe
#   selfbuild_runtime_entry_bundle.vibe
#   _cli_adapter_module_source.vibe
#   cache/codegen_fingerprint.vibe
#
# All five are deterministic functions of the compiler source, so *any* two
# branches that touch compiler source conflict in all five — which is why
# every open PR goes `dirty` the moment another one merges. The conflict is
# never a real one: the correct content is neither side's, it is whatever
# generate_bundle.sh produces from the already-merged sources.
#
# This script does exactly that: drop the conflicted artifacts, regenerate them
# from the merged sources, and stage the result. It does NOT touch a conflict in
# any hand-written file — those still need a human/agent decision, and the
# script refuses to stage anything while one is outstanding.
#
# Usage (inside an in-progress merge or rebase):
#   bash scripts/resolve_generated_conflicts.sh
#   git rebase --continue     # or: git commit
#
# A multi-commit rebase conflicts once PER COMMIT that touches the artifacts,
# and each later commit reintroduces its own (pre-rebase) copy — so resolving
# the first conflict does not make the FINAL tree correct. After the rebase
# finishes, regenerate the tip once:
#
#   bash scripts/resolve_generated_conflicts.sh --regen
#   git commit                # or: git commit --amend
#
# `--regen` needs no conflict; it just regenerates from the current tree and
# stages the result. `scripts/check_module_source_sync.sh` is the check that
# catches a tip that skipped this.
set -euo pipefail

REGEN_ONLY=0
case "${1:-}" in
  --regen) REGEN_ONLY=1 ;;
  "") ;;
  *) echo "usage: $0 [--regen]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
cd "$PROJECT_ROOT"

GENERATED=(
  "lib/@vibe/compiler/compiler_sources_bundle.vibe"
  "lib/@vibe/compiler/cli_adapter_bundle.vibe"
  "lib/@vibe/compiler/selfbuild_runtime_entry_bundle.vibe"
  "lib/@vibe/compiler/_cli_adapter_module_source.vibe"
  "lib/@vibe/compiler/cache/codegen_fingerprint.vibe"
)

is_generated() {
  local needle="$1" g
  for g in "${GENERATED[@]}"; do
    [ "$needle" = "$g" ] && return 0
  done
  return 1
}

if [ "$REGEN_ONLY" -eq 1 ]; then
  echo "resolve-generated-conflicts: --regen (no conflict required)"
  # The tip is already committed here, so there is no staged set to format from.
  # Lint the whole tree instead — generating from unformatted source is the one
  # ordering mistake that turns into a confusing bundle-drift failure later.
  if ! bash "$SCRIPT_DIR/check_vibe_fmt.sh" >/dev/null 2>&1; then
    echo "resolve-generated-conflicts: lib/ is not formatted; run 'pkf run fmt' first" >&2
    echo "(generating from unformatted source bakes the wrong text into the bundle)" >&2
    exit 1
  fi
else
  # `git diff --name-only --diff-filter=U` lists exactly the unmerged paths, in
  # both merge and rebase states.
  mapfile -t conflicted < <(git diff --name-only --diff-filter=U)

  if [ "${#conflicted[@]}" -eq 0 ]; then
    echo "resolve-generated-conflicts: no conflicted paths; nothing to do"
    echo "(after a finished rebase, regenerate the tip with --regen)"
    exit 0
  fi

  gen_conflicts=()
  other_conflicts=()
  for path in "${conflicted[@]}"; do
    if is_generated "$path"; then
      gen_conflicts+=("$path")
    else
      other_conflicts+=("$path")
    fi
  done

  if [ "${#other_conflicts[@]}" -gt 0 ]; then
    echo "resolve-generated-conflicts: hand-written files are still conflicted:" >&2
    printf '  %s\n' "${other_conflicts[@]}" >&2
    echo "Resolve those first; regenerating now would bake an unresolved tree" >&2
    echo "into the artifacts." >&2
    exit 1
  fi

  echo "resolve-generated-conflicts: regenerating ${#gen_conflicts[@]} artifact(s)"
  printf '  %s\n' "${gen_conflicts[@]}"

  # Take one side verbatim purely to clear the unmerged index entries — the
  # content is overwritten by the regeneration below, so which side loses does
  # not matter. `--ours` is the side already checked out in both merge and
  # rebase, so it always exists.
  for path in "${gen_conflicts[@]}"; do
    git checkout --ours -- "$path"
  done
fi

# Format the merged hand-written sources BEFORE generating: the bundles embed
# source text verbatim, so generating first and formatting second leaves the
# committed bundle disagreeing with the committed source, which reads as
# bundle drift in the gate rather than as a formatting problem.
mapfile -t touched < <(git diff --cached --name-only --diff-filter=ACM -- 'lib/**/*.vibe' 2>/dev/null || true)
for f in "${touched[@]}"; do
  is_generated "$f" && continue
  [ -f "$f" ] || continue
  if ! bash "$SCRIPT_DIR/vibe_fmt.sh" --check "$f" >/dev/null 2>&1; then
    echo "  fmt: $f"
    bash "$SCRIPT_DIR/vibe_fmt.sh" --stdout "$f" > "$f.fmt.tmp" && mv "$f.fmt.tmp" "$f"
  fi
done

VIBE_REGEN_MODULE_SOURCE=1 \
  VIBE_ADAPTER_MODULE_SOURCE_OUT=lib/@vibe/compiler/_cli_adapter_module_source.vibe \
  bash "$SCRIPT_DIR/generate_bundle.sh"

git add -- "${GENERATED[@]}"
for f in "${touched[@]}"; do
  [ -f "$f" ] && git add -- "$f"
done

echo "resolve-generated-conflicts: staged. Next: git rebase --continue (or git commit)"
echo "Then verify with: bash scripts/compiler_gate.sh"
