#!/usr/bin/env bash
# Red self-test for scripts/prelude_reuse_oracle.mjs (#2248, #4043).
#
# 1. The real compiler, unmutated, on the edits section: the oracle must pass.
# 2. The real compiler behind a wrapper that perturbs ONE thing, and the oracle
#    must fail with the assertion that owns it:
#    - a stored record whose replayed statement is corrupted (a string literal
#      rewritten in place, so the record still decodes): in the verify cache
#      the verify build must refuse it; in the on cache the module must differ
#      from the reuse-off one;
#    - one byte of a reuse-on module flipped;
#    - every record deleted before the on build, so nothing replays (the
#      vacuity check);
#    - the `; verified` note dropped from the verify trace.
# 3. Scripted, for the commits section (the real one builds the CLI closure of
#    several trees, which is the gate's job, not this test's): the wrapper
#    fakes each tree's build. Faked green passes; a verify failure, a HEAD
#    tree that does not build, HEAD edits that do not replay, and too few
#    trees built are each refused.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/resolve_stage2.sh"

# The oracle drops every VIBE_* variable from its children; these are the ones
# this test reads itself, so none may arrive from the caller (#2252).
unset PRELUDE_REUSE_ORACLE_RUNNER PRELUDE_REUSE_ORACLE_SECTIONS PRELUDE_REUSE_ORACLE_COMMITS \
  PRELUDE_REUSE_ORACLE_KEEP PRELUDE_REUSE_ORACLE_ACTION PRELUDE_REUSE_ORACLE_REAL_RUNNER \
  PRELUDE_REUSE_ORACLE_GIT_ROOT PRELUDE_REUSE_ORACLE_GIT_ROOT_OVERRIDE

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0
ORACLE="$ROOT_DIR/scripts/prelude_reuse_oracle.mjs"
REAL_RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"

# Strict: the real cases need a compiler with verify mode, so a fallback to
# the newest generation on disk or the seed would fail for the wrong reason.
STAGE2="$(resolve_stage2_strict prelude-reuse-oracle-test "${PRELUDE_REUSE_ORACLE_STAGE2:-${VIBE_STAGE2_WASM:-}}")" || {
  echo "FAIL no compiler to run the real cases against" >&2; exit 1; }

# The faked commits run against a scratch repository of three commits, so the
# test needs neither this checkout's history (CI checks out one commit) nor
# its tree's size.
FAKE_GIT="$WORK/fake-git"
mkdir -p "$FAKE_GIT/lib/@vibe/core"
git -C "$FAKE_GIT" init -q
for i in 1 2 3; do
  printf 'fn hex_probe() -> Int {\n  %s\n}\n' "$i" > "$FAKE_GIT/lib/@vibe/core/hex.vibe"
  git -C "$FAKE_GIT" add -A
  git -C "$FAKE_GIT" -c user.name=oracle -c user.email=oracle@localhost commit -q -m "fake $i"
done
case "$STAGE2" in /*) STAGE2_ABS="$STAGE2" ;; *) STAGE2_ABS="$ROOT_DIR/$STAGE2" ;; esac

# The wrapper: a build is `--invoke cli_main STAGE2 ENTRY OUT FN`, an
# execution `--invoke main WASM`. PRELUDE_REUSE_ORACLE_ACTION picks the
# perturbation; the step is read off OUT (`<step>-<mode>.wasm`).
cat > "$WORK/wrap.sh" <<'WRAP'
#!/usr/bin/env bash
set -uo pipefail
action="${PRELUDE_REUSE_ORACLE_ACTION:-none}"
real="${PRELUDE_REUSE_ORACLE_REAL_RUNNER:?}"
records() { grep -rl "vibe-prelude-reuse-v3" "$VIBE_BUILD_CACHE_DIR" 2>/dev/null; }
if [ "${2:-}" != "cli_main" ]; then exec bash "$real" "$@"; fi
# The header-cache warm-up before a faked CLI build: nothing to cache.
if [ "${VIBE_DEPS:-}" = 1 ]; then exit 0; fi
entry="$4"; out="$5"; base="$(basename "$out" .wasm)"
case "$entry" in
  lib/@vibe/cli/entry.vibe)
    # Faked commits: one module per tree, one trace line per build.
    tree="$(basename "$(dirname "$out")")"
    case "$action" in
      fake-verify-fails)
        if [ "$tree" = tree-1 ]; then
          echo "prelude-reuse: replayed; VERIFY FAILED: statement 3" >> "$VIBE_PRELUDE_REUSE_TRACE"
          echo "VIBE_PRELUDE_REUSE=verify: the replayed prelude differs from the effect passes' output" >&2
          exit 1
        fi ;;
      fake-head-fails)
        if [ "$tree" = tree-2 ]; then echo "error: does not build" >&2; exit 1; fi ;;
      fake-old-fail)
        if [ "$tree" != tree-2 ]; then echo "error: does not build" >&2; exit 1; fi ;;
    esac
    # HEAD's tree edited by the oracle replays, unless the action says not.
    if head -n 1 lib/@vibe/core/hex.vibe | grep -qF "an edit that only moves offsets" \
      && [ "$action" != fake-no-head-replay ]; then
      echo "prelude-reuse: replayed; recorded; verified" >> "$VIBE_PRELUDE_REUSE_TRACE"
    else
      echo "prelude-reuse: missed: no record; recorded" >> "$VIBE_PRELUDE_REUSE_TRACE"
    fi
    printf 'fake module %s\n' "$tree" > "$out"
    exit 0 ;;
esac
case "$action:$base" in
  corrupt-verify:*-verify|corrupt-on:*-on)
    case "$base" in cold-*) ;; *)
      for f in $(records); do
        python3 -c 'import sys; p=sys.argv[1]; b=open(p,"rb").read(); open(p,"wb").write(b.replace(b"qq", b"qz"))' "$f"
      done ;;
    esac ;;
  no-replay:*-on)
    for f in $(records); do rm -f "$f"; done ;;
esac
bash "$real" "$@"; status=$?
case "$action:$base" in
  flip:pure-body-on)
    python3 -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[len(b)//2]^=1; open(p,"wb").write(bytes(b))' "$out" ;;
  drop-verified:*-verify)
    python3 -c 'import sys; p=sys.argv[1]; t=open(p).read(); open(p,"w").write(t.replace("; verified\n", "\n"))' "$VIBE_PRELUDE_REUSE_TRACE" ;;
esac
exit $status
WRAP

# run_oracle SECTIONS [ENV=VALUE...] -> exit code; output in $WORK/out
run_oracle() {
  local sections="$1"
  shift
  env "$@" PRELUDE_REUSE_ORACLE_SECTIONS="$sections" PRELUDE_REUSE_ORACLE_RUNNER="$WORK/wrap.sh" \
    PRELUDE_REUSE_ORACLE_REAL_RUNNER="$REAL_RUNNER" PRELUDE_REUSE_ORACLE_GIT_ROOT="${PRELUDE_REUSE_ORACLE_GIT_ROOT_OVERRIDE:-$FAKE_GIT}" \
    node "$ORACLE" "$STAGE2_ABS" >"$WORK/out" 2>&1
}

pass_case() { # label sections [env...]
  local label="$1"; shift
  if run_oracle "$@"; then
    echo "ok   $label"
  else
    echo "FAIL $label: expected the oracle to pass"; tail -n 8 "$WORK/out"; fails=$((fails + 1))
  fi
}

fail_case() { # label expected-substring sections [env...]
  local label="$1" expected="$2"; shift 2
  if run_oracle "$@"; then
    echo "FAIL $label: expected the oracle to fail"; tail -n 8 "$WORK/out"; fails=$((fails + 1))
  elif ! grep -qF -- "$expected" "$WORK/out"; then
    echo "FAIL $label: the oracle failed, but not with: $expected"; tail -n 8 "$WORK/out"; fails=$((fails + 1))
  else
    echo "ok   $label"
  fi
}

pass_case "the real compiler passes the edits corpus" edits
fail_case "a corrupted record in the verify cache is refused by the verify build" \
  "differs from the effect passes' output" edits PRELUDE_REUSE_ORACLE_ACTION=corrupt-verify
fail_case "a corrupted record in the on cache makes the module differ" \
  "pure-body: the reuse-on module differs from a reuse-off compile" edits PRELUDE_REUSE_ORACLE_ACTION=corrupt-on
fail_case "a flipped byte in a reuse-on module is refused" \
  "pure-body: the reuse-on module differs from a reuse-off compile" edits PRELUDE_REUSE_ORACLE_ACTION=flip
fail_case "a corpus where nothing replays is refused as vacuous" \
  "pure-body: reuse did not replay" edits PRELUDE_REUSE_ORACLE_ACTION=no-replay
fail_case "a verify build that does not say verified is refused" \
  "pure-body: the verify build did not replay and verify" edits PRELUDE_REUSE_ORACLE_ACTION=drop-verified

pass_case "faked commits pass" commits PRELUDE_REUSE_ORACLE_ACTION=none
# A one-commit clone, as CI checks out: the oracle deepens it itself.
git clone -q --depth 1 "file://$FAKE_GIT" "$WORK/shallow-git"
PRELUDE_REUSE_ORACLE_GIT_ROOT_OVERRIDE="$WORK/shallow-git" \
  pass_case "a shallow checkout is deepened" commits PRELUDE_REUSE_ORACLE_ACTION=none
if [ "$(git -C "$WORK/shallow-git" rev-list --count HEAD)" -lt 3 ]; then
  echo "FAIL the shallow checkout passed without being deepened"; fails=$((fails + 1))
fi
fail_case "a verify failure on a commit is refused" \
  "VERIFY FAILED" commits PRELUDE_REUSE_ORACLE_ACTION=fake-verify-fails
fail_case "a HEAD tree that does not build is refused" \
  "(HEAD) did not build" commits PRELUDE_REUSE_ORACLE_ACTION=fake-head-fails
fail_case "HEAD edits that do not replay are refused as vacuous" \
  "HEAD + comment: the build did not replay and verify" commits PRELUDE_REUSE_ORACLE_ACTION=fake-no-head-replay
fail_case "one tree built is refused as vacuous" \
  "only 1 tree(s) built" commits PRELUDE_REUSE_ORACLE_ACTION=fake-old-fail
fail_case "fewer than two commits is refused" \
  "must be an integer >= 2" commits PRELUDE_REUSE_ORACLE_COMMITS=1

if [ "$fails" -eq 0 ]; then
  echo "prelude-reuse-oracle self-test: ok (real green + real and scripted reds, against $STAGE2)"
else
  echo "prelude-reuse-oracle self-test: $fails case(s) failed" >&2
  exit 1
fi
