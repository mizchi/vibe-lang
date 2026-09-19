#!/usr/bin/env bash
# ADR-0088's L1 + L3, end to end (#2828, ADR-0088 Remaining/#2332).
#
# `preflight_instantiate` raised its message from the day it was written and
# was reachable from NOTHING but its unit test -- measured, zero production
# callers, and `--allow-*` existed only as the text inside that message. So the
# property this gate holds is not "the function is correct" (the unit tests in
# checker_entry_effect_test.vibe do that); it is that a RUN reaches it.
#
# Five cases, and the first is the one that matters most: with no flag the
# answer must be exactly what it was before the ladder was connected, or every
# existing program's authority changed silently.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=scripts/resolve_stage2.sh
. "$(dirname "$0")/resolve_stage2.sh"
# STRICT, and reading the lane's own export. The degrading resolver was the
# first version of this line and it cost a CI cycle: with no generation on the
# runner it settled for something else entirely, every one of the six cases
# failed with a wasm trap, and the gate reported them as PROPERTY failures
# ("--allow-nope must be refused") about a compiler that could not run a
# program at all. A gate that cannot say which compiler answered should refuse,
# not degrade (AGENTS.md, "A MEASUREMENT has no honest fallback").
STAGE2="$(resolve_stage2_strict capability-preflight "${CAPABILITY_PREFLIGHT_STAGE2:-${VIBE_STAGE2_WASM:-}}")" || exit 1

# The runner is part of the environment this gate assumes, so it is checked
# rather than assumed (#2252). Built if missing, the way the neighbouring
# capability gate does, and named if it cannot be.
VIBERUN="${CAPABILITY_PREFLIGHT_VIBERUN:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
if [ ! -x "$VIBERUN" ]; then
  if ! bash "$ROOT_DIR/scripts/ensure_viberun.sh" >&2; then
    echo "capability-preflight: FAIL: could not build runtime/viberun." >&2
    echo "  build it with: cargo build --release --manifest-path runtime/viberun/Cargo.toml" >&2
    exit 1
  fi
fi
if [ ! -x "$VIBERUN" ]; then
  echo "capability-preflight: FAIL: the Rust runner is missing at '$VIBERUN'." >&2
  exit 1
fi

WORK="$ROOT_DIR/_build/_capability_preflight"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

PROG="$WORK/prog.vibex"
cat > "$PROG" <<'VIBE'
fn main() -> Unit allows Stdout + Fs::read_file {
  println("ok")
}
VIBE

pass=0; fail=0
ok()  { echo "capability-preflight: ok: $1"; pass=$((pass + 1)); }
bad() { echo "capability-preflight: FAIL: $1" >&2; fail=$((fail + 1)); }

# Each case runs the launcher with the resolved compiler and captures both
# streams; `run` exits non-zero on a refusal, so `|| true` keeps `set -e` from
# ending the gate at the first case that is SUPPOSED to fail.
run_case() {
  VIBE_CLI_WASM="$STAGE2" VIBE_RUNNER="$VIBERUN" \
    bash "$ROOT_DIR/runtime/vibe" run "$@" "$PROG" 2>&1 || true
}

# CONTROL, before any assertion. If the toolchain cannot run a program that
# needs no capability at all, then nothing below is a statement about the
# preflight -- it is a statement about the environment, and reporting it as six
# property failures is how a gate lies about its subject. Measured: this is
# exactly what happened on the first CI run of this gate.
CONTROL="$WORK/control.vibex"
cat > "$CONTROL" <<'VIBE'
fn main() -> Unit allows Stdout {
  println("control")
}
VIBE
control_out="$(VIBE_CLI_WASM="$STAGE2" VIBE_RUNNER="$VIBERUN" \
  bash "$ROOT_DIR/runtime/vibe" run "$CONTROL" 2>&1 || true)"
if ! printf '%s\n' "$control_out" | grep -q '^control$'; then
  echo "capability-preflight: FAIL: the toolchain cannot run a capability-free program," >&2
  echo "  so this gate can say nothing about the preflight. Compiler: $STAGE2" >&2
  echo "  runner: $VIBERUN" >&2
  printf '%s\n' "$control_out" | sed 's/^/  /' >&2
  exit 1
fi

# 1. No flag: unchanged. A program that ran before must still run.
out="$(run_case)"
if printf '%s\n' "$out" | grep -q '^ok$'; then
  ok "no capability flag leaves the run exactly as it was"
else
  bad "an unflagged run must be unchanged; got: $out"
fi

# 2. A denied REQUIRED capability aborts, and the message names the edit --
#    both of them: the flag that grants it and the optional spelling.
out="$(run_case --deny-fs)"
if printf '%s\n' "$out" | grep -q 'not granted' \
   && printf '%s\n' "$out" | grep -q -- '--allow-fs' \
   && printf '%s\n' "$out" | grep -q 'allows Fs::read_file?'; then
  ok "a denied required capability aborts, naming both edits"
else
  bad "--deny-fs must abort naming --allow-fs and the optional spelling; got: $out"
fi

# 3. An allow-list that covers the entry's row still runs.
out="$(run_case --allow-fs --allow-stdout)"
if printf '%s\n' "$out" | grep -q '^ok$'; then
  ok "an allow-list covering the row runs"
else
  bad "--allow-fs --allow-stdout must run; got: $out"
fi

# 4. An allow-list is a LIST: naming one capability does not grant the others.
out="$(run_case --allow-stdout)"
if printf '%s\n' "$out" | grep -q 'not granted'; then
  ok "an allow-list that omits a required capability aborts"
else
  bad "--allow-stdout alone must abort on Fs::read_file; got: $out"
fi

# 5. Deny beats allow. Fail-closed is the only safe direction for this table,
#    and it is the one rule in the ladder that no document records -- so it is
#    pinned HERE rather than left to whoever reads the code next.
out="$(run_case --allow-fs --deny-fs)"
if printf '%s\n' "$out" | grep -q 'not granted'; then
  ok "--deny-* beats --allow-* for the same provider"
else
  bad "deny must beat allow; got: $out"
fi

# 6. A flag that is not a capability is refused rather than ignored: silently
#    accepting `--allow-nope` would read as a grant that was never made.
out="$(run_case --allow-nope)"
if printf '%s\n' "$out" | grep -q 'not a capability'; then
  ok "a non-capability --allow-* is refused, naming the providers"
else
  bad "--allow-nope must be refused; got: $out"
fi

# 7-10. ADR-0088 L2 (#2828 rung 2): the grants must actually REACH the
#       optional-capability lowering, not merely travel beside it.
#
#       This case exists because of a measured near-miss. The grant table was
#       threaded through all nine hops from the CLI to the lowering, every hop
#       type-checked, the build was clean, the control program ran -- and every
#       `perform?` still answered `NotGranted`, because
#       `optional_perform_artifact_resolution` has TWO call sites and the
#       non-split one still passed `array_empty()`. A single-file `vibe run`
#       takes exactly that fallback. Nothing but RUNNING a `perform?` program
#       distinguishes "wired" from "wired and read", which is why the property
#       here is an ANSWER and not the presence of a call.
OPT="$WORK/opt.vibex"
DATA="$WORK/data.txt"
printf 'hello-from-file\n' > "$DATA"
cat > "$OPT" <<VIBE
fn main() -> Unit allows Stdout + Fs::read_file? {
  let a = perform? Fs::read_file("$DATA")
  match a {
    Granted(v) => println("GRANTED:" + v),
    Errored(_) => println("ERRORED"),
    NotGranted => println("NOTGRANTED")
  }
}
VIBE

opt_case() {
  VIBE_CLI_WASM="$STAGE2" VIBE_RUNNER="$VIBERUN" \
    bash "$ROOT_DIR/runtime/vibe" run "$@" "$OPT" 2>&1 || true
}

out="$(opt_case --allow-fs --allow-stdout)"
if printf '%s\n' "$out" | grep -q '^GRANTED:hello-from-file$'; then
  ok "a granted provider resolves perform? to Granted and the call runs"
else
  bad "--allow-fs must make perform? Fs::read_file Granted; got: $out"
  # WHICH COMPILER ANSWERED (AGENTS.md). This case failed once on CI while
  # passing locally on a stage2 built the same way, and the message above could
  # not tell the two apart: it reports the ANSWER and not the artifact that
  # produced it, so there was nothing to diagnose from the log.
  #
  # The no-flag probe is the decisive one. With rung 2 present a run with no
  # capability flag has ambient authority and answers `GRANTED`; without it,
  # `optional_perform_artifact_resolution` still receives an empty table and
  # every arm answers `NotGranted`. So NOTGRANTED here means the compiler does
  # not carry rung 2 at all, and GRANTED means it does and the FLAG path is
  # what broke -- two different bugs that look identical above.
  {
    echo "capability-preflight: diagnosis for the failure above:"
    echo "  compiler: $STAGE2"
    if [ -f "$STAGE2" ]; then
      echo "  size:     $(wc -c < "$STAGE2") bytes"
      echo "  mtime:    $(date -r "$STAGE2" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
    else
      echo "  size:     MISSING"
    fi
    echo "  runner:   $VIBERUN"
    echo "  no-flag perform? answer: $(opt_case --allow-stdout --allow-fs 2>&1 | tr '\n' ' ')"
    echo "  ambient (no flags at all): $(opt_case 2>&1 | tr '\n' ' ')"
    echo "  -> ambient NOTGRANTED means this compiler does not carry #2828 rung 2;"
    echo "     ambient GRANTED means it does and the --allow-fs path is the bug."
  } >&2
fi

out="$(opt_case --deny-fs --allow-stdout)"
if printf '%s\n' "$out" | grep -q '^NOTGRANTED$'; then
  ok "a denied provider resolves perform? to NotGranted"
else
  bad "--deny-fs must make perform? NotGranted; got: $out"
fi

# An allow-list is a list here too: Stdout alone does not grant Fs.
out="$(opt_case --allow-stdout)"
if printf '%s\n' "$out" | grep -q '^NOTGRANTED$'; then
  ok "an allow-list omitting the provider leaves perform? NotGranted"
else
  bad "--allow-stdout alone must leave perform? NotGranted; got: $out"
fi

# Deny beats allow for the optional surface too, not just the required one.
out="$(opt_case --allow-fs --deny-fs --allow-stdout)"
if printf '%s\n' "$out" | grep -q '^NOTGRANTED$'; then
  ok "--deny-* beats --allow-* for perform? as well"
else
  bad "deny must beat allow for perform?; got: $out"
fi

echo "capability-preflight: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
