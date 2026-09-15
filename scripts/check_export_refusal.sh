#!/usr/bin/env bash
# #2762: an aggregate `export { }` naming a name the module neither declares nor
# imports is refused, and the refusal LEADS with the edit.
#
# Left accepted, the export silently became a no-op and the two lanes disagreed
# about whether the module was a program. Measured 2026-09-15 against a stage2
# built from main at f8d0b24, one module whose only oddity is
# `export { NotDeclaredAnywhere }`:
#
#   VIBE_CHECK_ONLY=1                   clean, exit 0, output written
#   the same plus the invalidation trace  `incremental interface observation:
#                                        exported name missing from checked
#                                        environment: NotDeclaredAnywhere`,
#                                        exit 1, no output, no trace
#
# and a consumer that imported the promised name was told `line 3:3: imported
# name 'NotDeclaredAnywhere' is not exported by './dep.vibe'` -- pointing at ITS
# OWN import rather than at the module that promised it.
#
# The MESSAGE is asserted and not merely the refusal: "did not compile" is
# satisfied by any unrelated breakage, which is how a gate ends up green about
# something it never saw (#2248). And it is asserted to BEGIN with the edit, not
# merely to contain it -- CLAUDE.md's rule is that a diagnostic leads with the
# edit that fixes it, and a message that buries the edit behind the reason
# satisfies "contains" while failing the rule. That distinction is the one
# Codex round 4 on #2753 found missing from the sibling gate for #2737.
#
# The GREEN side -- the six shapes an `export { }` may legitimately name -- is a
# separate corpus in the `fixtures/typecheck` lane
# (`export_aggregate_*_ok` rows in `fixtures/typecheck/expected.tsv`). It is what
# would catch a refusal that grew wide enough to reject `lib/@vibe/builtin/
# option.vibe` (which publishes the compiler-provided `Option`) or to withdraw a
# private trait's impls from an export surface. Every condition here is one step
# from that, so the two corpora are checked in different lanes on purpose.
#
# THIS GATE IS THE FS LANE ONLY, deliberately. Codex (P1 round 2 on #2806)
# correctly noted that forcing VIBE_FS_COMPILE=1 means it cannot see the flat
# single-source lanes (`compile_source_wasi*`, `compile_source_gc_only`), which
# publish no export surface and so did accept the module until that round.
# Those lanes are pinned by `lib/@vibe/compiler/tests/export_lane_parity_test.
# vibe`, which calls them directly and asserts the message.
#
# Not by a second pass here, and the reason is #2248's own rule: with the fix in
# place no input is refused on one lane and accepted on the other, so a red case
# isolating a second pass cannot be written from inputs -- and an assertion that
# cannot be shown failing is exactly what that rule forbids. The unit lane can
# assert it because it calls the lane under test directly, in a lane whose
# ability to fail is already established.
#
# The corpus is a GLOB: a route found later joins by adding a fixture, not by
# editing this script. It currently holds two, and the second is not a
# duplicate: `export_aggregate_importer_refused.vibe` is CLEAN and imports the
# broken module, so it is what says the diagnostic names the module that
# PROMISED the name rather than the one that believed it -- the issue's actual
# complaint. Its `.diag` leads with the DEPENDENCY's path, which is why the
# leads-check below strips a path prefix as well as a location one.
#
# Usage:
#   bash scripts/check_export_refusal.sh
#   EXPORT_REFUSAL_STAGE2=<stage2.wasm> bash scripts/check_export_refusal.sh
set -euo pipefail
# Overridable ONLY so this gate's own self-test can run a MUTATED COPY of this
# script from a scratch directory -- the same escape hatch, for the same reason,
# as check_lambda_bound_refusal.sh's VIBE_LAMBDA_BOUND_REFUSAL_ROOT. Unset on
# every real invocation.
ROOT_DIR="${VIBE_EXPORT_REFUSAL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT_DIR"

# A gate must be told WHICH compiler (CLAUDE.md, "Which compiler answered?").
# shellcheck source=resolve_stage2.sh
. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2 export-refusal "${EXPORT_REFUSAL_STAGE2:-}")" || exit 1

# Overridable so the self-test can point the gate at a mutated copy of the
# corpus instead of editing the tree's own fixtures.
FIXTURE_GLOB="${EXPORT_REFUSAL_FIXTURES:-fixtures/typecheck/export_aggregate_*_refused.vibe}"

# The clause the diagnostic must BEGIN with, named once so the self-test's
# mutation is a single edit.
EDIT_NEEDLE="declare or import "
# The reason clause. Asserted separately so a refusal that merely happens to
# start with the same words cannot pass as this one.
REASON_NEEDLE="the export publishes a name this module does not have"

WORK="$ROOT_DIR/_build/_export_refusal"
rm -rf "$WORK"; mkdir -p "$WORK"

found=0
for src in $FIXTURE_GLOB; do
  [ -f "$src" ] || continue
  found=$((found + 1))
  name="$(basename "${src%.vibe}")"
  out="$WORK/$name.wasm"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    "$src" "$out" main >/dev/null 2>&1 || true
  if [ -s "$out" ]; then
    echo "[export-refusal] FAIL: $src compiled; expected a compile-time refusal (#2762)" >&2
    exit 1
  fi
  if ! grep -qF "$REASON_NEEDLE" "$out.diag" 2>/dev/null; then
    echo "[export-refusal] FAIL: $src was refused without the #2762 message" >&2
    cat "$out.diag" >&2 2>/dev/null || true
    exit 1
  fi
  # CLAUDE.md: a diagnostic LEADS with the edit that fixes it.
  #
  # The property itself, not "both clauses are present": the payload BEGINS with
  # the edit. The location prefix this diagnostic carries (`line L:C: `) and the
  # module path are stripped first, each only in its own exact shape -- stripping
  # arbitrary text up to a `: ` would silently turn "begins with" back into
  # "contains".
  leads_ok="$(awk -v edit="$EDIT_NEEDLE" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      # At most two prefixes, in either order: the compiler emits
      # `<path>: line L:C: <msg>` here and `line L:C: <path>: <msg>` elsewhere.
      for (n = 0; n < 2; n++) {
        if (sub(/^line [0-9]+:[0-9]+(-[0-9]+)?:[[:space:]]*/, "", line)) continue
        if (sub(/^[^[:space:]]*\.vibe[^[:space:]]*:[[:space:]]*/, "", line)) continue
        break
      }
      if (index(line, edit) == 1) { print "ok"; exit }
    }
  ' "$out.diag" 2>/dev/null || true)"
  if [ "$leads_ok" != "ok" ]; then
    echo "[export-refusal] FAIL: $src refusal does not BEGIN with the edit (#2762)" >&2
    echo "  expected the payload to start with: $EDIT_NEEDLE" >&2
    cat "$out.diag" >&2 2>/dev/null || true
    exit 1
  fi
done

if [ "$found" -eq 0 ]; then
  # Silence is "unchecked", not "clean".
  echo "[export-refusal] FAIL: no fixtures matched $FIXTURE_GLOB" >&2
  exit 1
fi

echo "[export-refusal] ok ($found refusal fixture(s), message asserted to lead with the edit)"
