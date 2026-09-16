# Lazy Component Model command dispatch

`runtime/vibe` is a host loop. Argument parsing and everything that drives the
compiler live in `lib/@vibe/cli`, which means every subcommand is a call graph
inside ONE core module — the wasm the launcher hands `viberun`. Measured on
this tree (`lib/@vibe/cli/main.vibex` compiled by the committed seed):

| artifact | size |
|---|---:|
| the whole CLI as one core module | 38 MB |
| one command as a `.component.wasm` | 6–7 KB |

Every invocation pays for the 38 MB: it is read, validated and compiled before
`main` runs, whatever verb was asked for. This document describes the lane that
makes an invocation pay for the verb it used and nothing else.

## The two halves

```
runtime/vibe  (host loop)
  └─ viberun --commands <manifest> <verb> [args...]
       ├─ parse the manifest            strings only, no artifact touched
       ├─ resolve <verb> -> one path    a scan over those strings
       └─ load THAT artifact            read, compile, instantiate, call
            └─ run: func(args: string) -> string
```

The guest half is `vibe build --component`; the host half is `--commands`
(`runtime/viberun/src/commands.rs`). Neither knows how many other commands
exist: the manifest is the only thing that does, and it holds paths, not code.

### `vibe build --component` has two front doors

`runtime/vibe` talks to the compiler through POSITIONAL arguments plus a
`VIBE_*` selector, never a verb, so a verb arm alone is unreachable from the
public launcher. The flag therefore exists in two places, over one
implementation:

| entry point | reached by | lane |
|---|---|---|
| `runtime/vibe build --component` | what a user types | `VIBE_BUILD_COMPONENT=1` → `cli_adapter.vibe`'s `adapter_command_component` |
| `build --component` on the user CLI | `lib/@vibe/cli/dispatch.vibe` | `selfhost_cli_build_args` |

Both call `comp_emit_component_wasm_command`, so they cannot pick different
faces for the same module — which is the point of the split being over one
implementation rather than two.

**The compile lane is shared the same way, and had to be made so.** Each door
originally spelled its own `(entry_name, mode)` literal, and when `dce-root`
replaced `no-dce` on the adapter door the other kept `no-dce` — the same
`vibe build --component` then produced a 40 MB artifact through the user CLI
and a 2.6 MB one through the launcher. Both now read
`command_component_entry()` and `command_component_compile_mode()` from
`lib/@vibe/compiler/cli_support.vibe`, so the pair has one spelling and a
future lane change cannot land on one door only. `lib/@vibe/cli/dispatch_test.vibe`
asserts the door returns exactly that pair rather than a literal that happens
to agree today.

The first version of this lane had only the verb arm. Measured:
`vibe build --component app.vibex` printed
`compiled app.vibex -> .vibe/build/out/app.wasm` and wrote a **core module** —
the flag fell through the launcher's catch-all, which treats an unrecognized
token as the source path. That is the silently-wrong failure this project
ranks worst, and the gate missed it by invoking the CLI wasm directly instead
of the launcher. Both are fixed: the launcher now REFUSES an unknown `build`
option by name instead of swallowing it, and the gate drives the public
launcher.

## The manifest — `vibe-commands-v1`

Line-oriented TSV. Blank lines and `#` comments are skipped; the first line
that is neither must be the version header, and every line after it is
`<verb>\t<artifact-path>`. Relative paths resolve against the manifest's own
directory.

```
# toolchains/<name>/lib/commands.tsv
vibe-commands-v1
check	commands/check.component.wasm
build	commands/build.cwasm
```

Refused, all with the manifest's own `path:line` in the message: a missing
header, a row with no TAB, an empty verb or path, and a **verb listed twice** —
a duplicate would make dispatch depend on scan order, which is an answer that
is right until someone reorders the file.

A row may name a precompiled image (`.cwasm`, from
`viberun --precompile-component`) instead of a component binary, and dispatch
then skips Cranelift entirely. Which rows are precompiled is the manifest's
decision, never a freshness heuristic in the runner: picking up a sibling
`.cwasm` when it "looks newer" answers from a stale image the moment mtimes lie,
which on a CI runner they routinely do (`scripts/ensure_viberun.sh` has the
measurement).

**A `.cwasm` row needs `--trust-precompiled`.** `Component::deserialize_file`
is `unsafe`, and wasmtime's contract says why in its own words: the blob
"should not be exposed to arbitrary user input" because "arbitrary input could
trivially be used to execute arbitrary code". Its version header only makes
blobs wasmtime ITSELF produced safe to reject — it is not a provenance check on
a crafted file. A manifest is data, so letting a row select native-code loading
by file extension would make a `commands.tsv` in a cloned repository an
attacker-controlled path to code outside the sandbox: one level of indirection
beyond `viberun x.cwasm`, where the person invoking it named the path.

So the decision belongs to the invoker:

```
viberun --commands --trust-precompiled <manifest> <verb> [args...]
```

Options are read BEFORE the manifest, because everything from the verb onwards
belongs to the command — otherwise whatever supplies a command's arguments
could smuggle the flag past the invoker. Without it a `.cwasm` row is refused
by name, before the file is opened, and the message names both the flag and the
`.component.wasm` alternative.

## The component — `run: func(args: string) -> string`

A command module exports exactly one function:

```vibe
import @vibe/command { command_args, command_failed, command_ok }

export fn vibe_command(args: String) -> String with Fs {
  let argv = command_args(args)
  if Array::length(argv) < 2 {
    command_failed(2, "usage: cat <file>\n")
  } else {
    let path = Array::get(argv, 1)
    if Fs::exists(path) {
      command_ok(Fs::read_file(path))
    } else {
      command_failed(1, "cat: no such file: \{path}\n")
    }
  }
}
```

That is the exact module `scripts/test_component_lazy_dispatch_gate.sh` builds
and dispatches, so this example is checked by running it, not only by
compiling it.

`vibe build --component cat.vibe` compiles it and lifts `vibe_command` to the
component export `run`, writing `cat.component.wasm`.

**argv is joined by NUL.** NUL cannot occur in a POSIX path or in a process
argument, so the join is lossless and the split needs no escaping. `argv[0]` is
the verb, exactly where a process finds its own name. `@vibe/command`'s
`command_args` performs the split, so a command module never spells the
separator.

**The result is framed, and the frame is mandatory:**

```
vibe-command-result-v1\t<exit>\n
<everything after the first newline is stdout, verbatim>
```

`viberun` writes the payload to stdout and exits with `<exit>`. A result
without the frame is REFUSED. That is deliberate and is the one place this lane
spends a little ergonomics: with an optional frame, a command that trapped
halfway and returned a partial string would exit 0 and read as a success —
the silently-wrong failure this project ranks above crashing
(`docs/internal/project/issue-triage.md`). `@vibe/command`'s `command_ok` /
`command_result` / `command_failed` write the frame.

## Which wrap a command gets, and what it may do

`vibe build --component` reads the compiled core's own import section, never a
flag:

| the core imports | wrap | what the command may do |
|---|---|---|
| nothing from `vibe` | `comp_emit_component_wasm_string_handler` | pure function of its argv |
| anything from `vibe` | `comp_emit_component_wasm_string_handler_vfs` | + `read-file` / `exists` / `read-dir` / `stat-token` |

The vfs wrap lifts those four read operations to root-level component imports,
which `viberun` serves with the same semantics the core lane has
(`read-file`/`read-dir` fail on a missing path, `read-dir` returns the sorted
names joined by `\n`, `stat-token` is `vibe_stat_token`'s digest). Every OTHER
`vibe.*` import becomes a trap in the wrap, and the pure wrap REFUSES a
`vibe.*` import outright — so a command that grows a capability it cannot have
is caught at build time rather than at dispatch.

**"Trap" is the whole point, and it took a second wrap to get.** The vfs
componentization `vibec` uses answers four of those imports with a benign zero
instead — `env-get` with the empty string, `fs_write_file` / `fs_write_bytes`
by dropping the write, `profile-now-us` with 0. That is right for the vibec
core, whose only writer is the persistent cache, where a dropped write is a
cache miss. It is silently wrong for a command, where the write is what the
caller asked for. Measured on the permissive wrap:

```
$ viberun --commands cmds.tsv write out.txt
wrote out.txt
$ echo $?
0
$ ls out.txt
ls: cannot access 'out.txt': No such file or directory
```

`vibe build --component` therefore takes
`comp_emit_component_wasm_string_handler_vfs_trapping`, under which the same
command traps: exit 1, no output, no fabricated success. The permissive wrap
keeps its behaviour for the caller it was written for.

Reading the core rather than a flag is what keeps the two answers from
disagreeing: there is no way to ask for the pure wrap and get filesystem
access, or to declare `with Fs` and be handed the strict one.

### What a command component cannot do yet

- **Write, or reach any capability outside the four read operations.** The vfs
  wrap turns them into traps, and after `dce-root` this — not size — is what
  blocks the two real verbs measured here:
  - **`check`** builds and dispatches, and traps. `check_linked_file` reaches
    `Env::get` for its cache configuration and then writes the persistent
    header cache, and neither is one of the four reads. Its 2.6 MB component
    is a perfectly good artifact that cannot run.
  - **`fmt`** is pure in its core — `format_script` is a `String -> String`,
    and the 40 real `lib/` files it was run over through the built component
    all came back fixpoint. But `vibe fmt`'s DEFAULT mode rewrites the file in
    place, so the verb *as a user spells it* needs the write the wrap traps.
    Only `--stdout` fits today's contract.

  Two routes are open and neither is started. Widen the wrap to serve
  `env-get` and the write imports for real, with the authority decided at
  build time the way every other capability is (ADR-0075/0084). Or return a
  host-action plan as the payload and let the launcher execute it — the shape
  `runtime/vibe` already uses, though today it carries exactly one kind
  (`run-guest-profile`, via `VIBE_HOST_ACTION_OUT`), so that route is an
  expansion of the plan vocabulary and not just a new caller.
- **Stream stdout.** Output comes back as the returned string, so a long-running
  command prints nothing until it finishes.
- **`--component --minify`.** `vibe-opt` optimizes core modules; running it over
  a component binary is not the same operation. Refused by name, as are
  `--component --wit` (two different artifacts from one file) and
  `--component --entry` (a component has no command entry).
- **A `.vibex` input.** A `.vibex` is an executable root with no export surface
  (ADR-0075, #2229 — the loader rejects every export in one), so it can never
  carry the `export fn vibe_command` a command component is made of. Refused at
  argument parsing rather than deep in compilation, where the message would be
  about exports and never mention `--component`.

Each is additive: a wider wrap, or a `print` import, extends the contract
without changing the manifest or the frame.

### Size: the lane prunes from `vibe_command`

The compiler offered two lanes and neither fits a command:

- `mvp` roots the DCE at `entry_name` and then hands the **same name** to a
  codegen that requires a 0-parameter WASI entry. `vibe_command(args)` takes a
  parameter, so it is refused with "WASI entry function must take 0
  parameters".
- `no-dce` keeps every statement of the merged program.

The command lane took `no-dce`, and the cost was not theoretical. Measured on
this tree, building each as a command component:

| command module | `no-dce` | `dce-root` | |
|---|---:|---:|---:|
| no imports at all | 5,587 B | 5,328 B | 95% |
| `format_script` | 84,139 B | 77,474 B | 92% |
| `lsp_diagnostics_json_string` | 4,322,042 B | 1,650,466 B | 38% |
| `check_linked_file` | 40,368,293 B | 2,590,728 B | **6%** |

A command that called the checker came to **40 MB — 7.8 times the whole
compiler adapter the launcher drives** (`lib/@vibe/compiler/cli_adapter.vibe`,
5,172,686 B), which is the opposite of what a per-verb artifact is for. Both columns come from one controlled run: two CLIs built from this same
checkout by the same seed, differing only in the mode string
`adapter_command_component` passes.

`dce-root` separates the two roles `mvp` conflates: `entry_name` is the DCE
ROOT, and the codegen entry is the library sentinel. So a command prunes from
`vibe_command` and still emits a library the wrap can lift. Pinned by
`lib/@vibe/compiler/tests/file_compile_mode_test.vibe` and, end to end, by the
gate's reachability pair — two modules that differ only in whether
`vibe_command` reaches the formatter, compared against **each other** rather
than a fixed size, so the assertion survives the formatter growing. That pair
is what separates the lanes most sharply, because the only variable left is
reachability:

| lane | reaches | avoids | avoids/reaches |
|---|---:|---:|---:|
| `no-dce` | 84,084 B | 83,154 B | 98% |
| `dce-root` | 77,317 B | 27,986 B | **36%** |

The external lever `scripts/build_vibec.sh` uses (`scripts/minify_wasm.sh
--keep-exports vibe_command,memory,__heap_ptr`) is independent of this and
composes with it: measured on the `no-dce` `format_script` core, it went from
87,014 B to 58,716 B (−32%) in 21 s. It is a separate process per pass because
a whole round over a large module exhausts the 4 GB wasm space under the bump
allocator — which is exactly why the in-compiler fix above is the one that
scales, and why it had to come first.

## Laziness, and how it is proved

`CommandManifest::resolve` is a pure function of the manifest text, and
`CommandRegistry::load` performs the only filesystem read — of the single path
that resolution returned. A verb that is never dispatched is never read,
validated, compiled or instantiated; a verb dispatched twice in one process
compiles once.

`scripts/test_component_lazy_dispatch_gate.sh` proves it the way that cannot be
faked: the manifest's other rows point at a file that is not a wasm binary and
at a path that does not exist, and the dispatch is still expected to be clean.
A loader that read, validated or even stat'd the other rows fails there.
`chmod 000` was the obvious probe and is the wrong one — the containers here
run as root, where permissions are not enforced and the probe would pass while
proving nothing.

The gate then shows the probe BITES (dispatching the poisoned verb must fail),
because "the good verb worked" is otherwise equally consistent with a manifest
nobody read. `scripts/test_component_lazy_dispatch_gate_test.sh` is the red
test for the gate itself: seven mutations of a real fixture, each asserted to
turn it red.

## Trying it

```bash
cat > hello.vibe <<'EOF'
import @vibe/command { command_args, command_ok }

export fn vibe_command(args: String) -> String {
  let argv = command_args(args)
  command_ok("hello from \{Array::get(argv, 0)}, \{Array::length(argv) - 1} arg(s)\n")
}
EOF
# Without `-o` the artifact goes under .vibe/build/out/ like every other
# build output (ADR-0111); `-o` keeps this example to one directory.
vibe build --component hello.vibe -o hello.component.wasm
printf 'vibe-commands-v1\nhello\thello.component.wasm\n' > commands.tsv
viberun --commands commands.tsv hello a b c       # -> hello from hello, 3 arg(s)

viberun --precompile-component hello.component.wasm -o hello.cwasm
printf 'vibe-commands-v1\nhello\thello.cwasm\n' > commands.tsv
# --trust-precompiled because loading an image runs native code; without it the
# row is refused by name.
viberun --commands --trust-precompiled commands.tsv hello a b c
```

## Where this is going

The launcher does not use this lane yet — it still hands `viberun` one CLI
wasm. Adopting it means splitting `lib/@vibe/cli`'s verbs into command modules
and writing a `commands.tsv` into the toolchain, which is the size lever
[#2499](https://github.com/mizchi/vibe-lang/issues/2499) asks for and which a
run-time branch in `cli_main` cannot provide: every handler stays reachable
from one entry, so DCE keeps them all. Separate artifacts per verb is the
build-time boundary that issue names, and `dce-root` is what makes each of
those artifacts worth cutting out — the same measurement that says a
per-verb `check` is 2.6 MB rather than 40 MB.

The capability half is designed in
[host-contract-artifact-lazy-cli.md](host-contract-artifact-lazy-cli.md)
(ADR-0112): the wrap becomes the generated `vibe:host` world, and a
`vibe-commands-v2` row carries the verb's requirement so authority is settled
before the artifact is read.

**The order of the remaining work is set by what was measured, not by what is
cheapest.** Capability comes first: of the verbs worth splitting out, `check`
traps and `fmt` is reduced to `--stdout` until the wrap serves `env-get` and
writes. A `commands.tsv` shipped before that would enumerate verbs that
cannot run, which is worse than not shipping one. Streaming stdout follows,
since a verb that prints as it goes is most of what a CLI does.
