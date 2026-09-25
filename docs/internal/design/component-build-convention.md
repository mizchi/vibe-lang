# Component build convention: the export surface is the contract, WIT is derived, vibe-to-vibe is transparent

Status: proposed — the build-side half of
[host-contract-artifact-lazy-cli.md](host-contract-artifact-lazy-cli.md)
(ADR-0112, [#1346](https://github.com/mizchi/vibe-lang/issues/1346)); the
import half of #2064. Accepted when `vibe build --component` derives both
artifacts in §5 from one source, a vibe consumer imports a vibe component with
an ordinary `import`, and the round-trip gate in §8 rejects its own mutations.

Date: 2026-09-17

Related: ADR-0063 / ADR-0070 (`index.vpkg` is the package boundary and the
public API), ADR-0075 (a `.vibex` has no export surface), ADR-0085
(`Exception[E]`), ADR-0088 (`allows` / `with`), ADR-0089 (the boundary rules
for `Future` / `stream<u8>`), ADR-0093 (contract identities),
[effect-wit-mapping.md](effect-wit-mapping.md) (today's `--wit` generator,
which this convention subsumes), [component-lazy-dispatch.md](component-lazy-dispatch.md)
(the command kind), `lib/@vibe/wit_runtime` (the boundary `Result`),
`lib/@vibex/wasm_wit_parser` (the WIT reader the inverse projection needs).

## The two rules

**1. WIT is derived, never written.** A vibe author writes vibe: `export fn`
declarations with full signatures in a `.vibe` module. `vibe build --component`
derives everything else from those signatures — the component's `.wit`, its
vibe-facing contract, its entry kind, its import list. A hand-written `.wit`
anywhere in the tree is a bug, the same way a hand-edited sidecar is: the
generator is the only writer, and the gate in §8 is what proves the two
artifacts never disagree.

**2. Between vibe programs, the boundary is transparent.** A vibe consumer
imports a vibe component with the same `import @scope/pkg { f }` it uses for a
source package. It sees vibe names, vibe types and vibe effect rows — the
derived contract — and never reads WIT. The compiler decides the linkage
(source: merge and link; component: canonical-ABI import) from what the
package is, not from anything the consumer writes. WIT is the interchange
format for hosts and consumers that are not vibe, and it stays exact for them
because it is derived from the same contract.

What transparency does **not** mean is worth stating once: it is limited to
the WIT-expressible subset (§2). A component boundary is a service boundary —
argv in, values out, first-order, closed types — never a library boundary
(host-contract §2.5). Nothing generic crosses, and the convention refuses
rather than approximates.

## 1. What a component is built from

### 1.1 Input

A `.vibe` module. A `.vibex` is refused as today: it is an executable root
with no export surface (ADR-0075, #2229), so there is nothing to project.

There are two inputs, and they are told apart by what the author names:

- **A package**: `vibe build --component <dir>` (or its `index.vpkg`). The
  surface is the contract's own bodyless declarations — `index.vpkg` *is*
  the public API (ADR-0063 / ADR-0070) — and the implementations are
  resolved through the ordinary loader and checked against it by the
  existing conformance engine. The package's `name` and `version` become
  the WIT package id (§4) and the component gets a vibe-facing identity a
  consumer can import by name. No implementation file's `export` list
  stands in for the contract: a package may have several implementation
  roots, and letting any of them publish under the package's name would let
  two files ship incompatible components under one identity, or expose a
  declaration the contract never listed.
- **A loose module**: `vibe build --component file.vibe`. Its `export`
  declarations are the surface, it builds under `vibe:app` as today, and it
  can only be composed by path; nothing can `import` it. Sitting next to an
  `index.vpkg` does not change this — a file is not a package.

### 1.2 The surface

The surface is exactly the set of declarations the input publishes — the
`index.vpkg` declarations for a package, the `export fn` /
`export let f: (..) -> .. =` declarations for a loose module — each fully
annotated (parameter types, return type, row). Two changes from today's
`--wit`:

- **An unannotated export is refused, not skipped.** `--wit` skips one
  ("nothing is guessed at the boundary") and so silently narrows the surface;
  under `--component` the export is named and the edit asked for.
- **An export that does not project is refused, naming the export, the
  offending type and the admitted list** (§2). Today's generator throws the
  same way; the convention only pins that no build lane may catch and
  continue past it.

Non-exported declarations are the implementation and are linked in as the
DCE root reaches them, the same `dce-root` lane the command kind uses.

### 1.3 The entry kind is read from the surface, not from a flag

The same principle that picks a command's wrap from the core's import
section: two front doors cannot disagree about a module if neither is told
anything the module does not already say.

`vibe.entry` names both layers, because they are not the same export
(host-contract §2.3): `core-export` is the vibe function on the core module,
`component-export` the lifted name.

| the surface is | `kind` | `core-export` | `component-export` |
|---|---|---|---|
| exactly one export, `vibe_command(args: String) -> String` | `command` | `vibe_command` | `run: func(args: string) -> string` |
| exactly one export, `handler = (method, url, headers, body) -> String`, body `String` or `HostStream` | `handler` | `handler` | `handler: func(..)`, sync or async lift by the body type (#1540) |
| anything else | `service` (new) | (none: no single entry) | the interface id of §4, holding every export |

A module that exports `vibe_command` **and** other functions is refused: a
command exports exactly one function (component-lazy-dispatch.md), and the
extra exports are named in the message rather than silently pruned by DCE.
The same holds for `handler`. **The two reserved kinds also refuse a row that
would change their ABI**: `run` is exactly `func(args: string) -> string`
(`runtime/viberun/src/commands.rs` looks it up by that type), so
`Exception[E]` (§3.1 would make it `result<string, E>`) and `Async` (an
`async func`) on `vibe_command` are refused naming the edit — the frame
(`command_failed`) is a command's failure channel. A `handler` refuses
`Exception[E]` for the same reason (its status line is the channel) and
takes `Async` only with a `HostStream` body, as #1540 already enforces. Host
capabilities on either row are fine; they are imports, not signature
changes. The reserved names are the only way to ask for
those kinds, which keeps the reserved words to two and the flag count to one.

The `wasi-command` kind of host-contract §2.3 is a core-module kind
(`core-export=_start`, no component export), so a `.vibex` is not a
`--component` input. A `.vibex` entry lifted to `wasi:cli/run` is not a
`--component` kind in this convention either. The two gates that assert
`export wasi:cli/run@0.2.6` today (`scripts/test_cli_command_component.sh`,
`scripts/test_check_command_component.sh`) call builder scripts that are no
longer in the tree, so that lane has no producer at the moment; when it
returns it is `kind=wasi-command`, and nothing here has to change for it.

## 2. The admitted boundary types

The subset that projects in both directions. The forward mapping is
`wit_type_text`'s today; the inverse is new and must be its exact inverse.

| vibe | WIT | notes |
|---|---|---|
| `Int` | `s64` | 63-bit inside vibe (ADR-0105); a foreign `s64` outside that range is refused at the shim, never wrapped |
| `Double` | `f64` | |
| `Bool` | `bool` | |
| `Char` | `char` | a Unicode scalar at the boundary; inside vibe `Char` is a transparent `Int` alias (ADR-0098), so the shim validates the range |
| `String` | `string` | valid UTF-8 both ways; an invalid byte string is refused, naming the operation and the first bad byte offset, on the component lane **and** the raw lane alike (host-contract §1.2 — today's raw lane silently replaces, which that section retires). Arbitrary bytes cross as `Bytes` / `list<u8>` |
| `Bytes` | `list<u8>` | |
| `Array[T]` | `list<T>` | |
| `Option[T]` | `option<T>` | |
| `Result[T, E]` (`@vibe/wit_runtime`) | `result<T, E>` | explicit two-track value; see §3 for the row form |
| `Map[String, V]` | `list<tuple<string, V>>` | a non-`String` key is refused; the type mapping is a bijection but the value mapping is not — a list with a duplicate key has no `Map`, so the inbound shim **refuses** one naming the key rather than dropping a pair. A foreign `list<tuple<string, V>>` never becomes a `Map` (§7) |
| `(A, B, ..)` | `tuple<A, B, ..>` | |
| `Unit` return | no result | |
| `Future[T]` | `future<T>` | ADR-0089 D5 |
| `ByteStream` / `HostStream` | `stream<u8>` | nominal host-owned handles only (ADR-0089 D4) |
| **`export struct S { .. }`** | `record s { .. }` | new: fields must themselves be admitted |
| **`export enum E { A; B }`** | `enum e { a, b }` | new: no payloads |
| **`export enum E { A(T); B(U, V) }`** | `variant e { a(t), b(tuple<u, v>) }` | new: payload types admitted |
| `type A = ..` | expanded before projection | an alias never names a WIT type |

Refused, each with the edit in the message:

- **a type parameter on an export** — "a component boundary carries no
  generics; export at a concrete type". Closed signatures only.
- **a function type** in a parameter or result — WIT has no function type;
  the edit is to pass data and call back through an export.
- an eager `Stream[T]` / `AsyncIter` (ADR-0089 D4), a `Map` with a non-`String`
  key, an `opaque type` (nothing to project), a trait bound, a row variable.
- a `struct` / `enum` used at the boundary that is not `export`ed: a private
  type has no name the consumer can see, so the edit is to export it
  (decided by the owner, 2026-09-17).
- **a recursive boundary type** (`struct Node { next: Option[Node] }`, or a
  cycle through several types): WIT value types are ordered and a cycle has
  no definition, so the build refuses the strongly connected component by
  name, with the edit (flatten, or index into a list) rather than emitting
  a contract no tool can read.

The mapping is a bijection on this subset, and §8 checks it as one.

## 3. Effects at the boundary

An export's row is projected label by label:

| label in the row | projects to |
|---|---|
| a host capability (`Fs`, `Env`, `Http`, .. — the registry's provider labels) | an **inline** interface named by the catalog interface that **owns the raw field** the operation lowers to, holding only the used functions (host-contract §1.3; never `import vibe:host/<label>` whole, which would demand the full surface); derived from the emitted import section, so it can never list a function the code does not reach. For an **alias-only** label the owning interface is another provider's: `Console::write_stream` lowers to `stdout_write_stream`, so the world gets `stdout.write-stream` and `Console` survives only as the grant label in `used` rows and the manifest column (host-contract §1.1). Naming the interface after the label instead would ask for a `console` interface no host registers. |
| a user algebraic effect `effect E { .. }` | an import of interface `<kebab-e>` (today's rule); the composer, not the caller, supplies it (§6.3). **Tail-resumptive only**: the import is a synchronous function that returns exactly once, so a handler that stores its `resume`, resumes late or never (the first-class one-shot `resume` the cheatsheet documents) is not expressible across an instance boundary. The derived contract says so, and a producer needing those semantics keeps the `handle` inside the component. |
| `Async` | the export becomes `async func`; never an import (ADR-0089 D5) |
| `Exception[E]` | **`result<T, E>` on the export, with the `handle` generated in the lift** (§3.1); exactly one exception kind per export |
| two or more exception kinds on one export (`Exception[IoError] + Exception[ParseError]`, directly or through an effectset) | refused: one `result` has one error type, and choosing either kind would lose the other; the edit is to discharge into one payload type (an enum) in the body |
| a bare `Exception` / legacy `Error` with no payload type | refused: annotate the payload type, because `result<T, ?>` has no `?` |

**The host requirement of a `service` is the union over its exports.** A
component is one instance with one world, and every world import is
satisfied when the instance is created, whichever export is later called. So
a `service` that exports a pure `add` and an `Fs`-reaching `load` has an `fs`
import that a consumer of `add` alone must still see satisfied. The derived
contract therefore carries a `requires = <operations>` header line, and a
consumer that imports **anything** from the package takes that union into
its own row: `import @acme/greeter { add }` inside `fn main allows Console`
is refused naming the missing operation (or the
split — one package per authority — as the other edit).

**The union is over normalized OPERATIONS, not provider labels.** Authority
is the operation (ADR-0071 / ADR-0084), and a label denotes all of them, so
`requires = Fs` would make a consumer of a pure export grant the whole
filesystem to satisfy a package whose only reach is `Fs::read_file`. The
line therefore reads `requires = Fs::read_file, Env::get`, exactly the row a
`with` clause would carry, and `allows Fs::read_file` satisfies it. Per-export
rows still type each call (`Exception[E]`, `Async`); only the host
requirement is instance-level. This is ADR-0075's `Entry.requires ⊆ ComposedHost.provides`
applied to the instance it actually names.

### 3.1 `Exception[E]` projects to `result<T, E>`, in both directions

Decided by the owner, 2026-09-17.

This revises the boundary stance from #1324, which filtered exception labels
out of the world and let an escaping `throw` trap. That was the right call for
a generator that only *describes* a surface; for a component that a vibe
consumer calls transparently, a trap that drops `e` on the floor is a
degraded answer, and the transparent form is the one where the row survives
the crossing:

```vibe skip
// producer: greeter/index.vibe
export fn parse_port(s: String) -> Int with Exception[String] {
  if String::length(s) == 0 { throw("empty port") }
  8080
}
```

derives `parse-port: func(s: string) -> result<s64, string>` and a lift that
runs `handle { Ok(body) } with Exception[String] { Throw(e) => Err(e) }` — the
success branch is wrapped in `Ok` inside the handler, the shape
`lib/@vibe/wit_runtime/index.vpkg` already documents, so both arms have the
`Result[T, E]` type;
a vibe consumer sees `fn parse_port(s: String) -> Int with Exception[String]`
in the derived contract and a lowered shim that re-raises `Err(e)` as
`throw(e)`. A non-vibe consumer sees `result`. `E` must itself be admitted
(§2). An explicit `Result[T, E]` return stays legal for an author who wants
the two-track value visible on the vibe side; it projects to the same WIT, and
the derived contract records which spelling the producer used, so a vibe
consumer gets the producer's spelling back (§5).

The #1361 objection — a thunk-taking helper does not discharge the row at its
call site — is about a source-level helper. The lift is generated per export
by the compiler with the export's own row, which is exactly the "convert once,
in the export body" rule, done by the tool instead of by hand.

### 3.2 Optional grades

An optional grade (`with Fs::read_file?`) is a **core-module** fact: the
`vibe.capabilities` row and the `__vibe_granted$<label>` global live on the
core module, and a component host cannot write that global
(host-contract §2.3). A `perform?` inside a component would therefore read
the default `0` and answer `NotGranted` whatever the host intended — a
silently wrong answer, which is why `--component` **refuses** an optional
grade on the surface or anywhere the entry reaches, naming the two lifts
that would admit it (a WIT-exported grant, or a grant argument set before
the export is called). Until one of those exists, a component's world lists
required operations only.

## 4. Names and identity

- **Package id.** `index.vpkg`'s `name = @scope/pkg` and `version = x.y.z`
  become `scope:pkg@x.y.z`. A loose module is `vibe:app` with no version, as
  today.
- **Interface.** A `service` component exports one interface — its
  **facade interface**, the one `import @scope/pkg { .. }` binds on the vibe
  side. Its WIT name is the package's last segment (decided by the owner,
  2026-09-17): `@acme/greeter` → `acme:greeter/greeter@0.1.0`, the form WASI
  uses when a package has one main interface (`wasi:random/random`,
  `wasi:logging/logging`). A last segment that is not a WIT identifier after
  the kebab mapping is refused at build, naming the package. A consumer's
  world imports that id. World-level function exports (today's `--wit` output) are kept
  only for the loose `vibe:app` case, where there is no id to import by.
- **A package with several interfaces.** A vibe producer has one (its
  facade). A foreign package may have many (`wasi:http/handler`,
  `wasi:http/types`), and their function names may collide, so the vibe
  import path names the interface after the package: `import
  @wasi/http/handler { handle }`. The bare `import @scope/pkg { .. }` form is
  the facade interface, whichever spelling it has; a vibe producer's
  interface name is therefore never something a vibe consumer types.
- **Functions and fields**: `snake_case` ↔ `kebab-case`. **Types**:
  `CamelCase` ↔ `kebab-case` (`HttpReq` ↔ `http-req`). Both are mechanical
  inverses because vibe's own naming rules leave no ambiguity (functions are
  snake_case only, types are strict CamelCase); a name whose round trip does
  not reproduce it is refused at build rather than silently renamed.
- The derived vibe-facing contract carries the **original** vibe spellings, so
  vibe-to-vibe never needs the name round trip at all; only a foreign WIT
  package goes through the inverse.

## 5. What `vibe build --component` writes

One command, one source, two derived artifacts:

| artifact | what it is | rule |
|---|---|---|
| `<name>.component.wasm` | the component, carrying `vibe.entry` (kind, `core-export`, `component-export`), `vibe.abi` / `vibe.tagmode` as applicable, `vibe.capabilities` `used` rows, and **`vibe.contract`** — the derived vibe-facing contract as text: a `.vpkg` header with a `kind = component` directive plus the bodyless declarations of the surface, in the producer's own spellings. The wrap copies these sections out of the core into the component binary, as host-contract §2.3 has it copy `vibe.entry`, so a consumer reads them from the `.component.wasm`; a `.cwasm` is a host image and never a distribution format | the artifact is the truth; the section is what a consumer's `vibe add` extracts |
| `<name>.wit` | the sidecar: `to_wit(vibe.contract)` | a projection; `to_wit` of the section must equal it byte for byte (§8) |

Both under `.vibe/build/out/` by default (ADR-0111), `-o` for another path.
`--component` composes with nothing else: `--debug`, `--minify`, `--entry`
and `--wit` are refused by name as today, because each names a second
artifact or a second lane for the same file.

`vibe.contract` is a third derived artifact only in the sense that the WIT
sidecar is one; both come from the same signatures, and neither is ever
edited. It exists because WIT loses what vibe needs back — `Exception[E]`
versus explicit `Result`, the effect labels, vibe's own names, doc comments —
and because a consumer that pulled only the `.component.wasm` from a registry
must still get the exact vibe view.

## 6. Consuming a component from vibe

### 6.1 The store

`vibe add <spec>` of a component package materializes
`.vibe/store/@scope/pkg/` holding the `.component.wasm` and an `index.vpkg`
**extracted from its `vibe.contract` section**. That `.vpkg` is derived like
every other artifact here and is never edited. Two identities, both on
ADR-0093's line, and **they live in different directives**:

| identity | directive | what it hashes |
|---|---|---|
| package pin | `generated_hash = #pkg:b3:<64hex>`, and the `require` row in the consumer's `index.vpkg` | the extracted `.vpkg` **together with the component bytes**, so a component with different code and the same contract does not satisfy the pin |
| contract identity | `contract_hash = #ct:b3:<64hex>` (**new**) | the contract text alone — what a consumer was type-checked against, so a producer rebuild that keeps the contract is visible as such |

`generated_hash` keeps its package-pin domain because that is what the
parser admits: `scan_package_header` refuses anything but an empty value,
`#pkg:sha1:<40hex>` or `#pkg:b3:<64hex>` ("generated_hash must be empty or
…"), so a `ct:b3:` value there would make every installed component contract
fail to parse before linkage. The contract identity therefore needs its own
directive, and admitting `contract_hash` (empty or `#ct:b3:`) in
`scan_package_header` / `parse_contract_header` is a **prerequisite** of this
section, not a consequence of it. A contract-only pin would leave the
executable unpinned, which is the one thing a pin is for. `vibe add` refuses
an artifact whose section and sidecar disagree.

The loader's resolution rule does not change: it finds an `index.vpkg` under
the store exactly as for a source package. The one new fact it reads is the
`kind = component` directive, which switches linkage.

### 6.2 The import

```vibe skip
import @acme/greeter { greet, parse_port, Greeting }

fn main allows Console + Exception[String] {
  let g: Greeting = greet("vibe")
  println(g.text)
  let p = parse_port("")     // re-raises the producer's Err as Exception[String]
  ()
}
```

Same syntax, same checker: the calls are typed from the contract as with any
package. What differs is codegen. Each imported function lowers to a
canon-lowered import of `acme:greeter/greeter@0.1.0.<kebab-name>` plus a
generated shim between the raw ABI and the canonical one — strings and lists
copied, records and variants marshalled field by field, `Exception[E]`
re-raised from `result` (§3.1). The consumer's own artifact therefore
declares `import acme:greeter/greeter@0.1.0` in its world.

**A component dependency makes the consumer a component** (decided by the
owner, 2026-09-17, on the safe side: a refusal can be relaxed later, a
second linkage in the runner cannot be taken back). A core module has no
component imports, so a program that imports a component package cannot be
emitted as a core `.wasm`.

**An executable or test root takes the `wasi-command` form, derived, never
requested.** A `.vibex`'s `main` and the harness entry `vibe test` / `vibe
bench` synthesize match none of §1.3's three surface-derived kinds, because
none of them is a surface the author writes: they are roots. So the
dependency decides the form, not a flag — `kind=wasi-command`,
`core-export=_start`, `component-export=wasi:cli/run` (host-contract §2.3).
Explicit `vibe build --component <file.vibex>` stays refused (§1.1): that
asks for an export surface a `.vibex` does not have, which is a different
request from "this root depends on a component".

**That producer does not exist yet, and until it does the dependency is
refused on every lane.** §1.3 records that the two gates asserting
`export wasi:cli/run@0.2.6` call builder scripts no longer in the tree, so
nothing currently lifts a root to `wasi:cli/run`. Routing `vibe run` and
`vibe test` to a lane with no producer would promise a run that cannot
happen, so until the `wasi-command` producer lands, `build`, `run` and
`test` alike refuse a component dependency with one message naming the
package, the missing lane and this section. Building that producer is the
first item of any implementation of this convention, ahead of the store and
the shims.

### 6.3 Host capabilities take the same shim and the same linker

`Fs::read_file` inside a component is a call whose import the composer
resolves, exactly as `greet` is: the world's inline `fs` interface
(host-contract §1.3) is satisfied by the runner's own functions where
`acme:greeter/greeter` is satisfied by a store component. The difference is
only who provides the instance — there is no `kind = host` package, because
the world never imports a catalog interface whole and the runner registers
exactly the functions the world names. That is why the lazy CLI lane and
vibe-to-vibe consumption need one linker and one shim generator, not two —
and why a user algebraic effect in a producer's row (§3, "supplied by the
composer") is the same shape again: an interface the producer imports and
some other component exports. A `handle` around a component call in the
consumer cannot discharge it, because the producer runs in another instance;
the message says so and names the composition edit.

### 6.4 Running

`vibe run` and `vibe test` on a component consumer compose the instance graph
from the store and the runner's own host functions, then call the
`component-export` that `vibe.entry` names. The per-verb CLI manifest is the same graph with
the manifest naming the root. Producing a single deployable file from that
graph (`wac plug` today, by hand) is a packaging step this convention does
not decide; the compiler emits unlinked components and the store is where
their dependencies are.

## 7. Foreign WIT: the inverse projection

A package that is not vibe arrives as a `.wit` (and a component). `vibe add`
derives its `index.vpkg` with `from_wit`, the exact inverse of §2 / §4:

- `record` → `export struct`, `enum` → payload-less `export enum`, `variant` →
  `export enum` with payloads, `option` / `list` / `tuple` / `result` as in
  the table — except that a foreign `list<tuple<string, V>>` is
  `Array[(String, V)]`, never `Map[String, V]`: the foreign author did not
  write a map, duplicates are legal in the list, and only a vibe producer's
  own `vibe.contract` spelling brings a `Map` back (§2).
- **`result<T, E>` → `-> T with Exception[E]`**, the vibe idiom, because
  inside vibe failure belongs in the row (#1324). An author who wants the
  explicit `Result` can still write one on the producer side; only a foreign
  package has to pick a canonical reading, and this is it.
- a `resource` → an `opaque type` plus its methods as `fn`s taking the handle
  first, and an explicit `drop` function. A resource handle is not a vibe heap
  value, so RC does not free it; the consumer calls `drop`. That is the same
  discipline the raw lane already has for `http_close` / `tcp_close`, and it
  is the one place the inverse is honest about being less than transparent.
- a WIT type with no vibe mapping (`u8` outside `list<u8>`, `u64`, `s8`, ..,
  `flags`, `borrow<>`, a `future` / `stream` of a non-admitted payload) is
  refused at `vibe add`, naming the function and type, so an unusable
  package is refused when it is added and not when it is called.

WASI worlds (`wasi:http/service`, `wasi:cli/stdin`) take this path too; the
async ones are #2064 / #2832's subject and only their *reading* is decided
here.

## 8. The round-trip gate

Three laws, each with the mutation that must turn the gate red (#2248):

| law | statement | red test |
|---|---|---|
| **forward** | for every admitted contract `c`: `from_wit(to_wit(c)) == c` up to spelling recovered from `vibe.contract` | change one field type in an exported struct; the derived `.wit` and the section must change together, and a hand-edited sidecar must be refused |
| **inverse** | for every WIT in the admitted subset `w`: `to_wit(from_wit(w)) == w` after normalization | add a `u32` parameter to a fixture WIT; `vibe add` must refuse it naming the function |
| **agreement** | the component's export types, its `vibe.contract` section and its `.wit` sidecar describe the same functions | rename one export in the section only; the build must refuse to write the artifact |

Fixtures: the existing `fixtures/wit_gen_*.golden.wit` pairs become forward
cases; each refusal in §1–§3 gets a fixture whose message is asserted, not
merely its exit code; and one end-to-end pair — a producer package built as a
component, a consumer importing it by name, composed and run — pins the
transparent path with a value the consumer prints, on both runners.

## 9. Stability

The derived WIT is public surface. A change to it is a change to the package
version under the SemVer table in
[../../user/reference/stable-surface.md](../../user/reference/stable-surface.md)
(a removed or narrowed export is Major, an added one is Minor), and
**`contract_hash` is the surface pin** — the identity a consumer was
type-checked against (§6.1). `generated_hash` is not: it covers the
component bytes too, so an implementation-only rebuild changes it while the
WIT is identical, and reading it as the surface would report a contract
change where none occurred and reject a valid Patch. Because the contract is
derived, the version bump is checkable: the gate diffs the previous
published contract against the current one and refuses a Patch whose
`contract_hash` moved.

## What this decides

- One source of truth for a component: its exported vibe signatures. WIT and
  the vibe-facing contract are both outputs.
- The entry kind from the surface, three kinds, two reserved names.
- The admitted type subset as a bijection, with `struct` / `enum` added.
- `Exception[E]` crossing as `result<T, E>` with generated conversion on both
  sides (owner, 2026-09-17).
- Transparent consumption through the ordinary `import`, with the store
  holding a derived `.vpkg`, and host capabilities as the same mechanism.
- A component dependency makes the consumer a component, as a refusal on a
  core `vibe build` (owner, 2026-09-17, safe side).
- A boundary `struct` / `enum` must be `export`ed (owner, 2026-09-17).
- The facade interface is named after the package's last segment
  (owner, 2026-09-17).
- A package component is built from its `index.vpkg` surface; a loose module
  stays path-only. A `service`'s host requirement is the union over its
  exports and is taken by any consumer of the package. `command` / `handler`
  refuse a row that would change their fixed ABI; one exception kind per
  export; recursive boundary types refused; the store pin covers the
  component bytes, the contract identity the contract text.

## What it does not decide

- **Packaging a composed graph into one file.** `wac plug` by hand today.
- **Async imports** (#2064, #2832): read by §7, lowered elsewhere.
- **A `wasi:cli/run` kind.** No producer in the tree at the moment.
- **Resource lifetimes under RC.** Explicit `drop` in this version.

## Open for the owner

Nothing. The four items this document put to the owner — `Exception[E]` →
`result<T, E>`, a component dependency making the consumer a component, the
`export` requirement on a boundary type, and the facade interface's name —
were decided on 2026-09-17 and are recorded where each applies (§3.1, §6.2,
§2, §4). The naming comparison that informed the last one: the package's
last segment is the derived answer, has WASI's one-main-interface precedent,
and carries more information in the one place a person reads it; a fixed
`api` would only have bought "find the main interface without knowing the
package", which `vibe.entry`'s `component-export` already answers.
