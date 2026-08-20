#!/usr/bin/env bash
# Which backend is the linear default, asked of the COMPILER rather than of a
# document.
#
# Three places recorded an answer and they disagreed: AGENTS.md called RC "the
# production default", ADR-0055 recorded cutover readiness as READY, and
# docs/spec/rc-cutover-readiness.md still said "NOT READY … **Do not flip the
# default until the real corpus reaches parity**". A reader could take any of
# the three. Nothing checked which was true, so nothing corrected the two that
# were not.
#
# The compiler answers it in one line: compile the same source with `VIBE_RC`
# unset, with `VIBE_RC=1`, and with `VIBE_RC=0`, and see which artifact the
# default matches. That is a fact about the build, so the document is now
# downstream of it.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

STAGE2="${RC_DEFAULT_STAGE2:-}"
if [ -n "$STAGE2" ]; then
  [ -f "$STAGE2" ] || { echo "rc-default: RC_DEFAULT_STAGE2=$STAGE2 does not exist" >&2; exit 1; }
else
  for gen in $(ls -td _build/selfhost/generations/*/ 2>/dev/null); do
    [ -s "${gen}stage2.wasm" ] && { STAGE2="${gen}stage2.wasm"; break; }
  done
  [ -n "${STAGE2:-}" ] || STAGE2="bootstrap/seed/compiler.wasm"
  [ -s "$STAGE2" ] || { echo "rc-default: no compiler available" >&2; exit 1; }
fi

WORK="$ROOT_DIR/_build/_rc_default"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Allocating, so the comparison has something to distinguish. The guard below
# is DEFENSIVE rather than verified: I could not construct a program where the
# two lanes emit the same module -- even `fn main() -> Int { 1 + 1 }` differs,
# because the RC lane carries its own runtime scaffolding. So the guard has
# never fired; it is there so that if the lanes ever do converge, this gate
# says so instead of reporting a default it can no longer see.
cat > "$WORK/probe.vibe" <<'VIBE'
fn main() -> Int {
  let xs = [1, 2, 3]
  let ys = [Array::length(xs), 4]
  Array::length(ys) + Array::length(xs)
}
VIBE

build() { # build <label> <VIBE_RC value or empty>
  local out="$WORK/$1.wasm"
  rm -f "$out" "$out.diag"
  env ${2:+VIBE_RC=$2} VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    "$WORK/probe.vibe" "$out" main >/dev/null 2>&1 || true
  [ -s "$out" ] || { echo "rc-default: FAIL: the probe did not compile with VIBE_RC=${2:-<unset>}" >&2; exit 1; }
}

build default ""
build rc1 "1"
build rc0 "0"

if cmp -s "$WORK/rc1.wasm" "$WORK/rc0.wasm"; then
  echo "rc-default: FAIL: VIBE_RC=1 and VIBE_RC=0 produced identical modules, so this" >&2
  echo "  probe cannot tell the lanes apart and proves nothing. Make it allocate." >&2
  exit 1
fi

if cmp -s "$WORK/default.wasm" "$WORK/rc1.wasm"; then
  actual="RC"
elif cmp -s "$WORK/default.wasm" "$WORK/rc0.wasm"; then
  actual="bump"
else
  echo "rc-default: FAIL: the default matches neither VIBE_RC=1 nor VIBE_RC=0" >&2
  exit 1
fi

DOC="docs/spec/rc-cutover-readiness.md"
if [ "$actual" = "RC" ]; then
  if grep -qi "NOT READY for cutover\|Do not flip the default" "$DOC"; then
    echo "rc-default: FAIL: the compiler's linear default IS RC, but $DOC still tells" >&2
    echo "  the reader not to flip it. Rewrite that status to the current state (#2138)." >&2
    exit 1
  fi
else
  if ! grep -qi "NOT READY for cutover\|Do not flip the default" "$DOC"; then
    echo "rc-default: FAIL: the compiler's linear default is BUMP, but $DOC reads as though" >&2
    echo "  the cutover happened. One of the two moved; make them agree." >&2
    exit 1
  fi
fi

echo "rc-default: ok (the compiler's linear default is $actual, and $DOC says so)"
