#!/usr/bin/env bash
# #2872: a bodyless `impl` of a method-bearing trait, whose method has no
# `<Type>::<method>` of any kind to fall back to, is refused at BUILD time --
# and the refusal LEADS with the edit.
#
# Left accepted, the witness dictionary was built with a hole and the call site
# was emitted one argument SHORT. Measured 2026-09-18 against a stage2 built
# from main at 3017a67, on `fixtures/bodyless_impl_missing_method_refused.vibe`:
#
#   vibe check -> clean, empty output, exit 0
#   run        -> viberun: from_file: failed to compile: wasm[0]::function[4]
#
# The wasm VALIDATOR rejected the module, after the checker certified it, and
# the error the user saw was about the wasm stack rather than about the impl
# they had not finished writing. AGENTS.md names that exact shape
# (型検査を通り抜けて codegen で初めて落ちる) as evidence an implementation
# detail is leaking into the language.
#
# The MESSAGE is asserted and not merely the refusal: "did not compile" is
# satisfied by any unrelated breakage, which is how a gate ends up green about
# something it never saw (#2248). And it is asserted to BEGIN with the edit,
# not merely to contain it -- CLAUDE.md's rule is that a diagnostic leads with
# the edit that fixes it, and a message that buries the edit behind the reason
# satisfies "contains" while failing the rule.
#
# The GREEN side -- a bodyless impl whose fallback DOES resolve -- is
# `fixtures/bodyless_impl_witness_test.vibe`, on the unit lane. It is what
# would catch a refusal grown wide enough to reject a `derive (Eq)` struct's
# registration, which is the thing #2523 needs to keep working. The two are in
# different lanes on purpose: each condition here is one step from it.
#
# The corpus is a GLOB: a route found later joins by adding a fixture, not by
# editing this script.
#
# Usage:
#   bash scripts/check_bodyless_impl_refusal.sh
#   BODYLESS_IMPL_REFUSAL_STAGE2=<stage2.wasm> bash scripts/check_bodyless_impl_refusal.sh
set -euo pipefail
# Overridable ONLY so this gate's own self-test can run a MUTATED COPY of this
# script from a scratch directory -- the same escape hatch, for the same reason,
# as check_export_refusal.sh's VIBE_EXPORT_REFUSAL_ROOT. Unset on every real
# invocation.
ROOT_DIR="${VIBE_BODYLESS_IMPL_REFUSAL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT_DIR"

# A gate must be told WHICH compiler (CLAUDE.md, "Which compiler answered?").
# shellcheck source=resolve_stage2.sh
. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2 bodyless-impl-refusal "${BODYLESS_IMPL_REFUSAL_STAGE2:-}")" || exit 1

# Overridable so the self-test can point the gate at a mutated copy of the
# corpus instead of editing the tree's own fixtures.
FIXTURE_GLOB="${BODYLESS_IMPL_REFUSAL_FIXTURES:-fixtures/bodyless_impl_*_refused.vibe}"

# The clause the diagnostic must BEGIN with, named once so the self-test's
# mutation is a single edit.
EDIT_NEEDLE="add a body for "
# The reason clause. Asserted separately so a refusal that merely happens to
# start with the same words cannot pass as this one.
REASON_NEEDLE="must implement every method"

WORK="$ROOT_DIR/_build/_bodyless_impl_refusal"
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
    echo "[bodyless-impl-refusal] FAIL: $src compiled; expected a compile-time refusal (#2872)" >&2
    exit 1
  fi
  if ! grep -qF "$REASON_NEEDLE" "$out.diag" 2>/dev/null; then
    echo "[bodyless-impl-refusal] FAIL: $src was refused without the #2872 message" >&2
    cat "$out.diag" >&2 2>/dev/null || true
    exit 1
  fi
  # CLAUDE.md: a diagnostic LEADS with the edit that fixes it.
  #
  # The property itself, not "both clauses are present": the payload BEGINS
  # with the edit. A location prefix (`line L:C: `) and a module path prefix
  # are stripped first, each only in its own exact shape -- stripping arbitrary
  # text up to a `: ` would silently turn "begins with" back into "contains".
  # This diagnostic carries neither today; they are stripped so that giving it
  # a position later (#2831) does not turn this gate red for the right reason.
  leads_ok="$(awk -v edit="$EDIT_NEEDLE" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      for (n = 0; n < 2; n++) {
        if (sub(/^line [0-9]+:[0-9]+(-[0-9]+)?:[[:space:]]*/, "", line)) continue
        if (sub(/^[^[:space:]]*\.vibe[^[:space:]]*:[[:space:]]*/, "", line)) continue
        break
      }
      if (index(line, edit) == 1) { print "ok"; exit }
    }
  ' "$out.diag" 2>/dev/null || true)"
  if [ "$leads_ok" != "ok" ]; then
    echo "[bodyless-impl-refusal] FAIL: $src refusal does not BEGIN with the edit (#2872)" >&2
    echo "  expected the payload to start with: $EDIT_NEEDLE" >&2
    cat "$out.diag" >&2 2>/dev/null || true
    exit 1
  fi
done

if [ "$found" -eq 0 ]; then
  # Silence is "unchecked", not "clean".
  echo "[bodyless-impl-refusal] FAIL: no fixtures matched $FIXTURE_GLOB" >&2
  exit 1
fi

echo "[bodyless-impl-refusal] ok ($found refusal fixture(s), message asserted to lead with the edit)"
