# Capability host contract: the not-granted stub, and the grant a host sets at instantiate

Status: partial. Hosts can withhold a capability, and `vibe run` resolves
`perform?` from the grant its launcher froze. The instantiate-time half — the
`vibe.capabilities` section and the `__vibe_granted$<label>` globals that let
`perform?` keep both arms — is designed here and not built; it is step 1 of
[#2825](https://github.com/mizchi/vibe-lang/issues/2825)'s sequence, in front
of the lowering change.

Date: 2026-09-15

Related: ADR-0088 (amended 2026-09-15 — `perform?` becomes an instantiate-time
branch; [capability-authorization-surface.md](capability-authorization-surface.md)
§4), ADR-0075 (`Entry.requires ⊆ ComposedHost.provides`), ADR-0086
([compiler-host-boundary.md](compiler-host-boundary.md) — the *compiler's own*
host boundary, a sibling surface with the same two implementations),
[effect-wit-mapping.md](effect-wit-mapping.md).

## Where this stands

A `perform?` is still resolved at **compile** time. The lowering selects one
arm from a frozen grant table and erases the other, together with the host
import only that arm called:

- `vibe run` freezes the table from its L1 flags (`--allow-*` / `--deny-*`;
  no flag grants every standard provider), #2828 rung 2;
- a `test` / `bench` / `example` artifact resolves every optional grant to
  `Granted`;
- `vibe build`, `compile` and `serve` pass no launcher grant, so every
  optional capability resolves `NotGranted` there.

The required side is settled before the module is built: `vibe run` refuses a
required capability its flags withhold, naming the flag (#2828 rung 1). Both
runners can withhold a capability by import field (`VIBE_HOST_WITHHOLD`), and
the withheld import traps when called.

What does not exist yet is everything a HOST would need to decide an optional
grant itself: no compiler emits `vibe.capabilities` or a grant global, and no
runner reads them. The rest of this document is that contract.

## What the amendment takes away

Today an ungranted `perform?` is erased at compile time. The erasure does two
jobs, and only one of them is the one anybody asked for:

1. it selects the `NotGranted` arm — the job;
2. it also removes the granted arm's **host import**, so the module's import
   list happens to match the granted set.

ADR-0088's amendment keeps both arms in the emitted code so a body stops
depending on the build's grants — which is the whole point, because a
capability-independent body is one two consumers with different `--allow-*` can
share, and one the codegen body cache can replay (#2825 §3, #2507). Job 2 is
collateral: the module now declares an import for a capability the host may
withhold.

So before any lowering change, two questions need an answer that does not
depend on which runner you happen to be using:

- **Linking**: what does a host do with a capability import it withholds?
- **Selection**: how does the module learn, before `main`, which optional
  capabilities were granted?

## What the hosts do with an import they do not provide

Measured on `945d755`, against a stage2 built from that checkout
(`_build/selfhost/generations/bytes-capacity-2026-09-15_945d755/stage2.wasm`,
18 `vibe.*` capability imports). Reproduce with:

```bash
node scripts/host_capability_probe.mjs <stage2.wasm>
```

The probe links the real artifact against a host that provides everything
except one capability, once per capability, and reports what happened.

| host | a `vibe.*` capability import it does not provide |
|---|---|
| a strict host (a plain import object) | **refuses to instantiate** — `LinkError: ... module="vibe" function="env-get": function import requires a callable` |
| `runtime/viberun` (wasmtime `Linker`) | **refuses to instantiate** — unknown import, before user code runs |
| `scripts/wasm_vibe_host_runner.js` | **instantiates; a call throws**, naming the import |

All 18 capabilities, both shapes, same answer each. The node runner's row is
pinned by `scripts/wasm_vibe_host_runner_unknown_import.test.cjs`.

viberun's own source states its half in two places, so this is not a surprise
there — "Without this import a program using `Env::args_len` fails to
instantiate with an unknown import before user code runs".

The node runner's `vibe` import module is a `Proxy` whose `get` handler ends
in a stub that throws on call, naming the import and the lane that serves it
(`unimplementedImportStub` in `scripts/wasm_vibe_host_runtime.js`). A
withheld name (§2) and the async imports #2928 refuses are answered before it
with their own messages. The module still instantiates, so a name it links but
never calls costs nothing.

### Which modules reach the fallback

`docs/generated/host-runtime-contract.json` partitions every emitted import
field into bands, and `scripts/check_host_runtime_contract.py` enforces them
fail-closed (run in the compiler gate's mid lane, with its mutation suite under
`pkf run test-check-host-runtime-contract`). The manifest today holds 68
static fields and 5 name patterns:

| band | count | who provides it |
|---|---:|---|
| `portableCore` | 49 | **both** runners, required |
| `nodeCoreOnly` | 1 | the node runner only (`resolve_path`) |
| `viberunDebugOnly` | 2 | viberun only (`dbg_break`, `dbg_line`) |
| `componentAdapterOnly` | 16 + 5 patterns | the component adapter; the gate REJECTS these leaking into either standalone runner |

So no in-contract module reaches the fallback: every `portableCore` name is
implemented on both sides, and the gate proves it. The fallback is what lets an
out-of-band module (one carrying `componentAdapterOnly` imports, say)
instantiate under the node runner, where viberun refuses, and a call to such an
import throws.

> **"Linkable, but not callable" is the answer an optional capability needs.**
> viberun alone cannot give it: an import it does not register makes the whole
> module fail to instantiate. `VIBE_HOST_WITHHOLD` (see *What of this has
> landed*) gives both runners that answer for a withheld capability, and the
> node runner's fallback gives the same shape, a trap on call, for an import it
> does not implement.

#2825 §4 predicted the blocker as "the module stops instantiating"; that is
viberun's half. Until `perform?` is a branch, nothing but the withholding gate
ever withholds.

## The contract

### 1. The band is already global; only "optional" is per-module

The instinct here is a grade table in the compiler — `capability` vs
`instrumentation` — so a host can tell `fs_read_file` answering `0` (a silent
wrong answer) from `dbg_line` answering `0` (a no-op, correct). That table
already exists, as `docs/generated/host-runtime-contract.json`'s bands, with a
fail-closed gate on it and both runners checked against it. Adding a second one
in the compiler would be a second source of truth for a fact this repo already
pins, and #2759 is about there being too many of those, not too few.

What the manifest cannot carry is the fact that is **per module and decided by
the build**: which of the capability imports this particular module declares
are reachable only from the granted arm of a `perform?`. A module compiled with
`Fs::read_file` granted and one compiled with it optional declare the same
import; only the second one is safe to withhold.

So the module declares that, and only that. A new custom section,
`vibe.capabilities`, ASCII, `\n`-terminated lines in the shape `vibe.abi`
already uses:

```
version=1
optional\tHttp::fetch\tvibe\thttp_request\t__vibe_granted$Http::fetch
```

Fields, tab-separated: grade, capability label, import module, import field,
and the name of the grant global (§3). Every `vibe.*` import with no row is
**required** — the fail-closed reading, and the reading that keeps a module
built before this contract correct without a version check, since such a module
has no optional imports at all. A capability import is emitted only when the
program still calls the builtin after late DCE (`collect_used_builtin_names`
runs after `dce_stmts`), so "declared" and "reachable" mean the same thing here.

The rows are derived from the lowering that emitted the branch, so the section
cannot disagree with the code: the same pass that chooses a dynamic branch over
an erasure is the one that records the row.

### 2. Not-granted stub: a withheld capability traps, it never answers

For an import the module declares `optional` and the host withholds, the host
links a **stub of the same type that traps when called**. Not absent
(the module would not instantiate, and refusing to run a program whose
`NotGranted` arm is exactly what it asked for is wrong), and never a value.

The stub is unreachable in a correct program: the branch that calls it is the
granted arm, and the grant global that selects it is `0`. It exists so that
*linking* succeeds, and it traps so that a mistake anywhere else in this
contract — a grant global the host forgot to clear, a lowering that selected
the wrong arm — surfaces as a trap naming the capability instead of as a zero
flowing into user data.

`scripts/wasm_vibe_host_runner.js` already has the shape this needs and the
message to match: `policy raw import denied: ${name}`, thrown from the same
proxy handler that currently answers `0`.

For a required capability — any `vibe.*` import with no `optional` row —
withholding is refusal: the host reports the capability by name and does not
instantiate. That is ADR-0075's
`Entry.requires ⊆ ComposedHost.provides` preflight, now answerable from the
section without decoding the import section semantically.

### 3. The grant the host sets before `main`

One **exported mutable `i64` global per optional capability**, named
`__vibe_granted$<label>`, initialised to `0`. The host writes `1` before
calling the entry; the `perform?` branch reads it.

Chosen over the alternatives for four reasons:

- **No import-surface change.** A grant delivered as an imported global or a
  query function is itself an import, so an old host fails to link a module it
  could otherwise have run correctly.
- **The default is fail-closed.** A host that does nothing leaves every global
  `0`, so every `perform?` takes `NotGranted` — what a compile with no launcher
  grant (`vibe build`) produces today, since `opq_resolution` defaults to
  `NotGranted` on an empty table. A host that knows nothing of this contract
  therefore sees the behaviour of today's `vibe build` artifacts, including
  hosts nobody in this repo controls.
- **No cap and no ordering dependency.** A bitmask over an ordered label list
  is smaller, and it breaks silently at 64 labels and on any reordering.
- **Host-enumerable without the section.** `WebAssembly.Module.exports` and
  wasmtime's `Instance` both enumerate globals by name, so a host can find the
  grant set even if it ignores `vibe.capabilities` entirely.

Authorization is still settled once and never changes mid-run (ADR-0088): the
host writes the globals before the entry and nothing writes them again. Making
them writable *during* the run would break that, so a host that exposes the
globals to program-reachable code is out of contract.

### 4. Preflight, and what it can now answer

Before instantiating, a host reads `vibe.capabilities` and:

1. every `vibe.*` import with no `optional` row that it does not provide →
   refuse, naming the capability and the grant that would fix it;
2. every `optional` row it withholds → link a trapping stub, leave
   `__vibe_granted$<label>` at `0`;
3. every `optional` row it grants → link the real implementation, write `1`;
4. every import outside `portableCore` that it does not provide → the band in
   `docs/generated/host-runtime-contract.json` already decides this, and nothing
   here changes it.

Step 1 is the rung ADR-0075 calls preflight. `vibe run` already performs it
from its own L1 flags, before the module is built (#2828 rung 1); the section
plus the manifest are what would let any host answer it from the artifact
alone, since together they are the machine-readable form of
`Entry.requires`.

## What each host has to change

| | `scripts/wasm_vibe_host_runner.js` | `runtime/viberun` | a component host (WIT) |
|---|---|---|---|
| read `vibe.capabilities` | new | new | new |
| a way to withhold at all | **landed** — `VIBE_HOST_WITHHOLD`, checked before the implemented methods | it had one (do not register the import); `VIBE_HOST_WITHHOLD` adds the linkable form | the composed host chooses what it provides |
| refusal names the capability | new (it never refuses an unknown field; it answers `0`) | new (today: wasmtime's raw "unknown import") | ADR-0075 preflight |
| trapping stub for a withheld optional | **landed** — `capabilityWithheldStub` throws `vibe capability withheld: <field>` | **landed** — `Linker::func_new` with the module's own import type, returning `Err` | a stub implementation in the composed host |
| write the grant globals | `instance.exports["__vibe_granted$L"].value = 1n` | `Instance::get_global(..).set(..)` | component-model global, or a host-set config value |

The WIT surface needs the third row to be expressible: `Entry.requires` has to
admit an optional import whose provider is a stub, which is the amendment's
"ADR-0075's rule has to admit a not-granted stub". Nothing here needs a new
WIT *type* — an optional capability is the same interface, provided by a
different implementation.

## What of this has landed

Design, plus three pieces: withholding on both runners, which the measurement
above justifies on its own (a host has to be able to withhold a capability
before any of the rest can be tested); the required-capability preflight
(#2828 rung 1), which needed neither the section nor the globals because a
REQUIRED capability is decided before the module is built; and the launcher's
frozen grant reaching `perform?` on `vibe run` (#2828 rung 2). Measured on one
program reading a file that exists:

| flags | `perform? Fs::read_file(..)` |
|---|---|
| *(none)* | `Granted` — ambient authority, matching the preflight |
| `--allow-stdout` | `NotGranted` — an allow-list is a list |
| `--allow-fs --allow-stdout` | `Granted`, and the call runs |
| `--deny-fs --allow-stdout` | `NotGranted` |
| `--allow-fs --deny-fs` | `NotGranted` — deny beats allow |

Before rung 2 every row answered `NotGranted`: the `Granted` and `Errored` arms
were dead code in every program that wrote them.

### The frozen-grant constant (#1346 criterion 4)

What the launcher freezes is a table of `(name, status)` rows, `status` being
`Granted` or `NotGranted` and nothing else — any other spelling is a build
error, not a silent default. `opq_resolution` reads it in three tiers: an exact
operation (`Fs::read_file`), then the PROVIDER (`Fs`), then the `"*"` row, whose
absence means `NotGranted`.

That ordering is what makes the table fail-closed **by construction**: a granted
provider needs a row, a denied one needs none, and a provider nobody thought
about cannot be granted by omission. `optional_grants_from_flags` therefore
emits one `(provider, "Granted")` row per granted provider and nothing for the
rest; with no flags the granted set is every standard provider, which is the
same ambient authority the L3 preflight already assumes.

**The grant is a property of the run, not of the allocator.** Every arm of
`compile_release_lane` carries the same table, so `VIBE_RC=0`, `shadow` and the
default answer alike. `check_capability_preflight.sh` case 11 pins it by naming
the three lanes rather than inheriting one, because the first wiring reached
only the default arm.

### The denied-operation stub (#1346 criterion 4)

A capability the run did not grant is not linked, not called, and not trapped at
the optional surface: the lowering replaces the whole `perform?` expression with
the `NotGranted` constructor, so the artifact never imports the host function on
that path. The trapping stub described in section 2 is the REQUIRED surface's
answer — a host withholding something the module declared it needs — and the two
must not be confused. Optional means the program branches; required means the
run does not start.

`Errored(E)` is reachable as of this rung, and it did not need an ABI to become
so. `opq_expr` only builds the `EHandle` whose arm constructs
`$vibe_attempt_errored` on the `Granted` branch, so while nothing resolved to
`Granted` that arm was never emitted. A catchable host-failure ABI is still
outstanding (below); what is fixed here is that the branch now exists.

| | state |
|---|---|
| the measurement, re-runnable | `node scripts/host_capability_probe.mjs <wasm>`, unit-tested by `node --test scripts/host_capability_probe.test.mjs` |
| node runner can withhold | **landed** — `VIBE_HOST_WITHHOLD=<import-field>[,...]` links a trapping stub in place of the implementation |
| viberun can withhold | **landed** — the same variable; `Linker::func_new` shadows the real implementation with a stub whose type comes from the module's own import section, so no list here can drift from the fields the emitter can produce |
| the trap is proven to fire | **landed** — `scripts/host_capability_withhold_test.sh` (`pkf run test-host-capability-withhold`, and in `tests/gates/selftests/run.sh`) runs both runners: the granted run reads the file, the withheld run traps by name *after* instantiating (asserted via the wasm frame in the backtrace, so a link failure cannot pass for a stub) and prints no value. The node half also carries a source mutation — with the withhold branch removed, the same run succeeds — which pins the trap to that branch. The viberun half has the env-var control only: rebuilding the Rust runner per case costs ~80 s, so the counterfactual is the same binary and wasm with only the variable differing. Verified once by hand at the rebuild: with the stub never installed, the withheld run prints `read: apple` and the gate fails on it |
| `vibe.capabilities` section | not done — nothing emits an `optional` row until the lowering does |
| grant globals | not done — same reason |
| optional-capability grants reach the lowering | **landed for `vibe run`** (#2828 rung 2) — `optional_grants_from_flags` turns the L1 flags into the frozen-grant table above and threads it to `optional_perform_artifact_resolution` on every allocator lane. Pinned by `check_capability_preflight.sh` cases 7–11, whose red input is a real pre-rung-2 stage2 rather than a mutation |
| required-capability preflight | **landed for `vibe run`** (#2828 rung 1) — `preflight_instantiate` runs before the artifact is built, and a required authority the host does not grant aborts naming both edits (`--allow-fs`, and the `allows X?` alternative). It takes the REFUSE side of the question in *Decided* below. Driven by L1 flags (`--allow-*` / `--deny-*`, new in the same rung); it does NOT read the section or the globals, because neither is emitted yet. No flag leaves every provider granted, so an existing program is unaffected. Pinned by `scripts/check_capability_preflight.sh` and its red test |

Withholding is named by the wasm **import field** (`fs_read_file`), not the
capability label (`Fs::read_file`), because the field is what the module
declares and what a host links against. Once the section exists, a host can
map one to the other; until then the field is the only name both sides have.

## What this does not decide

- **The lowering** (#2825 next-sequence step 2). This document says what the
  emitted module declares and what a host does with it; it does not say how
  `lowering/effects/optional/optional.vibe` emits the branch.
- **The checker change** (step 3), which is breaking and needs its own
  migration note.
- **Who decides the grant.** The host reads it from somewhere — a CLI flag, a
  manifest, a `BindingLock` (ADR-0075 L2). `vibe run` answers with its L1
  flags today; a persisted L2 `BindingLock` has no `apply` phase to be written
  in and no open owner. The contract above is the same whichever way it is
  answered.
- **`Errored(E)`'s ABI.** The branch is reachable as of rung 2, but a catchable
  host-failure ABI is outstanding (ADR-0088 §4, no open owner) and is untouched
  here: the required-surface stub traps, it does not produce `Errored`.

## Decided

**A withheld required capability refuses; it does not degrade.** Treating
every capability as optional, so a program always runs and always branches,
would erase the distinction between "this program asked for permission" and
"this program needs it", which is not what ADR-0088's `?` grade means. `vibe
run`'s preflight (#2828 rung 1) implements the refusal.

## Open

1. **Whether the absence of an `optional` row is the right default.** The
   contract above reads "no row" as required, so a module built before it, and
   a module built after it with nothing optional, are treated the same and
   correctly. The cost is that the section cannot distinguish "this compiler
   emits rows and had none to emit" from "this compiler predates rows"; if a
   future grade needs that distinction, the `version=1` line is where it goes.
   Decided when the section is first emitted (#2825).
