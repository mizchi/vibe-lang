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

The guest half is `vibe build --component`
(`lib/@vibe/cli/dispatch.vibe`); the host half is `--commands`
(`runtime/viberun/src/commands.rs`). Neither knows how many other commands
exist: the manifest is the only thing that does, and it holds paths, not code.

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

Reading the core rather than a flag is what keeps the two answers from
disagreeing: there is no way to ask for the pure wrap and get filesystem
access, or to declare `with Fs` and be handed the strict one.

### What a command component cannot do yet

- **Write, or reach any capability outside the four read operations.** The vfs
  wrap turns them into traps. A verb that produces files is expressible in the
  shape `runtime/vibe` already uses — return a host-action plan as the payload
  and let the launcher execute it — but no verb does that yet.
- **Stream stdout.** Output comes back as the returned string, so a long-running
  command prints nothing until it finishes.
- **`--component --minify`.** `vibe-opt` optimizes core modules; running it over
  a component binary is not the same operation.

Each is additive: a wider wrap, or a `print` import, extends the contract
without changing the manifest or the frame.

### Size: the component keeps every export

The component lane compiles the core with `no-dce`, for the reason `serve` does
— there is no command entry, so entry-rooted DCE has no root and answers "no
functions found to compile". Every export of the module and its imports
survives. For a command module that is what you want (one small module, one
export); for one that pulls in a large package it is not, and the lever is the
one `scripts/build_vibec.sh` already uses: `scripts/minify_wasm.sh
--keep-exports vibe_command,memory,__heap_ptr` on the core before the wrap.

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
vibe build --component hello.vibe                 # -> hello.component.wasm
printf 'vibe-commands-v1\nhello\thello.component.wasm\n' > commands.tsv
viberun --commands commands.tsv hello a b c       # -> hello from hello, 3 arg(s)

viberun --precompile-component hello.component.wasm -o hello.cwasm
printf 'vibe-commands-v1\nhello\thello.cwasm\n' > commands.tsv
viberun --commands commands.tsv hello a b c       # same answer, no Cranelift
```

## Where this is going

The launcher does not use this lane yet — it still hands `viberun` one CLI
wasm. Adopting it means splitting `lib/@vibe/cli`'s verbs into command modules
and writing a `commands.tsv` into the toolchain, which is the size lever
[#2499](https://github.com/mizchi/vibe-lang/issues/2499) asks for and which a
run-time branch in `cli_main` cannot provide: every handler stays reachable
from one entry, so DCE keeps them all. Separate artifacts per verb is the
build-time boundary that issue names.
