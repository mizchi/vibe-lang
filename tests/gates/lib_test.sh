#!/usr/bin/env bash
# Self-test for the helpers in tests/gates/lib.sh.
#
# `gate_split_cli_cache_is_current` decides WHICH compiler the #2305 lane
# questions. It got one because the thing it replaced -- "reuse whatever is at
# _build/bench/selfhost_cli_core/index_stage1.wasm" -- produced a false RED
# twice in one session on a reused workspace, and the same mechanism produces
# a false GREEN just as easily.
set -euo pipefail

GATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "$GATES_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_gates_lib_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
ok()  { echo "ok: $1"; passed=$((passed + 1)); }
bad() { echo "FAIL: $1" >&2; failed=$((failed + 1)); }

# Two distinct "stage2" artifacts. Content, not names: the helper compares
# bytes, so the test must too.
printf 'stage2-A' > "$WORK/a.wasm"
printf 'stage2-B' > "$WORK/b.wasm"

fresh_cache() {
  rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"
  printf 'cli' > "$WORK/cache/index_stage1.wasm"
  cp "$1" "$WORK/cache/base_stage2.wasm"
}

# 1. built from THIS stage2 -> reuse, and the cache survives.
fresh_cache "$WORK/a.wasm"
if gate_split_cli_cache_is_current "$WORK/cache" "$WORK/a.wasm"; then
  if [ -s "$WORK/cache/index_stage1.wasm" ]; then
    ok "a cache built from this stage2 is reused"
  else
    bad "answered current but removed the cache"
  fi
else
  bad "a cache built from this stage2 was rejected"
fi

# 2. built from a DIFFERENT stage2 -> refuse, and the cache is GONE. Removing
#    it is the half that matters: a caller that ignores the status still
#    cannot reuse a mismatched artifact.
fresh_cache "$WORK/b.wasm"
if gate_split_cli_cache_is_current "$WORK/cache" "$WORK/a.wasm"; then
  bad "a cache built from another stage2 was accepted"
elif [ -e "$WORK/cache" ]; then
  bad "rejected a mismatched cache but left it in place"
else
  ok "a cache built from another stage2 is rejected AND removed"
fi

# 3. same SIZE, different bytes. Size and mtime are the proxies this helper
#    exists to avoid; without a content compare this case passes wrongly.
fresh_cache "$WORK/a.wasm"
printf 'stage2-C' > "$WORK/c.wasm"
if [ "$(wc -c < "$WORK/a.wasm")" != "$(wc -c < "$WORK/c.wasm")" ]; then
  bad "the same-size case is not set up: a and c differ in length"
elif gate_split_cli_cache_is_current "$WORK/cache" "$WORK/c.wasm"; then
  bad "a same-size, different-content stage2 was accepted"
else
  ok "identity is content, not size"
fi

# 4. no provenance record at all (what every pre-existing cache looks like)
#    -> refuse. Otherwise the first run after this lands trusts a directory
#    whose origin nobody knows.
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"
printf 'cli' > "$WORK/cache/index_stage1.wasm"
if gate_split_cli_cache_is_current "$WORK/cache" "$WORK/a.wasm"; then
  bad "a cache with no provenance record was accepted"
else
  ok "a cache with no provenance record is rejected"
fi

# 5. a missing stage2 -> refuse rather than treat absence as a match.
fresh_cache "$WORK/a.wasm"
if gate_split_cli_cache_is_current "$WORK/cache" "$WORK/nonexistent.wasm"; then
  bad "a missing stage2 was treated as a match"
else
  ok "a missing stage2 is rejected"
fi

# Selection runs in an isolated real git checkout. Its build stand-ins copy
# source bytes through the generated flat input, so reusing either a stale
# generation or a stale fallback produces the wrong artifact, not just a
# missing marker. No fake generation enters the working checkout.
selection_repo="$WORK/selection"
mkdir -p "$selection_repo/scripts" "$selection_repo/lib/@vibe/compiler"
git -C "$selection_repo" init --quiet
git -C "$selection_repo" config user.name vibe
git -C "$selection_repo" config user.email vibe@example.invalid
printf 'current source A' > "$selection_repo/source.vibe"
git -C "$selection_repo" add source.vibe
git -C "$selection_repo" commit --quiet -m init
cp "$ROOT_DIR/scripts/run_bounded.sh" "$ROOT_DIR/scripts/resolve_stage2.sh" "$selection_repo/scripts/"
cat > "$selection_repo/scripts/ensure_generated.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
[ ! -f fail-freshen ] || exit 8
cp source.vibe lib/@vibe/compiler/_cli_adapter_module_source.vibe
EOF
cat > "$selection_repo/scripts/generations.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$*" = 'build --out-dir _build/_gate_lane_gen' ]
[ "$VIBE_PREBUILT_MODULE_SOURCE" = 'lib/@vibe/compiler/_cli_adapter_module_source.vibe' ]
[ ! -f fail-build ] || exit 7
mkdir -p _build/_gate_lane_gen
if [ -f empty-build ]; then : > _build/_gate_lane_gen/stage2.wasm; exit 0; fi
cp "$VIBE_PREBUILT_MODULE_SOURCE" _build/_gate_lane_gen/stage2.wasm
printf 'build\n' >> builds
EOF
selection_sha="$(git -C "$selection_repo" rev-parse --short HEAD)"
head_gen="$selection_repo/_build/selfhost/generations/seed_$selection_sha"
stale_gen="$selection_repo/_build/selfhost/generations/seed_deadbee"
mkdir -p "$head_gen" "$stale_gen"
printf 'current HEAD compiler' > "$head_gen/stage2.wasm"
printf 'stale compiler' > "$stale_gen/stage2.wasm"
touch -t 203001010000 "$stale_gen"
[ "$stale_gen" -nt "$head_gen" ] || { echo 'FAIL: newer stale-generation mutation did not land' >&2; exit 1; }
select_compiler() {
  ROOT_DIR="$selection_repo" SCRIPT_DIR="$selection_repo/scripts" VIBE_STAGE2_WASM="${1:-}" \
    bash -c '. "$1"; gate_resolve_stage2; [ "$stage2_wasm" = "$VIBE_STAGE2_WASM" ] || exit 91; cat "$stage2_wasm"' \
    _ "$GATES_DIR/lib.sh"
}
if [ "$(select_compiler)" = 'current HEAD compiler' ]; then
  ok "HEAD's generation wins over a newer stale generation and is exported"
else
  bad "a newer stale generation hijacks the compiler selection"
fi
printf 'explicit compiler' > "$WORK/explicit.wasm"
if [ "$(select_compiler "$WORK/explicit.wasm")" = 'explicit compiler' ]; then
  ok "an explicit compiler wins over the HEAD generation and is exported"
else
  bad "an explicit compiler was ignored"
fi
if select_compiler "$WORK/missing.wasm" > "$WORK/missing.out" 2>&1; then
  bad "a missing explicit compiler silently falls back"
else
  ok "a missing explicit compiler is refused"
fi
rm -rf "$head_gen"
mkdir -p "$selection_repo/_build/_gate_lane_gen"
printf 'stale fallback' > "$selection_repo/_build/_gate_lane_gen/stage2.wasm"
if select_compiler > "$WORK/build.out" && cmp -s "$selection_repo/source.vibe" "$selection_repo/_build/_gate_lane_gen/stage2.wasm"; then
  ok "without HEAD's generation, current sources build instead of reusing stale artifacts"
else
  bad "a stale generation or fallback was reused instead of building current sources"
fi
rm -rf "$stale_gen"
printf 'current source B' > "$selection_repo/source.vibe"
if select_compiler > "$WORK/rebuild.out" && cmp -s "$selection_repo/source.vibe" "$selection_repo/_build/_gate_lane_gen/stage2.wasm" && [ "$(wc -l < "$selection_repo/builds" | tr -d ' ')" = 2 ]; then
  ok "a later invocation rebuilds an unproven fallback from changed sources"
else
  bad "an existing fallback masks changed sources"
fi
printf 'current source C' > "$selection_repo/source.vibe"
: > "$selection_repo/fail-build"
if select_compiler > "$WORK/failed-build.out" 2>&1; then
  bad "a failed build returns the old fallback artifact"
else
  ok "a failed build refuses even when an old fallback remains"
fi
rm "$selection_repo/fail-build"
printf 'current source D' > "$selection_repo/source.vibe"
: > "$selection_repo/fail-freshen"
if select_compiler > "$WORK/failed-freshen.out" 2>&1; then
  bad "failed source regeneration still builds from stale flat input"
else
  ok "failed source regeneration is refused"
fi
rm "$selection_repo/fail-freshen"
: > "$selection_repo/empty-build"
if select_compiler > "$WORK/empty-build.out" 2>&1; then
  bad "a successful build can return an empty artifact"
else
  ok "an empty build product is refused"
fi

# --- gate_require_artifact (#3671) ---------------------------------------------
#
# It exits, so each case runs in a subshell and the case reads its status.

# 5. a non-empty artifact passes, silently.
printf 'wasm' > "$WORK/ok.wasm"
if (gate_require_artifact "$WORK/ok.wasm" "should not fire") >"$WORK/req.out" 2>&1 && [ ! -s "$WORK/req.out" ]; then
  ok "gate_require_artifact passes a non-empty artifact"
else
  bad "gate_require_artifact rejected a non-empty artifact: $(cat "$WORK/req.out")"
fi

# 6. a missing artifact fails with the message AND the compiler's diagnostic.
rm -f "$WORK/none.wasm"
printf 'error: unknown name: frobnicate\n' > "$WORK/none.wasm.diag"
if (gate_require_artifact "$WORK/none.wasm" "the probe did not compile") >"$WORK/req.out" 2>&1; then
  bad "gate_require_artifact passed a missing artifact"
elif grep -qF "[compiler-gate] FAIL: the probe did not compile" "$WORK/req.out" \
  && grep -qF "unknown name: frobnicate" "$WORK/req.out"; then
  ok "gate_require_artifact fails a missing artifact with the message and the .diag"
else
  bad "gate_require_artifact failed without the message or the .diag: $(cat "$WORK/req.out")"
fi

# 7. an EMPTY artifact is a failure too: a zero-byte module is not a module.
: > "$WORK/empty.wasm"
if (gate_require_artifact "$WORK/empty.wasm" "empty") >/dev/null 2>&1; then
  bad "gate_require_artifact passed an empty artifact"
else
  ok "gate_require_artifact fails an empty artifact"
fi

# --- gate_fs_compile (#3671) -------------------------------------------------
#
# 8. a compile that fails leaves NO artifact behind, even when an earlier run
# left one at the same path -- otherwise gate_require_artifact would pass on
# the stale module. A compiler that does not exist is the failing compile.
printf 'stale' > "$WORK/stale.wasm"
printf 'stale diag' > "$WORK/stale.wasm.diag"
printf 'let x = 1\n' > "$WORK/src.vibe"
if ( stage2_wasm="$WORK/no_such_stage2.wasm"; gate_fs_compile "$WORK/src.vibe" "$WORK/stale.wasm" main ); then
  if [ ! -e "$WORK/stale.wasm" ] && [ ! -e "$WORK/stale.wasm.diag" ]; then
    ok "gate_fs_compile removes a stale artifact and never aborts"
  else
    bad "gate_fs_compile left the stale artifact or its .diag in place"
  fi
else
  bad "gate_fs_compile aborted on a failing compile; the caller's check would never run"
fi

# --- gate_require_refused / gate_require_diag_has / _matches (#3671) ----------

# 9. a refusal: no artifact passes, an artifact fails with the message.
rm -f "$WORK/refused.wasm"
if (gate_require_refused "$WORK/refused.wasm" "should not fire") >/dev/null 2>&1; then
  ok "gate_require_refused passes when nothing was written"
else
  bad "gate_require_refused failed although nothing was written"
fi
printf 'wasm' > "$WORK/refused.wasm"
if (gate_require_refused "$WORK/refused.wasm" "the bad program compiled") >"$WORK/req.out" 2>&1; then
  bad "gate_require_refused passed a written artifact"
elif grep -qF "[compiler-gate] FAIL: the bad program compiled" "$WORK/req.out"; then
  ok "gate_require_refused fails a written artifact with the message"
else
  bad "gate_require_refused failed without the message: $(cat "$WORK/req.out")"
fi

# 10. the diagnostic's MESSAGE: present passes, absent fails and shows the file.
printf 'error: binding type mismatch for x: expected Int, got String\n' > "$WORK/m.diag"
if (gate_require_diag_has "$WORK/m.diag" "expected Int, got String" "x") >/dev/null 2>&1; then
  ok "gate_require_diag_has passes when the text is there"
else
  bad "gate_require_diag_has failed although the text is there"
fi
if (gate_require_diag_has "$WORK/m.diag" "unknown name" "the refusal gave the wrong error") >"$WORK/req.out" 2>&1; then
  bad "gate_require_diag_has passed text that is not there"
elif grep -qF "the refusal gave the wrong error" "$WORK/req.out" && grep -qF "binding type mismatch" "$WORK/req.out"; then
  ok "gate_require_diag_has fails absent text with the message and the diagnostic"
else
  bad "gate_require_diag_has failed without the message or the diagnostic: $(cat "$WORK/req.out")"
fi
# A fixed string is fixed: `.` is not a wildcard there, and is one for _matches.
if (gate_require_diag_has "$WORK/m.diag" "expected.Int" "x") >/dev/null 2>&1; then
  bad "gate_require_diag_has read its text as a pattern"
elif (gate_require_diag_matches "$WORK/m.diag" "expected.Int" "x") >/dev/null 2>&1; then
  ok "gate_require_diag_has is a fixed string and gate_require_diag_matches a pattern"
else
  bad "gate_require_diag_matches did not match a basic regular expression"
fi
# A missing diagnostic file is a failure, not a silent pass.
if (gate_require_diag_matches "$WORK/no_such.diag" "x" "no diag") >/dev/null 2>&1; then
  bad "gate_require_diag_matches passed a missing diagnostic"
else
  ok "gate_require_diag_matches fails a missing diagnostic"
fi

# --- gate_fs_compile_on / gate_flat_compile (#3671) --------------------------

# 11. every lane of the matrix removes a stale artifact and never aborts, like
# gate_fs_compile; the flat compile does too.
for lane in bump linear rc shadow gc; do
  printf 'stale' > "$WORK/lane.wasm"; printf 'stale' > "$WORK/lane.wasm.diag"
  if ( stage2_wasm="$WORK/no_such_stage2.wasm"; gate_fs_compile_on "$lane" "$WORK/src.vibe" "$WORK/lane.wasm" main ) \
    && [ ! -e "$WORK/lane.wasm" ] && [ ! -e "$WORK/lane.wasm.diag" ]; then
    ok "gate_fs_compile_on $lane removes a stale artifact and never aborts"
  else
    bad "gate_fs_compile_on $lane aborted or left a stale artifact"
  fi
done
printf 'stale' > "$WORK/flat.wasm"
if ( stage2_wasm="$WORK/no_such_stage2.wasm"; gate_flat_compile "$WORK/src.vibe" "$WORK/flat.wasm" main ) && [ ! -e "$WORK/flat.wasm" ]; then
  ok "gate_flat_compile removes a stale artifact and never aborts"
else
  bad "gate_flat_compile aborted or left a stale artifact"
fi

# 12. a lane the matrix does not know FAILS, rather than compiling nothing --
# which a refusal check would read as the refusal it wanted.
if ( stage2_wasm="$WORK/no_such_stage2.wasm"; gate_fs_compile_on rcx "$WORK/src.vibe" "$WORK/lane.wasm" main ) >"$WORK/req.out" 2>&1; then
  bad "gate_fs_compile_on accepted an unknown lane"
elif grep -qF "unknown lane 'rcx'" "$WORK/req.out"; then
  ok "gate_fs_compile_on fails an unknown lane by name"
else
  bad "gate_fs_compile_on failed an unknown lane without naming it: $(cat "$WORK/req.out")"
fi

# --- gate_run / gate_require_eq (#3671) --------------------------------------
# gate_host_run is the harness's one process launch; each case below replaces
# it in a subshell with a fake runner, so no compiler or module is needed.
fake_runner() { # <status>: print a fixed transcript, then exit <status>
  printf 'a\n12x-3\n'
  printf 'trap: oops\n' >&2
  return "$1"
}
mkdir -p "$WORK/tmp"

# 13. each shape reduces the transcript the way the inline spelling did.
for case_ in "last|trap: oops" "stdout-last|12x-3" "digits|123" "int|12-3"; do
  shape="${case_%%|*}"; want="${case_#*|}"
  got="$( gate_host_run() { fake_runner 0; }; TMPDIR="$WORK/tmp"; gate_run v "$shape" m.wasm; printf '%s' "$v" )" || got="<aborted>"
  if [ "$got" = "$want" ]; then
    ok "gate_run $shape reads '$want'"
  else
    bad "gate_run $shape read '$got' (want '$want')"
  fi
done
if [ -z "$(ls -A "$WORK/tmp")" ]; then
  ok "gate_run leaves no temporary file behind"
else
  bad "gate_run left temporary files: $(ls -A "$WORK/tmp")"
fi

# 14. a run that exits non-zero FAILS, naming the module -- even when what it
# printed is the expected answer, as under the lanes' `set -euo pipefail`.
if ( gate_host_run() { fake_runner 3; }; TMPDIR="$WORK/tmp"; gate_run v stdout-last --invoke main m.wasm; gate_require_eq "$v" "12x-3" "unreached" ) >"$WORK/req.out" 2>&1; then
  bad "gate_run accepted a run that exited 3"
elif grep -qF "running --invoke main m.wasm exited 3" "$WORK/req.out" && grep -qF "trap: oops" "$WORK/req.out"; then
  ok "gate_run fails a non-zero run by name and shows its output"
else
  bad "gate_run failed a non-zero run without naming it: $(cat "$WORK/req.out")"
fi

# 15. an unknown shape fails by name rather than assigning nothing.
if ( gate_host_run() { fake_runner 0; }; gate_run v tail m.wasm ) >"$WORK/req.out" 2>&1; then
  bad "gate_run accepted an unknown shape"
elif grep -qF "unknown shape 'tail'" "$WORK/req.out"; then
  ok "gate_run fails an unknown shape by name"
else
  bad "gate_run failed an unknown shape without naming it: $(cat "$WORK/req.out")"
fi

# 16. gate_require_eq passes an exact match and fails anything else with the
# lane's message -- a prefix and the empty string included.
if ( gate_require_eq "42" "42" "unreached" ) >"$WORK/req.out" 2>&1; then
  ok "gate_require_eq passes an exact match"
else
  bad "gate_require_eq failed an exact match: $(cat "$WORK/req.out")"
fi
for got_ in "4" "420" ""; do
  if ( gate_require_eq "$got_" "42" "got '$got_' (want 42)" ) >"$WORK/req.out" 2>&1; then
    bad "gate_require_eq accepted '$got_' for 42"
  elif grep -qF "[compiler-gate] FAIL: got '$got_' (want 42)" "$WORK/req.out"; then
    ok "gate_require_eq fails '$got_' for 42 with the lane's message"
  else
    bad "gate_require_eq failed '$got_' without the lane's message: $(cat "$WORK/req.out")"
  fi
done

# --- gate_workdir (#3671) ------------------------------------------------------
# 17. it empties an existing directory and names it.
wd_path="_build/_gate_lib_test_workdir.$$"
mkdir -p "$wd_path/stale"; printf 'old' > "$wd_path/stale/f"
if ( gate_workdir wd "$wd_path"; [ "$wd" = "$wd_path" ] && [ -d "$wd" ] && [ -z "$(ls -A "$wd")" ] ) >"$WORK/req.out" 2>&1; then
  ok "gate_workdir empties the directory and assigns its path"
else
  bad "gate_workdir did not leave an empty, named directory: $(cat "$WORK/req.out")"
fi
rm -rf "$wd_path"

# 18. it refuses, without deleting anything, a path it must not rm -rf.
mkdir -p "$WORK/keep"; printf 'x' > "$WORK/keep/f"
for wd_bad in "$WORK/keep" "" "_build" "_build/" "_build/../tests" "lib/@vibe" ".vibe"; do
  if ( gate_workdir wd "$wd_bad" ) >"$WORK/req.out" 2>&1; then
    bad "gate_workdir accepted '$wd_bad'"
  elif grep -qF "gate_workdir: '$wd_bad'" "$WORK/req.out"; then
    ok "gate_workdir refuses '$wd_bad' by name"
  else
    bad "gate_workdir refused '$wd_bad' without naming it: $(cat "$WORK/req.out")"
  fi
done
if [ -s "$WORK/keep/f" ] && [ -d tests ] && [ -d lib/@vibe ]; then
  ok "a refused path is left in place"
else
  bad "gate_workdir deleted a path it refused"
fi

echo "----"
echo "passed: $passed, failed: $failed"
[ "$failed" -eq 0 ]
