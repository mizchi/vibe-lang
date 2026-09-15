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
# Both runners are covered, because they failed the same question in opposite
# directions: the node runner could not refuse, and viberun could not do
# anything BUT refuse (an import it does not register makes the whole module
# fail to instantiate, before user code runs).
#
# How each one is proven able to fail differs, and the difference is stated
# rather than papered over:
#
#   node    -- the env-var control PLUS a source mutation: the same run against
#              a copy of the runner with the withhold branch removed must
#              succeed, which pins the trap to that branch.
#   viberun -- the env-var control only. Rebuilding the Rust runner per case
#              costs ~80s, so the counterfactual here is the same binary and
#              the same wasm with only VIBE_HOST_WITHHOLD differing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# #2252: a self-test must not inherit the variable it is testing, nor the
# runner flags a caller may have set for something else.
#
# RUST_BACKTRACE / VIBE_RUNNER_BACKTRACE are here because inheriting them once
# already made this gate pass for the wrong reason. viberun renders a guest
# error Display-only unless one of them is set, and wasmtime wraps a host
# function's error as "error while executing at wasm backtrace: ..." -- so the
# capability's name lived in the cause chain, which only the debug rendering
# printed. This dev container exports RUST_BACKTRACE=1; CI does not. The gate
# was green locally and red in CI on the same commit, and the difference was
# the environment rather than the code. Unset, this asserts what a plain user
# actually sees.
unset VIBE_HOST_WITHHOLD VIBE_NODE_EXTRA_FLAGS VIBE_FORCE_RUN_INIT
unset RUST_BACKTRACE VIBE_RUNNER_BACKTRACE

# shellcheck source=scripts/resolve_stage2.sh
. scripts/resolve_stage2.sh
# Strict, even though this is a check rather than a measurement (AGENTS.md
# reserves the strict resolver for measurements, on the grounds that a check is
# usually better run against something than not run). The reasoning does not
# reach here: this case compiles a program and then asserts what it IMPORTS, so
# a run against an unrelated generation certifies that the runner withholds an
# import shape the current compiler may no longer emit (Codex on #2844, P1).
# And the lenient fallback buys nothing, because every way this runs already
# has a compiler: the pkfire task carries `deps { selfhostGeneration }`, and in
# tests/gates/selftests/run.sh `gate_resolve_stage2` has exported
# VIBE_STAGE2_WASM for the whole lane before this script runs.
stage2="$(resolve_stage2_strict host-capability-withhold "${VIBE_STAGE2_WASM:-}")"

# This gate asks the question of BOTH host runners, so one runner cannot answer
# it -- the same reasoning (and the same remedy lines) as
# scripts/check_host_remove_parity.sh. `ensure_viberun.sh` is content-hashed,
# so on a tree whose runner sources have not changed it is a no-op.
if [ -z "${HOST_CAPABILITY_WITHHOLD_VIBERUN:-}" ]; then
  if ! bash "$ROOT_DIR/scripts/ensure_viberun.sh" >&2; then
    echo "host-capability-withhold: FAIL: could not build runtime/viberun." >&2
    echo "host-capability-withhold: this gate asks BOTH host runners what they do with a withheld capability." >&2
    echo "host-capability-withhold: build it with: cargo build --release --manifest-path runtime/viberun/Cargo.toml" >&2
    echo "host-capability-withhold: or point HOST_CAPABILITY_WITHHOLD_VIBERUN at an existing binary." >&2
    exit 1
  fi
fi
viberun="${HOST_CAPABILITY_WITHHOLD_VIBERUN:-runtime/viberun/target/release/viberun}"
if [ ! -x "$viberun" ]; then
  echo "host-capability-withhold: FAIL: the Rust runner is missing at '$viberun'." >&2
  echo "host-capability-withhold: this gate asks BOTH host runners what they do with a withheld capability." >&2
  echo "host-capability-withhold: build it with: cargo build --release --manifest-path runtime/viberun/Cargo.toml" >&2
  echo "host-capability-withhold: or point HOST_CAPABILITY_WITHHOLD_VIBERUN at an existing binary." >&2
  exit 1
fi

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

# 4. viberun, granted: the same wasm, the other runner, reads the file.
if ! run_probe "$viberun" "$work/withhold.wasm"; then
  echo "host-capability-withhold: FAIL viberun's granted run did not succeed" >&2
  cat "$work/run.out" >&2
  exit 1
fi
grep -q '^read: apple$' "$work/run.out" || {
  echo "host-capability-withhold: FAIL viberun's granted run did not read the file" >&2
  cat "$work/run.out" >&2
  exit 1
}

# 5. viberun, withheld: instantiates, then traps by name. Same binary and same
# wasm as case 4 -- only VIBE_HOST_WITHHOLD differs, which is this half's
# control. viberun renders a host error as an anyhow chain, so the capability
# is named under `Caused by:` rather than on the first line; assert the text,
# not its position.
if run_probe env VIBE_HOST_WITHHOLD=fs_read_file "$viberun" "$work/withhold.wasm"; then
  echo "host-capability-withhold: FAIL viberun's withheld run succeeded" >&2
  cat "$work/run.out" >&2
  exit 1
fi
grep -q 'vibe capability withheld: fs_read_file' "$work/run.out" || {
  echo "host-capability-withhold: FAIL viberun's withheld run did not trap by name" >&2
  cat "$work/run.out" >&2
  exit 1
}
# The refusal must come from the stub, not from a failure to LINK: an import
# viberun does not register makes the module fail to instantiate, which is the
# behaviour this contract replaces. A link failure never reaches a wasm frame.
grep -q 'wasm backtrace' "$work/run.out" || {
  echo "host-capability-withhold: FAIL viberun refused before running the program; the stub must link and then trap" >&2
  cat "$work/run.out" >&2
  exit 1
}
if grep -q '^read: ' "$work/run.out"; then
  echo "host-capability-withhold: FAIL viberun's withheld capability still answered" >&2
  cat "$work/run.out" >&2
  exit 1
fi

# 6. viberun's BENCH path, which renders errors separately from `run()` and so
# can lose the refusal on its own. It did: `bail!("...: {e}")` formats Display,
# which shows only wasmtime's outer "error while executing at wasm backtrace",
# and then builds a NEW error whose chain no longer carries the cause at all
# (Codex on #2844, P2). A capability whose name never reaches the person
# running the bench is a diagnostic that does not name the edit.
#
# Scope, stated because the red case measured it: viberun has TWO bench error
# sites, per-block and whole-module. Both are fixed; a `bench` block exercises
# the per-block one, which is what this case pins. Mutating the whole-module
# site left this case GREEN -- the first red attempt did exactly that and
# proved nothing until it was pointed at the site the probe reaches.
cat > "$work/bench.vibe" <<'BENCH'
bench "read_one" {
  let _ = Fs::read_file("_build/host_capability_withhold/secret.txt")
  ()
}
BENCH
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2" \
  "$work/bench.vibe" "$work/bench.wasm" __no_entry__ > "$work/bench_compile.log" 2>&1 || {
    echo "host-capability-withhold: FAIL compiling the bench probe" >&2
    cat "$work/bench_compile.log" >&2
    exit 1
  }
if run_probe env VIBE_BENCH_ITERS=2 VIBE_BENCH_WARMUP=1 VIBE_HOST_WITHHOLD=fs_read_file "$viberun" --bench "$work/bench.wasm"; then
  echo "host-capability-withhold: FAIL viberun's withheld bench succeeded" >&2
  cat "$work/run.out" >&2
  exit 1
fi
grep -q 'vibe capability withheld: fs_read_file' "$work/run.out" || {
  echo "host-capability-withhold: FAIL viberun's bench path lost the capability name" >&2
  cat "$work/run.out" >&2
  exit 1
}

echo "host-capability-withhold: ok (both runners: granted reads, withheld links then traps by name; viberun's bench path keeps the name; node red case without the branch reads)"
