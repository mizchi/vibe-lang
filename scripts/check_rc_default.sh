#!/usr/bin/env bash
# Which backend is the linear default, asked of the COMPILER rather than of a
# document.
#
# Three places recorded an answer and they disagreed: AGENTS.md called RC "the
# production default", ADR-0055 recorded cutover readiness as READY, and
# docs/spec/rc-cutover-readiness.md told the reader to hold the cutover. A
# reader could take any of the three. Nothing checked which was true, so
# nothing corrected the two that were not.
#
# The compiler answers it in one line: compile the same source with `VIBE_RC`
# unset, with `VIBE_RC=1`, and with `VIBE_RC=0`, and see which artifact the
# default matches. That is a fact about the build, so the document is now
# downstream of it.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

. "$(dirname "$0")/resolve_stage2.sh"
STAGE2="$(resolve_stage2 rc-default "${RC_DEFAULT_STAGE2:-}")" || exit 1

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

# The "unset" build must be genuinely unset. Adding no assignment is not the
# same thing: a caller who exports VIBE_RC -- `VIBE_RC=0 pkf run release-check`
# does exactly that -- would have the probe inherit it, match the bump artifact,
# and report a default the compiler does not have. `env -u` removes it.
build() { # build <label> <VIBE_RC value or empty>
  local out="$WORK/$1.wasm"
  local -a rc_env
  if [ -n "$2" ]; then rc_env=(VIBE_RC="$2"); else rc_env=(-u VIBE_RC); fi
  rm -f "$out" "$out.diag"
  env "${rc_env[@]}" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
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

# The document states its answer ONCE, in a line this gate parses. The first
# version of this check searched instead for two literal phrases from the
# pre-cutover text and passed as long as neither appeared -- which a document
# can satisfy while still telling the reader, in other words and in other
# sections, the opposite of what the compiler does. That is what happened: a
# current-state header sat on top of sections that still described the default
# as bump and concluded the cutover "must wait", and this gate called it
# agreement. Absence of a phrase is not a claim; the line below is.
DOC="docs/spec/rc-cutover-readiness.md"
documented="$(sed -n 's/^linear-default:[[:space:]]*\([A-Za-z]*\)[[:space:]]*$/\1/p' "$DOC")"
case "$(printf '%s\n' "$documented" | wc -l | tr -d ' ')" in
  1) ;;
  *) documented="" ;;   # zero or several -- neither is a single answer
esac

if [ -z "$documented" ]; then
  echo "rc-default: FAIL: $DOC must carry exactly one line spelled" >&2
  echo "  'linear-default: RC' or 'linear-default: bump'. That line is what this gate" >&2
  echo "  compares against the compiler; without it the document states no answer." >&2
  exit 1
fi

if [ "$documented" != "$actual" ]; then
  echo "rc-default: FAIL: the compiler's linear default is $actual, but $DOC says" >&2
  echo "  'linear-default: $documented'. One of the two moved; make them agree." >&2
  echo "  If the compiler moved, the document's prose has to move with the line --" >&2
  echo "  editing only the line reinstates exactly the drift this gate exists to catch." >&2
  exit 1
fi

echo "rc-default: ok (the compiler's linear default is $actual, and $DOC says so)"
