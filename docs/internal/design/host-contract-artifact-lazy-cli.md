# One declaration, three readers: the residual `.wit`, the build artifact, and lazy CLI dispatch

Status: proposed — [#1346](https://github.com/mizchi/vibe-lang/issues/1346)
(the synchronous host contract), under
[#2828](https://github.com/mizchi/vibe-lang/issues/2828). Accepted when the
generator, the artifact sections and the manifest column below exist and the
conformance gate in §5 rejects its own mutations.

Date: 2026-09-16

Related: ADR-0075 (`Entry.requires ⊆ ComposedHost.provides`), ADR-0084 (effect
classes), ADR-0086 ([compiler-host-boundary.md](compiler-host-boundary.md), the
compiler's own `cli_main` boundary), ADR-0088 as amended 2026-09-15
([capability-host-contract.md](capability-host-contract.md), the not-granted
stub and the grant globals), ADR-0106 (`vibe.tagmode`), ADR-0111 (toolchain
layout), [component-lazy-dispatch.md](component-lazy-dispatch.md) (the
`viberun --commands` lane), [effect-wit-mapping.md](effect-wit-mapping.md) (the
current `--wit` generator),
[../../user/reference/host-runtime-contract.md](../../user/reference/host-runtime-contract.md)
(the three boundaries and the generated manifest), #2499 (per-verb artifacts as
the CLI size lever), #2825 (the body cache and the instantiate-time branch),
#2832 (the async half, 0.2.0 — nothing here decides it).

## Why these are one design and not three

Three threads in this repository are stuck on the same missing object:

- **The `.wit`.** `vibe compile --wit` renders a program's own effects as WIT
  and leaves every host capability as a comment, `// host capability effect
  'Fs' (provided by the vibe runtime; no WIT mapping yet)`
  (`lib/@vibe/compiler/wit_gen.vibe`). The compiler's own boundary
  (`docs/internal/compiler/wit/vibe-compiler-host.wit`) is hand-authored and
  took three review rounds to get its six `fs` operations right; nothing keeps
  it in step with the emitter. The `vibec` component ships its own hand-written
  `vibec-hosted.wit` with four root-level reads.
- **The build artifact.** A compiled core module declares what it needs only
  through its import section, in a raw i64 ABI (`vibe.abi` says
  `host_import_abi=raw`) that a host cannot read as a requirement without the
  compiler's own table. The one thing #2825 needs from the artifact — "which of
  these imports may be withheld" — has a designed section
  (`vibe.capabilities`) and no emitter yet.
- **Lazy CLI dispatch.** `viberun --commands` is built and proven lazy, and the
  launcher does not use it. The stated blocker is capability: the command wrap
  serves four reads and traps on everything else, so `check` (which reads
  `Env::get` and writes its cache) cannot run and `fmt` is reduced to
  `--stdout`. The manifest holds paths only, so a verb's authority cannot be
  settled before its artifact is opened — which is what ADR-0088's "earliest
  phase" rule asks for.

Each of these needs the same thing: **a machine-readable statement of what an
artifact requires from its host, written once by the compiler at the point where
it decides the import section, and read by a WIT generator, by a host at
instantiate, and by a manifest at dispatch.** This document specifies that
statement and the three readers. It does not add a second hand-maintained list
anywhere; every table below is derived from
`docs/generated/host-runtime-contract.json` or from the emitter, and the gate in
§5 is what proves it.

## What exists, as of `5275d33`

| piece | state | where |
|---|---|---|
| raw `vibe.*` import inventory: 59 static fields in four bands, plus two dynamic name patterns, with core type indices | generated, gated fail-closed on emitter + both runners | `docs/generated/host-runtime-contract.json`, `scripts/check_host_runtime_contract.py` |
| value layout of the raw lane: packed `(ptr << 32) \| byte_len` strings, `Bytes` header struct, untagged `i64` results, opaque `i64` handles | documented | [../../user/reference/host-runtime-contract.md](../../user/reference/host-runtime-contract.md), [../../user/reference/host-abi.md](../../user/reference/host-abi.md) |
| `vibe.abi` custom section (`version=1`, `host_import_abi=raw`) on both lanes | emitted, read by the node runner | `lib/@vibe/compiler/codegen/wasm_emit/metadata.vibe` |
| `vibe.tagmode` custom section for adapters | emitted where an adapter is selected, required by ADR-0106 | `lib/@vibe/compiler/entry/source_compile/wasi_only/component_codegen.vibe` |
| `vibe.capabilities` section + `__vibe_granted$<label>` globals + trapping stub | designed; withholding landed on both runners (`VIBE_HOST_WITHHOLD`) | [capability-host-contract.md](capability-host-contract.md) |
| `--wit` generator for user effects and exports | implemented; host capabilities are a comment | `lib/@vibe/compiler/wit_gen.vibe` |
| `viberun --commands`: `vibe-commands-v1` manifest, `run: func(args: string) -> string`, result frame, lazy load proven by a poisoned-row gate | implemented; launcher does not use it | `runtime/viberun/src/commands.rs`, [component-lazy-dispatch.md](component-lazy-dispatch.md) |
| per-verb DCE (`dce-root`): `check` as a command is 2.6 MB against a 38 MB whole CLI | implemented | `lib/@vibe/compiler/cli_support.vibe` |
| `Fs::remove` parity (#2758): the recursive form is `Fs::remove_tree`; `fs_remove`, `fs_remove_file`, `fs_remove_tree` are all `portableCore` now | landed (PR #2823, merged) | the manifest above |
| launcher artifact selection: one `vibe-cli.wasm`, a `.cwasm` picked by an mtime freshness rule | implemented | `runtime/vibe` (`pick_cli`) |

Nothing below removes any of these. The design adds one section, one column and
one generator, and turns two hand-written WIT files into outputs.

## 1. The `.wit`: one interface per provider label, generated from the import table

### 1.1 Shape

A WIT package `vibe:host`, one interface per **provider label** — the capability
effect the checker tags a builtin with (`Some("Fs")` on the registry entry) and
the unit ADR-0088 grants by. One function per **operation**, which is the unit
of authority ADR-0071 / ADR-0084 settled on (`Fs::read_file`, never `Fs`).

```wit
package vibe:host@0.1.0;

interface fs {
  read-file: func(path: string) -> string;
  read-bytes: func(path: string) -> list<u8>;
  write-file: func(path: string, content: string);
  write-bytes: func(path: string, content: list<u8>);
  publish-immutable-text: func(path: string, content: string) -> bool;
  exists: func(path: string) -> bool;
  is-dir: func(path: string) -> bool;
  is-file: func(path: string) -> bool;
  stat-token: func(path: string) -> s64;
  read-dir: func(path: string) -> list<string>;
  mkdir: func(path: string);
  mkdir-p: func(path: string);
  remove: func(path: string);
  remove-file: func(path: string);
  remove-tree: func(path: string);
  rename: func(from: string, to: string);
  copy: func(from: string, to: string);
  append: func(path: string, content: string);
  chdir: func(path: string);
  getcwd: func() -> string;
}

interface env {
  get: func(name: string) -> string;
  args-len: func() -> s64;
  args-get: func(index: s64) -> string;
}

interface http {
  resource response {
    status: func() -> s64;
    header: func(name: string) -> string;
    body: func() -> string;
  }
  request: func(method: string, url: string, headers: string, body: string) -> response;
}
```

`stdin`, `stdout`, `stderr`, `process`, `sh`, `tcp`, `profiler` and `clock`
(`sleep`) follow the same rule. The names are not a design choice to be made
here: they are the labels the registry already carries and the kebab mapping
`wit_gen.vibe` already applies (`HttpReq` → `http-req`, `read_file` →
`read-file`).

### 1.2 The rule that makes it a contract: one function, two lowerings

A raw core import `vibe.fs_read_file: (i64) -> i64` and the WIT function
`vibe:host/fs.read-file: func(path: string) -> string` are **the same
operation with two lowerings**:

| lowering | who uses it | argument / result representation |
|---|---|---|
| canonical ABI | a component host (the `--commands` lane, `vibe serve`, `vibec`) | WIT types; `string` is `(ptr, len)` in the canonical ABI |
| vibe-raw | a core-module host (`viberun`, the node runner) | `vibe.abi` layout: packed `(ptr << 32) \| len`, untagged `i64`, opaque handles |

The WIT signature is therefore the *definition* and the raw signature is
*derived* from it by a fixed mapping — the one `wit_type_text` already
implements in reverse (`Int` ↔ `s64`, `Bool` ↔ `bool`, `String` ↔ `string`,
`Bytes` ↔ `list<u8>`, `Array[String]` ↔ `list<string>`, `Unit` ↔ no result).
Two consequences:

- The three-way check `scripts/check_host_runtime_contract.py` performs today
  (emitter names, runner names, type indices) gains a fourth side: the WIT
  text. A raw signature that does not match its WIT function's mapping fails
  the gate, so the two lowerings cannot drift.
- A component host and a core host implement one semantics. `viberun`'s
  `--commands` face today serves `read-dir` as sorted names joined by `\n`
  (`register_vfs_imports`), while the core lane's `fs_read_dir` returns the
  same content as a packed string; under this rule both are the canonical and
  the raw lowering of `fs.read-dir: func(path: string) -> list<string>`, and
  the join is an artifact of the packed lane, not part of the contract.

**Handles are WIT resources.** `http_request` returns an opaque `i64` today and
`http_close` is its destructor by convention; in WIT the same is `resource
response` with an implicit drop. The raw lane keeps the `i64` and the explicit
close import. `sh_capture` / `sh_capture_close` and `tcp_connect` / `tcp_close`
are the same pattern.

**Failure is a trap in this version.** Every runner today turns a host failure
into a trap (a Rust `Err` through `func_wrap`, a thrown JS error), and the
program cannot observe it. The WIT above says so by returning `T` rather than
`result<T, E>`. ADR-0088's `Errored(E)` arm needs a catchable host-failure ABI;
that is #2828's item, and when it lands the residual signature becomes
`result<T, host-error>` on the operations it covers, with a version bump on
the package. Declaring `result` now, before any host produces one, would
describe a boundary that does not exist.

### 1.3 The world per entry: generated from the same set that gates the imports

`linked_compile` decides the import section from
`collect_used_builtin_names` after late DCE, so an import is emitted only when
the program still calls the builtin. The residual world for an entry is
generated from **that same set**, not from a scan of `with` rows:

```wit
package vibe:app;

world check {
  import vibe:host/fs;
  import vibe:host/env;
  import vibe:host/stdout;
  export run: func(args: string) -> string;
}
```

With the interface granularity being the label and the authority granularity
being the operation, the world imports whole interfaces and the artifact's
`vibe.capabilities` section (§2) says which operations are required and which
are optional. A host may implement an interface partially; the preflight in
§2.4 is what decides whether that is enough, operation by operation.

This replaces the `// host capability effect ... no WIT mapping yet` comment.
Because the set is the emitter's own, the generated world cannot list an
interface the module does not import or omit one it does — the property the
hand-authored compiler-host file needed three review rounds to approximate.

How a *producer's* export surface becomes its WIT, its vibe-facing contract
and its entry kind — and how a vibe consumer imports the result transparently —
is the build-side convention in
[component-build-convention.md](component-build-convention.md) (ADR-0113).
This document owns the host side: the `vibe:host` interfaces, the artifact
sections and the manifest.

### 1.4 What happens to the two hand-written files

- `docs/internal/compiler/wit/vibe-compiler-host.wit` becomes the generator's
  output for `cli_main`. It is regenerated by the gate and diffed; when they
  agree the hand-authored comments go (the reachability audit they narrate is
  now the generator's job), and ADR-0086 is amended to cite the generated file.
- The `vibec-hosted.wit` four-read face becomes `import vibe:host/fs` with a
  `vibe.capabilities` section listing the four operations as required; its
  `stat-token = -1 for a non-regular file` semantics moves into the `fs`
  interface's doc comment, where the core lane's `fs_stat_token` already has
  to agree with it.

### 1.5 Ownership, pinned

| surface | owner | source of truth |
|---|---|---|
| operation identity and label | the builtin registry (`lib/@vibe/compiler/core/builtin_registry.vibe`) | the checker's tag |
| WIT interfaces and functions (`vibe:host/*`) | the generator, from the registry and the manifest | a generated file under `docs/generated/`, gated |
| raw `vibe.*` field name and core type | `lib/@vibe/compiler/codegen/wasi/linked_compile.vibe` | `docs/generated/host-runtime-contract.json` |
| the mapping between the two | the type-mapping table in `wit_gen.vibe` | the gate's fourth side |
| `host_future_*`, `host_stream_*`, `stdin_provider_*` | the component adapter | private; the gate keeps them out of both standalone runners |
| async lift, `future<T>`, `stream<u8>` | ADR-0089 | #2832, 0.2.0 |
| Wasmtime `Linker` setup, preopens, fuel, store limits | each runner | not contract |

## 2. The build artifact: a core module that describes itself

### 2.1 No new container

The intermediate build format is **the core wasm module, plus custom
sections**. A new object-file format was considered and rejected on the
measurements already in hand:

- #2825 §2 measured the checked-module artifact (`vCHK`) at 179 MB for a
  9 MB build and +87 % warm wall; the transport exceeded the phase it would
  feed. It is not the artifact to hang more on.
- #2825 §3 found the persisted codegen body cache (16 MB) carrying the
  expensive phases, and found it never fired on a build with an entry because
  the capability const-fold rewrote bodies. The 2026-09-15 amendment to
  ADR-0088 removes that fold, which is exactly what makes a body
  **capability-independent** — one body serves every grant set.

So the intermediate that matters for per-verb artifacts is the body cache, and
what a per-verb build does is *link*: prune from one root (`dce-root`) over
bodies the cache already holds. The core module is the only thing that crosses
from build to instantiate, and it has to carry its own requirements because
nothing else travels with it.

### 2.2 The sections

| section | payload | status |
|---|---|---|
| `vibe.abi` | `version=1\nhost_import_abi=raw\n` | exists |
| `vibe.tagmode` | one little-endian i32: 0 plain i64, 1 tagged | exists where an adapter is selected (ADR-0106) |
| `vibe.capabilities` | `version=1`, then one row per **optional** operation: `optional\t<label>\t<module>\t<field>\t<grant global>` | designed in [capability-host-contract.md](capability-host-contract.md); emitter pending on the `perform?` lowering (#2825 step 2) |
| `vibe.entry` | `version=1\nkind=<kind>\nexport=<name>\n` | **new, this document** |
| `name` | function names | exists |

Two rules keep this from becoming a second import section:

- **Required is the import section.** A `vibe.*` import with no
  `vibe.capabilities` row is required. The section never lists required
  operations; a host that needs the label for a field reads the mapping from
  the toolchain's contract manifest, and a host that lacks the mapping can
  still refuse by field name. This is the fail-closed reading the capability
  contract chose, and it keeps a module built before any of this correct
  without a version check.
- **A sidecar is a projection.** `<out>.wit` is generated from the artifact's
  import section and sections and is for tooling and people; `<out>.funcmap`
  and `<out>.diag` likewise. A host decides from the artifact, never from a
  sidecar. The one place that reads a sidecar to decide behaviour today —
  `vibe serve` picking the `body: stream<u8>` adapter by reading the `.wit`
  next to the handler — folds into reading the handler component's own export
  type, which the launcher already has open.

### 2.3 `vibe.entry`: initialization, lifetime and re-entry, without a flag

The issue asks for initialization, invocation lifetime and re-entry constraints
independent of Wasmtime flags. Today they are conventions per entry shape,
known to the launcher and to nobody else. The section names the shape so a
host applies the right protocol without being told:

| `kind` | `export` | protocol |
|---|---|---|
| `wasi-command` | `_start` | instantiate, write grant globals, call once, discard the instance. A second `_start` on the same instance is out of contract (`__heap_ptr` and every `let mut` at module scope are live state). |
| `command` | `run` | one instance per invocation; `args` is argv joined by NUL, the result is `vibe-command-result-v1`-framed. `viberun` already does exactly this (`invoke_command` builds a fresh `Store` and instance per call). |
| `handler` | `handler` | the 4-string `vibe serve` contract, or its `stream<u8>` form; one instance may serve many requests, and a handler that keeps state across them is the author's choice, not the host's. |
| `library` | none | no entry; the module is an input to composition (`vibec`'s `compile` face, a bench or test harness). Re-entry is per export and is the export's own contract. |

Initialization is one order for every kind: **link → write grant globals →
call the export.** Nothing runs before the export is called (there is no
`start` function on the linear lane), and a host that writes a grant global
after the call has changed authority mid-run, which ADR-0088 forbids.

### 2.4 Preflight, and what the host answers before `main`

A host with the artifact open and the toolchain's contract manifest at hand can
now answer ADR-0075's `Entry.requires ⊆ ComposedHost.provides` without the
compiler:

1. read the import section; for each `vibe.*` field with no `optional` row,
   the host must provide it or refuse — naming the label, the verb (§3) and
   the grant that supplies it;
2. for each `optional` row, link the real implementation and write `1`, or
   link the trapping stub and leave `0`;
3. anything outside `portableCore` is decided by the manifest's band, as it
   is today;
4. call the export named by `vibe.entry`.

This is the third boundary the issue asks to keep separate from the other
two: neither the WIT (which is a projection) nor Wasmtime (which is one way to
implement step 2) appears in it.

### 2.5 A component boundary is an executable boundary, never a library boundary

The question this section answers: if a `.wit` and a `.component.wasm` sit in
the build pipeline, what happens to generics? The answer is that they never
reach one, by construction, and the design has to say so because the two
readings of "intermediate" are easy to confuse.

**What cannot cross a component boundary.** WIT has no type parameters, no
function types and no effect rows. The canonical ABI lifts concrete values
only, and two component instances have two linear memories, so every string,
list or record that crosses is a copy and no heap reference survives the
crossing. Concretely, four things vibe relies on have no representation there:

| vibe | how it is compiled today | at a component boundary |
|---|---|---|
| a generic function `fn f[T](x: T)` | one erased body over the uniform tagged `i64` (top-level generic bodies are not specialized) | no WIT type for `T`; passing the `i64` as `s64` hands the callee a pointer into another instance's memory |
| a closure `(T) -> U` | a funcref index plus captured environment in the caller's heap | WIT has no function type; only a `resource` with a method, in the callee's instance |
| a trait bound `[T: Show]` | a witness dictionary threaded by `thread_dict_params` | no dictionary type; the caller's dictionary indexes the caller's function table |
| an effect row `with e` / a handler | evidence passing (ADR-0076) through the caller's evidence frames | no effect in WIT; `Async` is the one exception and is a lift mode, not a value |

Metadata cannot recover these. A custom section can carry the type scheme
(the `.vpkg` header and the `vCHK` transport already do), but a scheme is a
fact about source; it does not give a second instance a way to call a funcref
or read a struct that lives in the first instance's memory. The only working
encodings are to monomorphize every instantiation the consumer needs at the
boundary (impossible for a prebuilt artifact whose consumer is unknown) or to
represent every polymorphic value as a `resource` handle with a `call` method
(every crossing becomes a host round-trip and a manual refcount, which defeats
the boundary's purpose). Neither is taken.

**So the rule is: a component boundary is only ever placed where the surface
is already monomorphic and first-order.** Those places are the entry points
`vibe.entry` names — `run: func(args: string) -> string`, `_start`, the
4-string `handler`, `vibec`'s `compile` — and they are process-like: argv in,
bytes out. A verb component is a **whole-program link** from its root: the
formatter's, the checker's and the core library's generic code is linked into
it, erased and dictionary-threaded exactly as it is into the monolithic CLI
today. That is why `check` as a component is 2.6 MB and contains its own
checker rather than importing one. Nothing generic crosses because nothing is
imported but host capabilities, whose operations are first-order by
definition (§1).

Where code IS shared between units, the unit is a core-module function body
in the body cache, which has no boundary at all: a cached body is linked into
the consumer's module, same memory, same function table (after #2669's
symbolic relocation), same tag representation. Sharing at that layer keeps
every property above because it is the same program, assembled from parts.

### 2.6 The optimization unit

A component is the right unit for **authority and isolation** (a verb runs
with exactly the interfaces its world names, in its own memory) and for
**loading** (a verb that is not dispatched is not read). It is the wrong unit
for **optimization**, and the design does not use it as one:

- **Inside a verb: whole-program.** DCE from the root (`dce-root`), constant
  folding, effect-lowering prelude, trait-dictionary desugar, borrow inference
  and Perceus all run over the whole linked program, as today. A component
  boundary would stop every one of them: an engine does not inline across
  instances, a Perceus reuse token cannot name another memory, and a
  `#zero_alloc` summary (ADR-0091) can be imported only from a body in the
  same link.
- **Across verbs: the function body.** The capability-independent body cache
  is the sharing unit, keyed on the body's own inputs. This is a function-
  granularity unit, not a module or a component, because that is the
  granularity at which the compiler already proves replay is safe (the
  `guard_*` fields of the body cache, and #2669's move to symbolic references
  so the guards stop depending on whole-program layout).

**What this does not make free.** #2825 §1 measured a warm CLI compile at
~8 s, of which the post-merge linked compile is 6.3 s: the body codegen the
cache replays is 0.6 s of it, and the effect-lowering prelude (2.6 s),
trait-dictionary desugar (0.7 s), borrow + Perceus (0.9 s) and DCE / index
assignment / assembly (1.2 s) are per-link today. Linking ten verbs is
therefore closer to ten post-merge phases than to one, until those phases
become per-module cacheable — which is #2507's link unit and #2669's
relocation, not this document. The design depends on that line; it does not
replace it. Disk is not the constraint (ten verbs at 2–3 MB each), build
time of the toolchain is, and it lands on `vibe self update` and the release
build rather than on a user's `vibe build`.

## 3. Lazy CLI: the manifest carries requirements, the host composes from the world

### 3.1 The row gains one column

`vibe-commands-v1` rows are `verb\tpath`. The next version adds the residual
requirement so it can be read **before the artifact is opened**:

```text
vibe-commands-v2
check	commands/check.cwasm	fs.read-file,fs.exists,fs.stat-token,fs.read-dir,fs.write-bytes,env.get,stdout.write-stream
fmt	commands/fmt.cwasm	fs.read-file,fs.write-file,stdout.write-stream
symbols	commands/symbols.cwasm	fs.read-file,fs.read-dir,stdout.write-stream
```

The column is a comma-separated list of `<interface>.<operation>` names, an
operation suffixed `?` when the artifact declares it optional. It is written by
`vibe build --component` from the import section and the `vibe.capabilities`
section — never by hand — and it is a **cache of the artifact, verified on
load**: when the artifact is opened, its own sections are compared to the row,
and a disagreement is refused by name. The row cannot become a second truth,
because the artifact always wins and a stale row is an error rather than a
quietly different answer.

What the column buys, in the order the launcher uses it:

1. **Authority before I/O.** The launcher's grant for a verb is the toolchain
   policy (the CLI runs with the authority the user gave the toolchain, not
   with `--allow-*` per verb). A verb whose required operation the policy
   denies is refused with the verb and the operation named, and the artifact
   is never read. This is the "settled once, in the earliest phase" rule
   applied to the CLI itself.
2. **The host is composed from the row.** The linker registers exactly the
   `vibe:host/*` functions the row names, from the same implementations the
   core lane uses — the canonical lowering of §1.2 — and a trapping stub for
   an optional operation the policy withholds. There is no longer a fixed
   "pure" or "vfs" wrap: the wrap is the world.
3. **Then the one read.** `CommandRegistry::load` opens the one path, as
   today. The laziness gate (`scripts/test_component_lazy_dispatch_gate.sh`)
   keeps its poisoned rows and gains one: a row whose column disagrees with
   its artifact must be refused, and a row whose column names a denied
   operation must be refused without the artifact being read.

### 3.2 What this unblocks, by the measurements already taken

| verb | blocked on today | under §3.1 |
|---|---|---|
| `check` (2.6 MB) | `Env::get` and the cache write trap in the vfs wrap | `env.get`, `fs.write-bytes`, `fs.publish-immutable-text` are rows; served |
| `fmt` in place | the write traps | `fs.write-file` is a row; served |
| every verb | output returned as one string at exit | `stdout.write-stream` is a row; a command prints as it goes through the same `Stdout::write_stream` the monolithic CLI already calls |

The result frame stays mandatory (`vibe-command-result-v1\t<exit>\n`), because
its job — a trapped command can never read as success — does not change. Its
payload becomes what a command chose to return after writing its output, and
is empty for a verb that streams.

### 3.3 Precompiled rows and the launcher

- **Whether a row is precompiled is the manifest's decision** (unchanged).
  `vibe self update` and `install/install.sh` precompile each command with
  the toolchain's own `viberun` and write `.cwasm` rows, the same way they
  precompile `vibe-cli.wasm` today. A checkout install writes `.component.wasm`
  rows.
- **`--trust-precompiled` is passed by the launcher only for a manifest under
  `$VIBE_HOME/toolchains/<name>/`**, the directory the installer wrote and
  `manifest.json` describes. A `commands.tsv` anywhere else is data.
- The launcher's `pick_cli` mtime rule is retired for verbs the manifest
  covers: a row names one artifact and there is nothing to guess. The
  monolithic `vibe-cli.wasm` remains the fallback for a verb with no row, so
  migration is one verb at a time and `VIBE_CLI_WASM=<stage2>` keeps its
  meaning for every script that sets it.

### 3.4 Which verbs, in which order

The same order [component-lazy-dispatch.md](component-lazy-dispatch.md) set,
now with its blocker resolved: capability first (§1–§2), then streaming (§3.2),
then the verbs. Editor-query verbs (`symbols`, `type-at`, `binding-at`,
`escapes`, `deps`, `grep`, `check`, `fmt`) go first — each is a pure
`String -> String` or a read-mostly function over the checker, each prunes
well under `dce-root`, and together they are what an LSP-driven session runs
most. `build`, `run`, `test`, `bench` go last: they need the whole compiler and
gain nothing from splitting until the compile-only artifact (`vibec`, already a
component) is what they link against.

## 4. Reconciling the two runners

The issue's third criterion — node and viberun agreeing — is answered by the
gate, not by a list. The one live divergence it named, `Fs::remove`, closed
with #2823: the recursive form is `Fs::remove_tree`, and all three `fs_remove*`
fields are `portableCore`. What remains is the class of bug #2758 described:
"the two runners agreeing is a property nothing currently checks". §5 adds
that check.

The node runner's `() => 0n` fallback for an unimplemented `vibe.*` import
(capability-host-contract.md, open item 3) is replaced by the throw its
withhold path already has. Under §2.4 every field the module declares is
either provided, stubbed to trap, or refused before instantiation; a silent
zero has no remaining case to serve.

## 5. The conformance gate, and how it is proved to bite

Per #2248 a gate is trusted only after it has failed on purpose. Three checks,
each with the mutation that must turn it red:

| check | what it asserts | red test |
|---|---|---|
| **generator diff** | the committed `vibe:host` WIT equals the generator's output from the registry and the manifest; the raw signature of every field equals the mapping of its WIT function | change one WIT parameter type; change one core type index in the JSON; each must fail naming the field |
| **semantic conformance** | a fixture set of small programs (one per operation family: read/write/exists/read-dir ordering, `stat-token` on a non-regular path, `env.get` on an unset name, handle close-twice, a withheld optional operation) runs on both runners with byte-identical stdout and identical exit, on the linear lane | edit one runner's `read-dir` to skip the sort; the fixture must fail on that runner only |
| **manifest row** | a `vibe-commands-v2` row equals what `vibe build --component` derives from its artifact | rewrite one row's column; dispatch must refuse before reading the artifact (the row lists a denied operation) and on reading it (the row disagrees) |

The semantic fixtures pin values, not agreement: "agreement alone passes when
both lanes break the same way" (`fixtures/gc_host_builtins.vibe` says this for
the linear/gc pair, and the same holds for the node/Rust pair).

## 6. Sequence

1. **Generator** (compiler): `vibe:host` interfaces from the registry and the
   manifest; `--wit` imports them instead of emitting the comment; the
   compiler-host and `vibec` files become outputs. Gate side one.
2. **`vibe.entry`** (compiler): emitted on every lane; runners read it and
   drop their per-shape flags where one exists.
3. **Canonical lowering on the hosts**: `viberun --commands` and the node
   runner serve `vibe:host/*` from the core-lane implementations; withhold
   becomes the stub, the `0n` fallback goes. Gate side two.
4. **`vibe.capabilities` emitter** lands with #2825 step 2 (the `perform?`
   branch), which is what produces an `optional` row.
5. **`vibe-commands-v2`** and the launcher: the column, the verification on
   load, policy-before-open, `--trust-precompiled` scoped to the toolchain
   directory. Gate side three. Editor-query verbs move first.

Steps 1–3 are independent of #2825's lowering change and can land before it;
step 4 is that change's own deliverable; step 5 needs 3.

## What this does not decide

- **Who sets the toolchain policy** (which labels the CLI may use on this
  machine). Today the CLI has full authority and nothing here narrows it; the
  column makes narrowing possible, and #2332's L1 flags are where the answer
  goes.
- **`Errored(E)`** and any `result<T, E>` residual signature (#2828).
- **Async**: `future<T>`, `stream<u8>`, the async lift and the
  `componentAdapterOnly` names stay exactly where ADR-0089 and #2832 put them.
- **The `.cwasm` freshness rule for the monolithic CLI**, which stays until
  the last verb has a row.

## Open for the owner

1. **Interface granularity.** §1 imports whole interfaces (`vibe:host/fs`) and
   lets the section and the manifest column name operations. The alternative
   is one WIT interface per operation, which makes the world itself the
   operation-level statement at the cost of ~50 one-function interfaces. The
   label-level world matches how a host implements things (a filesystem
   provider, not twenty providers) and how ADR-0088 grants (`allows Fs`), so
   this document takes it.
2. **Whether the manifest column should exist at all**, given the artifact is
   the truth. It exists so that authority is settled before any file other
   than the manifest is read, which is the property the lazy lane was built
   for. If the owner prefers to open the artifact and read its sections, the
   column is dropped and §3.1 step 1 moves after step 3; nothing else changes.
3. **The `vibe:host` package version.** `0.1.0` here, bumped when `result`
   signatures land. Whether that version tracks the language's 0.1.0 tag or
   its own line is a release question.
