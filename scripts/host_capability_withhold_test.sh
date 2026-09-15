#!/usr/bin/env bash
# A host must be able to withhold a capability: link something of the right
# type so the module instantiates, and TRAP if the program calls it
# (docs/internal/design/capability-host-contract.md, #2825 step 1).
#
# Before this, `scripts/wasm_vibe_host_runner.js` could not express that. Its
# `vibe` import module is a Proxy whose `get` answers an unknown field with
# `() => 0n`, so removing a method did not withhold the capability -- it made
# the capability answer zero. Measured, same program both ways:
#
#   strict host, capability absent   -> LinkError, the program does not run
#   this runner, capability absent   -> runs; Fs::read_file answers 0
#
# So the assertion below is not "the run failed". It is "the run failed HERE,
# with this message, after instantiating" -- a link failure and a silent zero
# both have to be distinguishable from the withheld stub, or the switch tests
# nothing.
#
# Red case: the same program, run against a copy of the runner with the
# withhold branch removed. It must SUCCEED and print the file's contents,
# which is what proves the trap in the green case comes from that branch and
# not from something else about the run.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# #2252: a self-test must not inherit the variable it is testing, nor the
# runner flags a caller may have set for something else.
unset VIBE_HOST_WITHHOLD VIBE_NODE_EXTRA_FLAGS VIBE_FORCE_RUN_INIT

# shellcheck source=scripts/resolve_stage2.sh
. scripts/resolve_stage2.sh
# A CHECK, not a measurement: the property under test belongs to the runner,
# not to the compiler, so the lenient resolver (down to the committed seed) is
# the right one -- the program below compiles identically on any of them.
stage2="$(resolve_stage2 host-capability-withhold "${VIBE_STAGE2_WASM:-}")"

work="_build/host_capability_withhold"
mutated="scripts/wasm_vibe_host_runner.withhold.redtest.js"
cleanup() { rm -rf "$work" "$mutated"; }
trap cleanup EXIT
rm -rf "$work"
mkdir -p "$work"

printf 'apple\n' > "$work/secret.txt"
cat > "$work/withhold.vibex" <<'PROG'
fn main allows Fs + Stdout {
  let text = Fs::read_file("_build/host_capability_withhold/secret.txt")
  println("read: \{text}")
}
PROG

VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2" \
  "$work/withhold.vibex" "$work/withhold.wasm" main > "$work/compile.log" 2>&1 || {
    echo "host-capability-withhold: FAIL compiling the probe program" >&2
    cat "$work/compile.log" >&2
    exit 1
  }
[ -s "$work/withhold.wasm" ] || { echo "host-capability-withhold: FAIL no wasm emitted" >&2; exit 1; }

# The program must actually declare the import, or withholding it proves
# nothing. `vibe deps`-style assumptions are not enough here: read the module.
node scripts/host_capability_probe.mjs "$work/withhold.wasm" > "$work/probe.txt" 2>&1 || {
  echo "host-capability-withhold: FAIL the probe could not read the module" >&2
  cat "$work/probe.txt" >&2
  exit 1
}
grep -q '^fs_read_file' "$work/probe.txt" || {
  echo "host-capability-withhold: FAIL the probe program does not import vibe.fs_read_file" >&2
  cat "$work/probe.txt" >&2
  exit 1
}

run_probe() { # <runner-invocation...> ; writes $work/run.out, returns the rc
  set +e
  VIBE_PREOPEN_DIR="$ROOT_DIR" "$@" > "$work/run.out" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

# 1. Granted: the capability is provided, the program reads the file.
if ! run_probe bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$work/withhold.wasm"; then
  echo "host-capability-withhold: FAIL the granted run did not succeed" >&2
  cat "$work/run.out" >&2
  exit 1
fi
grep -q '^read: apple$' "$work/run.out" || {
  echo "host-capability-withhold: FAIL the granted run did not read the file" >&2
  cat "$work/run.out" >&2
  exit 1
}

# 2. Withheld: the module still instantiates, and the call traps by name.
if run_probe env VIBE_HOST_WITHHOLD=fs_read_file bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$work/withhold.wasm"; then
  echo "host-capability-withhold: FAIL the withheld run succeeded" >&2
  cat "$work/run.out" >&2
  exit 1
fi
grep -q 'vibe capability withheld: fs_read_file' "$work/run.out" || {
  echo "host-capability-withhold: FAIL the withheld run did not trap by name" >&2
  cat "$work/run.out" >&2
  exit 1
}
# A withheld capability must not be reachable as a VALUE. `read: 0` is what the
# old `() => 0n` fallback produced and is the failure this whole contract is
# about; assert its absence separately so a future change that reintroduces it
# cannot pass by also happening to print the message somewhere.
if grep -q '^read: ' "$work/run.out"; then
  echo "host-capability-withhold: FAIL the withheld capability still answered" >&2
  cat "$work/run.out" >&2
  exit 1
fi

# 3. Red: without the withhold branch, the SAME invocation must succeed.
python3 - "$mutated" <<'PY'
import pathlib
import sys

source = pathlib.Path("scripts/wasm_vibe_host_runner.js").read_text()
branch = """        if (withheldCapabilities.has(name)) {
          return capabilityWithheldStub(name);
        }
"""
if source.count(branch) != 1:
    sys.exit(f"red-test mutation did not match exactly once (matched {source.count(branch)})")
pathlib.Path(sys.argv[1]).write_text(source.replace(branch, "", 1))
PY

if ! run_probe env VIBE_HOST_WITHHOLD=fs_read_file node "$mutated" --invoke main "$work/withhold.wasm"; then
  echo "host-capability-withhold: FAIL red case -- removing the withhold branch should have let the run succeed" >&2
  cat "$work/run.out" >&2
  exit 1
fi
grep -q '^read: apple$' "$work/run.out" || {
  echo "host-capability-withhold: FAIL red case -- the mutated runner did not read the file" >&2
  cat "$work/run.out" >&2
  exit 1
}

echo "host-capability-withhold: ok (granted reads; withheld traps by name; red case without the branch reads)"
