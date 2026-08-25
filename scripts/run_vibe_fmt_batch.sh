#!/usr/bin/env bash
# Format/check many files through ONE batched vibe process
# (lib/@vibe/cli/fmt.vibe) instead of one scripts/vibe_fmt.sh process per
# file. Per-file process spawn + wasm instantiate is a ~200-250ms fixed
# cost regardless of file size (see lib/@vibe/compiler/fmt_bench.vibe) --
# batching amortizes that across the whole file list, and `jobs > 1` shards
# it across a few backgrounded subprocess re-invocations for real
# wall-clock parallelism on top.
#
# Reads the file list on stdin (one repo-relative path per line, as
# produced by `git ls-files`), writes one "STATUS\tpath[\tmessage]" report
# line per input file to stdout (STATUS: OK | DIFF | ERROR). Callers
# (scripts/vibe_fmt_apply.sh, scripts/check_vibe_fmt.sh) own listing files
# and any allowlist policy.
#
#   printf '%s\n' "${files[@]}" | bash scripts/run_vibe_fmt_batch.sh <check|write> [jobs]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mode="${1:?usage: run_vibe_fmt_batch.sh <check|write> [jobs]}"
jobs="${2:-$(nproc 2>/dev/null || echo 1)}"

case "$mode" in
  check | write) ;;
  *) echo "run_vibe_fmt_batch.sh: mode must be check or write, got: $mode" >&2; exit 2 ;;
esac

# `|| exit 2` -- NOT a bare assignment. Under `set -e` a failed formatter
# build killed this script with exit 1 and nothing on stderr, and the caller
# reads this script through a process substitution whose status it never
# sees, so the batch simply produced no report lines and the lint reported
# "checked 0 file(s)" and exited 0 (#2271).
batch_wasm_rel="$(bash "$ROOT_DIR/scripts/ensure_vibe_fmt_batch.sh")" || {
  echo "run_vibe_fmt_batch.sh: could not build the batch formatter -- see the compile diagnostics above" >&2
  echo "  no file was checked or rewritten; this is not a formatting verdict" >&2
  exit 2
}

work="$ROOT_DIR/_build/vibe_fmt_batch"
mkdir -p "$work"
manifest_rel="_build/vibe_fmt_batch/manifest.txt"
report_rel="_build/vibe_fmt_batch/report.txt"
rm -f "$ROOT_DIR/$report_rel"
cat > "$ROOT_DIR/$manifest_rel"

if [ ! -s "$ROOT_DIR/$manifest_rel" ]; then
  exit 0
fi

VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
  --invoke main "$batch_wasm_rel" "$mode" "$manifest_rel" "$report_rel" "$jobs" >/dev/null

[ -f "$ROOT_DIR/$report_rel" ] || { echo "run_vibe_fmt_batch.sh: no report produced" >&2; exit 1; }
# The report has no trailing newline (lib/@vibe/cli/fmt.vibe joins lines
# without one) -- add one so a naive `while read` loop over this output
# doesn't drop the final line.
cat "$ROOT_DIR/$report_rel"
echo
