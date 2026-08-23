#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$ROOT_DIR/_build/vibe_fmt_parse_guard_test.$$"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work"

# This test used to assert the opposite of what it asserts now, and the change
# is the point.
#
# It was written for #1822, when the formatter still rewrote `Point { x: 1 }`
# into `Point::{ x: 1 }` and needed a hand-written exclusion for every token
# that could sit before the brace. `!` was not one of them, so `if !Flag {`
# became `if !Flag::{` -- and the test asserted that the entry's parse guard
# CAUGHT that, by requiring vibe_fmt.sh to fail on this input.
#
# #1821 then measured what the rewrite was for: across 948 files under lib and
# 727 candidates under fixtures/ and scripts/, it fired exactly once, on a
# fixture that does not compile. Its whole useful domain was source the parser
# rejects; on source it accepts it could only misfire, which it did six times
# (#945, #1429, #1505, `!=`, `in`, `!`). It is gone.
#
# So this input no longer corrupts, and demanding a refusal would demand the bug
# back. What is worth pinning is the outcome -- the shape formats, and it
# formats to itself.

pass_input="$work/pass.vibe"
cat >"$pass_input" <<'VIBE'
fn f() -> Int {
  if !Flag {
    1
  } else {
    0
  }
}
VIBE
cp "$pass_input" "$work/pass.original"

if ! bash "$ROOT_DIR/scripts/vibe_fmt.sh" "$pass_input" >/dev/null 2>&1; then
  echo "vibe_fmt_parse_guard_test: formatter declined a file it should format" >&2
  exit 1
fi
if grep -q '::{' "$pass_input"; then
  echo "vibe_fmt_parse_guard_test: formatter inserted a struct-literal :: (#1821 regression)" >&2
  sed -n '1,20p' "$pass_input" >&2
  exit 1
fi
if ! cmp -s "$pass_input" "$work/pass.original"; then
  echo "vibe_fmt_parse_guard_test: formatter changed a file that was already formatted" >&2
  diff "$work/pass.original" "$pass_input" >&2 || true
  exit 1
fi

# The guard's other half, which IS still reachable: it must not over-refuse.
# It rejects a rewrite that BREAKS a file, not any file that happens not to
# parse -- the promise is "no worse", not "only valid input". Getting this
# backwards would make the formatter useless on exactly the broken files a
# person most wants to run it on.
broken="$work/broken.vibe"
printf 'fn f( {\n  1\n' >"$broken"
if ! bash "$ROOT_DIR/scripts/vibe_fmt.sh" "$broken" >/dev/null 2>&1; then
  echo "vibe_fmt_parse_guard_test: formatter refused a file that never parsed;" >&2
  echo "  the guard rejects rewrites that BREAK a file, not files already broken" >&2
  exit 1
fi


# #2244 round-3 finding: a leading `require ... = #pkg:sha1:` pin head is a
# loader directive, not vibe syntax. The formatter used to feed it to the CST
# formatter and mangle it into text the loader rejects (`require @vibe /
# core0.2.0 = ...`), and the parse guard could not see it -- the RAW input
# does not parse either. The head must come back byte-identical, the body
# formatted, and the result must be a --check fixpoint.
pin="$work/pin_head.vibe"
printf 'require @vibe/core 0.2.0 = #pkg:sha1:0000000000000000000000000000000000000000\n\nfn double(n:Int)->Int {\n  n*2\n}\n' >"$pin"
if ! bash "$ROOT_DIR/scripts/vibe_fmt.sh" "$pin" >/dev/null 2>&1; then
  echo "vibe_fmt_parse_guard_test: formatter declined a require-pin-head file" >&2
  exit 1
fi
if ! head -1 "$pin" | grep -q '^require @vibe/core 0\.2\.0 = #pkg:sha1:0000000000000000000000000000000000000000$'; then
  echo "vibe_fmt_parse_guard_test: formatter mangled the require-pin head" >&2
  head -1 "$pin" >&2
  exit 1
fi
if ! grep -q '^fn double(n: Int) -> Int {$' "$pin"; then
  echo "vibe_fmt_parse_guard_test: body under a pin head was not formatted" >&2
  sed -n '1,6p' "$pin" >&2
  exit 1
fi
if ! bash "$ROOT_DIR/scripts/vibe_fmt.sh" --check "$pin" >/dev/null 2>&1; then
  echo "vibe_fmt_parse_guard_test: pin-head formatting is not a --check fixpoint" >&2
  exit 1
fi

# #2253 round-6 finding: the head split must reach EVERY formatter entry, not
# just fmt_entry -- the batch lane (lib/@vibe/cli/fmt.vibe, what CI's
# vibe-fmt-check and `pkf run fmt` run) calls format_source directly and used
# to mangle the same pin head. The split now lives inside format_source, so
# the batch lane preserves it too; prove it through the real batch runner.
# (run_vibe_fmt_batch.sh wants repo-relative paths under the preopen root, so
# the fixture lives under _build.)
batch_pin_rel="_build/vibe_fmt_parse_guard_batch_pin.$$.vibe"
batch_pin="$ROOT_DIR/$batch_pin_rel"
trap 'rm -rf "$work" "$batch_pin"' EXIT
printf 'require @vibe/core 0.2.0 = #pkg:sha1:0000000000000000000000000000000000000000\n\nfn double(n:Int)->Int {\n  n*2\n}\n' >"$batch_pin"
batch_report="$(printf '%s\n' "$batch_pin_rel" | bash "$ROOT_DIR/scripts/run_vibe_fmt_batch.sh" write 1)"
case "$batch_report" in
  DIFF*) : ;;
  *)
    echo "vibe_fmt_parse_guard_test: batch lane did not rewrite the pin-head file (report: $batch_report)" >&2
    exit 1
    ;;
esac
if ! head -1 "$batch_pin" | grep -q '^require @vibe/core 0\.2\.0 = #pkg:sha1:0000000000000000000000000000000000000000$'; then
  echo "vibe_fmt_parse_guard_test: BATCH lane mangled the require-pin head" >&2
  head -1 "$batch_pin" >&2
  exit 1
fi
if ! grep -q '^fn double(n: Int) -> Int {$' "$batch_pin"; then
  echo "vibe_fmt_parse_guard_test: batch lane did not format the body under a pin head" >&2
  sed -n '1,6p' "$batch_pin" >&2
  exit 1
fi

# #730 D-3 (module-system-v2 §6): pinned form is canonical, so fmt COMPLETES
# an unpinned `require @scope/name x.y.z` head line with `= #hash` when the
# package is installed in the workspace store -- offline, best-effort. A
# package the store cannot answer leaves its line byte-identical (fetching
# belongs to `vibe add`/`update`, and a formatter that fails over an absent
# store entry would be unusable on machines that never use the pin lane).
# The store fixture is created here because the workspace store is
# gitignored -- nothing in a fresh clone provides one.
store_pkg="@fmtpin/p$$"
store_dir="$ROOT_DIR/.vibe/store/$store_pkg"
fill_in="_build/vibe_fmt_pin_fill.$$.vibe"
fill_abs="$ROOT_DIR/$fill_in"
trap 'rm -rf "$work" "$batch_pin" "$store_dir" "$fill_abs"' EXIT
mkdir -p "$store_dir"
printf 'import ./impl.vibe {}\nfn quadruple(x: Int) -> Int\n' >"$store_dir/index.vibei"
printf 'export fn quadruple(x: Int) -> Int { x * 4 }\n' >"$store_dir/impl.vibe"

printf 'require %s 0.1.0\n\nfn double(n:Int)->Int {\n  n*2\n}\n' "$store_pkg" >"$fill_abs"
if ! bash "$ROOT_DIR/scripts/vibe_fmt.sh" "$fill_abs" >/dev/null 2>&1; then
  echo "vibe_fmt_parse_guard_test: formatter declined an unpinned-require file" >&2
  exit 1
fi
if ! head -1 "$fill_abs" | grep -Eq "^require $store_pkg 0\.1\.0 = #pkg:sha1:[0-9a-f]{40}\$"; then
  echo "vibe_fmt_parse_guard_test: fmt did not fill the require pin from the store" >&2
  head -1 "$fill_abs" >&2
  exit 1
fi
if ! grep -q '^fn double(n: Int) -> Int {$' "$fill_abs"; then
  echo "vibe_fmt_parse_guard_test: body under a filled pin head was not formatted" >&2
  sed -n '1,6p' "$fill_abs" >&2
  exit 1
fi
if ! bash "$ROOT_DIR/scripts/vibe_fmt.sh" --check "$fill_abs" >/dev/null 2>&1; then
  echo "vibe_fmt_parse_guard_test: pin filling is not a --check fixpoint" >&2
  exit 1
fi

# A package absent from the store: the line comes back byte-identical and the
# run still succeeds (the body is formatted; the build is what rejects an
# unpinned require).
printf 'require @fmtpin/absent%s 0.1.0\n\nfn id(n:Int)->Int {\n  n\n}\n' "$$" >"$fill_abs"
if ! bash "$ROOT_DIR/scripts/vibe_fmt.sh" "$fill_abs" >/dev/null 2>&1; then
  echo "vibe_fmt_parse_guard_test: formatter failed on a require the store cannot answer" >&2
  exit 1
fi
if ! head -1 "$fill_abs" | grep -q "^require @fmtpin/absent$$ 0\.1\.0\$"; then
  echo "vibe_fmt_parse_guard_test: an unanswerable require line was not left verbatim" >&2
  head -1 "$fill_abs" >&2
  exit 1
fi

# The batch lane (CI's vibe-fmt-check / `pkf run fmt`) fills the same way.
printf 'require %s 0.1.0\n\nfn double(n:Int)->Int {\n  n*2\n}\n' "$store_pkg" >"$fill_abs"
fill_report="$(printf '%s\n' "$fill_in" | bash "$ROOT_DIR/scripts/run_vibe_fmt_batch.sh" write 1)"
case "$fill_report" in
  DIFF*) : ;;
  *)
    echo "vibe_fmt_parse_guard_test: batch lane did not fill the pin (report: $fill_report)" >&2
    exit 1
    ;;
esac
if ! head -1 "$fill_abs" | grep -Eq "^require $store_pkg 0\.1\.0 = #pkg:sha1:[0-9a-f]{40}\$"; then
  echo "vibe_fmt_parse_guard_test: BATCH lane did not fill the require pin" >&2
  head -1 "$fill_abs" >&2
  exit 1
fi

# #2260 Codex round 1: the formatter artifact's staleness must track the
# entry's RESOLVED import closure, not a hand list -- a hand list cannot see
# transitive dependencies (loader/header_cache.vibe is reachable from
# fmt_entry through contract_package_hashes_fs and was tracked by nothing).
# ensure_entry_wasm.sh captures the closure into <wasm>.deps at build time;
# prove a transitive dep is IN the manifest and that touching it rebuilds.
entry_wasm="$ROOT_DIR/_build/vibe_fmt/fmt_entry.wasm"
bash "$ROOT_DIR/scripts/ensure_vibe_fmt_entry.sh" >/dev/null
if ! grep -q '^lib/@vibe/compiler/loader/header_cache\.vibe$' "$entry_wasm.deps"; then
  echo "vibe_fmt_parse_guard_test: fmt_entry's captured closure is missing a transitive dep (header_cache.vibe)" >&2
  exit 1
fi
before_mtime="$(stat -c %Y "$entry_wasm")"
sleep 1
touch "$ROOT_DIR/lib/@vibe/compiler/loader/header_cache.vibe"
bash "$ROOT_DIR/scripts/ensure_vibe_fmt_entry.sh" >/dev/null
after_mtime="$(stat -c %Y "$entry_wasm")"
if [ "$after_mtime" -le "$before_mtime" ]; then
  echo "vibe_fmt_parse_guard_test: touching a transitive dep did not rebuild the cached formatter" >&2
  exit 1
fi

echo "vibe_fmt_parse_guard_test: ok"
