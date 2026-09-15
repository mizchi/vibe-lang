# Capability host contract: the not-granted stub, and the grant a host sets at instantiate

Status: proposed — [#2825](https://github.com/mizchi/vibe-lang/issues/2825)
step 1, the blocker in front of the `perform?` lowering change.

Date: 2026-09-15

Related: ADR-0088 (amended 2026-09-15 — `perform?` becomes an instantiate-time
branch), ADR-0075 (`Entry.requires ⊆ ComposedHost.provides`), ADR-0086
([compiler-host-boundary.md](compiler-host-boundary.md) — the *compiler's own*
host boundary, a sibling surface with the same two implementations),
[effect-wit-mapping.md](effect-wit-mapping.md).

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

## What the hosts do today — measured, not read

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
| `scripts/wasm_vibe_host_runner.js` | **instantiates, and the call answers `0`** |

All 18 capabilities, both shapes, same answer each: `refused` / `silent`.

viberun's own source states its half in two places, so this is not a surprise
there — "Without this import a program using `Env::args_len` fails to
instantiate with an unknown import before user code runs".

The node runner's half was not stated anywhere. Its `vibe` import module is a
`Proxy` whose `get` handler ends `return () => 0n;`, so **a capability the
runner does not implement is not absent — it is present and answers zero**.

### This is not a live wrong answer today, and that is the point

`docs/generated/host-runtime-contract.json` already partitions all 59 emitted import
fields into bands, and `scripts/check_host_runtime_contract.py` enforces them
fail-closed (`pkf run check-host-runtime-contract`, measured ok at `945d755`:
59 static imports, 49 portable):

| band | count | who provides it |
|---|---:|---|
| `portableCore` | 49 | **both** runners, required |
| `nodeCoreOnly` | 1 | the node runner only (`resolve_path`) |
| `viberunDebugOnly` | 2 | viberun only (`dbg_break`, `dbg_line`) |
| `componentAdapterOnly` | 7 | the component adapter; the gate REJECTS these leaking into either standalone runner |

So the fallback is not silently answering a capability some in-contract module
asked for — every `portableCore` name is implemented on both sides, and the
gate proves it. The fallback is what lets an out-of-band module (one carrying
`componentAdapterOnly` imports, say) instantiate under the node runner anyway,
answering `0`, where viberun refuses.

What the measurement actually establishes is narrower and more useful:

> **Neither host can express "linkable, but not callable".** The node runner
> cannot refuse — deleting a method from `vibeModule` does not withhold the
> capability, it makes the capability answer `0`. viberun cannot do anything
> *but* refuse — an import it does not register makes the whole module fail to
> instantiate.

That is precisely the shape an optional capability needs. #2825 §4 predicted
the blocker as "the module stops instantiating"; that is viberun's half. The
node runner's half is the opposite and worse — it would keep going and hand the
program a zero — and it is invisible from either runner's source, because
nothing in the contract has ever needed to distinguish a capability a host
*withholds* from one it does not implement. Until `perform?` is a branch,
nothing ever withholds.

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
- **The default is fail-closed and is exactly today's behaviour.** A host that
  does nothing leaves every global `0`, so every `perform?` takes `NotGranted`
  — which is what a production compile does today, since `linked_compile`
  passes an empty resolution table and `opq_resolution` defaults to
  `NotGranted`. The lowering change is therefore behaviour-preserving for every
  existing host, including ones nobody in this repo controls.
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

Step 1 is the rung ADR-0075 calls preflight and #2332 still lists as
outstanding. It becomes implementable here because the section plus the
manifest are together the machine-readable form of `Entry.requires`.

## What each host has to change

| | `scripts/wasm_vibe_host_runner.js` | `runtime/viberun` | a component host (WIT) |
|---|---|---|---|
| read `vibe.capabilities` | new | new | new |
| a way to withhold at all | **new** — today every `vibe.*` field resolves, implemented or not | it has one: do not register the import | the composed host chooses what it provides |
| refusal names the capability | new (today: nothing to name — it never refuses) | new (today: wasmtime's raw "unknown import") | ADR-0075 preflight |
| trapping stub for a withheld optional | **new** — reuse the `policy raw import denied` throw in the `vibe` proxy handler, in place of `() => 0n` | **new** — `Linker::func_new` returning `Err`, in place of not registering | a stub implementation in the composed host |
| write the grant globals | `instance.exports["__vibe_granted$L"].value = 1n` | `Instance::get_global(..).set(..)` | component-model global, or a host-set config value |

The WIT surface needs the third row to be expressible: `Entry.requires` has to
admit an optional import whose provider is a stub, which is the amendment's
"ADR-0075's rule has to admit a not-granted stub". Nothing here needs a new
WIT *type* — an optional capability is the same interface, provided by a
different implementation.

## What of this has landed

Design, plus the one piece the measurement justifies on its own — a host has to
be able to withhold a capability before any of the rest can be tested.

| | state |
|---|---|
| the measurement, re-runnable | `node scripts/host_capability_probe.mjs <wasm>`, unit-tested in `scripts/host_capability_probe.test.mjs` (`pkf run test-host-capability-probe`) |
| node runner can withhold | **landed** — `VIBE_HOST_WITHHOLD=<import-field>[,...]` links a trapping stub in place of the implementation |
| viberun can withhold | **landed** — the same variable; `Linker::func_new` shadows the real implementation with a stub whose type comes from the module's own import section, so no list here can drift from the 59 fields the emitter can produce |
| the trap is proven to fire | **landed** — `scripts/host_capability_withhold_test.sh` (`pkf run test-host-capability-withhold`, and in `tests/gates/selftests/run.sh`) runs both runners: the granted run reads the file, the withheld run traps by name *after* instantiating (asserted via the wasm frame in the backtrace, so a link failure cannot pass for a stub) and prints no value. The node half also carries a source mutation — with the withhold branch removed, the same run succeeds — which pins the trap to that branch. The viberun half has the env-var control only: rebuilding the Rust runner per case costs ~80 s, so the counterfactual is the same binary and wasm with only the variable differing. Verified once by hand at the rebuild: with the stub never installed, the withheld run prints `read: apple` and the gate fails on it |
| `vibe.capabilities` section | not done — nothing emits an `optional` row until the lowering does |
| grant globals | not done — same reason |
| required-capability preflight | not done |

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
  manifest, a `BindingLock` (ADR-0075 L2). That is #2332's rung, and the
  contract above is the same whichever way it is answered.
- **`Errored(E)`.** A catchable host-failure ABI is listed in ADR-0088 as
  outstanding and is untouched here; the stub traps, it does not produce
  `Errored`.

## Open for the owner

1. **Whether the absence of an `optional` row is the right default.** The
   contract above reads "no row" as required, so a module built before it, and
   a module built after it with nothing optional, are treated the same and
   correctly. The cost is that the section cannot distinguish "this compiler
   emits rows and had none to emit" from "this compiler predates rows"; if a
   future grade needs that distinction, the `version=1` line is where it goes.
2. **Whether a withheld required capability should refuse or should be
   permitted to degrade.** The table above refuses. The alternative — treat
   every capability as optional, so a program always runs and always branches —
   erases the distinction between "this program asked for permission" and "this
   program needs it", and is not what ADR-0088's `?` grade means.
3. **Whether the node runner's `() => 0n` fallback should survive at all.** It
   is out of band for every import the manifest names, and it is the reason
   that runner cannot withhold anything. Replacing it with a throw is a
   one-line change with a blast radius nobody has measured: it is what lets an
   out-of-band module (`componentAdapterOnly` imports under the node runner)
   run at all today. Doing it is independent of the lowering and is the
   smallest item on this page.
