#!/usr/bin/env bash
# #2758: the two host runners must agree about what `Fs::remove` MEANS.
#
# They did not. One declared builtin had two implementations:
#
#   scripts/wasm_vibe_host_runner.js   rmSync(path, {recursive:true, force:true})
#   runtime/viberun/src/main.rs        fs::remove_file(path)
#
# so a program clearing a path that happened to name a directory destroyed a
# tree under `vibe test` and trapped under `vibe run`. Nothing checked it.
# `fixtures/gc_host_builtins.vibe` pins linear-vs-gc agreement for exactly this
# class of bug and says why -- "agreement alone passes when BOTH lanes break the
# same way", so it pins the value too. There was no equivalent for JS-vs-Rust,
# and this is it.
#
# The property, three programs, each run under BOTH runners:
#
#   remove_file   Fs::remove on a FILE      -> gone under both
#   remove_dir    Fs::remove on a DIRECTORY -> FAILS under both, tree SURVIVES
#   remove_tree   Fs::remove_tree on a tree -> gone under both
#
# The middle one is the regression. Restore the JS runner's `rmSync` and it
# reports "gone" on JS and "failed" on Rust, which is what this refuses.
#
# WHICH COMPILER: passed in, never guessed (AGENTS.md "Which compiler answered?").
# WHICH RUNNERS: both required. This gate's whole subject is the two disagreeing,
# so a missing runner is UNCHECKED, not "safe" -- it fails and says how to fix it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# resolve_stage2.sh defines a FUNCTION; it is sourced, not executed. Running it
# as a script defines the function in a subshell and exits 0 with no output,
# which reads as "resolved to the empty string" -- measured, that is exactly how
# this gate first failed under the self-test ratchet.
. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2 host-remove-parity "${HOST_REMOVE_PARITY_STAGE2:-}")"
if [ ! -f "$STAGE2" ]; then
  echo "host-remove-parity: FAIL: no stage2. Pass HOST_REMOVE_PARITY_STAGE2=<stage2.wasm>." >&2
  exit 1
fi

VIBERUN="${HOST_REMOVE_PARITY_VIBERUN:-runtime/viberun/target/release/viberun}"
if [ ! -x "$VIBERUN" ]; then
  echo "host-remove-parity: FAIL: the Rust runner is missing at '$VIBERUN'." >&2
  echo "host-remove-parity: this gate compares the TWO host runners, so one runner cannot answer it." >&2
  echo "host-remove-parity: build it with: cargo build --release --manifest-path runtime/viberun/Cargo.toml" >&2
  echo "host-remove-parity: or point HOST_REMOVE_PARITY_VIBERUN at an existing binary." >&2
  exit 1
fi

WORK="${HOST_REMOVE_PARITY_WORK:-_build/_gate_host_remove_parity}"
rm -rf "$WORK"; mkdir -p "$WORK"

# Each probe prints one token. The token is the OBSERVATION, not a pass/fail, so
# the two runners are compared on what they saw rather than on whether each
# independently liked it.
emit_probe() { # <name> <body-expr>
  cat > "$WORK/$1.vibe" <<VIBE
export let main = () -> Int with Fs {
$2
}
VIBE
}

# 1. Fs::remove on a FILE: both runners must remove it.
emit_probe remove_file '  Fs::write_file("'"$WORK"'/f1", "z")
  Fs::remove("'"$WORK"'/f1")
  if Fs::exists("'"$WORK"'/f1") {
    1
  } else {
    0
  }'

# 2. Fs::remove on a DIRECTORY: neither runner may remove it. This is #2758.
#    The probe never reports "gone" itself -- it is expected to FAIL, and the
#    surviving directory is checked from the shell afterwards, because a runner
#    that aborts prints nothing a guest expression could have returned.
emit_probe remove_dir '  Fs::remove("'"$WORK"'/d1")
  0'

# 3. Fs::remove_tree on a populated tree: both runners must remove it whole.
emit_probe remove_tree '  Fs::remove_tree("'"$WORK"'/d2")
  if Fs::is_dir("'"$WORK"'/d2") {
    1
  } else {
    0
  }'

for probe in remove_file remove_dir remove_tree; do
  env -u VIBE_FS_COMPILE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    "$WORK/$probe.vibe" "$WORK/$probe.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$WORK/$probe.wasm" ]; then
    echo "host-remove-parity: FAIL: '$probe' did not compile with $STAGE2." >&2
    if [ "$probe" = "remove_tree" ]; then
      echo "host-remove-parity: if the diagnostic names Fs::remove_tree, that compiler predates #2758 --" >&2
      echo "host-remove-parity: build one from this checkout, or pass HOST_REMOVE_PARITY_STAGE2." >&2
    fi
    cat "$WORK/$probe.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
done

# Rebuild the directory fixtures before EACH runner, so the second runner is not
# handed a tree the first one already removed -- that would let a recursive
# Fs::remove pass on whichever runner happened to go second.
seed_dirs() {
  rm -rf "$WORK/d1" "$WORK/d2"
  mkdir -p "$WORK/d1/nested" "$WORK/d2/nested"
  printf 'keep\n' > "$WORK/d1/nested/inside"
  printf 'gone\n' > "$WORK/d2/nested/inside"
}

# <runner-label> <probe> -> "<exit-ok>:<stdout-tail>:<d1-survived>:<d2-survived>"
observe() {
  local label="$1" probe="$2" rc=0 out=""
  seed_dirs
  case "$label" in
    js)
      if [ -n "${HOST_REMOVE_PARITY_JS_RUNNER:-}" ]; then
        # Self-test hook only: run a MUTATED copy of the JS runner, so the
        # red test can prove this gate detects a real divergence rather than
        # trusting that it would.
        out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" node --experimental-wasm-exnref --stack-size=131072 \
          "$HOST_REMOVE_PARITY_JS_RUNNER" "$WORK/$probe.wasm" 2>/dev/null | tail -1)" || rc=$?
      else
        out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh "$WORK/$probe.wasm" 2>/dev/null | tail -1)" || rc=$?
      fi
      ;;
    rust) out="$("$VIBERUN" "$WORK/$probe.wasm" 2>/dev/null | tail -1)" || rc=$? ;;
  esac
  local ok="ok"; [ "$rc" -eq 0 ] || ok="failed"
  local d1="absent"; [ -e "$WORK/d1" ] && d1="present"
  local d2="absent"; [ -e "$WORK/d2" ] && d2="present"
  printf '%s:%s:%s:%s' "$ok" "$out" "$d1" "$d2"
}

status=0
for probe in remove_file remove_dir remove_tree; do
  js="$(observe js "$probe")"
  rust="$(observe rust "$probe")"
  if [ "$js" != "$rust" ]; then
    echo "host-remove-parity: FAIL: '$probe' -- the two runners disagree." >&2
    echo "host-remove-parity:   js   = $js" >&2
    echo "host-remove-parity:   rust = $rust" >&2
    echo "host-remove-parity:   (fields: exit:stdout:d1-after:d2-after)" >&2
    status=1
    continue
  fi
  # Agreement alone is not enough -- both could break the same way, which is the
  # exact hole gc_host_builtins.vibe documents. Pin the VALUE too.
  want=""
  case "$probe" in
    remove_file) want="ok:0:present:present" ;;
    remove_dir)  want="failed::present:present" ;;
    remove_tree) want="ok:0:present:absent" ;;
  esac
  if [ "$js" != "$want" ]; then
    echo "host-remove-parity: FAIL: '$probe' agreed but on the wrong answer: got '$js', want '$want'." >&2
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  exit 1
fi
echo "host-remove-parity: ok (3 probes x 2 runners; Fs::remove is non-recursive on both, Fs::remove_tree is recursive on both)"
