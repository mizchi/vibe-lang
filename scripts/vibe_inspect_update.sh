#!/usr/bin/env bash
# `vibe_inspect_update.sh <path.vibe>...` -- MoonBit `inspect`/`--update`
# style snapshot auto-update for lib/@vibe/core/assert.vibe's
# `inspect(value, content)` (#1061 follow-up).
#
# `inspect()` itself is unchanged: on a mismatch it still `println`s
#   inspect mismatch:
#     actual:   <ACTUAL>
#     expected: <EXPECTED>
# and traps. scripts/vibe_test.sh compiles/runs a test file the same way
# but discards stdout, so it can only report pass/fail -- this script
# reuses the same compile/run recipe while KEEPING stdout, feeds a
# failing run's captured output to vibe_inspect_update_patch.py (which
# rewrites the first occurrence of the stale `content` literal to the
# actual value), and repeats until the file's tests pass or a failure
# shows up that isn't a recognizable inspect() mismatch.
#
# Known v1 limitations (no CST/span tracking exists yet for EString --
# see docs/adr.md #0087): the patch (vibe_inspect_update_patch.py) locates
# the content argument of an actual inspect(...) call rather than any
# string literal in the file, but two DISTINCT inspect() calls with
# byte-identical `content` still can't be told apart by text alone -- only
# the first (in file order) is patched, and this loop's next iteration's
# trap surfaces the next distinct mismatch; an actual value containing the
# literal substring "\n  expected: " defeats the diagnostic parser. Both
# cases are reported as a manual-fixup failure instead of guessing.
#
# Independent of, and not a replacement for, the fixtures/ `__DATA__`
# suffix format (lib/@vibe/compiler/tests/fixture_test_support.vibe) --
# that's a separate, still-live "external snapshot" convention for
# whole-program expected-output fixtures. This tool is for `test {}`
# blocks using `inspect()` as an inline snapshot.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ "$#" -lt 1 ]; then
  echo "usage: vibe_inspect_update.sh <path.vibe> [more paths...]" >&2
  exit 2
fi

bash "$ROOT_DIR/scripts/ensure_seed.sh"
seed="$ROOT_DIR/bootstrap/seed/compiler.wasm"
cli_wasm="${VIBE_TEST_CLI_WASM:-$seed}"
outdir="$ROOT_DIR/_build/vibe_inspect_update"
mkdir -p "$outdir"

max_iters=50

update_one() {
  local src="$1" src_rel flat out_rel
  case "$src" in
    "$ROOT_DIR"/*) src_rel="${src#"$ROOT_DIR"/}" ;;
    /*)
      echo "[inspect-update] FAIL: path must be under the repo root: $src" >&2
      return 1
      ;;
    *) src_rel="$src" ;;
  esac
  if [ ! -f "$ROOT_DIR/$src_rel" ]; then
    echo "[inspect-update] FAIL: not found: $src_rel" >&2
    return 1
  fi
  flat="$(echo "$src_rel" | tr '/' '_' | sed 's/\.vibe$//')"
  out_rel="_build/vibe_inspect_update/$flat.wasm"

  local iter=0 patches=0
  while [ "$iter" -lt "$max_iters" ]; do
    iter=$((iter + 1))
    rm -f "$ROOT_DIR/$out_rel"
    if ! env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
        bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
        --invoke cli_main "$cli_wasm" "$src_rel" "$out_rel" "__no_entry__" \
        >/dev/null 2>&1 || [ ! -s "$ROOT_DIR/$out_rel" ]; then
      echo "[inspect-update] FAIL (compile): $src_rel" >&2
      return 1
    fi

    # #1235 review (P2): capture to a FILE, not a `$(...)` shell variable --
    # command substitution unconditionally strips trailing newlines, which
    # would truncate an <EXPECTED> snapshot ending in "\n" (it sits at the
    # very end of the captured stream) before the patch helper ever sees it.
    local run_out="$outdir/$flat.stdout" rc
    set +e
    VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke _start "$out_rel" >"$run_out" 2>/dev/null
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
      rm -f "$run_out"
      if [ "$patches" -eq 0 ]; then
        echo "[inspect-update] ok (already up to date): $src_rel"
      else
        echo "[inspect-update] updated $patches snapshot(s): $src_rel"
      fi
      return 0
    fi

    local verdict
    verdict="$(python3 "$ROOT_DIR/scripts/vibe_inspect_update_patch.py" "$ROOT_DIR/$src_rel" < "$run_out")"
    rm -f "$run_out"
    if [ "$verdict" != "patched" ]; then
      echo "[inspect-update] FAIL: $src_rel failed without a recognizable inspect() mismatch -- fix manually" >&2
      return 1
    fi
    patches=$((patches + 1))
  done
  echo "[inspect-update] FAIL: $src_rel did not converge after $max_iters iterations" >&2
  return 1
}

status=0
for f in "$@"; do
  update_one "$f" || status=1
done
exit "$status"
