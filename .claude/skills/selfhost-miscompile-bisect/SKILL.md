---
name: selfhost-miscompile-bisect
description: How to find a miscompile when the compiler built by one backend (gc/linear/RC) misbehaves, by appending probe entries to the bundle and bisecting phases. Use it when the compiler's self-compile hangs, emits a wrong diagnostic, or produces output that differs from the linear lane's.
---

# selfhost miscompile bisect — find a backend bug by running the compiler itself

When the compiler built by backend X (the wasm-gc lane, for example; "the
X-compiled compiler" below) misbehaves (a hang, a wrong diagnostic, a differing
output), the cause is almost certainly a **miscompile** in backend X, because
the compiler's source is proven on the linear lane. The steps below narrow it
down to which language construct breaks, and how. #538 P4.5 (the gc lane
reaching the self-compile fixpoint) found seven miscompiles in a row this way.

## Artifacts and commands

```bash
# 1. Build the linear CLI with the fix (stage2e): regenerate the flat module source
#    (lib/@vibe/compiler/_cli_adapter_module_source.vibe; a ~1s no-op when current),
#    then compile it with the stage2 built from this checkout
bash scripts/ensure_generated.sh
STAGE2="$(bash scripts/generations.sh out-dir)/stage2.wasm"
env VIBE_RC=0 VIBE_PREOPEN_DIR="$PWD" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
  lib/@vibe/compiler/_cli_adapter_module_source.vibe _build/gc538/stage2e.wasm cli_main

# 2. Compile the bundle with backend X using stage2e (gives the X-compiled compiler)
env VIBE_BACKEND=gc VIBE_RC=0 VIBE_PREOPEN_DIR="$PWD" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main _build/gc538/stage2e.wasm \
  lib/@vibe/compiler/_cli_adapter_module_source.vibe _build/gc538/bundle_gc.wasm cli_main

# 3. Run the X-compiled compiler (entry _start; argv arrives through the "vibe" host import)
env VIBE_RC=0 VIBE_PREOPEN_DIR="$PWD" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke _start _build/gc538/bundle_gc.wasm \
  <input.vibe> <out.wasm> main
```

The standing end-to-end measurement is
`bash scripts/test_gc_selfbuild.sh _build/gc538/stage2e.wasm` (probes, bundle
compile, run E2E, self-compile fixpoint).

## Steps

### 1. Classify the symptom

- No output file, but a `<out>.diag` → a wrong diagnostic (typically a
  miscompiled comparison in the checker or effect code).
- No output, no diag, CPU at 100% → a **hang** (typically a worklist that never
  pops, or a comparison that is always true or always false). Run it under
  `timeout N` and `time` and look at user time, to tell a busy loop from an I/O
  wait.
- Output that differs from the linear lane's under `cmp` → list the differing
  bytes with `cmp -l`. **The fewer bytes differ, the more they tell you** (for
  example, only the top two bytes of an f64 constant being 0 means float
  literals are being zeroed).

### 2. Bisect the phases — append a probe entry to the bundle

The flat bundle has a flat namespace, so appending a zero-argument entry at the
end lets you **call any internal function**. Copy the bundle to a scratch
directory, append the probe, and pass the probe's name as `entry_name`:

```vibe
// Appended to the end of a copy of the bundle (never committed)
export let probe_check: () -> Int with Exception = () -> {
  let stmts = parse_program(lex("export let main = () -> Int { 40 + 2 }"))
  expand_interp_stmts(stmts)
  let _ = check_program(stmts)
  1
}
```

```bash
env VIBE_BACKEND=gc VIBE_RC=0 ... --invoke cli_main _build/gc538/stage2e.wasm \
  $SCRATCH/bundle_probe.vibe $SCRATCH/bp.probe_check.wasm probe_check
timeout 60 env ... --invoke _start $SCRATCH/bp.probe_check.wasm
```

Write probes in the order lex → parse → interp → check → codegen and find the
first stage that breaks. Then dig probes into that stage (for `check_program`:
`check_stmts`, `check_program_bounds`, `collect_async_effect_errors`, ...).
**One bundle compile takes about a minute**, so fold several checks into one
probe function, either by encoding them in the return value
(`a * 1000 + b * 100 + ...`) or by writing a dump with `Fs::write_file`.

### 3. Reduce to a standalone probe

Once a suspicious construct shows up, turn it into a single-file probe that
needs no bundle, then **compile and run it on both gc and linear and compare**
(tens of seconds):

```bash
for BE in gc ""; do env ${BE:+VIBE_BACKEND=$BE} VIBE_RC=0 ... --invoke cli_main \
  _build/gc538/stage2e.wasm probe.vibe probe.$BE.wasm main; done
wasmtime run -W gc=y,function-references=y,exceptions=y probe.gc.wasm   # the gc side
env VIBE_PREOPEN_DIR="$PWD" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start probe.lin.wasm
```

A difference is a minimal reproduction. Cut it down from there to a single
construct. For a hang, adding a guard counter
(`while cond && guard < 100`) and reading how many iterations ran is the fast
way to see it.

### 4. Read the emitted wasm directly

```bash
wasm-tools print out.wasm | less        # the call/drop sequence shows a stub or a missing call at a glance
```

A rough map from function index to source: imports (0..hbo) → generated
builtins (hbo+1..hbo+num_generated) → user functions (from
func_offset = 1 + hbo + num_generated, in the bundle's SLet-EFn order). A
trap's `wasm-function[N]` translates to a source function through this map.

### 5. Fix → fixpoint verification loop

After every fix: regenerate the bundle → rebuild stage2e → recompile
bundle_gc → a tiny E2E (its output matches the linear lane's under `cmp`) →
self-compile (bundle_gc compiles the bundle itself, compared with stage2e by
`cmp`). **Byte-identical = fixpoint** is the final pass. The gates are
`bash scripts/test_gc_selfbuild.sh` and `bash scripts/compiler_gate.sh`.

## Pitfalls (all hit in practice)

- **Do not use `print()` inside a probe**: on the gc lane, print goes through
  `__to_string`, and passing it a String prints the packed pointer as a number
  (that was itself a #538 bug, and after the fix the behavior still differs by
  type). Return an encoded number or use `Fs::write_file`.
- **Always pin VIBE_RC=0**: a stage built with RC returns RC-tagged results and
  they get misread.
- **Suspect a miscompile first when it "hangs"**: in #538, what looked like a
  stack overflow from deep recursion was really an abnormal path taken because
  an equality was always false. Whether raising `--stack-size` changes the
  behavior separates legitimate deep recursion from a cycle.
- **A diagnostic reading "expected X, got X"**: when the two sides print the
  same, the printing function (`type_to_string` and the like) is hitting the
  same miscompile. Suspect what comparison and printing share (that time, a
  for-in comprehension).
- **Do not trust the runner's exit code**: `rc=$?` across a pipe is the tail's.
  Judge by whether the output file exists and by the `.diag`.
