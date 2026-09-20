#!/usr/bin/env bash
# An async host import this runner does not implement must FAIL, not answer 0
# (#2832 item 4 -- "no backend may silently reinterpret the same import").
#
# `scripts/wasm_vibe_host_runner.js` builds its `vibe` import object as a Proxy
# whose fallthrough answers an unknown field with `() => 0n`. Its 59 members
# include `sleep` and not one of the ADR-0089 future or stream imports, so a
# module importing `vibe.host_stream_get$body` and `vibe.host_stream_read`
# LINKED and read zeros. Measured before the guard, same source three ways:
#
#   while n < 5 { sum = sum + host_stream_next(s) }  -> prints `sum=0`, exit 0
#   for b in s { sum = sum + b }                     -> RuntimeError: unreachable
#   let mut b = ...; while 0 <= b { ... }            -> RuntimeError: unreachable
#
# The first is the one this gate exists for: a host stream that was never
# provided reads as five zero bytes and the program SUCCEEDS.
#
# So the assertion is not "the run failed". A missing capability and a silent
# zero both have to be distinguishable from the refusal, or the guard tests
# nothing, and the three rows below are exactly those three outcomes:
#
#   1. the guarded runner refuses, and the message NAMES the import
#   2. `vibe.sleep` -- implemented here -- still runs, so the guard did not
#      simply break the lane
#   3. RED: the same program against a copy of the runner with the guard branch
#      removed prints `sum=0` and exits 0, which pins the refusal to that branch
#      rather than to anything else about the program or the runner
#   4. runtime/viberun, asked the SAME question about the SAME module, refuses
#      at INSTANTIATION -- an import it does not register fails the module
#      before user code runs
#
# Row 4 is why this gate asks both runners rather than only the one that was
# wrong. The two lanes fail at different MOMENTS, and
# docs/internal/design/async-host-contract.md states that difference rather
# than averaging it; a gate that measured only the node side would let the
# document's claim about viberun go on being inherited instead of checked.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# #2252: do not inherit the variables this gate is about, nor runner flags a
# caller may have set for something else.
unset VIBE_HOST_WITHHOLD VIBE_ASYNC_FUTURES VIBE_ASYNC_STREAMS || true

# shellcheck source=scripts/resolve_stage2.sh
. scripts/resolve_stage2.sh
stage2="$(resolve_stage2 host-async-import-unsupported "${VIBE_STAGE2_WASM:-}")"

# This gate asks the question of BOTH host runners, so one runner cannot answer
# it. `ensure_viberun.sh` is content-hashed, so on a tree whose runner sources
# have not changed it is a no-op.
if [ -z "${HOST_ASYNC_IMPORT_VIBERUN:-}" ]; then
  if ! bash "$ROOT_DIR/scripts/ensure_viberun.sh" >&2; then
    echo "host-async-import-unsupported: FAIL: could not build runtime/viberun." >&2
    echo "host-async-import-unsupported: this gate asks BOTH host runners what they do with an async import they do not implement." >&2
    echo "host-async-import-unsupported: build it with: cargo build --release --manifest-path runtime/viberun/Cargo.toml" >&2
    echo "host-async-import-unsupported: or point HOST_ASYNC_IMPORT_VIBERUN at an existing binary." >&2
    exit 1
  fi
fi
viberun="${HOST_ASYNC_IMPORT_VIBERUN:-runtime/viberun/target/release/viberun}"
if [ ! -x "$viberun" ]; then
  echo "host-async-import-unsupported: FAIL: the Rust runner is missing at '$viberun'." >&2
  echo "host-async-import-unsupported: build it with: cargo build --release --manifest-path runtime/viberun/Cargo.toml" >&2
  exit 1
fi

work="$ROOT_DIR/_build/host_async_import_unsupported"
rm -rf "$work"
mkdir -p "$work"

cat > "$work/stream.vibe" <<'PROG'
fn main() -> Unit allows Stdout + Async {
  let s = host_stream_named("body")
  let mut sum = 0
  let mut n = 0
  while n < 5 {
    sum = sum + host_stream_next(s)
    n = n + 1
  }
  println("sum=" + Int::to_string(sum))
}
PROG

cat > "$work/sleep.vibe" <<'PROG'
fn main() -> Unit allows Stdout + Async {
  sleep_blocking(1)
  println("slept")
}
PROG

compile() {
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2" \
    build "$1" -o "$2" > "$work/compile.log" 2>&1 || {
      echo "host-async-import-unsupported: FAIL compiling $1" >&2
      cat "$work/compile.log" >&2
      exit 1
    }
  [ -s "$2" ] || { echo "host-async-import-unsupported: FAIL no wasm emitted for $1" >&2; exit 1; }
}

compile "$work/stream.vibe" "$work/stream.wasm"
compile "$work/sleep.vibe" "$work/sleep.wasm"

# The program must actually declare the import, or refusing it proves nothing.
node -e '
const { readFileSync } = require("node:fs");
const m = new WebAssembly.Module(readFileSync(process.argv[1]));
const names = WebAssembly.Module.imports(m)
  .filter((i) => i.module === "vibe")
  .map((i) => i.name);
const want = ["host_stream_get$body", "host_stream_read"];
for (const w of want) {
  if (!names.includes(w)) {
    console.error(`missing import vibe.${w}; got ${names.join(", ")}`);
    process.exit(1);
  }
}
' "$work/stream.wasm" || {
  echo "host-async-import-unsupported: FAIL the probe program does not import the async names" >&2
  exit 1
}

# 1. the guarded runner refuses, and names the import.
if node scripts/wasm_vibe_host_runner.js "$work/stream.wasm" > "$work/guarded.txt" 2>&1; then
  echo "host-async-import-unsupported: FAIL the runner ran a program whose host stream it does not implement" >&2
  cat "$work/guarded.txt" >&2
  exit 1
fi
grep -q 'vibe.host_stream_get\$body is not implemented by this runner' "$work/guarded.txt" || {
  echo "host-async-import-unsupported: FAIL the refusal does not name the import" >&2
  cat "$work/guarded.txt" >&2
  exit 1
}
grep -q 'viberun' "$work/guarded.txt" || {
  echo "host-async-import-unsupported: FAIL the refusal does not say where the lane that implements it is" >&2
  cat "$work/guarded.txt" >&2
  exit 1
}
echo "ok: an unimplemented async host import is refused, and the message names it"

# 2. the control: an async import this runner DOES implement still runs.
node scripts/wasm_vibe_host_runner.js "$work/sleep.wasm" > "$work/sleep.txt" 2>&1 || {
  echo "host-async-import-unsupported: FAIL vibe.sleep stopped working, so the guard is too wide" >&2
  cat "$work/sleep.txt" >&2
  exit 1
}
grep -q '^slept$' "$work/sleep.txt" || {
  echo "host-async-import-unsupported: FAIL vibe.sleep did not produce its output" >&2
  cat "$work/sleep.txt" >&2
  exit 1
}
echo "ok: vibe.sleep, which this runner does implement, still runs"

# 3. RED, by source mutation: without the guard branch the same program prints
#    `sum=0` and exits 0. A gate that cannot show the old behaviour returning is
#    a gate that would keep passing if the branch were deleted (#2248).
sed 's|        if (isUnimplementedAsyncImport(name)) {|        if (false) {|' \
  scripts/wasm_vibe_host_runner.js > "$work/runner_noguard.js"
if cmp -s scripts/wasm_vibe_host_runner.js "$work/runner_noguard.js"; then
  echo "host-async-import-unsupported: FAIL the red mutation matched nothing -- the guard moved, and this gate is asserting against a shape that no longer exists" >&2
  exit 1
fi
if ! node "$work/runner_noguard.js" "$work/stream.wasm" > "$work/red.txt" 2>&1; then
  echo "host-async-import-unsupported: FAIL without the guard the run should have SUCCEEDED (that is the behaviour being fixed); it failed instead" >&2
  cat "$work/red.txt" >&2
  exit 1
fi
grep -q '^sum=0$' "$work/red.txt" || {
  echo "host-async-import-unsupported: FAIL without the guard the program should print sum=0 -- the refusal is not pinned to the guard branch" >&2
  cat "$work/red.txt" >&2
  exit 1
}
echo "ok: removing the guard restores the silent sum=0, so the refusal is that branch"

# 4. the other runner, asked the same question about the same module: viberun's
#    core lane does not register these imports either, and there the failure is
#    at INSTANTIATION -- measured, not inherited from the design.
if "$viberun" "$work/stream.wasm" > "$work/viberun.txt" 2>&1; then
  echo "host-async-import-unsupported: FAIL viberun ran a module whose host stream imports it does not define" >&2
  cat "$work/viberun.txt" >&2
  exit 1
fi
grep -q 'has not been defined' "$work/viberun.txt" || {
  echo "host-async-import-unsupported: FAIL viberun did not refuse at instantiation; the contract's claim about this lane no longer holds" >&2
  cat "$work/viberun.txt" >&2
  exit 1
}
grep -q 'vibe::host_stream_read' "$work/viberun.txt" || {
  echo "host-async-import-unsupported: FAIL viberun's refusal does not name the import" >&2
  cat "$work/viberun.txt" >&2
  exit 1
}
# The program never ran, so its output cannot be there. Asserting the absence
# is what separates "refused before user code" from "ran and then failed".
if grep -q '^sum=' "$work/viberun.txt"; then
  echo "host-async-import-unsupported: FAIL viberun produced the program's output, so it did not refuse before user code ran" >&2
  cat "$work/viberun.txt" >&2
  exit 1
fi
echo "ok: viberun refuses the same module at instantiation, naming the import"

echo "----"
echo "host-async-import-unsupported: ok"
