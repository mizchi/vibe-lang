#!/usr/bin/env bash
# Compile a .vibe entry to wasm with the committed seed iff it is missing or
# stale, tracking the ENTRY'S RESOLVED IMPORT CLOSURE rather than a
# hand-maintained file list (#2260 Codex round 1: a hand list cannot see
# transitive dependencies -- loader/header_cache.vibe was reachable from
# fmt_entry through contract_package_hashes_fs and tracked by nothing, so an
# edit there left the cached formatter answering with stale behavior).
#
# The closure comes from the compiler's own module plan (VIBE_MODULE_PLAN,
# the same resolution `vibe deps` reports), captured into a sibling
# `<wasm>.deps` manifest at build time. Three staleness signals cover the
# ways the closure can drift (#2260 Codex round 2 -- mtimes of the old path
# set alone do not):
#   1. a recorded file newer than the wasm -- an edit anywhere in the old
#      closure, which is also how every import-graph change made BY editing
#      reaches us;
#   2. a recorded file that no longer exists -- deletions and renames,
#      where -nt alone would answer "fresh";
#   3. a closure member's parent DIRECTORY newer than the wasm -- the
#      loader auto-discovers `.vpkg` sibling implementations, so a newly
#      created file can join the closure without any recorded file
#      changing; creating/removing/renaming an entry updates its
#      directory's mtime.
# A manifest that cannot be produced is simply not written, which leaves
# the artifact permanently stale -- always-rebuild is the safe failure
# mode, never stale-reuse.
#
# Usage: ensure_entry_wasm.sh <entry_src_rel> <wasm_rel>
# Prints the repo-root-relative wasm path on stdout; all build noise on
# stderr (callers capture stdout).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

entry_src="${1:?usage: ensure_entry_wasm.sh <entry_src_rel> <wasm_rel>}"
wasm_rel="${2:?usage: ensure_entry_wasm.sh <entry_src_rel> <wasm_rel>}"
deps_rel="$wasm_rel.deps"

bash "$ROOT_DIR/scripts/ensure_seed.sh" >&2
seed="$ROOT_DIR/bootstrap/seed/compiler.wasm"
mkdir -p "$(dirname "$ROOT_DIR/$wasm_rel")"

stale=0
if [ ! -s "$ROOT_DIR/$wasm_rel" ] || [ ! -s "$ROOT_DIR/$deps_rel" ] \
   || [ "$entry_src" -nt "$ROOT_DIR/$wasm_rel" ] \
   || [ "$seed" -nt "$ROOT_DIR/$wasm_rel" ]; then
  stale=1
else
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    if [ ! -e "$ROOT_DIR/$dep" ] || [ "$ROOT_DIR/$dep" -nt "$ROOT_DIR/$wasm_rel" ]; then
      stale=1
      break
    fi
  done < "$ROOT_DIR/$deps_rel"
  if [ "$stale" = "0" ]; then
    # Dedupe the parent directories without an associative array -- stock
    # macOS runs Bash 3.2, where `declare -A` is a hard error (#2260
    # round 7; scripts/test_affected_test.sh documents 3.2 as supported).
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      if [ "$ROOT_DIR/$d" -nt "$ROOT_DIR/$wasm_rel" ]; then
        stale=1
        break
      fi
    done < <(
      while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        d="${dep%/*}"
        [ "$d" = "$dep" ] && d="."
        printf '%s\n' "$d"
      done < "$ROOT_DIR/$deps_rel" | sort -u
    )
  fi
fi

if [ "$stale" = "1" ]; then
  # Build to a PROCESS-UNIQUE path and publish by rename, never in place.
  #
  # A failed rebuild must not leave the previous artifact answering -- that is
  # the stale-reuse the staleness rules above exist to prevent (#2271) -- but
  # deleting it up front to achieve that opened a worse window: callers run
  # concurrently (scripts/vibe_md.sh spawns one worker per document), two
  # workers can both see "stale", and the slower one's `rm` then lands after
  # the faster one has finished compiling or has already started running the
  # wasm. The first caller is handed a path to a deleted or half-written file,
  # which surfaces as an intermittent formatter or docs-gate failure (#2277
  # review). Compiling to `$$`-suffixed paths and `mv`-ing on success gives
  # both properties without ever unlinking a file another process may be
  # running: a success replaces the artifact atomically for everyone else, and
  # a failure retracts only the manifest, which is enough to force a rebuild.
  build_wasm_rel="$wasm_rel.$$.tmp"
  build_diag_rel="$build_wasm_rel.diag"
  build_deps_rel="$deps_rel.$$.tmp"
  # The compiler writes `<out>.funcmap` beside the wasm and the runner reads it
  # to symbolize traps, so it has to travel WITH the wasm -- publishing one and
  # leaving the other names the wrong functions in every later stack trace.
  build_funcmap_rel="$build_wasm_rel.funcmap"
  rm -f "$ROOT_DIR/$build_wasm_rel" "$ROOT_DIR/$build_diag_rel" \
        "$ROOT_DIR/$build_deps_rel" "$ROOT_DIR/$build_funcmap_rel"
  trap 'rm -f "$ROOT_DIR/$build_wasm_rel" "$ROOT_DIR/$build_diag_rel" "$ROOT_DIR/$build_deps_rel" "$ROOT_DIR/$build_funcmap_rel"' EXIT
  # `|| compile_rc=$?` is load-bearing: as a bare command under `set -e` a
  # non-zero runner abandoned the script HERE, one line above the check that
  # was written to explain the failure, so the message below never printed
  # and the cause stayed in the .diag sidecar that nothing reads (#2271).
  compile_rc=0
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
    --invoke cli_main "$seed" "$entry_src" "$build_wasm_rel" main >&2 || compile_rc=$?
  if [ "$compile_rc" != "0" ] || [ ! -s "$ROOT_DIR/$build_wasm_rel" ]; then
    echo "ensure_entry_wasm.sh: failed to compile $entry_src -> $wasm_rel" >&2
    if [ -s "$ROOT_DIR/$build_diag_rel" ]; then
      # awk, not `sed s/^/  /`: the compiler writes the sidecar with NO
      # trailing newline, so sed ran the hint below onto the same line.
      awk '{ printf "  %s\n", $0 }' "$ROOT_DIR/$build_diag_rel" >&2
    else
      echo "  the compiler wrote no diagnostics (runner exit $compile_rc)" >&2
    fi
    # The overwhelmingly common cause on a fresh checkout: the untracked
    # generated artifacts are not there yet, so the compiler package's own
    # contract has declarations with no implementation.
    echo "  if that names a generated artifact (lib/@vibe/compiler/cache/, *_bundle.vibe), run: bash scripts/ensure_generated.sh" >&2
    # Nothing published, so nothing to undo -- but whatever an earlier run left
    # behind must not go on answering. Drop the MANIFEST rather than the wasm:
    # the staleness rules read it first, so its absence forces a rebuild, and a
    # concurrent caller that is running the previous artifact this instant keeps
    # the bytes it was handed. This process failing says nothing about those.
    rm -f "$ROOT_DIR/$deps_rel"
    exit 1
  fi
  # Capture the closure the compiler just resolved. The plan mode also
  # writes one `.N.src` sidecar per module; keep them in a scratch dir so
  # only the manifest survives. Best-effort: on failure no manifest is
  # written and the next run rebuilds again rather than reusing stale.
  plan_dir="$(mktemp -d "$ROOT_DIR/_build/ensure_entry_plan.XXXXXX")"
  plan_rel="${plan_dir#"$ROOT_DIR"/}/plan.tsv"
  captured=0
  if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_MODULE_PLAN=1 \
      bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
      --invoke cli_main "$seed" "$entry_src" "$plan_rel" "__no_entry__" >&2 \
      && [ -s "$ROOT_DIR/$plan_rel" ]; then
    awk -F'\t' '$1 == "module" { print $4 }' "$ROOT_DIR/$plan_rel" > "$ROOT_DIR/$build_deps_rel"
    captured=1
  else
    echo "ensure_entry_wasm.sh: could not capture the dependency closure for $entry_src; the artifact will rebuild every run until it can" >&2
  fi
  rm -rf "$plan_dir"

  # Publish. The manifest goes away FIRST: between the two renames a concurrent
  # reader would otherwise pair the new wasm with the old closure and call it
  # fresh, where an absent manifest just makes it rebuild. Both renames are
  # within one directory, so each is atomic for everyone else.
  rm -f "$ROOT_DIR/$deps_rel"
  mv -f "$ROOT_DIR/$build_wasm_rel" "$ROOT_DIR/$wasm_rel"
  if [ -s "$ROOT_DIR/$build_funcmap_rel" ]; then
    mv -f "$ROOT_DIR/$build_funcmap_rel" "$ROOT_DIR/$wasm_rel.funcmap"
  else
    rm -f "$ROOT_DIR/$wasm_rel.funcmap"
  fi
  if [ "$captured" = "1" ]; then
    mv -f "$ROOT_DIR/$build_deps_rel" "$ROOT_DIR/$deps_rel"
  fi
fi

echo "$wasm_rel"
