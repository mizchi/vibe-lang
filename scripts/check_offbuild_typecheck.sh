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

# One compiler run per source, and they share nothing -- so they run
# concurrently. Serially this was 168s of CI wall time (run 34567587111) using
# one of the runner's four cores. min(4, nproc) is the level
# scripts/unit_test_runner.sh already runs compiler-sized compiles at; each
# peaks at a few GB of wasm memory, so an unbounded -P would OOM.
# VIBE_OFFBUILD_JOBS=1 restores the serial order.
ob_hw_jobs="$(nproc 2>/dev/null || echo 1)"
[ "$ob_hw_jobs" -gt 4 ] && ob_hw_jobs=4
OB_JOBS="${VIBE_OFFBUILD_JOBS:-$ob_hw_jobs}"

OB_WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_offbuild.XXXXXX")"
trap 'rm -rf "$OB_WORK"' EXIT

# The selection is unchanged; it just becomes a file the workers consume.
ob_selected="$OB_WORK/selected"
: >"$ob_selected"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if printf '%s' "$f" | grep -Eq "$EXCLUDE_RE"; then
    skipped=$((skipped + 1))
    continue
  fi
  total=$((total + 1))
  printf '%s\n' "$f" >>"$ob_selected"
done < "$listing"

ob_worker() {
  ob_f="$1"
  ob_slug="$(printf '%s' "$ob_f" | tr / _)"
  ob_out="$OB_WORK/$ob_slug.wasm"
  ob_err="$OB_WORK/$ob_slug.stderr"
  ob_status=0
  VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_CHECK_ONLY=1 \
    timeout 300 bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" \
    --invoke cli_main "$STAGE2" "$ob_f" "$ob_out" __no_entry__ >/dev/null 2>"$ob_err" || ob_status=$?
  printf '%s\n' "$ob_status" >"$OB_WORK/$ob_slug.status"
  return 0
}
export -f ob_worker
export OB_WORK PROJECT_ROOT SCRIPT_DIR STAGE2

# `|| true`: a worker records its status instead of exiting non-zero, so a
# non-zero here would be xargs itself; the status files are the answer.
xargs -P "$OB_JOBS" -I{} bash -c 'ob_worker "$@"' _ {} <"$ob_selected" || true

# Reported serially in listing order: which worker finished first must not
# change the output.
timed_out=0
while IFS= read -r f; do
  slug="$(printf '%s' "$f" | tr / _)"
  out="$OB_WORK/$slug.wasm"
  runner_err="$OB_WORK/$slug.stderr"
  if [ ! -f "$OB_WORK/$slug.status" ]; then
    failed=$((failed + 1))
    echo "[offbuild-typecheck] FAIL $f: no verdict (worker died)" >&2
    continue
  fi
  runner_status="$(cat "$OB_WORK/$slug.status")"
  if [ -s "$out.diag" ]; then
    failed=$((failed + 1))
    echo "[offbuild-typecheck] FAIL $f" >&2
    head -3 "$out.diag" >&2
    if [ "$runner_status" -eq 124 ]; then
      echo "[offbuild-typecheck] runner also timed out after 300 seconds" >&2
      head -3 "$runner_err" >&2
    elif [ "$runner_status" -ne 0 ]; then
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
  [ "$runner_status" -eq 124 ] && timed_out=1
done < "$ob_selected"

# The serial loop aborted the REMAINING sources on a timeout, which was a
# latency choice; here every source has already run, so a timeout is reported
# with the rest and still fails the gate.
if [ "$timed_out" -eq 1 ]; then
  echo "[offbuild-typecheck] at least one source timed out after 300 seconds" >&2
fi

if [ "$failed" -gt 0 ]; then
  echo "[offbuild-typecheck] FAIL: $failed of $total off-manifest source(s) do not typecheck" >&2
  exit 1
fi
echo "[offbuild-typecheck] ok: $total off-manifest source(s) typecheck ($skipped excluded)"
