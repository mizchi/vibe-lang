#!/usr/bin/env bash
# Typecheck the compiler sources that the self-build does NOT.
#
# WHY: `stage2 == stage3` says the compiler can rebuild itself, and that is a
# strong statement about the files in compiler_sources_manifest.tsv. It says
# NOTHING about the ~65 sources under lib/@vibe/compiler and lib/@vibe/cli that
# are outside the manifest -- the CLI entry surface, the linked-artifact
# helpers, the selfbuild gate blocks. A signature change that misses a call
# site in one of those leaves the fixpoint perfectly green and only surfaces
# ~20 minutes later, as an arity error in whichever unit-test files happen to
# compile the offending module.
#
# That happened twice in a row while threading parameters through
# compile_wasi_module_linked_impl (#1259 steps 7 and 8): ten unit-test files
# each time, one root cause, fixpoint green throughout. This gate is the cheap
# version of that discovery -- the real typechecker, so no false positives,
# over exactly the files the fixpoint leaves uncovered.
#
# Not a replacement for the unit battery: it only typechecks, it runs nothing.
#
# Usage:
#   bash scripts/check_offbuild_typecheck.sh [stage2.wasm]
# Env:
#   VIBE_OFFBUILD_STAGE2   explicit stage2 to check with (default: newest build)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
cd "$PROJECT_ROOT"

STAGE2="${1:-${VIBE_OFFBUILD_STAGE2:-}}"
if [ -z "$STAGE2" ]; then
  gen="$(ls -dt _build/selfhost/generations/*/ 2>/dev/null | head -1 || true)"
  [ -n "$gen" ] && STAGE2="${gen}stage2.wasm"
fi
if [ -z "$STAGE2" ] || [ ! -s "$STAGE2" ]; then
  echo "[offbuild-typecheck] no stage2 found; build one first" >&2
  echo "  (bash scripts/generations.sh build --out-dir /tmp/g && \\" >&2
  echo "   bash scripts/check_offbuild_typecheck.sh /tmp/g/stage2.wasm)" >&2
  exit 2
fi

# Excluded, each for a reason that is a property of the file and not "it fails":
#
#   _cli_probe_entry.vibe, _cli_stage1_entry.vibe
#     Alternate CLI entry points built with their own effect configuration.
#     Standalone they report an effect-row mismatch on their entry function,
#     which is correct -- the row is supplied by the build that uses them.
#   builtins/declarations.vibe
#     A `declare` table, not a module. `declare` is not source syntax and the
#     parser rejects it outside the loader that reads this file.
#
# Anything else failing here is a real regression. Resist growing this list:
# an entry belongs here only when the file is genuinely not standalone-checkable.
EXCLUDE_RE='(_cli_probe_entry\.vibe|_cli_stage1_entry\.vibe|builtins/declarations\.vibe)$'

listing="$(mktemp)"
trap 'rm -f "$listing"' EXIT

python3 - > "$listing" <<'PY'
import glob, os
man = set()
with open("lib/@vibe/compiler/compiler_sources_manifest.tsv", encoding="utf-8") as fh:
    for line in fh:
        for cell in line.rstrip("\n").split("\t"):
            if cell.endswith(".vibe"):
                man.add(os.path.normpath("lib/@vibe/compiler/" + cell))

srcs = glob.glob("lib/@vibe/compiler/**/*.vibe", recursive=True)
srcs += glob.glob("lib/@vibe/cli/**/*.vibe", recursive=True)
for p in sorted(srcs):
    base = os.path.basename(p)
    if base.endswith("_bundle.vibe") or "module_source" in p:
        continue          # generated
    if p.endswith("_test.vibe") or p.endswith("_bench.vibe"):
        continue          # the unit battery already compiles these
    if os.path.normpath(p) in man:
        continue          # covered by the fixpoint
    print(p)
PY

total=0
skipped=0
failed=0
out="$(mktemp -u)"
runner_err="$out.stderr"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if printf '%s' "$f" | grep -Eq "$EXCLUDE_RE"; then
    skipped=$((skipped + 1))
    continue
  fi
  total=$((total + 1))
  rm -f "$out" "$out.diag" "$runner_err"
  runner_status=0
  VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_CHECK_ONLY=1 \
    timeout 300 bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" \
    --invoke cli_main "$STAGE2" "$f" "$out" __no_entry__ >/dev/null 2>"$runner_err" || runner_status=$?
  if [ -s "$out.diag" ]; then
    failed=$((failed + 1))
    echo "[offbuild-typecheck] FAIL $f" >&2
    head -3 "$out.diag" >&2
    if [ "$runner_status" -ne 0 ]; then
      echo "[offbuild-typecheck] runner also exited $runner_status" >&2
      head -3 "$runner_err" >&2
    fi
  elif [ "$runner_status" -ne 0 ]; then
    failed=$((failed + 1))
    if [ "$runner_status" -eq 124 ]; then
      echo "[offbuild-typecheck] FAIL $f: compiler runner timed out after 300 seconds without a diagnostic" >&2
    else
      echo "[offbuild-typecheck] FAIL $f: compiler runner exited $runner_status without a diagnostic" >&2
    fi
    head -3 "$runner_err" >&2
  fi
  rm -f "$out" "$out.diag" "$runner_err"
done < "$listing"

if [ "$failed" -gt 0 ]; then
  echo "[offbuild-typecheck] FAIL: $failed of $total off-manifest source(s) do not typecheck" >&2
  exit 1
fi
echo "[offbuild-typecheck] ok: $total off-manifest source(s) typecheck ($skipped excluded)"
