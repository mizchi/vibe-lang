#!/usr/bin/env bash
# Red test for check_check_json_lane_parity.sh (#2248: a gate means nothing
# until it is known to be able to fail).
#
# Each mutation is checked for having LANDED before its verdict is believed.
#
# The mutations replace the RUNNER, not the compiler: the gate's whole input is
# what `run_wasm_vibe_host_runner.sh --invoke cli_main … check … --json` writes
# and exits with, so a stub standing in for that call reaches every assertion
# without needing a compiler that can be made to misbehave on demand.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# #2252: inherit nothing the gate reads.
unset VIBE_CHECK_JSON_PARITY_ROOT
STAGE2_OVERRIDE="${CHECK_JSON_PARITY_STAGE2:-${VIBE_STAGE2_WASM:-}}"
unset CHECK_JSON_PARITY_STAGE2

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_cjp_selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "[check-json-parity-test] FAIL: $*" >&2; exit 1; }

# GREEN control. Without it a gate failing for an unrelated reason (no
# compiler, a broken runner) would make every red case below "pass".
if ! CHECK_JSON_PARITY_STAGE2="$STAGE2_OVERRIDE" bash scripts/check_check_json_lane_parity.sh >"$WORK/out" 2>&1; then
  cat "$WORK/out" >&2
  fail "the gate does not pass unmutated; the red cases below would prove nothing"
fi

# Run the gate against a mutated COPY of itself, with the runner call replaced.
# $1 = case name, $2 = sed script rewriting the runner invocation
run_mutated() {
  local name="$1" sedexpr="$2"
  sed "$sedexpr" scripts/check_check_json_lane_parity.sh > "$WORK/$name.sh"
  cmp -s "$WORK/$name.sh" scripts/check_check_json_lane_parity.sh \
    && fail "$name mutation did not land (the copy is identical to the gate)"
  # The copy runs from $WORK, so `$(dirname "$0")/..` would resolve to /tmp.
  # VIBE_CHECK_JSON_PARITY_ROOT is the gate's override for exactly this -- the
  # same escape hatch, for the same reason, as check_lambda_bound_refusal.sh's.
  VIBE_CHECK_JSON_PARITY_ROOT="$ROOT_DIR" CHECK_JSON_PARITY_STAGE2="$STAGE2_OVERRIDE" \
    bash "$WORK/$name.sh" >"$WORK/out" 2>&1
}

# RED 1: the two lanes disagree on the diagnostics. Emit a different body when
# --single-file is among the arguments.
if run_mutated lanes_differ \
  's#VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" .*#{ case " $* " in *" --single-file "*) echo "[{\\"x\\":1}]" ;; *) echo "[]" ;; esac; } >"$out" 2>/dev/null || status=$?#'; then
  fail "RED 1: the gate passed when the two lanes emitted different JSON"
fi
grep -qF 'emitted different JSON' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 1 failed for the wrong reason"; }

# RED 2: identical bodies, but a different exit status per lane. A gate that
# only diffed stdout would pass this.
if run_mutated exit_differs \
  's#VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" .*#{ echo "[]"; case " $* " in *" --single-file "*) status=7 ;; esac; } >"$out" 2>/dev/null#'; then
  fail "RED 2: the gate passed when the lanes exited differently"
fi
grep -qF 'exit differs' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 2 failed for the wrong reason"; }

# RED 3: empty output instead of `[]`. "No diagnostics" and "this mode is not
# supported here" must not look alike.
if run_mutated not_an_array \
  's#VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" .*#: >"$out" 2>/dev/null#'; then
  fail "RED 3: the gate passed on empty output rather than a JSON array"
fi
grep -qF 'did not emit a JSON array' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 3 failed for the wrong reason"; }

# RED 4: BYTE offsets where UTF-16 code units are required. Both lanes agree,
# the body is an array, the exits match -- only the conversion is wrong, which
# is the one defect the other three cases cannot see.
if run_mutated byte_offsets \
  's#VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" .*#{ case " $* " in *multibyte*) echo "[{\\"range\\":{\\"start\\":{\\"line\\":0,\\"character\\":13},\\"end\\":{\\"line\\":0,\\"character\\":33}}}]"; status=1 ;; *mismatch*) echo "[{}]"; status=1 ;; *) echo "[]" ;; esac; } >"$out" 2>/dev/null#'; then
  fail "RED 4: the gate passed on byte offsets where UTF-16 units are required"
fi
grep -qF 'not in UTF-16 code units' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 4 failed for the wrong reason"; }

echo "[check-json-parity-test] ok (4 red cases, each mutation verified to land)"
