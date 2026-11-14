# Incremental build design

Status: design and measurement plan. The current compiler has persistent loader
and type-environment caches, and `vibe run` / `build` / `test` replay the
finished module of an exact no-op (the linked-output memo below). After an edit
the final build still merges and code-generates the whole program. This
document defines the user-visible target before changing that architecture.

Related documents:

- [Build cache layering](build-cache.md)
- [Compiler parallelism](../design/compiler-parallelism.md)
- [Bootstrap and generation builds](bootstrap.md)
- [Editor and LSP behavior](../../user/reference/editor-and-debugging.md)
- [Component Model target](../compiler/vibec-component.md)
- [Lean formal model](../../../formal/README.md)

## Goals and non-goals

The primary goal is to reduce the latency a user observes after an edit. Compiler
selfbuild is an important large-project workload, but is not a substitute for
measuring ordinary projects.

The first implementation step is measurement. It must not change cache keys or
claim file-level code generation is safe. Generated compiler bundles are neither
benchmark inputs to edit cases nor files that the benchmark may update.

## Roadmap invariants

These hold across every phase of the production roadmap (#1379). They are
constraints on *how* a slice may be built, not a list of work items; changing one
is an ADR-sized decision, not a slice-sized one.

**Identity**

- A physical file is an ingestion/cache shard. Type checking and codegen reuse are
  keyed on the **semantic module**, and eventually the declaration SCC — not on the
  file.
- **mtime is a hint, never a semantic identity.** Its only job is to let the
  compiler skip *recomputing* a content identity. A stat-token match may reuse a
  previously computed source fingerprint; it may not stand in for one.
- **Git commit/author/last-modified dates are never content identity.** A Git
  blob OID is only an evaluation candidate, not production authority: filters,
  line-ending conversion, racy index state, linked/split indexes, hash formats,
  and repository availability can make it differ from the bytes actually
  ingested by the compiler. Production continues to use current working-tree
  bytes and behaves identically outside a Git repository.
- Do not conflate `source_fingerprint`, `implementation_fingerprint`,
  `interface_fingerprint`, `checked_env_fingerprint`, normalized typed-IR
  identity, and artifact-input identity. They answer different questions and
  invalidate on different edits.

**Safety**

- **A synthesized top-level definition carries the module that owns it, and a
  consumer reads that owner rather than inferring it from a position.** A
  per-module prelude places each module's synthesized helpers among its own
  statements, so a positional guess about which file a definition came from is
  wrong for exactly the definitions the split created (#2618, #2620).
- **A synthesized definition's NAME must determine its BODY.** The link folds
  per-module helpers by declaration key, so two modules that mint one name for
  two different bodies leave the link a choice it cannot make correctly. A
  comparator broke this — its body depended on how much of a field's type the
  synthesizing module could see (#2631, fixed) — and the fold refusing such a
  pair rather than keeping one of them is what caught it. See "What a module
  must see" below.
- A **missing required recheck is a failure.** Conservative over-invalidation is
  permitted but must be *visible* — reported as residual, never silently accepted
  as conformance.
- The Lean model covers cache-key eligibility and required invalidation. It does
  not claim to prove the compiler's semantics; the current over-invalidation is
  not evidence of planner conformance.
- Publish an artifact only after a successful computation. Failure, cancellation,
  and crash publish nothing — no artifacts, no diagnostics.
- Malformed, truncated, stale, or torn cache state fails closed to a cold full
  check. Never implicitly upgrade an older transport.

**Process**

- Switching from observation to production reuse is staged: shadow first, then
  feature-flagged, then default — with cold/warm parity and the oracle bridge
  green before each step.
- Benchmarks and oracles use a temporary workdir and an isolated cache. They never
  edit a tracked fixture while running.
- Do not paper over missing provenance in a full trait observation by reparsing
  and reprinting source.

### Shadow-only checked module typing aggregate v1/v2 (#1550)

`CheckedModuleTypingArtifact` remains a bounded checker/artifacts experiment, not a
production incremental-build input. `CheckedProgram` remains transparent and
manually constructible in this slice. Consequently neither the schema nor the
`shadow_unattested_checked_module_typing_artifact_from_checked_program` builder
cryptographically or type-system-proves that checking succeeded. The builder
checks only metadata shape and byte agreement with a supplied
`CheckedExportedInterfaceArtifact` v1; manually constructed matching inputs can
produce an artifact. The codec embeds those exact canonical interface bytes and
validates them by strict decode/re-encode.

The v1 commit unit is exactly one semantic module and therefore one singleton
SCC. Multi-member declaration SCC production requires a later producer and
schema revision. Its ordered dependency rows contain only semantic locators and
exported-interface fingerprints, preserving import order and duplicate
occurrences. A separate recorded implementation closure contains the owner and
is sorted lexicographically by semantic locator; duplicate locators are invalid.
Dependency implementations appear in that closure only when actually embedded
or referenced, so interface assumptions and implementation freshness are never
conflated.

Own and closure implementation identities use a closed tag:
`provisional_token_stream_v1` or `validated_metadata_v1`. The former is explicit
conservative syntax identity, not normalized typed IR. All implementation and
dependency identities use the exact positive-length compact fingerprint shape;
the two hash components are bounded by 2147483646 and 2147483628 respectively.
Canonical empty diagnostics mean only a caller-attested successful typing-error
set with the fixed ordering and scope `path,start,end,code,message`; they are not
proof that checking ran. Non-empty structured diagnostics, warnings, and CLI/LSP
diagnostic completeness are ineligible. Checked body state is only
`ineligible:lossless_checked_body_unavailable_v1`—there is no TypeEnv target or
fabricated typed-IR/body reference.

V2 preserves the complete v1 encoding unchanged and adds two separately tagged
identities derived from the same already-ingested `ModuleJob.source`: exact
`compact_string_fingerprint(ingested_source)` and the provisional parser-visible
`provisional_token_stream_v1`. The v2 unattested builder requires observed and
recorded claims to agree and still validates the implementation-closure owner.
The opaque opt-in runtime producer derives both values only after successful
checking. Ordinary `check_module` makes no artifact construction attempt;
diagnosed opt-in checks also make none; successful opt-in checks make exactly
one. An explicit in-memory validator can compare retained v2 bytes with one
current `ModuleJob.path/source/dep_envs`. It recomputes both identities from the
already-ingested source and requires ordered dependency assumptions plus exactly
the singleton owner closure. Success returns an opaque freshness attestation
bound to the exact retained bytes; its snapshot accessor returns those bytes
without decoding or re-encoding. Only an opaque successful `ModuleOutcome` can
mint it—decoded or manually authored bytes cannot. V1, malformed, stale, missing,
diagnosed, or wider-closure inputs return `None`. The legacy `Bool` observation
is only a wrapper over this attestation path. Ordinary checks never enter this
validator. Its attempt counter is test observation, not production telemetry.

The aggregate and its complete-encoding fingerprint are shadow comparison data
only. They are not wired to TypeDb, the TypeEnv v9 transport and persistent cache
namespace v19, TDRE5, interface-v7, artifact-input traces, planner decisions,
reuse, CLI, or a persistent cache namespace. Decoded values establish canonical
bytes, not a checker invocation. Runtime retains v2 bytes only in an opaque,
in-memory successful `ModuleOutcome`; it does not publish or persist them.

## What a module must see (#2388, #2575 item 2)

The per-module prelude is measured by an oracle that runs every pre-codegen
pass twice over the same program: once whole, once on each file alone, then
links the per-module results and compares by declaration key
(`prelude_module_full_oracle_report_fs`). What each file is given as *context*
decides what its green means.

That context is each module's own direct imports **plus everything reachable
across re-export edges** (`exact_import_closure`, #2658) — the same closure
production's `ordinary_lane_module_split` builds. Both come from the loader's
header scan (`load_or_parse_module_header_fs` — the same scan the FS typecheck
lane plans module order with), with a dependency that names a `.vpkg` contract
expanded to that package's sibling implementations, and the re-export subset
from `module_reexport_deps_fs`. It has to come from the loader because the merge
drops `SImport` / `SReExport` as already resolved, so the edges cannot be read
back off the merged program. The counters only mean what they say under a rule
that matches a real compile; what that takes is
[The context rule](#the-context-rule) below.

**Re-export edges, not transitive.** Closing transitively hands A the
declarations of a module C that A's dependency B imports *privately* — context
no real compile of A exposes. Closing across **re-export** edges is a different
thing: what B re-exports is precisely what a real compile of A does see, so
including it is not a widening at all.

The oracle measured on direct edges only until #2633, on the reasoning that for
a measurement, being handed context a module lacks is the one failure mode that
makes a green meaningless. That reasoning is sound and does not apply here: it
was written against the transitive rule. Measuring *without* the re-export edges
made the oracle solve a harder problem than the thing it models, and part of its
residue was an artifact of that. Adopting the exact closure on the compiler's own
CLI closure (369 modules) took `keyed content` 1 → 0 and `CTX unresolved_exp`
83 → 0, with `missing` / `extra` / `collisions` already 0 and the `seen`
denominator unchanged at 25 556 — the per-module lane reproducing the
whole-program prelude exactly.

`edges_unresolved` is reported for its own reason: a dropped edge narrows a
module's context further, and a closure built from every edge and one built from
half of them otherwise look identical.

### The production split lane, compiled to wasm (#2826)

The oracle compares declarations; #2826 asks for output parity. Compiling the
CLI closure (686 modules) through `compile_file_fs_mode_rc_body_cached_split`
with `use_split` false and true:

- **Byte-identical**, once the synthesized function region is laid out in
  NAME order. Before that, both lanes emitted the same 14842 functions but 27
  synthesized comparators sat in a different order (the split lane links a
  module's helpers after that module's statements; the whole-program lane
  emits them where its passes inserted them), so every call into them moved
  and 698 bodies differed. The pin reorder now sorts that region by name, the
  same consistent-permutation argument the reorder already relies on. Pinned
  by `prelude_split_fs_lane_test.vibe`, whose two-module case differs without
  the sort.
- **What a per-module prelude cache could save is bounded.** Cold, CPU inside
  the compile: the whole-program prelude is 13.0 s, of which the evidence pass
  is 7.7 s and suspend CPS 0.95 s. Both run at the link boundary on either
  lane. The per-module share is ~4.4 s, mostly trait-dict desugaring, and the
  split lane spends 16.6 s on the prelude today, +3.6 s. Even a perfect
  per-module cache would save at most ~4.4 s of a ~37 s cold compile; the
  evidence pass is the larger target.
- **A dependency's derived `Show` now renders on the split lane.** It used to
  refuse `"\{zeta(2)}"` with `Zeta`'s `derive(Show)` in another module
  (``cannot interpolate a value of type `Zeta`: it has no Show renderer``),
  which the whole-program lane compiles. A module's run derives only for its
  own declarations, and the renderer check needs `Zeta::to_string` in a
  return table built from this run's statements, while the definition is in
  the dependency's output. The derive pass now records context types whose own
  module will generate a renderer (the generating arms' condition, evaluated
  on the same statements), and the return table gains their
  `T::to_string -> String` rows, inserted in sorted order because the table is
  searched by bisection. The link joins the call to the dependency's
  definition; nothing is generated twice. Pinned by the cross-module `Show`
  case in `prelude_split_fs_lane_test.vibe` (byte-identical to the
  whole-program lane; refused without the fix).

### The four counters

Four counters name what a green would otherwise hide. `invisible_whole` /
`invisible_split` count the nominals each lane could **not** see while
synthesizing a comparator — a declared struct or enum absent from the statements
the pass was handed, as opposed to a scalar, a type formal, or the shape
scanner's `?EqUnknown`. `collisions` counts declaration keys under which two
modules produced two different bodies. `linked_dups` counts definition keys the
link left duplicated; it equals the keyed line's `dup_defs`, so the link removed
none of the definitions the program legitimately carries twice and left nothing
unfolded that it should have folded.

### What a comparator may depend on

`invisible_whole=0` is the load-bearing number, and it does not depend on the
context rule at all: a program that type-checks whole can see every nominal it
compares.
So a lane that sees fewer is the only one that can reach the question, and what
it does there used to differ.

`lib/@vibe/compiler/perceus/index.vpkg` declares `opaque type
PerceusActionKind` and a `struct PerceusAction` with a `kind:
PerceusActionKind` field; `perceus.vibe` declares the real `export enum`.
Compiled whole, the equality pass saw the enum and emitted
`PerceusActionKind::equals(a.kind, b.kind)`; compiled per module, the
materialized contract saw only the opaque type and emitted `a.kind == b.kind` —
a comparison of an aggregate **by reference**. Two bodies under one name, which
is the roadmap invariant *a synthesized definition's name must determine its
body* failing.

A nominal the statement list cannot see now takes the structural call too. The
emitted call is a reference the link resolves against the module that declares
the type, the same as any other cross-module call, and because the arm is
unreachable on the whole-program lane the rule is unconditional rather than
lane-dependent. `invisible_split` is unaffected by the fix and should be: those
nominals are still invisible to the modules comparing them — what changed is
that their invisibility no longer reaches the body. That is why `collisions=0`
survived the narrowing that took `invisible_split` from 2 to 15. Widening back
to the exact closure moves it the other way — 2 on the compiler's closure today
— for the same reason and with `collisions=0` again unaffected: the count tracks
what a module can see, and the fix is what keeps that from reaching the body.

The link still folds only by a key a module reported as **synthesized**, and
still content-checks the bodies under it. That is not redundant with the above:
it is what turns the next such divergence into a refusal instead of a silently
kept body.

### The per-module prelude reproduces the whole-program prelude exactly

```
CLOSURE files=369 edges=15874 unresolved=0
FULL stmts=10242 split=10413 linked=10242 folded=171 modules=369 collisions=0
     invisible_whole=0 invisible_split=2 linked_dups=5
keyed missing=0 extra=0 copies=448 content=0 renames=0 dup_keys=455 dup_defs=5
EVIDENCE declared=6 handled=5 performed=4
CTX  unresolved_exp=0 unresolved_dep=0 exp_unknown=0 seen=25556 amb=0
```

`lib/@vibe/cli/entry.vibe`, 369 modules, measured 2026-09-12 on the exact
closure. **`linked` equals `stmts`, and `missing`, `extra`, `content` and
`renames` are all zero.** Compiling the compiler's own CLI closure per module
and linking produces every declaration the whole-program prelude produces, name
for name and body for body.

`seen=25556` is the denominator the two `unresolved` zeros are read against: it
counts the merge-stamped names the context scan judged, so a zero here is an
answer rather than a scan that matched nothing (#2633).

`copies=448` is what remains after the link and is not a difference: each is a
module's own `reexport_boundary` marker, one per module, which no link should
merge. `dup_defs=5` equals `linked_dups=5`, so the link removed none of the
definitions the program legitimately carries twice and left nothing unfolded.

### What the oracle models, and what it does not

The claim above is about the passes the oracle runs, and that is every pass in
`effect_lowering_prelude` that **rewrites statements** — including the two whose
arguments are themselves whole-program computations
(`optional_perform_artifact_resolution` feeding `lower_optional_performs`,
`lc_stmts_call_host_future` feeding `await_poll_pass`). Those are recomputed
from each module's own statements on the split side, so `content=0` covers them:
the per-module computation produced the same rewrites.

Two passes read something besides the statements, and the dispatch takes both
through a `PreludeEnv`: `linked_imports` for `lc_waiter_hooks_available`
(pass 9, `await_poll_pass`) and the `iw_names` / `iw_wats` arrays
`lc_extract_inline_wasm` fills (pass 8). A driver that has to PRODUCE the
program needs both — those arrays are what carries an `inline_wasm` body to
codegen, and `linked_imports` decides whether any linked import supplies the
waiter hooks `await_poll_pass` lowers against.

The oracle's two lanes pass `prelude_env_none()`, and what that bounds is
lane-specific. For the RC production lane it is faithful: that lane hands
`compile_wasi_module_linked_impl_*` an empty `linked_imports` anyway, and the
inline-wasm arrays are empty for any program without `inline_wasm`. For a lane
that links real imports, or a program that uses `inline_wasm`, a measurement
taken under `prelude_env_none()` is not evidence about that lane.

None of this weakens the decomposition result for what it covers. It bounds it.

**The validators are now measured too.** `zero_alloc_check` and
`lc_validate_stdin_provider_stmts` produce diagnostics rather than rewrites, so
`missing` / `content` / `renames` are structurally blind to them — a per-module
run sees less of the program and could miss a violation or invent one with
nothing else in the report saying so. A separate counter compares them:

```
DIAGS validators=0
```

Both lanes silent on the compiler's own closure. That is agreement, but a
counter that has only ever read zero says nothing about whether it can read
anything else — so a test makes one fire. A `#zero_alloc` function whose body
allocates, in the **dependency** of a two-file program, reads `validators=1`:
the whole-program run walks it and the per-module union reports the same one
diagnostic. The clean two-file control reads `0`.

### The context rule

Three constraints. A rule that misses any of them produces counters that do not
mean what they say, and it can miss in either direction: too wide and a green
means less than it looks, too narrow and the comparison manufactures a
difference that is not there.

- A module sees what it **directly imports** — not what its dependencies import.
  A transitive closure hands A the declarations of a module its dependency
  imports *privately*.
- A dependency naming a **`.vpkg` contract** reaches that package's sibling
  implementations. This is not "siblings share scope" — they do not, and an
  explicit relative import is required between them. It is that an import *of
  the package* reaches what the package publishes, which its siblings implement.
  Without it, a module importing `@vibe/compiler/runtime` got the contract and
  not the sibling whose return types the prelude reads.
- Every context statement is reduced to its **exported** form
  (`oracle_is_interface_stmt` returns each declaration's `exported` flag). So
  what a module sees is exactly the published surface: nothing transitive,
  nothing private, no bodies.

Only the counters distinguish the two directions, which is why
`edges_unresolved` and `invisible_*` are reported rather than assumed.

**`edges_unresolved=0` says no direct dependency edge was DROPPED — not that the
context is what a real compile exposes.** The closure is a deliberate
under-approximation, because the header scan returns a module's deps and its
export *names* with no record of which deps a dep re-exports. So a type that
reaches a module through `export ./b.vibe { Box }` is named in that module with
its declaration absent from the context, and the split lane takes a different
path than an exact context would. `prelude_module_oracle_test.vibe` uses exactly
that chain to make a module defer on demand, which is also what an `opaque`
contract declaration does on the real closure.

**The approximation can hide a difference as well as manufacture one.**
Narrowing a module's context does not only restrict what it sees, it changes
what it *does*: a module that cannot see enough **defers**, and
`eq_mint_deferred_into` builds the helper at the link against the concatenated
program — which is the whole program. So a module that would have synthesized a
*differing* helper under an exact context receives the whole-program one
instead, and the comparison is green over a difference a real per-module
compile would have had.

So `missing=0 content=0` supports **"the linked program equals the
whole-program one"** — which is the question a per-module driver actually has —
and NOT "every module synthesized faithfully". `SYNTH deferred= minted=` is what
separates them: it counts how much of the green is the link's work rather than
the modules'. Read them together or the headline number claims more than it
shows.

### ORDER, which the keyed columns cannot see (#2575 item 2, step 3)

Every column above is keyed, so a declaration that **moved** reads identical.
`order_diff` / `order_first` compare the two key SEQUENCES positionally —
`order_diff` counts the positions whose key differs (plus the length excess),
`order_first` is the first of them, or `-1` when the sequences agree.

Concatenating the per-module results puts them badly out of order. A module's
appended helpers close *that module*, so they precede the next module's source
statements, while the whole-program lane appends every one at the end of the
program. On the compiler's own closure that read `order_diff=9869` of 9908
statements — which looks like "the linked program is scrambled" and is not what
happens. Each appended helper SHIFTS everything after it, and a positional
comparison charges one shift once per statement after it.

`ORDER residual=` is the counter that separates a shift from a reordering:
delete the synthesized declarations from both sequences and compare what is
left. It read `residual=0` even then — every statement the source wrote was
already in the same order on both lanes.

#### The link assembles in two waves

So the link does not concatenate. Wave 1 is every statement no pass appended —
what the source wrote, plus what a pass inserted next to an existing declaration
(#2620 places a hoisted lambda next to its own) — in module order, which is the
merged program's own order. Wave 2 is the appended ones, by the pass that
appended them, module order within.

Telling the two apart is the whole trick, and the only local test that works is
the **maximal new suffix** after each pass: an index comparison against the
pre-pass length is wrong the moment a pass inserts and appends in one run.

Measured on the compiler's own 365-module closure:

```
                       order_diff   order_first   ORDER residual
concatenated                 9869            24         0 of 9698
two waves                     212          9700         0 of 9701
```

`order_first=9700` with 9701 source statements is the result: **no difference
occurs before the end of the source program.** What is left is the ~213
synthesized helpers permuted among themselves in the tail — one pass emits
almost all of them, and it discovers them in a global traversal on one lane and
module by module on the other. They are top-level definitions that forward
reference freely, so the permutation is inert; closing it would mean reproducing
one pass's internal discovery order, which is not worth what it would cost to
depend on.

`missing=0 extra=0 content=0 renames=0` hold throughout, so the two waves moved
only declarations whose placement the lanes disagreed on and nothing the source
wrote.

#### The counters are red-tested

`ORDER residual=` reads 0 on every real split, and a counter that has only ever
read 0 says nothing about whether it can read anything else. Interleaving the
module map — statement 0 to module 0, statement 1 to module 1, statement 2 back
to module 0 — makes grouping by module reorder the source, and it reads `ORDER
residual=2 of=4`.

`prelude_split_bytes_test.vibe` pins the byte-level claim on a two-module
program, both directions. The positive: same declarations, same bodies, same
ORDER, with the derived `Pt::equals` at index 4 on both lanes where
concatenation put it at 2. The negative that makes it non-vacuous: with the
closure narrowed to `[[], []]` the second module cannot see `Pt`, its `a == b`
survives the prelude unlowered where both other lanes rewrite it to
`Pt::equals(a, b)`, and the declaration multisets differ too. So the closure is
load-bearing on that program, and the order test is measuring something the
keyed comparison genuinely cannot see rather than something it already covers.

#### Which passes are per-module safe (#2647 Codex round 3)

Five passes were found unsafe **one at a time, by review**, which is the shape
the repo's own guidance says to remove rather than keep patching. So here is the
audit, and it is the thing to check against rather than rediscovering a pass per
round. "Safe" means a module's partition answers the same question the whole
program does; everything else either takes the answer from `PreludeEnv` or runs
at the link.

**This table had a wrong row within one round of being published**, which is
worth stating before reading it: row 0 said "safe: per-statement rewrite" and it
is neither — `elaborate_heap_params` builds `heap_fns` and `ctors` tables from
the statements it sees, and it is not part of the prelude at all (the caller
runs it, so the split path was running it a SECOND time, per module). A hand
audit of 17 passes against cross-module dependence is not something to trust on
its own; the rows below are the current best understanding, not a proof, and the
validation this actually needs is **executing** a program compiled through the
split path, which is what step 3b is for.

| # | pass | per-module | why |
|---:|---|---|---|
| — | `zero_alloc_check` | **whole-program** | interprocedural: `za_walk` walks callee bodies out of a table built from the statements it was handed |
| 0 | `elaborate_heap_params` | **not in the prelude** | the caller runs it before `effect_lowering_prelude`, which never does; the split entry starts at pass 1. Per module it would also misclassify a heap value returned by an imported function |
| 1 | `desugar_inspect_calls` | safe | per-statement expansion |
| 2 | `optional_perform_artifact_resolution` + `lower_optional_performs` | **`PreludeEnv`** | TWO whole-program facts: the resolution grants ambient authority from a test-block scan (an AUTHORIZATION difference, ADR-0084/0088), and the source-shadow name set decides whether a `perform?` spelling names a SOURCE function rather than a capability |
| 3 | `erase_railway_origin_markers` | safe | per-statement |
| 4 | `desugar_trait_dicts_with_typed_eq` | **module entry + `PreludeEnv`** | takes the module's dependency interface (#2634), plus THREE whole-program facts it cannot derive from a partition — see below |
| 5 | `unbox_tuple_loop_params` | safe | per-statement |
| 6 | `rewrite_top_level_fn_alias_refs` | **`PreludeEnv`** | the alias map is global; an unrewritten call emits N args against a 0-param thunk = invalid wasm |
| — | `lc_validate_stdin_provider_stmts` | safe | local to each statement's own expression; the union is the whole-program answer |
| 7 | `lc_inject_stdin_surface_wrappers` | safe | gated on a presence scan and local to what it finds; duplicate wrappers are folded at the link |
| 8 | `lc_extract_inline_wasm` | safe | accumulates into the caller's arrays; the union is the program's |
| 9 | `await_poll_pass` | **`PreludeEnv`** | both its predicates (`host_future_*` called anywhere, waiter hooks available) are whole-program scans |
| 10 | `rewrite_self_tail_calls` | safe | per function body |
| 11 | `wrap_entry_exception_boundary` | safe | matches `entry_name`, which lives in one module — but WHICH module is derived (`lc_entry_module_of`), not assumed to be the last |
| 12 | `lc_inject_async_sleep_boundary` | **link** | needs the entry's `Async` row AND a boundary call anywhere; what it injects must be visible to 13/14, so it cannot be served by a precomputed fact |
| 13 | `suspend_cps_pass` | **link** | must see what 12 injects |
| 14 | `inline_direct_performs` | **link** | same |
| 15 | `evidence_dict_pass` | **link** | whole-program union, and the dependence runs backwards along the import graph (#2633) |
| 16 | `forin_discard_pass` | **link** | follows 15 to keep the order |

#### Pass 4 alone needed three more facts

The trait-dict pass has produced four findings across this review, which is more
than any other, and they are all the same shape — a whole-program read served
from a partition:

- the **merge rename table** (`namespace_rename_originals`), built per file
  during the merge and cleared by `dtd_run`; per module that emptied it after
  the first one, so later modules rendered `Local_dep_<path>` for `Local`. The
  reset moved to the lane boundary;
- the **trivial identity wrappers** (`apply(f) { f() }`). The whole-program pass
  inlines `apply(inner)` to `inner()`, which `dtd_run` documents as the
  workaround for a closure CRASH. `dtpw_collect_wrappers` scans only the
  module's own bodies and a dependency's interface is bodyless, so the caller
  partition left the call intact;
- the **explicit `T::op` definitions**. A module DOWNSTREAM of a type's owner
  can define `fn T::equals`; the owner sees neither it nor the dependent,
  derives a default, and the link reports a collision on a program the
  whole-program lane accepts.

The last two travel in `ModuleTraitFacts`; the first is a reset-granularity fix.
Worth recording that `oracle_interface_form`'s own doc comment names the
trivial-wrapper inliner as the body-reading collector the bodyless interface
blinds — the consequence was written down before the bug was found, and the
audit still missed it.

So the cut is **0..11 per module, 12..16 at the link** — most of the prelude, and
the half a per-module cache can reuse.

This also corrects what `missing=0 content=0` was reported to mean. An authority
resolution and a boundary injection are not declaration differences: the oracle
was structurally unable to see four of the six unsafe passes, and its green said
nothing about them either way.

#### Measured in the EMITTED WASM (#2575 item 2, step 3b)

Everything above compares statement arrays. The FS lane can now compile a
program both ways, so the question can be asked of the wasm. On the compiler's
own closure, with the body cache genuinely off:

```
function=2   code=9368/5778988   data=0   export=0   element=0   name=658
9250 functions, 477 differing, 18 of them at a different SIZE
```

The 19 that moved, by name:

```
BinderAuthorityNodeKind::equals   __arr_equals__N3_Pat
BinderSemanticRole::equals        __arr_equals__T2_N6_StringN3_Pat
__arr_equals__N8_TypeExpr         __arr_equals__N4_Expr        …
```

**All 19 are synthesized comparator helpers, at the end of the function list, in
a different order.** The other 458 differing functions are their CALLERS: a
callee at a different index changes the `call` immediate, same encoded width,
which is why 459 of 477 differ at identical size and why the difference is
spread across the whole index space. Data, exports and the element table are
byte-identical.

So this is the `order_diff` the two-wave assembly reduced from 9869 to 212,
surviving DCE and the link down to 19 functions. It is layout, not meaning —
and it is not closable without reproducing the trait-dict pass's whole-program
discovery order inside each module, which is a dependency on one pass's
traversal that is not worth taking.

#### Production prelude allocation (#2510)

The production split carries `PreludeLinkState`: synthesized declaration keys,
append ranks, diagnostics and synthesis collisions. The oracle opts into a
separate `PreludeObservations` record. Only that opt-in runs per-module
validator comparisons, context-use classification, evidence summaries, borrow
analyses, link-round comparisons and duplicate-count controls. Production does
not retain the oracle's pre-link AST copies. Both callers use the same pass
and assembly implementation, and codegen still runs its required borrow
analyses after final lowering and DCE.

Measured on 2026-09-13, with the compiler's 219-module / 5029-statement closure,
body caching off, separate processes and separate persistent cache directories:

| production split | before | after | allocation saved |
|---|---:|---:|---:|
| cold | 1,245,525,708 B | 1,152,199,348 B | 93,326,360 B |
| unchanged warm | 879,093,612 B | 785,765,964 B | 93,327,648 B |
| private leaf body edit | 1,147,366,068 B | 1,054,039,228 B | 93,326,840 B |

The private edit changes the copied `Default for Int` method body from `0` to
`1`. Each lane's emitted Wasm is byte-identical before and after this compiler
change. Whole and split retain their existing synthesized-helper placement
difference, so this comparison pairs the same lane across compiler versions.
These are deterministic allocation-volume measurements, not timings or a live
set. The unchanged warm split still allocates about 118 MB more than the
whole-program lane; removing observation work does not implement persistence
or satisfy #2510's memory criterion.

`scripts/prelude_split_memory.sh` requires
`VIBE_PRELUDE_SPLIT_CLI_WASM=<stage2.wasm>` explicitly, compiles its probe from
the current checkout, and measures a copied library tree. It runs three rounds
with alternating lane order, isolated caches, and cold / warm / comment-edited /
edited-warm temperatures. The comment edit preserves the program and each
lane's output is byte-compared across temperatures. It reports the modules the
production prelude actually lowered; constructing a split descriptor is not
evidence that the guarded split ran. No parsing or split-shape query precedes
the measured compile. Reports and outputs remain under
`_build/prelude-split-memory.*/`.

The continuous `perf-metrics` job now records a bounded cold/warm pair for
both prelude lanes on every PR, and full CLI cold/warm builds on main. Each
allocation reading is compared with the previous main snapshot. See
[the sampling protocol and retained history](../../../bench/perf/README.md#paired-prelude-allocation-and-full-cli-builds).
This series fixes the probe to the bump allocator and records its own protocol
identity; its absolute readings should not be mixed with the historical
before/after experiment above.

Persisted module preludes and the remaining whole-program passes are still
required. Cached codegen bodies also need either stable function indices or
relocations, because a call immediate depends on the linked program's index
assignment.

##### How far they actually move (#2669)

The paragraph above says a body cannot be replayed "into a build where indices
moved". How far they move was never measured. Measured, it splits into edit
classes that behave nothing alike, and it turns up two relocation classes
beyond the call immediates that sentence names.

`scripts/wasm_index_stability.mjs` compares two builds made with
`VIBE_WASM_NAMES=1`, matching functions **by name** — matching them by index
would assume the stability being measured. Corpus: the compiler's own closure
(`codegen_lexer_test.vibe`, 190 resolved files, 4743 defined functions, 4341
matched by name), compiled by the generation stage2 of `bef330a`, baseline
built on `6c53578`. Every leaf edited is checked to be IN that closure — the
first run of the neighbouring memory measurement edited a file that was not,
and every row came back identical, a vacuous experiment that looked like a
result. N=1 per cell, which is exact rather than approximate here: these are
byte comparisons of a deterministic compile, not timings.

Four edit classes, one baseline:

| | body only | +1 fn ABOVE the band | +1 fn BELOW the band | module reorder |
|---|---:|---:|---:|---:|
| index kept | 4341 (100%) | 216 (4.98%) | 87 (2.00%) | 4208 (96.94%) |
| index moved | 0 | 4125 (95.02%) | 4254 (98.00%) | 133 (3.06%) |
| distinct index deltas | — | 1 (`+1`) | 1 (`+1`) | **2** (`+4`, `−129`) |
| LEB width-band crossings | 0 | 0 | **1** | **8** |
| bodies byte-identical | 4340 (99.98%) | 1303 (30.02%) | 1192 (27.46%) | 3800 (87.54%) |
| bodies differing, same length | 0 | 3037 | 3146 | 527 |
| bodies whose LENGTH changed | 1 (edited) | 1 (edited) | **3** | **14** |
| sites explained | — | 31778 | 32218 | 433 |
| sites unexplained | — | 0 | 0 | **850** |

The edits: a `StringBuilder::push(sb, "")` added inside `hex_encode`; a private
function added to `hex.vibe` (indices 225–228, above the 127/128 boundary); the
same to `base64.vibe` (96–101, below it); and `import ./hex.vibe` added to
`base64.vibe`, which forces `hex.vibe` earlier in the order.

**A body-only edit moves nothing.** Adding a statement to a function changes
that function's body and no other byte of the module: 4340 of 4341 bodies come
back byte-identical and every index is unchanged. For this edit class the
constraint does not apply at all — no relocation, no index-independent form and
no stable assignment. That is the common edit, and a cache that served only it
would already serve most of what a developer does.

**Adding a function shifts every later index by exactly one.** Not a scatter:
ONE distinct delta, because the assignment is positional and a module's
functions are contiguous. The 216 (or 87) that keep their index are the ones
before the insertion point; the byte-identical bodies are those that call
nothing that moved. The rest differ at IDENTICAL length, so an in-place patch
is arithmetically possible — *for this class*.

**Where in the index space the insertion lands decides whether that holds.**
`leb128_encode_u32` (`lib/@vibe/compiler/core/bytebuf.vibe`) is minimal-width,
so an immediate's byte count tracks the index magnitude: one byte below 128,
two below 16384. Inserting into `hex.vibe` at 225 crosses no band, and exactly
one body (the edited one) changes length. Inserting into `base64.vibe` at 96
pushes `BigInt::abs` from 127 to 128, and its call immediate grows from one
byte to two: `Rational::abs` calls it once and grew 135 → 136, `make_rational`
calls it twice (`rational.vibe:72,73`) and grew 534 → 536. One byte per call
site, exactly. **Two bodies in a module the edit never touched changed
LENGTH** — so an in-place patch is not merely incomplete for this case, it
cannot represent it, and the case is reachable by a one-line edit.

**A module reorder is a different animal again.** Adding one import moved
`hex.vibe`'s four functions from 225–228 to just before 96, and the 129
functions between the two positions up by four: **two** distinct deltas, one
large and negative, where every other class produced exactly one. Eight
functions crossed a width band, fourteen bodies changed length. The function
SET is unchanged here (`only-in-a 0`, `only-in-b 0`) — this is purely a
reorder, the cleanest possible form of the case.

**Three relocation classes, and only one announces itself.** Of the 31778
sites on the added-function run, 31753 are `call` immediates and **25 are
`i64.const`**: a first-class function value is emitted as `i64.const
(idx*4+2)` — the index tagged once as a function reference and once as an
`Int`. Both decode to a function index that moved `+1`, and both carry the
same name on each side; only the first is recognisable from its opcode. The
reorder adds the third: 850 sites could not be attributed to any function
index, and their delta histogram is `-101:578  +60:268  +0:2
+257698037760:1` — structured, not noise. That last one decodes:
257698037760 is `60 << 32`, and the site goes `(367 << 32) | 1` →
`(427 << 32) | 1`, i.e. a `(ptr<<32)|len` **String constant whose DATA pointer
moved 60 bytes** with its length unchanged. Reordering the modules reordered
the data segment under them, and a String literal's pointer rides an
`i64.const` exactly as invisibly as a function value does.

The tool reports those deltas but deliberately does **not** name the class. A
bare `i64.const 288 -> 348` carries no cross-check that says what it is — the
fn-value arm can only claim a site because the decoded index carries the same
NAME on both sides. An absent classification is fine here; a wrong one is not.
`unexplained` prints next to `explained` for the same reason: "0 unexplained"
means nothing on its own, and it did not hold on the first run — the
`i64.const` function values came back as 7 unexplained bodies until the decoder
above was added.

**What this costs each option for closing the criterion.** Three relocation
classes are measured — `call` immediates, function values in `i64.const`, and
data pointers in `i64.const` — and only the first is recognisable by opcode:

- **patching immediates in place** covers the first class, silently misses the
  other two, and cannot represent a body whose LENGTH changes at all — which a
  single added function below index 128 already causes;
- **a stable, identity-derived function index assignment** removes the first
  two classes and leaves data pointers moving;
- **emitting against a per-module symbol table and resolving at the link** is
  the only shape where no class can be forgotten, because a symbolic reference
  is explicit by construction rather than recognised by a scanner.

A fourth reading, cheaper than all three: **gate the cache on the edit class.**
A body cache that serves body-only edits and declines the moment the function
set or the module order changes needs none of the above, and the first column
says what it would be worth.

##### The decision, and what has landed of it

**Index-independent bodies were chosen** (the third option above). The reason
is the P0 ordering rather than cost: the other two fail by *answering wrongly*
— a relocator keyed on the `call` opcode leaves the `i64.const` classes
untouched and produces a body that looks fine and calls the wrong function —
while a symbolic body's failure mode is a reference that will not resolve,
which is a build error. A fourth reading, gating the cache on the edit class,
remains available as a cheaper slice and is not excluded by this.

Landed so far — `@vibe/compiler/codegen/reloc`, the half that a cached body
needs before the link can exist: given a finished body, find every reference
and rewrite it against a new assignment. It changes no emission, so it can be
held against real output before anything depends on it.

The rebuild copies spans and re-encodes rather than patching in place, which
is what lets it serve the width-band case above: `call 127` → `call 128` grows
the body by a byte and the rebuild does not notice, where a patcher would have
had to refuse. `reloc_scan_test.vibe` pins that in both directions.

The scan is **fail-closed**: an opcode it does not know is refused by name, not
assumed to be one byte wide. That is what made its coverage measurable rather
than asserted. `scripts/reloc_roundtrip.sh` runs it over whole modules and
requires an identity rebuild to be byte-identical:

| module | bodies | sites | func | type | global | table | tag | mismatches |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| the compiler's own stage2 | 6681 | 143,675 | 101,449 | 1315 | 38,616 | 1315 | 980 | 0 |
| a linear probe | 13 | 51 | 34 | 0 | 17 | 0 | 0 | 0 |
| a gc-lane probe | 61 | 151 | 75 | 14 | 62 | 0 | 0 | 0 |

Nine reference kinds are recorded: function, type, global, table, tag,
blocktype, heap type, data segment and element segment. **Every immediate the
decoder reads goes through either a recording helper or a NAMED skip
helper** — `skip_local_index`, `skip_literal_uleb`, `skip_literal_sleb` — for
a reason the review history makes concrete: four classes were found missing
one at a time (tags, blocktypes, table indices, segment indices), and in every
case the miss looked like `let (_, p) = read_uleb_at(...)`, which is
indistinguishable from a reference someone forgot. With the immediates
classified, `_` is not a shape the code offers.

The per-kind breakdown is printed rather than just the total, because a kind
that never appears is a code path no real input exercised. Four are in that
position — blocktype, heap type, data and element segment indices read zero on
every module here — so their only coverage is synthetic, and the tests say so
where they sit.

**The oracle can report success while scanning the wrong region**, which is
the sharpest thing this exercise established and the reason "it round-trips"
is not sufficient on its own. The locals header decides where the first
instruction is, and a version of that walk which advanced a fixed byte per
local group was wrong for the gc backend's typed reference locals
(`0x63 <typeidx>`, `backend_body.vibe`). Measured on a probe that has three
such local groups: the broken walk started one byte early, read the type index
as an instruction, resynchronised, and produced a **different but
self-consistent** classification — one type site reported as a blocktype
site — with `identity_mismatch=0`. It passed. The probe in
`scripts/reloc_roundtrip.sh` was then rewritten to contain such locals,
because the previous one had none: a probe that cannot reach a construct is
not coverage of it.

The linear lanes passed on the first run; the first gc-lane module refused
`0xfb` by name, which is how the wasm-gc opcode family got added rather than
silently mis-walked. Identity alone would pass vacuously on a scanner that
found nothing, so the site count is reported beside it and a second pass
perturbs one value per body and requires the bytes to change.

Exception TAGS are in that table's count because review put them there, not
the oracle: an identity round-trip is precisely what an unrecorded reference
passes. Tag indices are sized by the declared effects (`len(effect_names) + 4`
in `linked_compile.vibe`), so adding an effect moves them, and a rebuilt body
holding a stale tag routes a `perform` to the wrong handler with nothing
failing at build time. Recording them raised stage2's site count from 141,380
to 142,360 — 980 references that were silently going to be left behind.

##### Fixed-width relocatable slots (#3941, opt-in)

`VIBE_RELOC_SLOT_WIDTH=<1..5>` (W) pads every relocatable immediate a body
embeds to a fixed minimum LEB128 width. Each one then keeps its byte count
when the layout behind it moves.

| reference | width | fixed while |
|---|---:|---|
| function index (`call`, `ref.func`) | W | index < 2^21 at W=3 |
| exception tag (`throw`, `try_table` catch) | W | tag < 2^21 |
| global (`global.get`, `global.set`) | W | global < 2^21 |
| type index: `call_indirect`, the gc lane's struct / array operands | W | type < 2^21 |
| type-index blocktype (the gc lane's reference-result `if`), signed | W | type < 2^20 |
| funcref table slot: `i64.const ((slot << 2) \| 2)` (kind 101), `i32.const slot` (kind 102) | W | slot < 2^18 |
| string address, bare offset (`blind_kind_str_ref`) | W | offset < 2^20 |
| string address, `(offset << 32) \| length` (`blind_kind_str_fat`) | W+5 | offset < 2^23 |
| constructor tag `(type_index << 16) \| variant` (kind 105), user types only | W+1 | type index < 2048 |

A non-minimal LEB128 is valid wasm. It is the slot shape that the
tool-conventions object format, `wasm-ld` and wild reserve for this reason.
Unset is minimal, and the output is byte-identical to a compiler without the
switch. A built-in constructor tag (below `2 << 16`) never moves and stays
minimal. So does the `call_indirect` table index (always 0). Heap types stay
minimal too: no instruction either lane emits carries a type-index heap type,
and the gc lane's typed locals (`(ref null $t)` in a body's locals header) sit
outside the instruction region the relocation scanner reads.

The width is read once, at the top of `cli_main`, so every compile in the
process uses it. That covers the positional protocol and also the
`vibe build` / `run` / `test` verbs, which reach `compile_file_fs_mode_cached`
without a lane request.

**Every writer of a padded reference goes through one encoder.**

- `leb128_encode_u32_slot` writes function indices, tags, globals and type
  indices:
  - `emit_call`, `emit_ref_func`, `emit_global_get` and `emit_global_set`;
  - the type index in `emit_call_indirect`, and in the gc lane's
    `struct.*` / `array.*` operands (`emit_gc_type_op`);
  - the inline-wat `call`;
  - the hand-encoded `throw` / `try_table` sites (`common_base_return_frame`,
    `compile_call_call_core`, `compile_call_named_1`, `compile_expr_tail6`,
    and the gc lane's `backend_expr` / `backend_call_named_1`);
  - the body-cache relocator `lc_move_body`;
  - late-DCE renumbering (`lc_pf_emit_code` and its linemap delta).
- `emit_i64_const_slot` and `emit_i32_const_slot` write table slots, at the
  four sites that record kinds 101 / 102 and in `lc_move_body`.
- `leb128_encode_s_slot` also writes the type-index blocktype in
  `emit_if_type_index`. A blocktype is an s33, so it is padded as a signed
  LEB128: the sign is bit 6 of the last byte, which padding keeps clear.
- `emit_i64_const_str` writes string addresses:
  - in `emit_str_ref_slot` / `emit_str_fat_slot`;
  - in the string relocator `lc_relocate_body`;
  - for the `(offset << 32) | length` message constants the generated runtime
    helpers embed. These are the `*_fat` operands in `builtin_bodies/` (OOB
    prefixes, capacity errors, the `__rt_oob_abort` / `__rt_div_zero_abort`
    fragments) and the shadow lane's use-after-free prefix.
- `emit_i32_const_ctor_tag` writes constructor tags, in `emit_ctor_tag` (the
  only emitter of kind 105) and `lc_move_body`.

That is what keeps a replayed or pruned body equal to a fresh one. The
persisted `codegen-body-cache` slot, the file-compile artifact
(`persistent_artifact_kind_for_mode`) and the linked-output memo are all keyed
on the width, so the two encodings never replay into each other. One build
directory used for `vibe build` at W=0, then 3, then 0 gives 1830, 1907 and
1830 bytes.

**Coverage is checked, not assumed.** `scripts/reloc_roundtrip.sh` with
`RELOC_ROUNDTRIP_SLOT_WIDTH=W` rebuilds every function, tag, global, type and
type-index blocktype site at width W and requires the bytes back unchanged. An emitter that wrote one of
them narrower fails it by name. On the corpus below at W=3 it is clean over
200,348 function, 740 tag, 3266 global and 1121 type sites. The build before
type indices were padded fails the same check in 222 bodies. The same module rebuilt at
width 0 is the red control and reports 6979 mismatches.

Measured with `scripts/wasm_index_stability.mjs`, corpus
`codegen_lexer_test.vibe` (7221 functions, 1027 globals, 7 tags, `__no_entry__`).
Each W=3 column adds one class to the column before it. "Length changed"
counts bodies whose byte length differs. At W=0 every build is byte-identical
to main.

| edit | W=0 | function indices | + table slots | + strings | + tags, globals | + ctor tags | + type indices |
|---|---:|---:|---:|---:|---:|---:|---:|
| body only (`hex_encode`) | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| +1 fn above the 127/128 band (`hex.vibe`) | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| +1 fn below the band (`base64.vibe`) | 6 | **1** | 1 | 1 | 1 | 1 | 1 |
| module reorder (`base64` imports `hex`) | 15 | **0** | 0 | 0 | 0 | 0 | 0 |
| +400 fn (a function value moves 1667 → 2068) | 16 | 3 | **1** | 1 | 1 | 1 | 1 |
| +300-byte literal (strings cross 8192 / 2^15) | 109 | 109 | 109 | **3** | 3 | 3 | 3 |
| +1 top-level thunk (+2 memo globals; two cross 127 → 128) | 8 | 3 | 3 | 3 | **1** | 1 | 1 |
| +1 effect (every tag 1 higher) | 6 | **1** | 1 | 1 | 1 | 1 | 1 |
| +1 unused enum (6301 ctor tags +1 type; `Deque` crosses 15 → 16) | 25 | — | — | — | 25 | **0** | 0 |
| +1 used enum (the same, plus a function) | 31 | 26 | 26 | 26 | 26 | **1** | 1 |
| +1 30-parameter function (types 35 → 41, four reordered) | 6 | — | — | — | — | 1 | 1 |

The table was measured with main at `a497c68` as the base. It was re-run
whole after merging main at `616d2e2`. W=0 is still byte-identical to that
main on all twelve builds, and the fully padded column answers the same in
every row. The W=0 counts moved with main's own codegen changes:

| edit | W=0 at `616d2e2` |
|---|---:|
| below band | 8 |
| reorder | 11 |
| literal | 105 |
| +400 fn | 12 |
| thunk | 10 |
| effect | 8 |
| used enum | 33 |
| unused enum | 25 |
| arity | 8 |

The total cost at `616d2e2` is +5.94% (6,726,147 → 7,125,553).

The runtime helpers' message constants were padded last, measured at
`616d2e2`. The literal edit drops from 3 to **1**, and every other row
answers as before. The cost is +7 bytes (7,125,560). `vibe run` at W=3 prints
the same OOB and division-by-zero lines as at W=0.

In every row the 1 is the edited body. A dash was not measured. Five rows
need a note:

- **Strings.** In this table the 3 left are the edited body, `__rt_oob_abort`
  and `__rt_div_zero_abort`. Those runtime helpers embed their message's
  address outside the recorded emitters; they are generated builtins, not
  cached bodies. Padding those constants as well removes both (above).
- **Thunk.** The two bodies only global padding removes are
  `rad_to_deg_lo` / `deg_to_rad_hi`, which read the memo globals that crossed
  127 → 128.
- **Effect.** It moves every tag, but with 7 tags no value leaves one byte. A
  tag crossing needs more than 120 declared effects, so tag padding is paid
  for and, here, unused.
- **Enum.** A constructor tag is `(type_index << 16) | variant`, so a user
  tag is three LEB bytes until type 16 and four until type 2048. The slot
  width alone does not change it; it takes W+1. Built-in tags are left minimal
  because they never move. Padding them too (an earlier variant) cost 35,679
  bytes instead of 16,579, for the same table.
- **Type indices.** The linear lane's type section is identical across every
  other edit here. A new signature does move it: four old types reorder (9→3,
  10→4, 11→8, 34→40). But with 35–41 types every index is one byte, so no
  length moves. Type padding is paid for and, at this size, unused. A type
  crossing needs more than 127 distinct signatures.

- **Cost.** W=0 is 6,636,149 bytes. Each class adds:

  | class | module size | added |
  |---|---:|---:|
  | function indices | 6,995,692 | +5.42% |
  | table slots | 6,995,732 | +40 B |
  | strings | 7,004,443 | +8,711 B |
  | tags and globals | 7,010,864 | +6,421 B |
  | constructor tags (user types) | 7,027,443 | +16,579 B |
  | type indices | 7,029,688 | +2,245 B |
  | **total** | | **+5.93%** |

  Function indices are almost all of it: 200,348 sites, most of them one or
  two bytes.
- **Body-cache replay** (`VIBE_CODEGEN_BODY_CACHE=on`, one cache, replay
  compared with a fresh compile). The output was byte-identical at W=3 and at
  W=0 for every edit that exercises a relocation class:

  | edit | offered | recompiled |
  |---|---:|---:|
  | below-band and reorder | 7039 | 347 |
  | function value ahead of every slot | 7044 | 342 |
  | +300-byte literal | 7046 | 340 |
  | thunk, effect | 7045 | 341 |
  | 30-parameter function (types reorder) | 7047 | 339 |

  Inserting a type is different. The cache declines the whole build (7387
  recompiled, at W=0 as well), so the constructor-tag relocator is not reached
  end to end on this corpus. It is reached by
  `tests/body_cache_insert_function_test.vibe`, whose 14 rows include "a type
  added in a middle file relocates the tags it moves" and "moved indices that
  cross a LEB width band are rebuilt".

**Every body-cache relocation row runs at both widths.** This covers six
files: `body_cache_{insert_function,changed_type,changed_struct,changed_row,downstream_edit,edit_classes}_test.vibe`.

- **Layout.** Each test body is a row function. The file runs it once as the
  original test and once as `<name>, at slot width 3 (#3941)`, against one
  expected literal, so the two widths must give the same answer.
- **Cache slot.** The rows clear the cache slot through
  `codegen_body_cache_artifact_key`, so they clear the slot the compile will
  actually read. Before this, each probe built the key from
  `"self-describing-"` by hand. At width 3 that cleared the width-0 slot, and
  a "cold" build replayed the previous row's artifact.
- **Coverage.** 26 rows, 52 tests.
- **The check can fail.** With the relocator writing a moved `call` target
  minimal again, the width-0 rows pass and "a thunk added ahead of a cached
  one moves its memo globals with it, at slot width 3" fails with
  `equal=false`.

`verify` does not reach this path. A function-set edit changes the guards, so
its second compile is skipped (the counted lane reports `-1`).

**The compiler itself as the corpus** (measured at `616d2e2`). The root is
`cli_adapter_cli_main_with_lanes.vibe` with entry `cli_main`: 719 modules,
12,649 functions after DCE. All padding classes are on.

Five of the edits above touch only `base64.vibe`, which `cli_main` does not
reach, so they come out byte-identical to the unedited build. Those were
dropped as vacuous rather than counted as zeros. They were rebuilt in
`lib/@vibe/ast/ast.vibe`, ahead of `trait_ref_name` (index 124), and called
from it. The module reorder has no counterpart there, because `ast.vibe`
imports nothing.

| edit | W=0 | W=3 |
|---|---:|---:|
| body only (`hex_encode`) | 1 | 1 |
| +1 fn after the band (`hex.vibe`) | 1 | 1 |
| +1 fn ahead of the band (`ast.vibe`; `impl_method_owner` 127 → 128) | 24 | **1** |
| +400 fn (`ast.vibe`) | 100 | **1** |
| +300-byte literal (`ast.vibe`) | 7 | **1** |
| +1 30-parameter fn (`ast.vibe`) | 24 | **1** |
| thunk, effect, used / unused enum (`base64.vibe`; bytes change, no length) | 0 | 0 |

- **Parity.** W=0 is byte-identical to main's stage2 on every build.
- **Cost.** The compiler grows from 10,826,109 to 11,508,692 bytes (+6.31%).
- **The padded compiler works.**
  - Compiling the `codegen_lexer_test.vibe` corpus, the W=3-built compiler
    and the W=0-built one give byte-identical output, equal to main's
    stage2.
  - Their wall times overlap (22.2–24.3 s against 22.4–22.6 s, N=3), so
    decoding non-minimal LEB128 costs nothing measurable here.
  - Each compiles the compiler itself to the same bytes, and that output
    equals the W=0 compiler, so the fixpoint holds.
- **Body-cache replay.** On this corpus, with the `ast.vibe` +1-fn edit,
  14,045 of 14,394 bodies are offered and 349 recompiled. The result is
  byte-identical to a fresh compile at W=3 and at W=0.

**The gc lane's blocktype.** The gc lane writes one type-index blocktype: an
`if` that joins two native-array references (#1541) names the reserved func
type `gc_native_array_block_type_idx`. Padding it costs 2 bytes per site at
W=3 and moved nothing, because that index is the constant 13. Bodies are
generated before the type section is laid out, so it is a fixed base type by
construction.

Measured on a generated gc-lane corpus: 8 such joins, 300 chained functions
and one struct, with no lambda and no `handle` in the joining function (either
one keeps that function's arrays off the reference lane, and the joins then
emit no blocktype at all). The gc lane has no name section, so bodies were
matched by sequence alignment rather than with
`scripts/wasm_index_stability.mjs`. "Length changed" counts the 311 shared
bodies; the edited body is one of them.

| edit | W=0 | W=3, blocktype minimal | W=3, blocktype padded |
|---|---:|---:|---:|
| body only | 0 | 0 | 0 |
| +1 fn ahead of the chain (every index +1; one `call` target crosses 127 → 128) | 2 | **1** | 1 |
| +400 fn | 0 | 0 | 0 |
| +1 struct declared first (`Pt`'s struct type 14 → 15) | 1 | 1 | 1 |

- **The blocktype never moved.** In every build the 8 bodies holding it are
  byte-identical across all five variants, at W=0, at W=3 with it minimal and
  at W=3 with it padded.
- **Parity.** W=0 is byte-identical to main on all five variants.
- **Cost.** 7,731 → 7,747 bytes on the base module, 2 bytes for each of the 8
  sites.
- **Coverage.** The gc probe in `scripts/reloc_roundtrip.sh` now holds one
  blocktype site. The compiler before this change fails it at W=3 with
  `identity_mismatch=1`.

So the blocktype padding is consistency, not a measured win: it keeps the
roundtrip identity holding at a slot width, and it would start to matter only
if that index stopped being a constant.

**In-place relocation of a cached body.** At a slot width a moved index
normally fits the bytes the old one held. `lc_move_body` tries that first
(`lc_move_body_inplace`): it copies the body once and overwrites each moved
immediate where it stands. It builds no edit list and rebuilds no spans, and
because nothing changes length, no blind record or linemap row has to be
shifted. A value that outgrew its slot falls back to the rebuild, which is
unchanged and is the only path at width 0.

Measured on `codegen_lexer_test.vibe` at W=3, body cache on, memo off, with a
reachable function added ahead of the 127/128 band in `base64.vibe`. Both
stage2s were built with names and run on the same source tree.

| | main | in-place |
|---|---:|---:|
| `lc_src_edit_reindex` (all relocation of cached bodies) | 183 ms | **133 ms** |
| `lc_move_body` | 117 ms | 102 ms |
| `scan_body_relocs` inside it | 79 ms | 72 ms |
| `lc_edit_shift` (record offsets past an edit) | 22 ms | 1 ms |
| warm build, wall, median of 6 (ABBA × 3) | 7.68 s | 7.91 s |

- **Correctness.** All 12 timed builds, cold and warm, gave one output each:
  the in-place path is byte-identical to the rebuild. The 26 twin-width
  body-cache rows pass at both widths. With the overwrite turned into a no-op,
  `body_cache_insert_function` and `body_cache_edit_classes` fail; the path
  runs only at a slot width, so those failures come from the width-3 rows.
- **Value.** The saving is 50 ms, about 0.6% of an 8.3 s profiled warm build.
  It does not show on wall time: the two medians differ by less than the
  spread of either side.
- **The ceiling is small.** All relocation of cached bodies is 2.2% of the
  warm build, and the scan is more than half of what is left. Removing the scan
  would need each body's site offsets stored with the cache, and could save at
  most about 72 ms more. Late-DCE renumbering (`lc_pf_*`) is 3.9% (same
  profile), and is the
  other relocation pass a fixed width could make in place.
- **Where a warm build goes instead** (main's profile of the same edit,
  7.4 s). The whole-program effect-lowering
  prelude is 27%, checked source groups 12%, trait-dictionary desugaring 11%
  and finishing the linked module 10.5%. A patcher of the linked output reaches
  none of these.

Not done: a default, and a patcher of the linked output itself. On the
numbers above, that patcher can save at most a few percent of a warm build.

**Delivering a rebuild as a delta.** A fixed width keeps every unedited body at
its length, so one could expect a binary patch from the old module to the new
one to shrink. Measured with zstd at level 19, window 2^27, long-distance
matching on, the old module as the dictionary (the `zstd --patch-from` shape).
Every patch was decompressed and checked against the new module. Sizes are of
modules without their custom sections, as a release build ships them. The
inputs are the edit sets of the two corpora above, built at `a497c68` (lexer)
and `616d2e2` (compiler), all classes padded at W=3.

| edit | lexer W=0 | lexer W=3 | compiler W=0 | compiler W=3 |
|---|---:|---:|---:|---:|
| body only | 678 B | 707 B | 1,069 B | 1,075 B |
| +1 fn after the band | 81,954 | 80,955 | 44,079 | 44,126 |
| +1 fn ahead of the band | 82,246 | 82,395 | 135,700 | 136,187 |
| module reorder | 6,181 | 6,179 | — | — |
| +400 fn | 105,649 | 105,343 | 177,339 | 174,462 |
| +300-byte literal | 50,033 | 47,783 | 93,949 | 93,232 |
| +1 thunk | 83,896 | 84,275 | 2,295 | 2,296 |
| +1 effect | 82,790 | 83,280 | 1,047 | 1,053 |
| +1 unused enum (constructor tags move) | 10,561 | 10,268 | 4,592 | 4,707 |
| +1 used enum (tags and a function) | 91,991 | 91,803 | 4,592 | 4,707 |
| +1 30-parameter function | 83,700 | 82,782 | 135,731 | 136,288 |

The whole module compresses to 1,172,198 bytes (lexer, W=0) and 1,955,831
(compiler, W=0). The compiler rows for thunk, effect and enum are the
`base64.vibe` edits, which `cli_main` does not reach.

- **A fixed width does not shrink the delta.** W=0 and W=3 agree within ±3%
  in every row but two: the literal (−4.5%) and the lexer's body-only row
  (+29 bytes, +4.3%). A long-distance-matching compressor
  encodes a shifted run as cheaply as an unshifted one, so keeping body
  lengths fixed leaves it almost nothing to save.
- **The delta is the renumbering.** An edit that moves no index is about
  1 KB. One that moves function indices costs 44–177 KB, even where no
  length moves (+1 fn after the band): every body that calls a moved function
  changes at the call's immediate, and those changed bytes are what the patch
  carries. Moving only constructor tags (the unused enum) costs about 10 KB;
  adding a function besides (the used enum) brings it back to 92 KB.
- **A delta is worth shipping at either width.** Even the edits that renumber
  ship 2–9% of the compressed module.
- **The padding costs little once compressed.** W=3 adds 6% to the module but
  0.6% (lexer, 1,179,792 bytes) and 0.7% (compiler, 1,968,889) to its zstd
  size.

What would shrink an edit's delta is a stable index assignment: a new function
takes an index past the existing ones and a removed one leaves its index
unused, so calls into the unedited code keep their immediates. That would bring
the renumbering edits toward the body-only row. It is not measured here.

##### Does a body actually relocate? (#2669, slice 1b)

The round-trip above proves the walk does not desynchronise. The cross-build
comparison in `scripts/reloc_crossbuild.sh` tests whether a body compiled
against one index assignment can be moved onto another: it builds the
compiler's own closure twice, pulls `hex.vibe` earlier through a new import in
`lib/@vibe/core/base64.vibe`, remaps function references by their unique names,
and compares the rebuilt bodies against what the compiler emitted for B.

The perturbation also adds a call to `encode_url_safe`. That function has
different source in A and B, so the wrapper passes its name in the optional
third, comma-separated argument. The comparator resolves each name to one
shared defined function and removes it before **all** counts and non-vacuity
guards. It reports `source_edited_excluded` separately. Calls
*to* an excluded function still relocate normally; only its own body is outside
the sample. Explicitly supplied module pairs must identify their source edits
the same way: the binary alone cannot establish source equality.

Measured on the compiler closure (`codegen_lexer_test.vibe`), excluding the one
known source-edited body (compiler sources at `2e9da1132`):

| | count | share |
|---|---:|---:|
| bodies compared | 4350 | |
| **REWRITTEN: at least one reference moved** | **3157** | |
| **rewritten AND byte-identical to the compiler's own output** | **2814** | **89.1%** |
| rewritten, mismatched | 343 | 10.9% |
| not rewritten — an identity rebuild, no relocation evidence | 1193 | |
| mismatch, cause not determinable (of all 382) | 284 | |
| mismatch, **encoding-blind** under the unchanged-source condition (of all 382) | 98 | |
| skipped: known source change | 1 | |
| skipped: the name is ambiguous on either side | 5 | |
| shared functions whose index actually moved | 4265 | |

The relocation success rate is **2814 / 3157**, restricted to bodies whose
references were actually rewritten. A containing function's own index does
not appear in its body, so a moved assignment alone is insufficient evidence.
The 1193 identity rebuilds do not enter that rate.

**98 is a lower bound under the unchanged-source condition.** These mismatches
carry neither a non-function reference (which this tool passes through) nor an
unresolved function target. The remaining differences require information the
instruction encoding does not expose, including function-value and data-pointer
constants. The 284 other mismatches may carry those constants too, but their
visible unresolved references prevent a causal attribution. A real link has
symbol tables for the non-function spaces that this binary comparison lacks.

The comparison refuses an empty sample, a sample with no moved assignment, or
one with no rewritten byte-identical body. Excluded functions cannot satisfy
any of these guards. Exact wasm names take precedence; a short name is accepted
only when it resolves uniquely on both sides. A missing, ambiguous, one-sided,
empty or duplicate exclusion is an error; it cannot silently leave a known
edit in the sample. Ambiguous names are also refused for relocation mappings on
both sides, including references targeting the compiler's repeated `__rt_gen`
names.

`pkf run test-reloc-crossbuild` exercises the production comparator on valid
small wasm modules. It proves that a source edit enters the old mismatch
bucket without an exclusion, that excluding it removes it from every relevant
count while retaining other mismatches and calls to it, and that exclusions
cannot satisfy the non-vacuity guards. It is included in `release-check` and
the CI selftests lane.

**What the scan cannot see, and why the link must record instead of derive.**
A `call` immediate is self-describing — the opcode says the next uleb is a
funcidx. A function used as a VALUE is not: it is an `i64.const (idx*4+2)`,
and a data pointer rides an `i64.const` the same way. Nothing in the encoding
separates either from an ordinary constant, so no amount of decoding can
recover them and a guess would be wrong some of the time. `#2669` measured 25
of the first class and 850 of the second on one module reorder. This is the
concrete argument that the emitter must RECORD those references as it writes
them; it is the next slice, and `reloc_scan_unseen_kinds` names the gap in the
code so the boundary is not something a reader has to infer.

The tool's own failure mode is worth recording, because it is the shape this
repository keeps finding. Its site scan walks BACK up to six bytes to find the
opcode owning a differing byte, then advanced to the end of that immediate —
which can be at or before where it started. On every edit whose deltas were
`+1` the differing byte sits right after the opcode, so the jump always went
forward and the bug was invisible; the first module pair whose indices moved by
more than one spun for 15 minutes at 100% CPU. Fixed by making the advance
monotonic. Red-tested by running the pre-fix version on that same pair under a
90s budget (exit 124, did not terminate) against the fixed one (exit 0, under a
second), and by confirming the added-function run reports byte-identical
figures after the change.

##### What a scan cannot find, recorded at emission (#2669, slice 2)

The measurement above relocates a body using only what the instruction
encoding exposes, and 98 of its mismatches are bodies where every such
reference was remapped and the body still differs. What is left in those is a
reference the encoding does not mark. Two shapes, both on the RC lane:

| shape | what it is |
|---|---|
| `i64.const ((slot << 2) \| 2)` | a function used as a VALUE — passed by name, or a captureless lambda |
| `i32.const slot` | the funcref-table slot a CAPTURING lambda stores into its closure header |

Neither is distinguishable from an ordinary integer constant, so the emitter
has to record them as it writes them. `CompileCtx` carries a blind-reference
log (`blind_reloc_*`), shared by reference into per-lambda derived contexts the
way `table_slots_used` already is, and `blind_reloc_record` appends one entry
per emission. The offset it stores is where the constant's **opcode** goes, not
where its immediate starts — so a consumer can check the byte it is about to
rewrite instead of trusting the arithmetic that produced the offset.

**Two checks, because a wrong record cannot be noticed later.** These are the
references nothing in the bytes marks as references. A stale offset does not
fail to resolve; it resolves, rewrites an unrelated operand, and the module
still validates. There is no later stage that would catch it, so both checks
run on every compile rather than in a test:

- **Every record is checked against the byte it names** (`lc_verify_blind_relocs`).
  The opcode must be the one the kind implies and the constant must decode —
  signed, since both immediates are sLEB — to exactly what the record says the
  reference is. A few thousand records on a compiler-sized program, two byte
  reads and one LEB decode each.
- **The record count must equal the funcref-slot count**, per compiled
  function. This is what makes the recording COMPLETE rather than believed
  complete: a function value is emitted at exactly the points that append to
  `table_slots_used`, and each appends one slot and records one reference. A
  new emission site that forgot to record shows up as a count that does not
  match, on the next build, instead of as a cached body that relocates one
  reference short.

**Owners, and the part with room to be wrong.** A record belongs to the BODY it
sits in, which is a user function or a lambda. A lambda's index is not drawn
from the frozen plan until its body is finished, so records made while
compiling one are written under a pending owner and reassigned afterwards —
and a nested lambda, which finishes first, must keep its own. If the outer
reassignment claimed the inner's records, their offsets would be read against
the outer body and land on unrelated bytes; the check above is what turns that
into a failed build. `lib/@vibe/compiler/tests/blind_reloc_test.vibe` compiles
one program per shape, including the nested case.

That nested case had to be BUILT rather than picked, and the first version of
it proved nothing. The obvious spelling of nested lambdas — a closure over an
enclosing binding — does not reach the hazard at all: a capturing lambda's slot
is emitted into the ENCLOSING buffer, so the inner body records nothing and an
outer reassignment has nothing to steal. Measured, with the reassignment
widened to drop its pending test: that version still passed. Both lambda bodies
have to contain a function value of their own, which is what the committed case
does. Three of four mutations failing is not a passing grade for the fourth.

**What it costs, on the KPI this issue is about.** The recording is not free,
and a memory regression on a memory issue should be stated rather than left in
a report:

| | selfcompile memory |
|---|---:|
| slice 1b alone (scripts and docs, no compiler change) | 852 MiB |
| with slice 2's recording | 857 MiB (**+0.63%**) |

Those two are the per-PR perf reports for `cb5bc9c` and `0ea74ec`, which share
the same main baseline (`595fed3eb`) and differ by exactly the slice-2 commits
— so the +5 MiB is attributable without building anything extra. Earlier
reports on this branch used older baselines and are NOT comparable: main moved
under them, which is most of what makes a "+x% vs main" row hard to read at
all. Compiled code grew 0.21% (the verifier and the recorder are new code in
the compiler's own wasm).

Most of the 5 MiB is the log itself — four parallel arrays growing with every
function-value reference in the program — which is the mechanism, not overhead
around it. A smaller share is the fresh one-element owner cell allocated per
function body; one module-level cell with save/restore in `compile_lambda`
would remove it, and is worth doing only if this number ever matters. The
trade is 0.63% now against what the warm build currently costs: 765 MB for a
one-module edit, 93% of a cold build.

**What is NOT recorded yet, said plainly.** Data pointers — the other class the
scan cannot see — have no kind number yet, because numbering one before
anything emits it would be a promise and the numbers are append-only. And a
REPLAYED function re-pushes its recorded funcref slots from
`CodegenBodyCache` without re-running codegen, so it contributes slots and no
blind references: a replaying build's log is incomplete by exactly that
amount, which is why the paired count is checked only for functions that were
compiled. Carrying these in the cache is what removes the asymmetry, and it
belongs with the consumer that reads them back.

##### Replaying past the unchanged prefix (#2669, step 2b)

The cross-compile body cache could only replay the unchanged **leading prefix**
of files: `decode_body_cache_payload_for` walked the stored file table, stopped
at the first file whose fingerprint differed, and dropped everything after it.
An edit to an early module therefore recompiled nearly the whole program
whether or not anything those bodies referred to had moved — which is most of
why a one-module edit measured at 93% of a cold build.

The prefix rule looked safe because merge order is topological: a body in the
unchanged prefix can only reference things declared in the unchanged prefix,
so its call immediates, funcref slots, constructor tags and exception tags
could not have moved. **Its string addresses could.** The pool places every
plain literal before the interpolation parts, map keys and the runtime's own
messages (a `%`'s divide-by-zero check among them), so a literal added in a
LATER file moves addresses a prefix body embeds. A body from a file after the
edit has no protection at all, and widening the filter is exactly the act of
giving it up. So the filter now keeps every unchanged file, and what the prefix
was assumed to supply for free is recorded and checked instead.

**What has to be pinned is a closed set, and `CompileCtx` is what closes it.**
A function's bytes are a function of its own AST and the context it compiles
in; every PER-function value in that context is in turn a function of its own
AST and the program-wide part (the Perceus plan, the widest of them, takes only
the body plus the borrow tables). So `guard_layout` is one `[h1, h2]`
fingerprint per program-wide field of the per-function `CompileCtx`,
enumerated at the site that builds it: the function vector with its param
counts and return kinds, the string pool below `src_str_base`, the lambda plan,
the constructor table with struct field names and float-field map, the folded
constants, the thunk names, the effect names and operation arities, the
generated-builtin index assignment, the whole-program return classifications,
and the compile modes. Enumerating index spaces by inspection is how the reloc
scan lost four reference classes one at a time; enumerating one struct's fields
at the site that builds it is a different kind of list — closed, next to what it
describes, and probed by a test that moves each of them for real.

Three things had to be got right, and each was found by measurement rather than
by reading:

- **File ownership and source positions survive lowering.** `fn_files` uses
  the pre-prelude name-to-file snapshot for the unchanged-file filter.
  `fn_src_stmts` uses the corresponding original merged-statement position
  for the prefix fallback, before insertion or DCE compaction (#2721).
  Ambiguous or synthesized names have no source position and cannot enter
  that prefix. The codec (VBC5 and later) rejects the former post-prelude
  coordinates.
- **The typed-lowering OFFSET arrays must not be pinned.** They are source
  positions in the merged text, so appending a comment to any file shifts every
  offset after it. Measured on the compiler's own closure, comment-edited: with
  them folded in, `offered=4394 recompiled=5155` — the wide lane declined and
  the build was a cold one in all but name; without them, `recompiled=848`.
  They also do not need pinning: a replayed body never consults them, and a
  recompiled one consults them against its own current offsets, which shift
  with the same text. What could change an unchanged file's lowering is a
  cross-file CLASSIFICATION change, and those are name-keyed and pinned.
- **A failed layout guard replays nothing, the prefix included.** The body
  loop used to fall back to the unchanged leading files the decoder measured
  (`consumer_src_limit`), on the reasoning above. That lane was never run by
  the edit-class corpus, which edits only the FIRST file, where the prefix is
  empty; measured on the compiler's own CLI closure, one string literal edited
  in `cli/commands/pkg.vibe` gave a warm `VIBE_CODEGEN_BODY_CACHE=on` build 15
  stale addresses against a fresh compile, each 16 bytes too low, and
  `verify` passed it because it replays only when every guard holds.
  `tests/body_cache_downstream_edit_test.vibe` pins that shape on a two-file
  program. The cost is reuse on exactly the edits the guard rejects (a new
  closure or declaration), which recompile in full. A string edit is no
  longer one of them; the next section says why.

##### String references are relocated, not pinned (#2669)

The string pool used to be a `guard_layout` slot, so any literal edit
anywhere declined the whole cache. It is a relocation class now:

- **Recorded at emission.** The linear lane's body code emits a pooled string
  only through `emit_str_ref_slot` (`i64.const off; i64.const 32; i64.shl;
  i64.const len; i64.or`, kind 103) and `emit_str_fat_slot` (one `i64.const
  (off << 32) | len`, kind 104), which record the pool slot in the same
  blind-reference log the function values use. `scripts/review_lint.vibex`
  refuses a raw pool read in `codegen/expr/`, and `lc_verify_blind_relocs`
  checks every record against its bytes, including the whole five-instruction
  shape, on every compile. Only the function-value kinds pair with a funcref
  slot; the pairing checks count those alone.
- **Carried with the pool.** The harvest stores its pool below
  `src_str_base` (`guard_str_pool`, added in VBC8).
- **Relocated at replay.** When the pools differ, every recorded slot is
  mapped through its STRING to this compile's slot (`lc_string_remap`); a
  string the new pool lacks declines the whole cache. Each replayed body is
  rebuilt with the new constants (a different LEB width changes its length),
  every other offset into it moves with it, and the relocated function is
  re-recorded so the refreshed artifact holds the new addresses. The merge of
  the consumed cache is skipped when the pools differ, because its entries
  hold the old ones.

`tests/body_cache_downstream_edit_test.vibe` is the acceptance row: a longer
or shorter literal downstream replays the unchanged file's bodies and answers
what a fresh compile answers.

##### A changed set of source functions is relocated, not pinned (#2669)

Adding, removing, renaming or reordering a function, or giving one a new
closure, moves most of what `guard_layout` pins: the function vector, the
lambda plan, and every name-keyed table (the return classes, the capture
index, the borrow table). Pinned whole, one helper added to the file being
edited recompiled every body in the program.

A body that never spells a changed name sees that change only through
indices, and indices are relocated. So the harvest records the layout split
in two, next to the full fingerprint (`linked_emission_layout.vibe`, VBC10):

- **`guard_layout_global`**: the same fingerprint without anything keyed by a
  source function's name. It covers the constructor and effect tables, the
  synthesized region (its lambda counts, not its bases), the builtins and the
  modes.
- **`guard_src_rows`**: one fingerprint per source function, in index order,
  of what the name-keyed tables say about it: arity, env, return class,
  borrow mask, whether it is a thunk or a folded constant. Its index and its
  lambda count are left out, because the relocation follows both.
- **`guard_src_names`** and **`guard_src_lambdas`**: the names and lambda
  counts by value.

A build whose full fingerprint differs is then compared as an edit
(`linked_body_cache_edit.vibe`):

- **Matched by name.** `lc_src_edit_of` maps each harvest function to this
  build's position. A name that occurs twice on either side identifies
  nothing, and the cache is declined.
- **Compared in halves.** The global half must match whole, and the rows of
  every name both builds hold must match one by one. The meta guards are
  asked without the names only one side holds: the borrow and unmangled-name
  tables, and the synthesized region by name, because the changed statements
  shift its statement positions and no body reads one.
- **Replayed when it spells no changed name** (`lc_src_edit_replayable`). This
  rule is load-bearing: a new global spelled like a local an upstream lambda
  captures changes what that lambda captures. With the rule switched off, the
  `captured-name` row compiles to different bytes from a fresh build.
- **Moved when it sits above the first change** (`lc_src_edit_reindex`,
  `linked_body_cache_reindex.vibe`). The file table keeps every unchanged
  file when only the edited files' statement counts moved, rebasing each kept
  entry's statement position. Each entry above the first moved index is then
  moved into this build's index space:
  - `call` immediates, found by `scan_body_relocs`;
  - function values (kinds 101 and 102) and the funcref slot log;
  - lambda indices, through the harvest's lambda plan
    (`lc_old_lambda_plan`);
  - record owners, and the record and linemap offsets that a different LEB
    width moves.

  An entry that cannot be moved is dropped and recompiles. That covers a
  removed function, an opcode the scanner does not know, a reference to a
  pad, a record that does not sit on its instruction, and a direct call into
  the lambda region while lambdas moved. Each of the three remaps is
  load-bearing: with any one of them made the identity, a middle-file row
  compiles to different bytes.
- **Re-recorded.** The harvest's guards describe the old layout, so the
  consumed cache is not merged back. Each replayed body is re-recorded
  instead, as a relocated one is.

**The pin capacity.** Source functions sit in `[0, src_n)`, padded to a
multiple of 1024. After them comes the synthesized region, and after that the
lambda slots and every function past the user ones (`_start`, `run`, the
lambdas). An edit that takes the source region across a multiple of 1024
moves all three by a known delta. So under an edit:

- `guard_meta` compares only the lambda slot base relative to the capacity;
- the global half folds the user-function count, the lambda slot base and the
  synthesized indices relative to the capacity;
- the relocation maps the old index space, sized by the old capacity,
  onto the new one.

`a source region that crosses a pin-capacity boundary is relocated` goes from
1010 to 1030 source functions. It reuses the unchanged files' bodies
byte-equal, and with the lambda-slot base shift dropped it compiles to
different bytes.

**Files that moved.** Importing a new module inserts a file into the merge
order, and an import-order change reorders it. Either way every file after the
change sits at another index. The file table then matches files by path
(`body_cache_file_moves`), and for each unchanged file it carries the entries
to the file's new position (`body_cache_move_files`):

- the file index is rewritten;
- each recorded statement position is shifted by how far its file's first
  statement moved;
- the linemap rows' file ids are rewritten;
- the per-file typed-lowering slots are put in this build's order, so each
  file is compared with its own.

A path that occurs twice on either side declines. The linemap step is
load-bearing: without it, the `new-module-first` row compiled to different
bytes from a fresh build, because a moved file's rows named another file. The
body-cached lane never runs `--break`, which is the one mode that embeds a file
id in body bytes, and `dbg_line_on` is part of the global half besides.

**Types.** Constructor tags are `(type_index << 16) | variant`, and
`type_index` counts type declarations in merge order, so a type declared
anywhere moves the tag of every later type. Every tag a body embeds is
recorded at emission: kind 105, `emit_ctor_tag`, `sym` being the tag value.
That covers construction, every match form, `is`, the struct field-dispatch
cases and the record-literal stamp. `lc_verify_blind_relocs` checks each
record against its `i32.const` on every compile. The harvest carries the
constructor table by value (`guard_ctor_names` / `guard_ctor_tags`, VBC15).
A replay maps each old tag through the names that held it
(`lc_ctor_tag_map`); tags below `2 << 16` are built-in and never move. While
every constructor and struct name is unique, the table is compared per TYPE
(`guard_type_rows`). A type's row covers its constructors' names, variants,
field counts and Double fields, but not the moving half of the tag.

- An added or a removed type is tolerated. Its name and constructors join the
  mention check, the removed ones taken from the harvest's constructor table.
  A removed constructor's tag maps to nothing, so a body still naming it
  fails closed.
- A changed type is tolerated too: a variant added, removed, reordered or
  reshaped. Its name and constructors join the mention check, which also
  walks match and handler patterns and record literals. Its constructors are
  also WITHHELD from the tag map (`lc_ctor_tag_map`), so their old tags map
  to nothing and a body embedding one fails closed in the relocation. Every
  constructor arm and construction embeds its tag (a constructor pattern is
  never a catch-all), so each net refuses such a body on its own.
- `body_cache_changed_type_test` adds a variant at the end, adds one in the
  middle, removes an unused one, and makes a payload Double. Each time, the
  downstream file's bodies that only pass the value along are reused,
  byte-equal. The one that matches the type recompiles (`saved=5`).
- Each net alone keeps `saved=5`. With both off, the matching body replays
  (`saved=6`) and is still byte-equal: its tag relocates by name, and a
  payload slot is one word whatever it holds. So no row shows such a replay
  going wrong, and the nets are a conservative refusal.
- A payload made Double declines the whole downstream file when the payload
  reaches a typed site there (an interpolation, a `==`): the per-file
  typed-lowering guard sees the operand type change. The test passes it to a
  generic to keep the lane open.
- `a type removed from a middle file relocates the tags it moved` holds every
  downstream form while their tags move DOWN. It is reused byte-equal, and
  with the tag remap made the identity it compiles to different bytes.
- Load-bearing: with the tag remap made the identity, the `later-type-moves`
  row and the edit-classes `add-type-ahead` row compile to different bytes.
- `every tag-bearing form is relocated across a type inserted ahead` puts each
  form in one downstream file: construction with and without payload, nested
  and guarded matches, `is`, a destructuring `let`, two-candidate field
  dispatch, a record literal and `Option`. Every body is reused,
  byte-equal.
- At scale: a type inserted into `core/hex.vibe` (file 14 of the CLI closure's
  680) moves nearly every tag in the compiler. The warm build with the cache
  on is byte-identical to the cache-off one (16.7 s against 17.5 s), and
  every record check passed.
- The used-builtin set collects constructor names too, so under an edit it is
  compared with this build's constructor names taken out of both sides.
- Not enforced: no lint makes a NEW tag site use `emit_ctor_tag`. At the
  emission point a tag is an ordinary integer, so no pattern separates it
  from one. A missed site would replay a stale tag, and only the corpus row's
  byte comparison catches it, for a form the row covers. Add a form to that
  row when you add a tag site.

- Structs are compared by value (`guard_struct_names` /
  `guard_struct_fields`, VBC13). Structs added, removed or changed (fields
  added, removed, renamed or reordered) are tolerated. The structs both
  builds hold must keep their relative order, because a field access
  dispatches over the structs holding the field in table order. Every
  struct that changed, came or went joins the mention check with its fields
  (`.field`: an access, a record literal's field, a struct pattern's field),
  old and new both.
- The mention check is not enough for a struct. Unlike an enum's, a
  struct's layout reaches a body that spells neither the struct nor its
  fields: `p.y` on a value whose type was inferred reads `y`'s slot out of
  the struct table, and spelling `y` is all it does. So what decides is a
  record of what the body's codegen READ. While a function body whose
  harvest is collected is compiled, every struct and constructor-table
  accessor (`ctor_table_index_of`, `struct_field_candidates`,
  `struct_index_by_field_set`, `agg_info_of_type_name`,
  `ctor_field_is_float`, ...) appends the name it was asked about to
  `layout_read_log`, a field as `.field`. The body loop turns the distinct
  names into records of kind 106 (`blind_kind_layout_read`, `sym` a hash of
  the name) plus a sentinel `sym == 0`. The records ride the blind-reference
  log, so they survive the codec, the file moves and the relocation
  unchanged.
- Under an edit, `lc_layout_refuse` withholds every entry that read a name
  of a struct that changed, came or went, or a changed enum's constructor.
  It also withholds every entry WITHOUT the sentinel: a body compiled
  without the log (a function worker's, or one harvested before it existed)
  says nothing about what it read, and that is not the same answer as "read
  nothing". A hash collision only withholds more.
- `body_cache_changed_struct_test` swaps two fields, makes one Double, adds
  one, and adds a struct that shares a field. The bodies that never read the
  struct (and `==` on two values of it) are reused byte-equal; the ones
  that read a field recompile, and so does the builder.
- A source function whose ROW changed (an added field moves the builder's
  aggregate-return row) no longer declines the lane either
  (`lc_src_rows_mark`). Its name joins the mention check, since a caller
  consumes a row only through a call, a function value or a thunk
  reference that spells it. Its own index is withheld as well, because
  whole-program inference can move the row of a function whose file did
  not change, and its body was lowered against the old one.
  `body_cache_changed_row_test` holds two rows, and neither needs the
  marking: a folded constant's callers are already withheld by the
  per-entry fold signature, and a changed return class moves the
  used-builtin set, which declines first.
- Measured: with the layout check and the field mention both off, the swap
  row replays a stale field offset and is NOT byte-equal. With either one
  alone it is. `body_cache_layout_refuse_test` pins the sentinel rule
  directly.
- `scripts/review_lint.vibex` refuses a raw read of `struct_names`,
  `struct_field_names` or `struct_field_is_ref` in `codegen/expr`: a read
  there that bypasses the accessors logs nothing, and the body would replay
  across a changed struct. The accessors that log it are
  `struct_index_named`, `struct_field_names_at` and
  `struct_first_field_slot`, beside the ones above.
- At scale: swapping `MutMap`'s `size` and `tombs` fields in
  `core/hashmap.vibe` builds the CLI closure warm in 16.6 s with the cache
  on, against 18.6 s on a stage2 that declined the edit and 17.4 s with the
  cache off. The output is byte-identical with the cache on and off. Single
  runs.
- The used-builtin set collects constructor names too, so under an edit it is
  compared with this build's constructor names taken out of both sides.

**Effects.** A declared effect routes through exception tag `3 + its index`,
and the tags past the effects (the unknown-op fallback and the control tag)
move with their count. A body names a tag only as a `throw` or `try_table`
catch immediate, and the scanner reports both (`reloc_kind_tag`). So the
global half leaves the declared effects out. They are compared per effect,
over each effect's ops and arities (`guard_effect_names` /
`guard_effect_rows`, VBC12). A changed effect list is relocated through the
names (`lc_tag_map`), and every entry moves while the map is not the identity.
Added and removed effects are tolerated, with their names and ops in the
mention check.

No row exercises a moved tag. The edit-classes corpus's `add-effect-ahead`
row is reused now, but with the remap made the identity it still answers
byte-equal. An effect declared in the middle file keeps
the existing effects' tags, and none of the corpus's handlers names the tags
past them. An effect declared AHEAD of an existing one also brings a
synthesized type that moves later constructor tags, and that declines on the
type rows. The tag remap uses the same scanned-immediate rebuild as the call
remap, which is tested, and a tag the map does not cover fails closed.

**Thunks.** A module-level non-function `let` is memoized in two globals,
`base + 2k` and `base + 2k + 1` (base 6, or 7 under RC), where `k` is its
position in the UNSORTED thunk list. These are the module's last globals. A
thunk added or removed ahead of a cached one moves those globals, and replayed
unchanged, the cached thunk would read another thunk's memo cell. The rows
record only whether a function is a thunk, so the harvest carries the thunk
list in memo order (`guard_thunk_names`, VBC14). Every `global.get` /
`global.set` immediate (`reloc_kind_global`) is then relocated through the
names (`lc_thunk_map`), and every entry moves while the map is not the
identity. Load-bearing: with the global remap made the identity, the thunk row
compiles to different bytes from a fresh build. Codex found this as a P1 on
#3765.

The rows are defence in depth for one class: a changed borrow ABI moves the
row and the borrow table both, and in the probe built for it the borrow guard
declined first. No row of the corpus is caught by the rows alone.

`tests/body_cache_insert_function_test.vibe` holds the rows, every one compared
byte for byte against a fresh build:

- **Reused:** a helper appended, prepended, or with its own closure, in the
  last file.
- **Reused, with `bif_cap` recompiled:** a new global spelled like a captured
  local.
- **Reused:** a function added together with a type in the last file, which
  moves no existing tag.
- **Types in a middle file:** reused whether or not a later file declares a
  type; a later type's moved tags are relocated.
- **A newly imported module**, listed after the existing imports and before
  them: the unchanged files are reused either way, byte-equal.
- **Effects:** one added in the middle file is reused, and one declared ahead
  of an existing effect is partly reused (its synthesized type's moved tags
  are relocated).
- **Structs:** one added in the middle file with new fields is reused. One
  that shares a field with an existing struct declines.
- **Thunks:** one added in the middle file ahead of a downstream file's own
  thunk is reused, with the downstream thunk's memo globals relocated.
- **A stable refreshed artifact:** a second warm build recompiles exactly what
  a third does.
- **Middle-file edits**, with the downstream file calling the moved
  functions, taking one as a value and building closures. Both the upstream
  and the downstream bodies are reused for each of:
  - an added helper, with and without a closure;
  - a removed helper;
  - a renamed helper;
  - a reorder;
  - a closure added inside an existing function.
- **Width bands:** 200 functions moved by two, so call targets cross the
  one-byte uleb boundary and function-value constants the one-byte sleb one.
  With every width-changing edit skipped, this row and no other fails, so the
  crossing really happens.

An added function must be called. One that nothing reaches is removed before
code generation, and the edit never reaches the body cache at all.

Measured on the compiler's own closure (`codegen_lexer_test.vibe`, 196 files,
5263 functions), `scripts/body_cache_reuse.sh`, one temperature per process
sharing one `VIBE_BUILD_CACHE_DIR`:

| temperature | offered | recompiled | heap_delta |
|---|---:|---:|---:|
| cold | 0 | 5263 | 1,081,422,048 |
| unchanged (warm) | 4431 | 832 | 659,839,296 |
| comment-edited | 4431 | **832** | 930,477,800 |
| reverted (a second one-file edit) | 4431 | 832 | 665,264,816 |

`offered + recompiled == 5263` exactly: everything the file table offered was
replayed. Under the prefix rule the same edit offers **0** — `defaults.vibe` is
early in merge order, so the unchanged leading run ends before almost
everything. The ~832 that always recompile are the pin region's pads and the
prelude-synthesized region, which the filter excludes by construction.

The allocation figure is the KPI, and it moved by less than the reuse did:
1.081 GB cold against 0.930 GB after the edit. Codegen is 28.7% of a warm
compile (measured above), so replaying 84% of the bodies cannot move more than
that share, and the front end still runs whole-program.

`VIBE_BODY_CACHE_REUSE_MODE=verify` reports the SAME counts on every warm row
(`offered=4431 recompiled=832`) and `recompiled=-1` on the cold one, which is
that lane saying no replay compile ran at all: nothing was offered, so there
was nothing to replay. The number is the REPLAY compile's harvest. It used to
be the FRESH compile's, which by construction holds every function, so every
verify row read as a full rebuild whatever it actually reused (Codex P2 on the
PR); the agreement with `on` above is what says the count now means something.
Each warm verify row allocates ~0.432 GB more than its `on` counterpart, which
is the second compile it performs to have something to compare against.

##### What the edit classes actually do (#2669, step 2b)

`lib/@vibe/compiler/tests/body_cache_edit_classes_test.vibe` compiles a
three-file chain and edits the FIRST file once per class, requiring the answer
to equal a fresh compile every time:

| edit to the first file | reuse | equals a fresh compile |
|---|---|---|
| a comment | partial | yes |
| an Int literal inside a body | partial | yes |
| lengthening a string literal | none | yes |
| adding a function | unoffered | yes |
| exchanging two declarations | none | yes |
| adding a closure | none | yes |
| adding a type declaration ahead | unoffered | yes |
| exchanging two struct fields | none | yes |
| adding an effect declaration ahead | unoffered | yes |
| a callee's return type, Int to Bool | partial | yes |
| changing a const's value | partial | yes |

`unoffered` is the file table refusing before any guard is consulted: those
edits change the file's statement count, so the stored indices are not this
build's. `none` is the lane being offered entries and replaying nothing of
them — a guard declined, and the prefix it narrowed to is empty because the
edit is in the first file. The `partial` rows are what the step buys; the rest
are the conservative fallback, and each is a case relocation would later
convert.

The Int-to-Bool row is there because review raised it as a P0: a callee that
changes between two scalar return types keeps its name, arity and
scalar-return classification, so no name-keyed table separates the two, while
the checker's per-call-site render and `eq` tables do. Two measurements came
back, pointing opposite ways, and both belong here.

**The channel is real.** Reading the untouched consumer's own typed-lowering
rows while editing the callee's file: a comment, a same-length body edit and a
body edit that lengthens the callee's file all leave them at `[715]`; the
`Int`-to-`Bool` change moves them to `[717]`. So those rows track the
interfaces a module reads rather than the bytes anyone else adds — an
untouched consumer's classification really does move on an upstream interface
change, and nothing name-keyed is watching it. `guard_typed_lowering`, a
per-FILE fingerprint of `module_typed_lowering_offsets_for_path` and
`module_typed_eq_rows_for_path`, is that watch.

**The row does not prove the guard necessary.** Rebuilt with the stamp
neutered, so the guard is never consulted, the row still reports `partial` and
`equal=true`: the callee's return classification is program-wide, a
`guard_layout` slot moves, and the lane declines before the typed-lowering
guard could matter. It is carried on the same footing as the ten `guard_layout`
slots below that this corpus leaves unproven. The shape that would separate
them — a classification moving through a type alias or a generic
instantiation, with every layout slot still — is the one the fixture cannot
build.

It is per file and not whole-program for a third measured reason: a
whole-program comparison declines on every edit there is, since the edited file
moves its own slot. Measured with the comparison whole-program, every row in
the table above that reuses went to reusing nothing.

**The guard set is sufficient — every row is byte-exact — and the test proves
some of it necessary rather than all of it.** Dropping a slot and re-running:
the string-pool slot flips `string-literal` to a wrong module, the struct
field-name slot flips `swap-struct-fields`, and the function-vector slot flips
`swap-order`. The other slots stay green under this corpus: they are carried on
the `CompileCtx` enumeration argument, not on a case that exercises them.

Unused struct and enum comparators may be pruned without disabling body
reuse (#2721). Deleting a declaration preserves the surviving bodies; the
layout guards still decide whether their embedded indices remain valid.
Constant Bool parameter folding continues to refuse cache publication and
consumption because it rewrites a body's meaning based on other call sites.
The edit-class corpus includes unused types, and the source-position regression
checks that pruned comparator helpers cannot move a later function into the
unchanged source prefix.

#### Where a compile's allocation actually goes, by PHASE (2026-09-12)

The rows below are the same instrument as the section that follows, cut by
phase instead of by lane: `scripts/compile_phase_memory.sh` drives the #1553
heap-mark lane (`compile_file_fs_mode_rc_heap_marked`, selected by
`VIBE_PROFILE_MEMORY_MARKS=1`) at three temperatures sharing one
`VIBE_BUILD_CACHE_DIR`. A delta between two marks is bytes ALLOCATED in that
phase. Corpus: the compiler's own closure, leaf `lib/@vibe/core/defaults.vibe`,
checked to be in it. Reproduced to the byte across runs.

| phase | cold | unchanged (warm) | one-leaf edit |
|---|---:|---:|---:|
| collect sources | 200.2 MB | 19.9 MB | 33.6 MB |
| **type check** | 269.2 MB | **11.3 MB** | **331.4 MB** |
| merge | 63.4 MB | 187.5 MB | 78.7 MB |
| codegen | 359.6 MB | 359.7 MB | 359.6 MB |
| write output | 25.2 MB | 25.2 MB | 25.2 MB |
| **total** | **917.6 MB** | **603.6 MB** | **828.5 MB** |

**The type check is what a one-file edit costs.** It is 11.3 MB when nothing
changed and **331.4 MB** when one leaf did — *more than a cold check's 269.2
MB*. That single row is #2510's fifth criterion failing: the live set is not
bounded by the edited module because the TYPE CHECK is not. Everything else in
the edited column is within a few tens of MB of its unchanged value.

Two readings that are easy to get wrong, so they are stated here:

- **The phases do not partition the work cleanly.** The parse happens inside
  whichever phase first needs a statement list. Cold, `collect sources` pays it
  (200.2 MB) and the merge is cheap; warm-unchanged, the typing cache hits so
  nothing has parsed yet and the merge pays it (187.5 MB). That row moving is
  not extra work appearing. Compare TOTALS; read a phase as "where this
  temperature paid".
- **This lane has no body cache.** `compile_file_fs_mode_rc_heap_marked` calls
  the plain RC compile, so codegen is a flat 359.6 MB in every column. The
  body cache (#2669 step 2b) is what moves that one, and on the lane that has
  it a one-leaf edit measures 0.923 GB against a cold 1.075 GB.

So the remaining work for criterion 5 is the check, not the back end: an edit
to one leaf must re-check that leaf and the modules whose interfaces it
changes, not the whole closure. That is #1379's semantic-module granularity,
and this row is the number it has to move.

##### Typing reuse on the compile lane — the default (#2728)

The check lane's typing-dependency env reuse (TDRE10) is also the compile
lanes' default: on a one-leaf edit only the edited module and the modules whose
interfaces it changes are re-checked, instead of the whole closure.
`VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE=1` opts out on every lane.

It was off on the compile lanes until both halves below held. The first
measurement of it (2026-09-12) was a regression: 1,647 MB against 271 MB for a
cold check phase, because a cold compile paid the whole transport for reads
that could not succeed.

**The cost.** Most of that cold cost was the size of what each module
published. #3783 memoized each dependency's env text. #3800 cut the alias down
to the target fingerprint and wrote the key and target once. #3808 stopped
building three strings, each as large as a module's source plus its
dependencies' env texts, and never reclaimed on the bump lane: the reuse key,
a copy of it hashed to name the alias path, and the witness text that embeds
it. The key is now kept as its segments' payloads (`TypingReuseKey`), the alias
path is named by a digest of those payloads, the witness is written piece by
piece, and a stored key is compared against the payloads where it lies.

**What a witness stores (#2825).** A key carries every direct dependency's
whole env text, so a witness that stored its key inline copied each
dependency's text once per consumer. On the CLI closure (733 modules, 4,677
direct-dependency edges) that was 144 MB of a 173 MB cold witness set, for
727 distinct texts totalling 5.6 MB. Every leaf edit republished the 592
dependent witnesses under new conservative fingerprints, with the texts again,
so the cache grew about 177 MB per edit. A witness now names each dependency
env text by digest (`#<len>:<digest>` in place of the inline `<len>:<text>`
segment) and the text is written once, to a shared text store
(`selfhost_typing_dependency_env_reuse_text_v1`). The identity is unchanged:
a lookup reads the stored text and requires it to equal the live text byte for
byte, so the digest only locates a record and a collision can only cost a
reuse. A torn or foreign text record misses and is rewritten by the next
publication. The reader accepts either segment form at any position, so a
forged inline witness is still compared by content.

Measured on the CLI closure with reuse on, N=3 medians per side, each side in
fresh caches, emitted wasm byte-identical to the inline-witness compiler:

| | inline witnesses | by-reference texts |
|---|---:|---:|
| cold cache directory | 185 MB | 46 MB |
| cache growth per leaf edit | +177 MB | +35 MB |
| cold `heap_ptr` | 2783 MB | 2797 MB |
| edited-warm `heap_ptr` | 1917 MB | 1799 MB |
| edited-warm peak RSS | 2016 MB | 1895 MB |

The cold heap rises by 14 MB, because the walk keeps the texts it has written or read.
Cold wall moved within noise: reuse on minus reuse off went from +0.79 s to
−0.19 s, and single samples spread over about 1 s on this host.

**One publication per module slot (#2825).** The remaining +35 MB per edit was
the previous witnesses and target records themselves: nothing deleted them. A
publication now retires the previous one of its slot. A slot is every input-key
piece except the source and the dependency envs: the owner path, target flags,
typing semantics and resolution authority. So a `vibe test` of another file,
which lowers other test blocks, keeps its own slot. A small record per slot
(`selfhost_typing_dependency_env_reuse_latest_v1`, tag `TDRE10L1`) names the
target fingerprint and alias digest it published last. The next publication
handles the old records in this order:

1. The old alias is repointed at the new target if the key is unchanged (a
   reuse hit leaves the alias naming the target it was found through).
   Otherwise it is deleted.
2. The old witness and target record are deleted.

Deleting only turns a later lookup into a miss, since every reader checks that
the records it reaches exist and bind each other. An edit reverted later is
checked again rather than reused. Dependency env texts are shared between
witnesses and are kept.

On the CLI closure (740 modules), the cache directory after a cold build and
three edits went from 58 / 95 / 131 / 168 MB to 61 / 61 / 62 / 62 MB. The
witness count stays at 740. Edited-warm wall time is unchanged within noise.
`compile_typing_env_reuse_oracle.mjs` pins it: each body edit must leave as
many witnesses and targets as the cold build wrote.

Reuse on minus reuse off, measured after #3808:

| corpus | case | heap | wall (advisory, one round) |
|---|---|---:|---:|
| selfcompile KPI input (`scripts/selfcompile_kpi.sh`) | cold | +12.1 MB (+1.0%) | — |
| CLI closure (694 modules) | cold | +21 MB | +0.6 s |
| CLI closure | comment appended to `core/hex.vibe` | −518 MB | −3.5 s |
| CLI closure | exported fn added to `core/hex.vibe` | −59 MB | −0.6 s |
| CLI closure | private fn added to `cli/entry.vibe` | +1 MB | +0.2 s |

The `core/hex.vibe` edits re-check 1 of 561 modules with reuse on (a comment)
and 283 (an exported function), against 561 with it off.

**The correctness side is a gate:
`scripts/compile_typing_env_reuse_oracle.mjs`** (stage2-oracles, with
`scripts/compile_typing_env_reuse_oracle_test.sh` as its red self-test). Most
edit shapes cannot be an oracle. The input key is the module's verbatim source
plus each dependency's exact env text (`typing_dependency_transport_input_key`),
so editing the module under test changes its own key, and editing a
dependency's *interface* changes every consumer's key. Both **miss** and are
freshly checked, and an oracle built from them passes whether or not the reuse
arm is correct. The shape that **hits** is a dependency-body edit that changes
meaning while leaving that dependency's public `TypeEnv` text identical: the
consumer's key is unchanged, the hit happens, and the open question is whether
the compile-only state it republishes (the typed-lowering offsets, #2391) is
still right. The public env being equal is what makes the hit happen, and is
exactly why the public env cannot detect the problem. So the oracle does five
things:

- it makes that edit three ways -- an exported body, a non-exported helper's
  body, and a non-exported helper that starts performing an optional
  capability (`perform? Env::get`) -- with a consumer whose `==` resolves only
  through its typed-lowering row;
- it requires the unchanged consumers to record a dependency-transport hit,
  because without one the oracle is vacuous: a cold compile has no hit to get
  wrong, and an edit that keeps the program's meaning (a comment) answers the
  same through a stale reuse as through a fresh check;
- it requires the module AND its executed result to have changed;
- it compares the module, the diagnostics (status, stdout, stderr, `.diag`)
  and the executed result against a fresh compile with reuse off in its own
  cache;
- it requires the executed result to equal the value it derives from the
  fixture state itself. The result subtracts, so swapped arguments show; equal
  declarations alone would not show that the edit landed (#3796).

The rest of the oracle is about refusal (#3796). A body error behind an
unchanged public env gives the fresh diagnostics, and the next good edit
recovers. From a snapshot of the cold cache, the alias, witness, dependency
text and target records are corrupted **independently**, each once malformed
and once spliced from another valid record (a stale but well-formed one); each must miss
and compile to the fresh module, and the uncorrupted snapshot must hit first,
or a miss would prove nothing about the corruption. The `#cfg` flag set, the
checked-error-row mode and the resolution authority are reuse authority, so
the same edit under a different one misses; the backend (`VIBE_RC`) is not
typing authority, so it hits, and must still equal a fresh compile under that
backend. `--allow-*` / `--deny-*` reach only `vibe run`'s artifact, so a
full-grant run then a `--deny-env` run through one reuse-on cache must execute
exactly like a fresh `--deny-env` run. That lane publishes no transport
records today, and the oracle fails when it starts to, because the case would
then need hit evidence. Interface edits and every record overwritten with
garbage miss, as before.

Every build's source digests, configuration, artifact digest, diagnostics,
executed result and telemetry are in the oracle's JSON. Its self-test replays
that recording through a scripted runner and perturbs one cell per case, then
drives the real compiler behind wrappers: a flipped module byte; the
typed-equality rows stripped from the reused records, with every binding kept
consistent so the reuse is still taken (the build must be refused at the
comparison); each corruption undone before its build and each
authority-changing configuration reset, so the real compiler hits and the
oracle's "must miss" fails; and `--deny-env` dropped from a run. Compile-lane
reuse stays opt-in: this is the correctness half, not the cost decision. The per-file AST cache was built before it was
measured and came back at exactly zero (#2668); this is the same mistake one
step later, caught by measuring first (#2728).

#### And what it costs in ALLOCATION — the #2510 criterion-5 KPI (2026-09-11)

The section above bounds the split's cost in wall time. The KPI #2510 actually
states is about memory: *the live set is bounded by the edited module plus
interfaces.* That had never been measured. It is now, by
`scripts/prelude_split_memory.sh` (protocol in its header) driving
`scripts/prelude_split_memory.vibex`.

Corpus: the compiler's own closure (`codegen_lexer_test.vibe`, 190 resolved
files, a split the lane really builds — 191 modules, 4728 statements mapped,
asserted per run so no row can be vacuous). `cache_mode = "off"`, one lane per
process, a fresh `VIBE_BUILD_CACHE_DIR` per lane. `heap_delta` is
`Profiler::heap_bytes`, a bump pointer, so it is **bytes allocated across the
compile, not bytes live at its end** — the allocator never frees, and no
instrument here can report a live set. N=1 per cell because the figure is
deterministic: every row below reproduced to the byte across separate runs.

| lane | cold | after a one-module edit | unchanged (warm) |
|---|---:|---:|---:|
| whole-program | 821,534,940 | 765,264,132 | 510,478,340 |
| per-module (split) | 938,747,492 | 882,476,684 | 627,625,364 |
| **split − whole** | **+117,212,552** | **+117,212,552** | **+117,147,024** |

**The split costs a flat ~117 MB and recovers none of it** — +14.3% cold,
+15.3% on the edit it exists for, +22.9% warm. The two left-hand deltas are
equal *to the byte*, which is the shape of the cost: one interface context
built per module, paid once per module, independent of what changed. The
emitted wasm is byte-identical in every row (4,025,394), so this is a price for
decomposition, not a behavior difference.

**So criterion 5 is not met, and the split alone cannot meet it.** A one-module
edit rebuild costs 765 MB against a cold 821 MB — 93% of a cold build — so
almost nothing is being reused across processes to begin with. Nothing persists
a module's prelude: there is no per-module prelude artifact anywhere under
`lib/@vibe/compiler/cache/`, so a new process re-runs all 191 module preludes
whatever changed, and the split adds its ~117 MB on top of that.

That re-orders the remaining work. The per-file binary AST (#2510's fourth
bullet) is not the last item on the list; it is the **prerequisite that makes
the split pay for itself**. Until a per-module artifact survives the process,
turning the split on is a straight loss, which is why it stays behind its
`use_split` argument rather than becoming the default.

One measurement note, because it nearly produced a false result. The first run
of this experiment edited `cache/header_codec.vibe`, which is **not** in this
corpus's closure, and every "leaf-edited" row came back byte-identical to the
unchanged row — a vacuous experiment that read as a finding. The script now
resolves the closure with the compiler's own `vibe deps` and refuses a leaf
that is not in it.

#### What a WARM build actually spends its time on (2026-09-11)

The section above says a one-module-edit rebuild costs 93% of a cold build,
and leaves open what is being repeated. #2510's fourth criterion assumed it
was the front end: persist the per-file AST and a warm build stops re-parsing.
It is not.

A warm compile of the compiler's own closure (`codegen_lexer_test.vibe`, FS
lane, cold run first into the same `VIBE_BUILD_CACHE_DIR`), profiled with
`node --cpu-prof` through a stage2 built with `VIBE_WASM_NAMES=1` — without
that flag every frame is `wasm-function[N]` and the profile says nothing:

| area | share of 3.66s |
|---|---:|
| compiler/codegen | 28.7% |
| runtime helpers (`__rt_*`) | 25.6% |
| compiler/normalize | 11.5% |
| host JS / other | 8.5% |
| **parser** | **6.9%** |
| core | 6.7% |
| compiler/core | 5.7% |
| compiler/perceus | 5.2% |
| **compiler/loader** | **0.1%** |

**The back end dominates**: codegen + normalize + perceus is 45.4%. The parser
is 6.9%, which is the CEILING on what a perfect AST cache can remove from a
warm build — and the loader, where such a cache has to live because it is the
only lane with an `Fs` row, is 0.1%.

That last row does not explain #2668's observation that turning the AST cache
on left the warm heap byte-identical, though it was read that way: 0.1% is what
the consulting code costs, not evidence about whether it runs.

**The prefetch runs at the head of the FS planner's walk, and it has to.** That
is the one point every planned module passes through exactly once, before any
branch decides it needs no parsing. Planning settles a module without parsing
in five different ways — a valid persistent leaf fingerprint, an in-process
reuse decision, `ripple_get_deps`, the persistent dep list, and the
module-header text cache — so a prefetch attached to any one of them serves
only the modules that happen to take that branch, and a warm build takes a
different one for every module in the closure. A leaf, for instance, never
resolves dependencies at all.

`ast_cache_prefetch_fs` owns the decision and the count for the same reason:
it has two call sites with different timing (the header pass runs before the
planner), and a policy or a counter written at one of them is simply absent at
the other. `ast_cache_prefetches` in the incremental telemetry is what says the
cache is being read at all.

### And with the cache working, it does not pay

On the full CLI closure, warm, `ast_cache_prefetches` reports **420 of 420**
and `non_walk_parse_operations` drops from 420 to 0: the merge lane's parses
are entirely replaced by decodes. That costs more than it saves. N=3, fresh
cache directory per repetition, cold-vs-cold and warm-vs-warm (#2393):

| | cache off | cache on | delta |
|---|---:|---:|---:|
| cold heap | 2,496,792,016 B | 2,707,974,464 B | **+201.4 MiB (+8.5%)** |
| warm heap | 1,901,348,896 B | 1,941,911,080 B | **+38.7 MiB (+2.1%)** |
| cold wall (median) | 11.94 s | 13.09 s | +1.15 s (+9.7%) |
| warm wall (median) | 8.94 s | 10.02 s | +1.07 s (+12.0%) |

Heap is byte-identical across repetitions in every configuration; the emitted
wasm is identical across all twelve runs. The decode allocates the same AST
the parse would have allocated and reads 42 MB of artifacts to do it, against
a parser that is only ~6.9% of the warm build to begin with — the ceiling
above. So the flag stays opt-in and off.

The value of the wiring is not a speedup; it is that **the question became
decidable**. Before it, the cache could not be evaluated at all: it was paying
its full write cost on every cold build and being read on none, and the only
signal available — a byte-identical warm heap — was indistinguishable from
"the cache does not help". Now `ast_cache_prefetches` says the cache is being
read, so a warm build that is slower with it on is the per-file AST cache
losing on its merits. That is the answer to #2510 criterion 4 on this corpus.

(CPU share, not allocation; the KPI is allocation and the two are correlated
rather than identical. N=1, which is enough for a structural read — a 0.1%
area is not going to be the 30% that matters under a different sampling — and
not enough to rank the 5-7% rows against each other.)

**So criterion 5 is not reachable by caching parses.** What a warm build
repeats is the back end running over the whole program, and the constraint on
fixing that is already recorded above: a cached function body contains call
immediates that depend on GLOBAL function index assignment, so a per-module
body cache cannot replay a body into a build where indices moved. That is the
problem to solve — index-independent bodies, or a relocation step at the link
— and it is a different piece of work from anything #2510's first four
criteria describe.

#### What the split path still costs a caller

Codegen emits functions in statement order, so switching lanes permutes the
synthesized tail and changes the emitted wasm's layout, even though the program
is the same declarations with the same bodies in the same source order. Whether
the *behavior* is identical is a further question that neither the keyed columns
nor either order counter answers.

The split path is therefore gated behind a `ModuleSplit` the caller must build,
and every guard on it **fails open** to the whole-program prelude:

```
file_count > 0
Array::length(stmt_file_id) == Array::length(stmts)
Array::length(import_closure) == file_count
```

Every **index** is checked too, not just the lengths: a `ModuleSplit` is
publicly constructible, so an out-of-range `stmt_file_id` reaches `Array::get(
parts, id)` and traps, and an out-of-range closure member is silently skipped by
the context loop — which narrows that module's context, the one failure mode
that produces a wrong program rather than a slow one. Both become "not usable",
which is the whole-program prelude.

And the map must be **non-decreasing**. The link partitions by module and emits
the parts in module order, so a map that revisits an earlier module — `[0, 1,
0]` — reorders the statements the source wrote. That was not hypothetical: the
`ORDER residual=2 of=4` test above feeds exactly that shape, so the failure had
a demonstration in this tree while the guard still accepted the input.
Non-decreasing is what makes partition-by-module order-preserving, and it is
what the merge produces anyway — the map is a run-length decode of per-file
statement counts.

A caller whose closure had unresolved edges passes an empty `import_closure`,
which fails the length check for the same reason. Narrowing a module's context
silently is worse than not splitting at all.

#### The split entry answers for the whole prelude, not part of it

Two things the per-module driver would otherwise drop on the floor, because the
driver grew out of a measurement and a measurement does not have to refuse
anything:

- **A collision is an error.** `prelude_run_per_module` links with the
  *reporting* fold, which keeps the first definition and records the conflict —
  right for a measurement, which wants every colliding key rather than the
  first. Production must not pick a body, so the split entry turns a reported
  collision into the same refusal `link_fold_duplicate_definitions` throws,
  from one spelling shared by both.
- **`zero_alloc_check` stays whole-program.** It is interprocedural — `za_walk`
  walks callee bodies out of the table the check builds from the statements it
  was handed — so a module's partition, which does not contain an imported
  callee's body, reports that callee as not proven allocation-free. Run per
  module it would REJECT a valid program, which is worse than a missing
  diagnostic. The per-module run stays for the oracle, so `DIAGS prelude=` keeps
  showing the difference rather than hiding it.
  `lc_validate_stdin_provider_stmts`, by contrast, is purely local — it walks
  each statement's own expression with no callee lookup — so the per-module
  union equals the whole-program run and it stays per module.
- **Three passes reject by returning a message**, not by throwing:
  `lc_inject_async_sleep_boundary`, `suspend_cps_pass` and
  `evidence_dict_pass`. The pass dispatch discarded all three into `let _ =`,
  which for a declaration-comparing measurement is merely incomplete and for an
  entry whose return value *is* the caller's error list is silently wrong: a
  program the whole-program prelude rejects would compile. Both lanes collect
  them now, which is also why the oracle's counter is `DIAGS prelude=` rather
  than the `validators=` it used to be — it compared two validators because the
  other three were thrown away.

### How the comparator family closed (#2634) — 9 rows, now zero

It was a synthesized comparator whose *existence* or *shape* depended on what
the synthesizing module could see:

```
missing  MutMap::equals__N6_String__N3_Int      MutSet::equals__N6_String
         MutMap::equals__N6_String__N6_String   __arr_equals__A1_N6_OptionN3_Int
         __arr_equals__A1_N6_OptionN6_String
content  CbfTable::equals   AliasIdx::equals   ExportRenamePlan::equals
         StrTable::equals
```

#2631's sibling one level up. That issue was a comparator whose *body* depended
on module visibility, and is fixed — which is why `collisions=0` survives a
non-zero `invisible_split`.

**Measured which half of "never emits" it is**, because the two have different
fixes: a module can fail to *record* the need, or record it and fail to emit.
`SYNTH requests=75/70:-A1_N6_OptionN3_Int+` — the whole program asks for 75
helpers, the union of the per-module runs for 70, and the five it does not ask
for are exactly the five missing rows. **The need is never recorded.** A `==`
site whose operand type the module cannot resolve takes a different arm, and
nothing downstream can supply a helper nobody asked for.

So this is not "the link should mint what the modules left out" — the link would
have nothing to mint *from*. The instantiation set it would key on is precisely
what the per-module run fails to produce.

**All five, named:**

```
A1_N6_OptionN3_Int         Array[Option[Int]]
A1_N6_OptionN6_String      Array[Option[String]]
spec:A2_N6_MutMapN6_StringN3_Int      MutMap[String, Int]
spec:A1_N6_MutSetN6_String            MutSet[String]
spec:A2_N6_MutMapN6_StringN6_String   MutMap[String, String]
```

Every one is a **builtin or core generic at a concrete instantiation** —
`Option`, `MutMap`, `MutSet`. No user-declared type appears.

Three of the five are **#2631's mechanism exactly**:

```
lib/@vibe/core/index.vpkg:72     type MutMap[K, V]          ← opaque, generic
lib/@vibe/core/hashmap.vibe:52   export struct MutMap[K, V] ← the real declaration
```

Opaque in the `.vpkg` contract, concrete in the sibling implementation — the
`PerceusActionKind` shape. `MutSet` is the same.

They did not *look* like it, and that was the instrument rather than the
program. The invisible-nominal recorder sat on `eq_for_typed`'s `TyName`
fallthrough; `MutMap[String, Int]` is a `TyApp`, which takes a generic-head arm,
finds nothing in the generic-struct registry and declines *silently*. So the two
sets looked disjoint and the same cause read as two. **A measurement that covers
one arm of a dispatch reports the other arm as absence.** With the `TyApp`
fallthrough recorded too, `invisible_split` goes 15 → 17 and the two new entries
are exactly `MutMap[]` and `MutSet[]` — while `invisible_whole` stays **0**, so
the arm is unreachable on the whole-program lane just like its twin.

The remaining two, `Array[Option[Int]]` and `Array[Option[String]]`, are **not**
explained by that. `Option` is a true builtin — there is no `enum Option`
declaration anywhere under `lib/`, it is handled by a builtin arm rather than a
declaration — and it does not appear among the invisible heads under either
recorder.

Three mechanisms are now ruled out for that pair, which is worth having even
without the answer: it is not an invisible nominal, not an invisible generic
head, and not a **typed-channel refusal**. That last one is a fourth silent
consequence of visibility and is measured for its own sake:

```
SYNTH requests=75/70:-…+   typed_refused=0/3:-+BinderAuthorityNodeKind
                                               BinderSemanticRole  Stmt
```

`dtd_typed_eq_admitted_ty` gates a row the checker supplied on
`eq_ty_field_is_content_comparable`, an allow-list that consults declared
registries. The whole program refuses **zero** rows; a per-module run refuses
three, all of them already in the invisible list. A refused row means the `==`
site never learns its type — so it never reaches `eq_for_typed`'s `Array` arm
and never records the helper it needs. None of the three is an `Option`, so the
pair stays open.

### Could a minting link close it?

The four sites all conflate two questions — *does this `==` need a structural
helper* and *can this module generate one* — and answer both with silence. They
are separable: needing is a property of the operand's type, which the checker
supplies; building needs the leaf declarations, which only some module has.

Recording the first without the second gives the answer directly:

```
deferred=3   unmintable=2: A1_N6_OptionN3_Int  A1_N6_OptionN6_String
```

A **deferral** is a helper a module knew it needed and declined to build.
**`unmintable`** counts what the whole program asks for that *no* module records
in either form.

**The link now does it**, and it closes all five:

```
deferred=3   minted=5   indirect=2          keyed missing: 6 → 1
```

`eq_mint_deferred_into` replays the deferred needs against the **concatenated**
program — which has every declaration a module lacked, by construction — and
runs `emit_recorded_structural_eq`, the same generator the whole-program lane
uses. Every comparator *absence* is gone; the one remaining `missing` row is
`struct:__EvDict_Source`, which belongs to the evidence family.

`minted=5` from `deferred=3` is the fixpoint at work: that generator loops, so
minting the `MutMap` / `MutSet` specializations records their nested
instantiations and mints those too — which is how the two `Array[Option[*]]`
helpers arrived.

**That corrects a prediction made here before the implementation existed.** The
counter now called `indirect` was called `unmintable`, and read as *"no link
could mint these"*; both were minted. It measures what no module recorded
**directly**, which is weaker and more useful: a need that reaches the link only
through another need. The 3/2 split was real; the conclusion drawn from it was
not.

### And the body differences close too

Minting does not address a *different body* — nothing is absent there. But it is
what made the fix available. The `TyApp` fallthrough now emits the **reference**
and lets the link build it:

```
whole   MutMap::equals__N6_String__N3_Int(a.idx, b.idx)
split   (a.idx == b.idx)          ← an aggregate, compared by reference
```

This is #2631's fix at the site #2631's fix did not reach, and it needed the
minting step first: `n::equals` already existed under that name, but a generic
instantiation's comparator is a *specialization* whose body a module that cannot
see the head's fields cannot generate.

```
keyed content:  9 → 5
```

`CbfTable::equals`, `AliasIdx::equals`, `ExportRenamePlan::equals` and
`StrTable::equals` are gone. **The comparator family is closed** — all nine
rows, five absences and four bodies.

**The evidence family — 6 rows.** `struct:__EvDict_Source` itself, plus the
functions the whole-program evidence pass rewrote to take an explicit
`__EvDict_Source` parameter and the call sites that thread a
`record { Read: …, Exists: … }` into them (`resolve_import_path_probe`,
`resolve_path_fs` in two modules, `resolve_existing_import_path`,
`check_linked_file_source_groups`).

Neither lowering is wrong; they are two coherent ones, and a module that merely
*defines* a function cannot choose between them. This produces no wrong answer
at either granularity — it produces two programs that cannot link to each other.

The dependence runs **backwards along the import graph**: `effect Source` is
declared and performed in `core/module_graph_path.vibe`, and handled in
`loader/loader.vibe`, which imports core and not the reverse. So carrying the
decision as interface data on *dependencies* cannot work — a dependency's
contract cannot hold a decision that depends on its dependents. What decomposes
is the *inputs*: measured, the union of the per-module (declared, handled,
performed) facts equals the whole-program facts (`EVIDENCE declared=6 handled=5
performed=4` on the closure measured above), sampled immediately before the pass
runs. So the module collects,
the link unions and decides, and the link rewrites — with the rewrite then
cacheable per function keyed on (body fingerprint, migration set). #2633.

Three of the nine content rows were read as rendered diffs; the other six are
classified by declaration name, which is why the excerpt block still prints the
first three in full.

### The phases after the prelude (#2575 item 4)

Between the prelude and codegen, `linked_compile` runs three whole-program
analyses: `compute_borrow_returning_names`, `compute_borrow_param_user_fns`
(ADR-0092, per-position masks), and `compute_may_return_view_fns`. All three
are interprocedural fixed points: a caller's classification depends on callees
that may live in other modules.

Borrow-parameter inference starts with every globally eligible position and
removes borrowed bits when the existing ownership judgment finds a consuming
use. A reverse call graph schedules only affected callers, including wrappers,
self calls, and mutually recursive components. The masks only shrink; with at
most 32 eligible bits per function, termination needs no arbitrary round limit.
The final mask changes the caller and callee ownership plans together.

Eligibility is decided before iteration. Non-identifier call arguments,
functions used as values, entry exclusions, duplicate declarations, and captures
must not acquire a speculative borrowed ABI. Aliases and declarations carry
owned entries when they shadow a builtin; local callee binders suppress that
callee's mask while the body is checked. These are RC optimization facts, not
a replacement for the language's safety borrow checker.

A module cannot safely publish its final masks in isolation:

- A name the whole program has and the module union lacks is a conservative
  miss. A wrapper cannot see the borrowed ABI or returned view of an imported
  callee.
- A name the module union has and the whole program lacks is an ownership
  disagreement. A call in another module may pass a temporary argument and
  globally disqualify an otherwise eligible position.
- Matching names are insufficient: two lanes can classify the same function
  with different borrowed parameter bits. Compare `(name, mask)` pairs too.

The module collects call-site disqualifiers and retains its bodies. The link
unions the facts and solves the combined call graph through
`borrow_fixpoint_link_parts`, the same solver used by the whole-program entry.
The oracle still compares independently linked body-local round-0 facts with
`compute_borrow_param_user_fns_round0`; that is a separate decomposition check,
not the production stopping point. Its existing `link_round01` report field
now compares the final fixed point, including mask equality.

`dce_entry` is the oracle's sampling caveat. Production runs
`fold_const_bool_params` and `dce_stmts` between the prelude and these analyses
when the merged program defines `entry_name`. A folded constant Boolean can
remove a consuming branch; DCE can remove a helper. The split oracle cannot
reproduce entry-rooted DCE independently in each module, so it prints
`unmeasured` when that condition holds. A `dce_entry=0` comparison describes the
unpruned closure, not every `vibe build` of that closure.

### Reusing the prelude's effect passes across builds (#4042, #4043, #4123)

Suspend CPS and the evidence pass are whole-program, and rewrite about 100 of
16,000 statements. `VIBE_PRELUDE_REUSE` (default `off`) keeps their output per
entry and replays it on the next build when no edit can move what they read
(`codegen/wasi/prelude_reuse.vibe` and `prelude_reuse_admit.vibe` hold the
rule):

- `on` replays when it can and records otherwise;
- `verify` replays the same way, runs the passes as well, produces their
  output, and fails the build when the replay differs from it in any
  statement, offsets included;
- `VIBE_PRELUDE_REUSE_TRACE=<file>` appends one line per build: whether it
  replayed and, if not, why; in `verify` mode, `; verified` or the first
  statement that differed.

An exception throw is not effect syntax for this rule (#4123). The desugar
lowers `throw(v)` to `perform <Exception>::Throw(v)`, but the passes read
whether a callee throws only off its declared row, which replay compares. So
an edit inside a function that throws replays, while one that adds or drops
`Exception` in its row does not.

**The gate: `scripts/prelude_reuse_oracle.mjs`** (stage2-oracles, with
`scripts/prelude_reuse_oracle_test.sh` as its red self-test).

- **Edits:** a small program with a handler is edited step by step: a pure
  body, a comment, an added helper, the performing body, a pure body again,
  a `with Exception` body, then a function that gains `with Exception`.
  Three caches follow the sequence: `on`, `verify` and `off`.
  - A step that must replay and does not fails the oracle, since its
    comparison would prove nothing.
  - Every `on` module must equal the `off` one in bytes and in its executed
    result, which must also equal the value the oracle derives from the
    fixture.
  - Every replaying `verify` build must say `verified`.
- **Commits:** the CLI closure of the last three first-parent commits is
  built oldest first in `verify` mode, through one cache. Every build must
  succeed. An older tree that this compiler cannot build is skipped and
  reported. HEAD's tree must build, and at least two trees must. Most real
  commits miss, so HEAD's tree is then edited where a replay is expected: a
  comment above everything in `core/hex.vibe`, a function appended to it,
  and a `let` inside its `with Exception` function `hex_digit_value`. Each
  build must replay and verify, over the whole CLI closure.

Reuse stays opt-in until this gate has stayed green.

## The incremental KPI, at three sizes (#1959 line)

`pkf run kpi-incremental` (`scripts/incremental_kpi.mjs`) measures what an
UNCHANGED rebuild skips, and CI runs it inside `bench_metrics.sh` so the table
lands in every run's step summary, in the PR comment, and in the `bench-data`
snapshot that carries the trend.

Three sizes, because every incremental number this document used to carry was
measured on the compiler's own 420-module closure, and that closure turns out
not to represent the sizes people actually build. Each corpus is a committed
root with a REAL entry — a `__no_entry__` root skips the constant-Bool fold
and the late DCE, which is most of what a build does after the checker (#2818).

Measured on a stage2 built from `bcb306a` plus the linked-output memo (below):

| corpus | modules | modules skipped | heap | wall | no-op heap | no-op wall |
|---|---:|---:|---:|---:|---:|---:|
| small (`bench/incremental/edit_cycle`) | 2 | 100 % | 90 % | 82 % | 74 % | 51 % |
| medium (`scripts/review_lint.vibex`) | 16 | 100 % | 79 % | 76 % | 23 % | 31 % |
| selfhost (`lib/@vibe/cli/entry.vibe`) | 678 | 100 % | 62 % | 59 % | **9 %** | **4 %** |

Absolute, in the same run: selfhost cold 20.2 s / 2381 MB, warm 12.0 s /
1482 MB, no-op 0.85 s / 207 MB; medium 412 / 314 / 129 ms; small 201 / 165 /
103 ms, where a bare `--version` invoke of the same compiler takes ~87 ms.

Read `modules skipped` against `heap` and `wall`. **The module walk is fully
skipped at every size** — nothing is rechecked — and a small project still
pays 82 % of a cold build's wall when the back end runs again. That back end is
whole-program (`§Which layer a distributed cache should carry`), which is what
the no-op columns answer for the case where nothing changed: the memo replays
the module and skips it entirely. What an EDIT costs is still the `heap` /
`wall` columns' question.

`skipped` is `1 − modules_rechecked / modules_planned`; `heap` and `wall` are
warm ÷ cold. The counters and `heap_ptr` are deterministic for a given input
and cache state, so N=1 is enough for them and a move is a real move; **wall on
a shared runner is advisory** and is labelled that way in the report. A warm
rebuild whose output differs from the cold one fails the KPI outright rather
than being reported — every ratio above assumes the two builds produced the
same program, and the run checks it.

### The exact no-op: the linked-output memo (#2825)

The contract's first row below is "an exact no-op does no semantic work". The
typing walk already met it; the back end did not, and ran in full on every
unchanged rebuild. `vibe run`, `vibe build` and `vibe test` now replay the
finished module when the compile's complete input identity matches the last
compile of that root (`lib/@vibe/compiler/entry/compiler/file_compile/linked_output_memo.vibe`):

- the compiler, through the persistent store's namespace (the hash of the
  compiler sources and the cfg flags);
- the lane, entry path and entry name, the `--allow-*` / `--deny-*` grants and
  whether the executable's exports will be stripped;
- every source the loader resolved, by group, path and content fingerprint,
  in load order (a typed wasm import is its synthesized binding text);
- the value of every environment variable the compiler reads.

The lookup runs after the typing walk, so a no-op still reports a type error,
records the closure for the unstable-surface gate and fills the typing
telemetry; only the back end is skipped. The identity is compared in full,
not by a hash of it, and the store keeps one module per root.

The variable list is the part that could be silently wrong: a setting that
reaches the output but is not in the key would replay a module built for the
other setting. It is not curated by judgement. `scripts/check_linked_output_memo_env.vibex`
reads every variable name the compiler's code mentions and fails unless each is
keyed or exempt with a reason, and its self-test drops `VIBE_RC` from the key
to prove the gate fires. The KPI caught the one exemption the first draft
missed: `VIBE_OUTPUT`, which the runner sets from the output argument, made
every build into a fresh path miss.

`VIBE_LINKED_OUTPUT_MEMO=off` compiles anyway and `verify` compiles and
refuses a stored module that differs from the fresh one, after replacing it,
so the next default build cannot replay it. The launcher's
internal `VIBE_FS_COMPILE` lane defaults to `off`, because the KPI's `warm`
column and the compiler's other warm measurements compile through it and
measure the back end's own reuse; the KPI turns the memo on for its `cold` and
`no-op` builds and requires the no-op to replay, which the compiler signals by
reading the never-set `VIBE_PROFILE_MEMORY_MARK:linked_output_memo_hit` (the
node runner echoes it under `VIBE_DEBUG_ENV=1`).

### What the run refuses to report (#2836 §2)

Both names in "warm ÷ cold" have to be earned, and until #2836 neither was
checked: the counters were printed and the timings divided whatever the
counters said. A cache that stopped reusing would have produced a full table of
ratios describing the machine — which is exactly the #2825 §3 failure, where
the body cache replayed nothing for as long as it existed and every published
number looked healthy.

So the run now **fails** rather than reporting when

- the cold run reused any module, from a cache directory the run created empty
  (an asymmetrically warmed baseline — the #2393 trap, which turned a +3.5 %
  regression into a "−31 %/−42 % win"), or
- the warm rebuild reused nothing of what it planned (no incremental build
  happened, so there is no KPI to state), or
- the cold build replayed a linked-output memo, or the no-op rebuild did not
  replay one, or replayed a different module.

The LEVELS are deliberately not asserted. How much gets skipped is the KPI; a
KPI with a budget is a gate. `scripts/incremental_kpi_test.sh` makes each
refusal fire against a mutated copy of the script, and `--corpora small` is
what makes that affordable (#2248).

### Body-cache publication, watched rather than bounded

The telemetry has no counter for the codegen body cache, so the KPI reads the
cache directory directly and reports how many artifacts of each kind each run
left. Measured at `05099ce`:

| corpus | checked-module artifacts | body-cache artifacts |
|---|---:|---:|
| small | 0 | 0 |
| medium | 0 | **1** |
| selfhost | 0 | 0 |

`checked_module` is 0 by construction (that cache is off on this lane). The two
body-cache zeroes are [#2825 §6](https://github.com/mizchi/vibe-lang/issues/2825)
in view: publication needs a replayable harvest, which `linked_compile` writes
only under `pin_region_capacity >= 0 && !late_dce_rewrote_bodies`, and #2811
made the compiler decline to publish a harvest nobody could replay rather than
store one. Which of those two conditions each corpus misses is not established
by these counts — all three corpora have a real entry — so `medium` publishing
is the fact to keep in sight, not a rule to derive from it. Reported and not
asserted for that reason: a threshold here would encode the open bug, and when
§6 lands these zeroes become nonzero on the run that lands it.

This is a measurement, not a gate: it holds no budget on any number it prints.
What it refuses is a run that cannot show it measured the thing.

## User-visible KPI contract

Measure these endpoints separately:

1. edit to the first accurate diagnostics;
2. edit to settled diagnostics for that revision;
3. edit to a runnable debug artifact;
4. edit to completion of a selected test;
5. edit to a runnable release artifact.

An editor/daemon request carries a source revision. A diagnostic or artifact for
an older revision must never be published as the result of a newer revision.
`stale_publish_count == 0` is a correctness gate, not a timing metric.

Each endpoint is measured cold and warm, with p50 and p95 reported independently
for small, medium, and compiler-sized projects. The edit matrix is:

| Case | Expected future invalidation |
|---|---|
| Exact no-op | No semantic work |
| Comment or whitespace only | Current-source ingestion and parse; owner typing may be reused only after a lossless checked-body authority exists |
| Private function body | Owning semantic unit; consumers keep typing results |
| Private signature | Dependent declarations in the same module/package |
| Export implementation, same interface | Consumer typechecking is reused |
| Export type/effect/contract | Complete reverse-dependency closure |
| Generic definition | Template and affected specializations |
| Import or `index.vpkg` | Module plan and affected reverse dependencies |
| Syntax error introduced/fixed | Affected diagnostics, with no stale publish |
| Root module | Worst-case reference case |

Wall time is advisory on shared runners. Deterministic work counters are suitable
for blocking gates: files read, modules parsed/rechecked/reused, interfaces
changed, functions code-generated, cache hits/misses by class, and invalidated
reverse dependencies. Artifact identity, diagnostics, guest heap, host RSS, and
bytes read/written are recorded alongside timings.

The initial executable baseline is `scripts/edit_cycle_kpi.mjs`. It measures the
one-shot `vibe check` path for cold, exact warm/no-op, comment-only, private-body,
and public-interface edits. It requests a disabled-by-default compiler sidecar
for deterministic `db_typecheck_fs` work counters: modules planned, rechecked,
reused, and parse operations. The qualified outer record (`schema:
"edit_cycle_kpi"`, `version: 2`) pins and records persistent ingestion stamps
off, production-default typing dependency environment reuse
on, invalidation tracing off, and check-only compilation; inherited environment
variables cannot silently change those modes. Each record also has a scoped
`work_summary` and matching `work_scopes`:

- `read_bytes`: all bytes returned by `fs_read_file` plus `fs_read_bytes` host
  imports, including cache and other host-FS traffic; it is not source-only;
- `hash_calls`: `ingestion_fingerprint.hash_calls`, counting operations—not
  proven-distinct files—at the current `fingerprint_file_fs` boundary;
- `parsed_files`: `current_source_parse_executions`, limited to TypeDb current-
  source parse-memo misses, excluding loader/header/import-scan parsing;
- `checked_modules`: `checker_executions`;
- `codegen_modules`: always zero because the endpoint is check-only.

`scripts/incremental_phase_summary.mjs before.jsonl after.jsonl` emits the
machine-readable before/after summary. It validates all nested telemetry and
fails before computing deltas if the outer schema, benchmark, fixture, runner,
endpoint, process mode, complete case-by-run topology, mode authority, or metric
scopes differ. Each case has fixed `edit_kind` and `cache_state` metadata.
Malformed/unsafe counts, ingestion read/hash unit disagreement, stamp activity
while stamps are pinned off, nondeterministic repetitions, and nonzero codegen
are also rejected. Version 2 additionally records a separate compiler-owned
`ingestion_pipeline` v1 sidecar. Its execution counters distinguish source-list
and source-group cache probes/hits/misses, list-to-group reconstruction,
cold collection, module-header probes and parse scans, entry/final/linked/warning
parses. Probe partitions and the reconstruction partition are exact; final
semantic parses must equal the incremental sidecar's current-source parse
executions. These
counters remain separate from `work_summary.parsed_files`, whose TypeDb scope is
unchanged. Phase summaries expose ingestion-pipeline before/after/deltas beside,
not inside, the five established work-summary metrics.

The KPI intentionally does not yet measure LSP residency, runnable artifacts,
or module codegen reuse.

### Initial local result (2026-08-02)

Ten repetitions with compiler SHA `7a2632fc5753` and runner SHA
`dac03e9834c9` produced:

| Case | median | p95 |
|---|---:|---:|
| Cold cache | 216.0 ms | 250.4 ms |
| Exact no-op, preserved cache | 218.2 ms | 283.7 ms |
| Comment edit | 216.7 ms | 238.7 ms |
| Private body edit | 229.5 ms | 246.7 ms |
| Public interface edit | 222.3 ms | 317.3 ms |

This tiny two-file, one-shot check shows no stable user-visible cache win: the
cases are within timing noise and process/runner startup dominates. This is a
useful negative baseline. The next measurement should retain the same cases but
use a resident process and a medium import graph; only after telemetry is added
can the timing be attributed to parse/typecheck/invalidation reuse. These local
numbers are advisory and are not a committed regression budget.

A follow-up run with compiler SHA `4ceba401a979` added deterministic
`db_typecheck_fs` work counters. Every run planned two modules:

| Case | rechecked | reused without body parse | parse operations |
|---|---:|---:|---:|
| Cold cache | 2 | 0 | 2 |
| Exact no-op, preserved cache | 0 | 2 | 0 |
| Comment edit | 2 | 0 | 2 |
| Private body edit | 2 | 0 | 2 |
| Public interface edit | 2 | 0 | 2 |

This confirmed a real no-op cache win hidden by process startup and, at that
revision, showed that comment-only and private-body edits rechecked both the
leaf and its consumer. `modules_reused` means any successful module that avoided
a full body parse; it may come from in-memory or persistent state and is not yet
a per-cache-class hit count. The invalidation conclusion in this historical
result is superseded by the current TDRE5 result below; the timing numbers remain
a valid negative startup-dominated baseline.

### Current production result (2026-08-13)

A fresh stage2 audit at compiler SHA `28d04e6abe7` used isolated persistent
caches and deterministic `db_typecheck_fs` counters. For a graph of `N` modules,
the current check-only production behavior is:

| Case | rechecked | reused without body parse | parse operations |
|---|---:|---:|---:|
| Exact no-op | 0 | N | 0 |
| Comment-only owner edit | 1 | N-1 | 1 |
| Whitespace-only owner edit | 1 | N-1 | 1 |
| Private-body owner edit | 1 | N-1 | 1 |
| Propagated public-signature edit | N | 0 | N |

These ratios were reproduced on two- and four-module graphs. In the four-module
graph, adding an unused public export rechecked only its affected closure
(`2 rechecked / 2 reused / 2 parses`); a public change need not invalidate
unaffected modules merely because it is public.

The edited owner misses because the production TDRE5 logical input includes its
byte-exact source. After that owner is checked successfully, its checked public
TypeEnv-v9 authority lets unchanged consumers reuse their existing typing
results. This is consumer typing reuse only: final builds still merge and
code-generate the whole program, and this evidence makes no build, codegen, or
LSP incrementality claim.

Owner reuse must not be authorized from the observation-only
`implementation_fingerprint`. It is a provisional untyped token stream that
omits comments and source offsets. In particular, `///` documentation comments
are user-visible to `doc-at` and LSP hover, and current-source parse, location,
and diagnostic provenance must remain accurate even when typing is reusable.
This rules out token-based owner reuse, including a narrower no-newline
whitespace/comment shortcut. The next safe authority milestone is a lossless
checked-body or normalized typed-IR identity with deterministic differential
coverage and clean-build parity. Multi-SCC persistence and production
build/codegen/LSP integration remain later milestones.

### Checked-module reuse across an edit, on the BUILD lane (2026-09-15, #1959)

The table above is the check-only lane. The complete checked-module artifact
(`VIBE_CHECKED_MODULE_CACHE`, `docs/internal/compiler/checked-body-transport.md`) is the same
question asked of `vibe build`, and it answers with a persisted artifact rather
than a TypeEnv, so it has its own invalidation shape. Measured at
`084e796` on a three-module chain (`entry` imports `mid`, `mid` imports
`leaf`), each case editing `leaf` against a cache warmed on the tree before
the edit:

| Edit to `leaf` | rechecked | reused from artifact | warm output |
|---|---:|---:|---|
| none (byte-identical rewrite) | 0 | 3 | = cold |
| comment only | 1 | 2 | = cold |
| private body | 1 | 2 | = cold |
| added public export | 2 | 1 | = cold |
| signature change breaking `mid` | — | — | = cold, a diagnostic |
| that signature repaired again | 3 | 0 | = cold |

An owner whose bytes moved at all always misses, because the input identity
binds its verbatim source — that is what keeps `///` docs and source offsets
honest, and it is why a comment edit costs exactly what a body edit costs.
What the two consumers do is the point: a private or non-semantic edit leaves
the leaf's public environment alone, so both hold, while a new public export
invalidates the direct consumer and stops there — `entry` imports only
`mid_value`, whose own environment did not change. **A public edit does not
invalidate the closure merely for being public.** The last row reuses nothing
for a different reason: the compile it was warmed on was diagnosed, and a
diagnosed module publishes no artifact, so there is nothing for `mid` or
`entry` to have kept.

The last two rows are the ones that can be silently wrong rather than slow. A
consumer that kept a stale artifact would emit a wasm where a clean build
reports an arity mismatch, and a cache warmed on a broken tree would keep
diagnosing one that has been repaired. Both are asserted as
success-versus-diagnostic, not as a counter.

Every row also requires the warm result to equal a cold compile of the same
tree at the same paths — bytes, diagnostic and exit status — and requires the
artifacts the warm run kept to be byte-identical to the ones a clean build
publishes. `scripts/checked_module_cache_parity.mjs` runs all of this through
the real CLI on each gate, and `scripts/checked_module_cache_parity_test.sh`
mutates the corpus four ways to prove each row can fail.

Each row then plants a stale artifact and requires the run to reject and
republish it. **The plant is paired BY MODULE** (#2836 §3): the artifact the
edited tree consults is replaced with the one THAT SAME MODULE published before
the edit, so the only thing that differs is the source the identity binds. The
probe used to plant "any earlier artifact whose bytes differ", which in the
`noop` row necessarily meant a different module's — and a different module's
artifact is rejected for its embedded `normalize_path(path)`, which a decoder
that wrongly accepted an earlier source for the RIGHT module would also pass.
The row claimed the strong property and tested the weak one. The module is
recovered by reading the identity out of the artifact (`scripts/cache_artifacts.mjs`;
the cache filename is an opaque hash and cannot answer), and the per-row plant
counts are exact like every other count in the table:

| Edit to `leaf` | same-module artifacts planted |
|---|---:|
| none | 0 — nothing moved, and the probe declines rather than reaching sideways |
| comment only | 1 (`leaf`) |
| private body | 1 (`leaf`) |
| added public export | 2 (`leaf`, `mid`) |
| signature change breaking `mid` | 1 (`leaf`; `mid` was diagnosed and published nothing) |
| that signature repaired again | 1 (`leaf`) |

Rejecting a FOREIGN artifact is still covered, by the corpus probe, which
plants another program's artifact along with a truncated one, a bit-flipped one
and one written under a different cfg set.

### What that reuse costs, which is why it is still default-off (2026-09-15)

#1959 makes default-on promotion conditional on "oracle parity and measured
wall/heap benefit". Parity holds. The benefit does not exist yet — measured on
the compiler's own sources by `scripts/checked_module_cache_cost.mjs`, three
rounds, one isolated `VIBE_BUILD_CACHE_DIR` per (round, case, lane), medians:

| Case | | wall off → on | heap off → on |
|---|---|---|---|
| `lib/@vibe/cli/entry.vibe` (420 modules) | cold | 12.78 s → 18.91 s (+48 %) | 2559 MB → 3364 MB (+31 %) |
| | warm | 9.47 s → 17.66 s (**+87 %**) | 1957 MB → 3142 MB (**+61 %**) |
| `codegen_lexer_test.vibe` | cold | 5.09 s → 5.85 s (+15 %) | 963 MB → 1131 MB (+18 %) |
| | warm | 3.54 s → 4.82 s (+36 %) | 630 MB → 1020 MB (+62 %) |

The warm row is the one that decides promotion, and it is the worse of the
two: `off` warm is not an empty control but today's default reuse, and the
artifact lane replaces that path rather than layering on it.

The counters say where the work moved. Warm, unchanged sources, same closure:

| | rechecked | reused | reuse class | non-walk parses |
|---|---:|---:|---|---:|
| `off` | 0 | 420 | conservative fingerprint | 420 |
| `on` | 3 | 417 | checked-module artifact | 0 |

Since #2836 §2 those counters are also what the measurement **accepts a sample
on**, not only what it reports. Each run writes an incremental-telemetry
sidecar, and a sample is refused when the run labelled cold reused anything, or
when the run labelled warm reused nothing in its own lane's class — including
`off`, whose reuse class is the conservative fingerprint plus TDRE9 and whose
warm row is the baseline `on` has to beat. Without that, either mode quietly
ceasing to publish or consume would leave the protocol comparing cold against
cold and calling the difference reuse: the #2825 §3 failure reproduced inside
the tool built to catch it. `scripts/checked_module_cache_cost_test.sh` makes
each refusal fire — cache directory per temperature, a third run labelled cold,
the `on` lane running with the cache off — and `--cases closure` is what keeps
that affordable (#2248).

So the artifact does exactly what it was built to do — it serves the merge
lane's ASTs, and those 420 re-parses disappear — and the lane is still nearly
twice as slow. A CPU profile of both warm compiles (named stage2, isolated
caches, `lib/@vibe/cli/entry.vibe`) says why, by self time:

| bucket | `off` | `on` | delta |
|---|---:|---:|---:|
| parser / lexer | 652 ms | 519 ms | **−133 ms** |
| artifact codec (`ast_binary_*`, checksum, decode) | 0 ms | 2816 ms | +2816 ms |
| `Bytes` runtime (push / append / blit) | 297 ms | 1880 ms | +1583 ms |
| host I/O (read, UTF-8 decode) | 321 ms | 968 ms | +647 ms |
| total profile | 9631 ms | 17543 ms | +7911 ms |

**The 420 parses it removes are worth 133 ms, and the transport that replaces
them costs about 60 times that.** The rest of the delta is the same codec seen
through the generic runtime rows — `__rt_string_join` +1160 ms and
`__rt_arr_push` +811 ms are the decoder rebuilding strings and arrays. The
single largest row in the whole `on` profile is `module_artifact_checksum` at
1416 ms (8.1 %): `decode_checked_module_artifact` verifies it over the
artifact body on every load, a byte at a time, with two i64 modulos per byte,
across 179 MB of artifacts.

Heap splits the same way, and cold-versus-warm separates the two directions.
A cold compile loads no artifact, so `on` cold − `off` cold is the **encode
and store** side at +805 MB; a warm one loads 417, so `on` warm − `off` warm
is the **read and decode** side at +1185 MB. On disk the same closure's cache
is 8.9 MB with the cache off and **179 MB** with it on, a factor of 20.

This paragraph previously blamed the retention of `parsed_stmts`
(`commit_checked_module_artifact` keeps each module's AST so
`parse_program_with_path` can serve the merge from it) for the warm heap. The
profile corrects that: `parse_program_located_shared` memoizes by
`(path, source)` as well, so the conservative lane **also** holds a whole
closure of ASTs. Retention is not what separates the lanes; the codec at both
ends is. The three modules `on` rechecks on an unchanged tree remain a
separate open question.

That changes what promotion waits on. Consuming the artifact one unit at a
time (#2507, #2510) bounds the live set, but a per-unit consumer still writes,
checksums and decodes the same 179 MB, so it does not by itself recover a cost
that is paid per byte. Which bytes those are was then measured directly, by
building three stage2 compilers that each drop one part of the artifact and
running the same cost protocol on each. Every variant was first put through
the edit rows above, so none of them is a variant that stopped invalidating
correctly.

| variant | artifact | cli warm wall | cli warm heap |
|---|---:|---:|---:|
| `off` (control) | 9 MB | 9.4 s | 1957 MB |
| production `on` | 179 MB | 17.66 s (+87 %) | 3142 MB (+61 %) |
| drop `parsed_stmts` | 138 MB | 16.78 s (+77 %) | 3116 MB (+59 %) |
| … and the unread `CheckedProgram` fields | 95 MB | 13.54 s (+41 %) | 2731 MB (+40 %) |
| … and the verbatim input identity | **24 MB** | **11.42 s (+22 %)** | 2563 MB (+31 %) |

By bytes, the artifact is 23 % parsed AST, 24 % `CheckedProgram` fields that
the reuse path never reads, 40 % a verbatim copy of its own input identity,
and 13 % what is actually read back.

Three separate findings, in the order the ladder produces them:

- **The AST is not the problem.** Removing it recovers 0.9 s of the 8.2 s and
  essentially no warm heap, which retires the hypothesis this paragraph used
  to end with.
- **Half the transport is written for a consumer that does not exist yet.**
  `checked_module_artifact_outcome` reads exactly `final_env`,
  `lowering_offsets`, `eq_offsets` and `eq_keys`; `checked_stmts`,
  `type_defs`, `final_subst` and `typed_occurrences` are encoded, stored,
  read back and dropped. They are there for the codegen unit of #2507, and
  they are 24 % of the bytes.
- **The artifact embeds its whole input identity**, which by
  `checked_module_cache_input_identity` is this module's entire source plus
  **every direct dependency's full TypeEnv text**. That makes the transport
  superlinear in the dependency graph, and it is the single largest share at
  40 %. Binding to a fingerprint of the identity instead keeps the edit rows
  green, including the stale-artifact plants — though the current fingerprint
  is the same weak two-modulo checksum, so a real version of this needs a
  strong hash, which is the trade the verbatim copy was avoiding.

The conclusion is about where the payoff can come from, not about a missing
optimization. **Even at 24 MB the lane is still +22 % wall and +31 % heap**,
and an artifact stripped that far carries nothing the conservative lane does
not already persist in 9 MB. So this cache cannot pay for itself inside the
checker: the work it saves there is 133 ms of parsing, and no arrangement of
its contents makes the transport cheaper than that. Its value is precisely
the payload that makes it expensive today — the checked statements the
codegen unit would otherwise re-derive. That was where this section stopped,
with the recommendation to decide promotion together with #2507's phase 3,
when something reads that payload. **Measured, that does not work either.**

#### Verifying the phase-3 premise (2026-09-15)

Phase 3 of #2507 is "lowering + linear codegen: in one checked module and its
dependency interfaces, out relocatable bodies". Two measurements decide
whether handing it the payload could pay, both on the compiler's own closure
with the codegen body cache ON — which is the honest baseline, because that
cache (#2388) already replays the bodies phase 3 would produce.

First, how big phase 3 is. A warm compile, body cache on, checked-module cache
off, profiled by self time (9476 ms total):

| bucket | ms | share |
|---|---:|---:|
| lowering / normalize | 1887 | 19.9 % |
| codegen | 1713 | 18.1 % |
| `rt` intrinsics | 2168 | 22.9 % |
| core / types | 1591 | 16.8 % |
| parser / lexer | 701 | 7.4 % |
| host / JS | 455 | 4.8 % |
| **checker** | **0** | **0.0 %** |

The checker row is the first answer: **on a warm compile the conservative lane
already spends nothing there**, so the checked-module artifact has no front-end
work left to save, whatever it carries. Phase 3's own territory is lowering
plus codegen — 38 %, about **3.6 s**.

Second, what a phase-3-usable artifact costs. That is the one that keeps
`checked_stmts` (the payload phase 3 exists to consume) while dropping the
redundant parsed AST and fingerprinting the identity — 74 MB, and it passes
the edit rows:

| configuration (cli closure, warm, body cache on) | wall | heap |
|---|---:|---:|
| checked-module off | 9.39 s | 2090 MB |
| phase-3-usable artifact on | 14.33 s (**+53 %**) | 3074 MB (+47 %) |

**The transport costs +4.94 s; the entire phase it would feed is 3.6 s.** Even
if phase 3 became free — no lowering, no codegen at all — the build would be
slower than it is today. So no phase-3 consumer rescues this artifact, and the
recommendation this section used to end with is withdrawn.

Two things that conclusion does not say. It is measured with **today's codec**,
and `module_artifact_checksum` alone is 1416 ms of it; fixing that moves +4.94 s
to roughly +3.5 s, which is at the boundary rather than past it. And it is
about wall and total heap, not about **peak** memory per unit of work, which is
what #2494 and #2507 are actually for — a per-unit pipeline can still be right
for bounding the live set while being worse on both numbers here.

One fix is worth taking on its own account either way:
`module_artifact_checksum` is a byte-at-a-time loop with two i64 modulos per
byte, and it is 1416 ms of the warm `on` profile — the largest single row —
independent of what the artifact ends up carrying.

#### Which layer a distributed cache should carry (2026-09-15)

The measurements above all ask about a LOCAL warm build. A remote or
dependency-level cache asks a different question — can the work be skipped by
fetching something instead of doing it — and the answer depends entirely on
which layer the something is. Two numbers decide it.

**Where a warm compile's time actually is.** Self time cannot say: the leaf
utilities (`core/*`, `__rt_*`) are ~30 % and spread across every phase. By
INCLUSIVE time down the call tree, the same warm compile (9476 ms total,
8039 ms inside `compile_file_fs_mode_rc_body_cached`):

| region | inclusive | share of the compile |
|---|---:|---:|
| `compile_wasi_module_linked_impl_with_split` (everything post-merge) | 6260 ms | 78 % |
| ├ `effect_lowering_prelude` | 2563 ms | 32 % |
| ├ `desugar_trait_dicts_with_typed_eq` | 688 ms | 9 % |
| ├ `compile_expr` (body codegen) | 626 ms | 8 % |
| ├ borrow fixpoint + perceus plan | ~945 ms | 12 % |
| └ const-fold, DCE, index assignment, assembly | ~1180 ms | 15 % |
| `build_grouped_merged_stmts_counted` (merge) | 832 ms | 10 % |
| source load + parse | ~970 ms | 12 % |
| **checker** | **0 ms** | **0 %** |

The largest single phase is the effect-lowering prelude at 32 %, and it is
already proven reproducible per module — see "The per-module prelude
reproduces the whole-program prelude exactly" above, where the CLI closure's
369 modules link to `linked == stmts` with `missing`, `extra`, `content` and
`renames` all zero. Body codegen is likewise already replayable (#2388). What
is left that no per-package artifact can skip — merge, trait-dict
instantiation, const-fold, DCE, index assignment, assembly — is roughly
**25 %**. So the ceiling for a cache that carries lowered and code-generated
output is high; the ceiling for one that carries TYPING is zero, because
typing is already free warm.

**What each layer weighs.** Same closure, same compile:

| transport | bytes |
|---|---:|
| checked-module artifacts (420 modules) | 179 MB |
| persisted codegen body cache, whole closure | **16 MB** |
| the emitted wasm itself | 39 MB |

An order of magnitude apart, and the lighter one carries the expensive phases
while the heavier one carries the free one. At the current codec's measured
~22 MB/s that is 0.7 s to decode against ~8.2 s, so the codec's speed stops
being the binding constraint once the granularity is right.

**A build with an entry point replays too (#2818).** `vibe build`, `vibe run`
and `vibe test` all compile with an entry, and until #2818 the body cache
never replayed a body for one: every published number came from
`scripts/body_cache_reuse.sh` with the entry hardcoded to `__no_entry__`, the
library shape. With `cli_main` the warm build offered **0** bodies on every
row, so it recompiled exactly what a cold one did.

The cause was `fold_const_bool_params` (#2497 unit 2, not the capability
lowering). It rewrites a body whose `Bool` parameter receives the same literal
at every call site, and it runs only when there is an entry. A folded body is
no longer its source text, and its bytes depend on call sites in OTHER files
that the file table cannot see: `gate(on: Bool)` called only as `gate(true)`
compiles to its `true` arm, and changing that call in another file must change
`gate`'s body while `gate`'s file stays byte-identical. The compile answered
that by withholding every guard whenever anything was folded, which made the
whole harvest unusable.

**The fold signs what it did, and the cache keys on it.**
`fold_const_bool_params_signed` reports, per rewritten function, the ordered
list of substitutions it applied (`0t` = parameter 0 fixed to `true`). That
names the folded body exactly, because a round keeps a substitution only when
it replaced a read: one that replaced nothing would still re-simplify literal
shapes the source already had, which would make the body depend on how many
rounds the whole program took. Every harvested entry carries the signature its
body was compiled under (`fn_fold_sigs`, VBC7), stamped at record time from
the compile's fold table (`guard_fold_names` / `guard_fold_sigs`, installed on
the out cache before the body phase so a function worker's template carries it
too). `codegen_body_cache_filter_fold_sigs` drops exactly the entries whose
function the consuming compile folds differently; everything else replays.
The signature is per entry rather than per compile because the persisted
artifact is a harvest MERGED with the entries it replayed, and no single
compile's table describes a merged cache.

Three places apply the filter, each against the compile that will use the
entries:

- linked_compile, before the guards are checked, against its own fold table.
  It stands down under `pin_region_capacity < 0`, for the reason the other
  guards do: that compile re-feeds statements an earlier compile in this
  process already folded, so its own fold finds no read left to substitute.
- the verify lane, against the FRESH compile's table, because its second
  compile is exactly that re-feed.
- the refreshed artifact's merge, so an entry the compile recompiled is not
  carried back in as a duplicate.

`lib/@vibe/compiler/tests/codegen_body_cache_persist_test.vibe` pins the
cross-file case: flipping the only caller of an imported `gate` from `true`
to `false` keeps every layout guard intact and offers `gate`'s cached `true`
body. With the filter disabled, the warm build is not what a fresh compile
emits. With it, the build is byte-identical to a fresh compile, in both
directions and under `verify`.

Measured on the CLI closure (`lib/@vibe/cli/entry.vibe`, 685 files),
`scripts/body_cache_reuse.sh lib/@vibe/cli/entry.vibe lib/@vibe/core/defaults.vibe cli_main`,
seed-compiled harness, one cache directory per tree:

| temperature | before: offered / recompiled | after: offered / recompiled |
|---|---:|---:|
| cold | 0 / 15416 | 0 / 15416 |
| unchanged | 0 / 15416 | **14498 / 918** |
| comment-edited | 0 / 15416 | **14498 / 918** |
| reverted | 0 / 15416 | **14498 / 918** |

What replay buys, on the production compiler: a stage2 built from this tree
compiling the same closure (`VIBE_FS_COMPILE=1 VIBE_RC=1`, the incremental
KPI's environment), one isolated cache per mode, a cold run and three warm
ones, the mode the only change. The emitted 51 MB module is byte-identical
either way.

| `VIBE_CODEGEN_BODY_CACHE` | cold | warm 1 | warm 2 | warm 3 |
|---|---:|---:|---:|---:|
| `off` | 32.3 s | 18.6 s | 18.8 s | 18.5 s |
| `on` | 29.6 s | 16.6 s | 15.7 s | 16.4 s |

About 12 % of a warm build. A CPU profile of the same warm compile through
the harness puts it where expected: the body phase (`lc_execute_function_plan`)
drops from 4.0 s to 0.37 s, decoding the artifact costs 0.26 s, and nothing
else moves. The effect-lowering prelude, merge, borrow fixpoint, DCE and
assembly still run whole-program, and the prelude alone is over half of what
remains. (`scripts/body_cache_reuse.sh` is the wrong tool for wall time: each
of its rows recompiles the seed-built harness first, ~60 s of ~90 s.)

**At the KPI's three sizes** (`scripts/incremental_kpi.mjs`, same stage2,
`VIBE_CODEGEN_BODY_CACHE` the only change, absolute times):

| corpus | cold | warm, `off` | warm, `on` | warm heap `off` → `on` |
|---|---:|---:|---:|---:|
| small (2 modules) | ~190 ms | 165 ms | 160 ms | 2 → 2 MB |
| medium (16 modules) | ~380 ms | 300 ms | 295 ms | 16 → 19 MB |
| selfhost (686 modules) | ~29.7 s | 18.9 s | 17.2 s | 2922 → 3092 MB |

Only the selfhost size gains. The small corpus publishes no artifact at all:
a program with no derived comparator never runs the pin reorder, so it
records no guards (`body_cache_harvest_is_replayable`). Below a few hundred
milliseconds the remaining cost is most likely the process itself (node
startup and instantiating a 5 MB compiler); no cache of compiler phases can
remove it. That is an inference from the absolute times, not something these
two corpora were profiled for. The price of the cache is heap. The bump heap
never frees, so decoding the ~12 MB artifact, re-encoding the refreshed one
and the intermediate copies show up as +170 MB at selfhost size. Two of those
copies are gone: the decoder reads the stream in place
(`codegen_body_cache_from_bytes_at`), the encoder writes it into the artifact
buffer (`codegen_body_cache_write_to`), and the typed-lowering refilter is
skipped when it would drop nothing (`codegen_body_cache_src_keep_drops_any`).
Measured with heap marks on a warm CLI-closure compile: decode 153 → 100 MB,
store 98 → 74 MB, the whole compile 2468 → 2391 MB, with the same replay
counts.

Before the filter that carries an entry's lambdas, slots, blind references and
linemap rows (`bcc_filter_entries`) used a direct-address table, it tested each
row's owner against the kept-function list linearly. That is quadratic, and
with ~14k kept functions it cost more than the replay saved. The artifact adds
~12 MB to the cache directory.

The body cache is still opt-in (`VIBE_CODEGEN_BODY_CACHE=on|verify`). This
makes the lane usable on the shape every real build takes, which is the
precondition for measuring it at all; it does not by itself meet #2826's
promotion bar.

**The constraint to design around** is not size but the capability lane.
`--allow-*` drives const-fold plus DCE (ADR-0075/0084/0088), so a dependency's
POST-DCE bodies depend on the consumer's grants and two consumers with
different permissions cannot share them. Caching PRE-DCE relocatable bodies
and leaving capability const-fold, DCE and index assignment to the link step
keeps the cache capability-independent — which is the same split #2507's link
unit already proposes, and the edit-stable index work (#2394, #2400) is the
part of it that exists.

### Host filesystem ingestion telemetry

The edit-cycle KPI also requests a separate runner-owned sidecar for actual
host filesystem import work. It opts in only when both variables are supplied:

```text
VIBE_HOST_FS_SCOPE_OUT=<sidecar.json>
VIBE_HOST_FS_SCOPE_NONCE=<unique-non-empty-run-id-without-control-characters>
```

`viberun` deletes an old requested sidecar before it executes the core guest,
counts calls at the exact `vibe` host-import boundaries (`fs_read_file`,
`fs_read_bytes`, `fs_stat_token`, and `fs_exists`), and publishes the sidecar
atomically only after a successful guest completion (including explicit
`exit(0)`). The host's post-completion write is not a guest import and does not
contaminate these counters. Failed guests, missing nonces, invalid nonces, and
sidecar publication failures produce no successful observation.

The strict version-1 JSON object has `schema: "host_fs_scope"`, `version: 1`,
the caller nonce, and non-negative integer fields `read_file_calls`,
`read_file_returned_bytes`, `read_bytes_calls`,
`read_bytes_returned_bytes`, `stat_token_calls`, and `exists_calls`.
`read_*_returned_bytes` count bytes returned through that import (after
`fs_read_file`'s existing lossy UTF-8 conversion). This schema describes host
filesystem-import scope only: it does **not** claim compiler source hashes,
cache keys, cache hits, reuse decisions, or a compiler ingestion identity.

`scripts/edit_cycle_kpi.mjs` generates a fresh nonce and fails closed if this
sidecar is missing, malformed, has unexpected fields, contains invalid counts
or a control-character nonce, or has the wrong nonce. It records the result as
`host_fs_scope` alongside—not inside—the compiler-owned
`incremental_typecheck` telemetry. The feature is disabled by default and does
not change compiler source loading, persistent formats, cache keys, or reuse.

Production use of Git blob OIDs for source identity is currently **NO-GO**.
Obtaining an OID from the index does not prove equality to compiler-ingested
working-tree bytes under attributes, clean/smudge filters, or line-ending
conversion; racy-clean state, alternate index formats, linked worktrees,
SHA-256 repositories, sparse state, and non-repository/sandbox execution also
lack one trusted authority boundary. Invoking Git would add ambient process
authority. Reconsideration requires a separately authenticated host API that
proves both clean classification and exact equality to the byte/text stream the
compiler consumes. No commit timestamp or author/modified date may substitute.

The opt-in persistent ingestion-stamp oracle similarly uses isolated gate-off
and gate-on cache histories for a copied package. It proves only that unchanged
and metadata-token-miss successful checks have equal observed invalidation
traces (apart from the freshness nonce) and equal check output bytes/text. It
retains malformed and content-token fallback checks. It also performs a
same-size in-place content mutation and restores the prior mtime: when the host
filesystem reproduces the exact inode/size/mtime token inputs, the oracle
requires the changed bytes to produce a stamp hit with no fingerprint-boundary
read or hash. Platforms that cannot reproduce the exact token report an
explicit capability skip. This adversarial evidence means metadata-token
equality is not a content identity and the stamp is unsafe as production
authority; it remains default-off and opt-in only. The oracle still does not
prove artifact equivalence.

## Trait generic provenance (bounded Phase 3)

The in-memory parser and checker retain bare trait-header parameter names and
positional method-generic rows for provenance. Type-parameter keys also retain
constructor arity (`F[_]`, `G[_, _]`) without changing the public source name.
The header names append a sixth
field to transparent `STrait`; checker-retained `EnvTraitDef` appends method
rows seventh, without shifting its prior slots. This is an explicit source
migration for positional consumers. Persistent TypeEnv v9 transports those
trait definitions, method-generic rows, kinded constructors, and applied-type
nodes, but remains a narrow environment transport, not a complete clean/warm
typed artifact or lossless `CheckedProgram` claim.

## Dependency transport-environment typing reuse

TypeEnv reuse is enabled by default on every lane, `vibe check` and the FS
compile lanes (`vibe build` / `run` / `test`) included; the compile lanes'
cost and their oracle are described under "Typing reuse on the compile lane"
above. `VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE=1` is the strict opt-out; the
check-only and FS-compile lanes reject any other nonempty value. An
incremental invalidation trace automatically forces reuse off so the trace
stays observation-only.

TDRE9 aliases the exact logical
`ModuleJob` checker input to a previously checked TypeEnv: canonical owner path,
byte-exact owner source, the canonical effective typing-semantics seed (currently
checked versus unchecked `Exception` rows), `resolution_env_seed()`, and every
`(path, canonical TypeEnv-v9 transport text)` row in the exact ordered resolved
direct-dependency projection. The coordinator retains the full accumulated environment cache only
for graph coordination and upsert; it projects each `deps` occurrence in order,
preserves duplicate paths and first-match cache lookup, and fails closed if any
resolved row is missing. The same projected array is passed to `check_module`
and to TDRE9 lookup/publication, so ambient non-direct cache mutations are
semantically irrelevant and avoid quadratic canonical serialization. TDRE9 does
not replace exact transport text with a compact fingerprint. It validates and
republishes the decoded environment under the ordinary conservative fingerprint.
It does not use the
trace-only `vibe-module-interface:v7` observation as a production key, and
malformed, missing, stale, torn, or cross-spliced aliases, witnesses, and targets
fall back to a full check. The alias remains incompatible with the incremental
invalidation trace lane so the two identities cannot be confused.

The v9 TypeEnv codec round-trips every current `TypeEnv` variant, including
trait definitions, impls, generic impl bounds, trait-header parameters,
positional method-generic binders/bounds, kinded constructors, applied types,
method `TypeExpr` metadata, and binding provenance. The binding-provenance
transition bumps the global persistent cache namespace from v22 to v23 and
replaces TDRE8 aliases/witnesses with disjoint TDRE9 namespaces and `TDRE9A` /
`TDRE9W` envelopes. The preceding constructor-bound self-reference transition
was v21 to v22 and TDRE7 to TDRE8. Old entries are never
reinterpreted. A
sidecar is still only an alias to a conservative
TypeEnv commit, not a `CheckedProgram` or lossless typed-IR transport.

Persistent storage uses a **v10 module record** (#2546), containing the
length-delimited TypeEnv payload and its typed-lowering v8 section in one file.
One atomic `Fs::write_file` publishes both outputs, and a cache read validates
both before installing the lowering rows for that module path and fingerprint.
The lowering codec's counts, digest, and end marker still reject damaged rows.
A missing or corrupt section invalidates the whole entry; it never silently
becomes an empty table. An explicit `lowering\tmissing` section represents a
worker result without transported rows: its environment can be read, but it
cannot skip the next module check. A checked empty table remains reusable.

The separate offsets cache path is removed. TypeEnv v9 remains the standalone
worker/dependency transport and the input to transport-identity observations;
adding lowering data to disk does not change those identities. The TDRE9 target
binding covers the **entire canonical v10 record**, including lowering rows.
A hit copied to a new conservative fingerprint preserves that exact record.
Old v9 disk entries fail closed in the v10 namespace.

A witness is published only after that module's canonical v10 module target and
when every direct dependency already has a validated witness for its conservative
fingerprint. Alias and witness both bind the logical input, target conservative
fingerprint, and exact canonical target text. Reuse reads the raw target,
strictly decodes it, requires an exact canonical re-encode, and verifies the
three-way alias/witness/target binding. A witness names each dependency env
text by digest and the text is stored once, in a shared text store (see "What
a witness stores" above); a lookup compares the stored bytes against the live
text. Publication order is target, dependency texts, witness, alias; diagnosed
or failed modules publish none of those rows. The production
oracle covers natural dependency transport changes (public signatures,
traits, and impls), sidecar-integrity corruption of dependency rows/order,
ambient non-direct cache irrelevance, valid-but-wrong targets, cross-splicing,
missing/malformed/stale entries, diagnostic non-publication, and multi-level
reuse. Focused checker tests cover package/directory candidate selection,
reexports, duplicate paths/order, first-match cache shadowing, and missing-row
failure. The production oracle treats the default check environment as
reuse-on and uses the explicit disable flag as its conservative control. It
also covers trace forced-off behavior, strict environment diagnostics,
conservative compile output parity, and isolation from v16 entries.

## Artifact boundaries

Checker-time typed-occurrence observation can remove legacy offsets at
statement-owner granularity: each retained row is associated with its checked
statement path. A separate opt-in observation records one append-time role and
checker lane for every legacy row through the centralized identifier, call
result, dot projection, and dot field-name funnels. It distinguishes primary
checking, synthetic rewrites, and auxiliary resume-value rechecks without
post-hoc offset inference. The ordinary checker path allocates no capture and
the legacy `CheckedProgram` shape remains unchanged.

An additional opt-in, opaque successful-check observation is append-aligned
with the same legacy table and records each row's statement path, exact
post-desugar `core::expr_children` expression path, role, lane, and raw checker
type. Its versioned snapshot applies `final_subst` through the shared canonical
occurrence-type formatter. Expression root is `[]`; each child appends its
zero-based structural index. Paths are captured when legacy rows append, never
recovered from offsets, so duplicate offsets remain unambiguous. This contract
is complete-or-none: synthetic rewrites, auxiliary resume rechecks, or a
checker traversal/frame imbalance return `None` rather than claim a partial
path. It is observation-only—not an edit-stability guarantee, typed-IR claim,
persistent artifact, or production cache identity—and ordinary checker calls
allocate no capture state.

`CheckedStatementRootTypeObservation` is a separate successful-check-only,
opt-in root view. It captures the direct checker return type for each retained
expression-bearing `SLet`, `SLetMut`, `SLetPat`, `STest`, `SBench`, and
non-marker `SExpr`, recursively through modules, alongside its retained path
and closed statement kind. Its canonical snapshot applies `final_subst` via the
shared checked-type formatter. Marker or alignment failures return `None`, and
it deliberately has no typed-IR, cache/reuse, import, or production-path
connection.

`CheckedStatementRootTypeArtifact` is a strict opaque v1 transport for that
merged observation. It deep-copies each statement path, accepts only the six
closed root kinds, and freezes each type as final-substitution canonical text.
Its singular marker is `vibe-checked-statement-root-type-artifact:v1\n`;
decoding bounds untrusted counts and lengths by remaining input, rejects
noncanonical fields and malformed rows, and requires exact re-encoding. It
carries no checker-provenance attestation, typed IR, cache/reuse, interface,
trace, or import claim.

A physical file is a useful ingestion/cache shard, but is not always an
independent semantic or code-generation unit. Files in one package can share a
namespace, and declarations can form dependency cycles. Use two layers.

### Physical file artifact

- CST/tokens and recovering parse diagnostics;
- import header and declaration index;
- source spans, documentation, and source map;
- source and canonical semantic fingerprints.

### Semantic module or declaration-SCC artifact

- resolved bindings;
- inferred public type, trait, and effect schemes;
- evidence requirements;
- normalized typed generic IR;
- direct dependency assumptions;
- separate interface and implementation fingerprints.

The scheduler may ingest files independently, but typechecking and codegen reuse
must follow semantic declaration SCCs or module boundaries rather than assuming
that every file is isolated.

## Fingerprints and invalidation

Maintain at least two identities:

- **Interface fingerprint:** canonical exported names, types, layouts promised by
  the contract, trait bounds, and effect schemes.
- **Implementation fingerprint:** normalized implementation IR plus every
  optimization assumption that can affect generated code.

A dependency implementation change with an unchanged interface permits reuse of
a consumer's typing derivation. It does **not** imply unchanged program behavior;
the final linked artifact must still include the new implementation. An artifact
that embeds or specializes dependency code must include that dependency's
implementation fingerprint in its key.

Cache namespaces should eventually be versioned by phase (resolution, parser/AST,
type/interface, link plan, codegen/runtime) rather than invalidating every cache
class on every compiler-source change.

## Normalization and optimization boundary

Normalization used for identity must be deterministic and distinct from
profitability-driven optimization.

### Canonicalization and typed elaboration

Safe candidates for early caching are normalized paths/imports, alpha-normal or
stable symbol identities, canonical type-variable numbering, canonical ordering
of record fields/effect rows/constraints, resolved bindings, type/effect
elaboration, pattern desugaring, and source maps stored separately from the IR.
Comments and whitespace may be excluded from a semantic fingerprint while the
physical source fingerprint still tracks exact editor content.

### Context-independent local optimization

Initially allow only transformations whose assumptions are local and explicit:
closed pure constant folding, CFG simplification, unreachable local block
removal, local DCE that preserves exports, and proven beta/eta reductions.

Cross-module inlining, specialization, or dictionary/evidence elimination is
reusable only when all referenced implementation identities, normalized type
arguments, evidence ABI, target, and optimization mode are in the cache key.

### Whole-program barriers retained initially

Keep export-collision renaming, private namespace rewriting, entry-root DCE,
generic-instantiation closure, global function/type/table/effect index planning,
final representation/memory layout, Wasm section assembly, and whole-program
RC/escape optimization at the coordinator/link step until an independently
linkable fragment format is proven byte- and behavior-equivalent.

## Generics

The internal artifact retains generic schemes and typed generic bodies. A
specialization cache, if introduced, is keyed by:

```text
definition symbol + implementation fingerprint
+ normalized type arguments + evidence/dictionary ABI
+ target/backend + optimization ABI
```

The linker can choose specialization or a uniform dictionary/evidence-passing
representation. Erasing generic parameters in a current backend is not evidence
that a generic module can be represented safely as an independently reusable
Wasm file.

## Component Model decision

The Component Model is a promising package, distribution, host-integration, or
remote compiler-service boundary. It is not the primary internal incremental
artifact format.

WIT does not directly carry arbitrary parametric generic bodies, polymorphic
effect rows, unresolved relocations, specialization requests, or compiler typed
IR. Encoding these through resources, variants, or bytes would lose useful static
information and may add Canonical ABI lift/lower and ownership costs. A component
import can act like an operation dictionary only after the relevant value types
and ABI are concrete.

Use this initial pipeline:

```text
source
  -> typed generic module artifact (internal cache boundary)
  -> specialized/core object fragment
  -> deterministic whole-program linker
  -> core Wasm or wasm-gc
  -> optional Component Model wrapper (package/external boundary)
```

A Component Model experiment should be package-level, monomorphic, and limited
to WIT-admissible exports. Compare build latency, artifact size, runtime overhead,
and composition reuse against direct core-Wasm linking before expanding it.
Putting opaque typed IR in a component custom section is possible, but then the
component is only a container and provides little advantage over a versioned
content-addressed artifact.

## Lean model and proof obligations

The bounded Lean invalidation model lives in
`formal/VibeFormal/Compiler/Incremental.lean`, with proofs and executable
examples in `formal/VibeFormal/Proofs/IncrementalCorrect.lean`. It models
snapshots with distinct source ingestion, interface, and implementation
identities, direct imports, reverse-closure interface invalidation, and
owner-only typing invalidation for implementation-only edits and owner
invalidation for dependency-plan changes. Source-only edits are telemetry and
model no typing invalidation.
It also distinguishes matching consumer typing-cache assumptions from linked
artifact freshness: an unchanged imported interface may keep a consumer cache
key eligible while a changed dependency implementation still makes any artifact
that recorded that implementation stale. The model contains fingerprints, not
typing derivations, so language-level typecheck reuse safety remains a separate
proof obligation. This is a relational model-level contract, not yet an
executable invalidation planner; the model itself does not alter production
cache keys. The bounded observation bridge below compares its observation-only
exported-interface identities, source ingestion identities, provisional
canonical token-stream implementation identities, and telemetry, but cannot
compare production cache-key interface identities or normalized typed-IR implementation
identities because those do not yet exist.

A later conformance bridge must add production interface identities and
final-artifact inputs, then establish correspondence between the executable
planner and the Lean relation before cache-key changes are proposed.

### Current bounded observation bridge

`vibe check` remains unchanged unless both of these environment variables opt
in to the trace sidecar:

```text
VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT=<sidecar.json>
VIBE_INCREMENTAL_INVALIDATION_TRACE_NONCE=<unique-non-empty-run-id>
```

The trace exists only in a compiler built with the `telemetry` cfg flag, which
the generation's stage2 is by default (#2498). A build without it -- the
compile-only artifact -- refuses `VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT` by
name on every lane and leaves the destination untouched.

The sidecar is schema version 6 and is written **only after a successful
check**. It includes the nonce, canonical module path, direct dependencies,
`compact_string_fingerprint` of each module's **ingested source**, distinct
version-tagged `implementation_fingerprint`, `interface_fingerprint`,
`checked_env_fingerprint`, and `persistent_type_env_transport_fingerprint`,
the observed current TypeDb decision (`rechecked`
or `reused`), and aggregate work telemetry. The interface identity hashes a canonical
`vibe-module-interface:v7` serialization of exported inferred value/function
types (including effects), exported public type/trait/effect/effectset
declarations, and re-exports. A name an aggregate `export { .. }` lists is
looked up as a value first; the three kinds that have no value binding --
measured, a locally declared trait, effect or effectset -- are recorded as an
`export-<kind>:` membership row rather than demanded as values, which is what
they were before #2744 (a struct, an enum, a type alias, a builtin declaration
such as `export { Option }`, an imported trait republished by name, and a
re-export all carry a binding and take the `value:` row). A name that is
neither bound nor declared is still refused.

An aggregate export also selects the declaration itself for serialization. The
serializer used to read each declaration's own `export` flag, so a declaration
published only through `export { Name }` had its name in the surface and its
CONTENTS omitted -- measured, adding a trait method, renaming an effect
operation, adding a `derive`, and adding an enum variant each left
`interface_fingerprint` byte-identical while the declaration was published. A
struct's and an alias's TYPE still moved it through the `value:` row their
constructor produces, which is why only what that row cannot carry went
missing. `interface_decl_selected` now takes the aggregate-export set, so the
serialized list agrees with the export surface that
`interface_public_trait_names` and `interface_public_type_names` already
computed. The trait-witness row passes an empty set and is unchanged: under
`include_private` it already emits every declaration and records the aggregate
export as its own `export:` row. For exported traits, schema 6 serializes
header-binder arity and positional association plus every method's positional
generic-binder row, bounds, and signature. Method binders explicitly shadow
trait-header binders; names outside either binder scope remain free/nominal
names. Header and method alpha-renames therefore preserve identity, while
binder arity, association, bounds, signatures, and free/nominal names do not.
Duplicate trait-header binders, missing/surplus method-generic rows, and
unbound/ambiguous bound ownership are encoded as deterministic
malformed-provenance markers rather than omitted.
Quantified variables are alpha-normalized; effect rows, bounds, derives, and
effectset members are lexically sorted/deduplicated. Bodies, comments, private
declarations, and ordinary imports are excluded. The compiler removes a pre-existing requested sidecar
before the check, rejects a missing nonce, and refuses to publish a partial
trace when an observation is missing. Callers must reject a missing sidecar or
a nonce mismatch as stale/failed rather than reusing old data.

`source_fingerprint` remains explicitly **not an interface or implementation
fingerprint**; it is ingestion telemetry only. `implementation_fingerprint`
remains the schema-v3 observation-only `vibe-module-token-stream:v1` hash over
a length-delimited sequence of each lexer's token kind and exact source lexeme.
It preserves every parser-visible syntax distinction, including fields that
today's unlocated AST or printer erases, while excluding comments and whitespace
between tokens, spans, and the module filesystem path. Literal/interpolation
lexemes remain exact, so formatting inside one lexical token may conservatively
change this identity. It is intentionally **not normalized typed IR** and makes
no optimization or artifact-freshness claim. `interface_fingerprint` is likewise
observation-only: it is computed from the successful typed environment for
rechecked modules and reconstructed from the existing cached environment plus
current source surface for reused modules. Schema 4 introduced
`checked_env_fingerprint`: a canonical, length-delimited
`vibe-module-checked-env:v1` serialization of the effective `TypeEnv` value
bindings. It uses the existing canonical type serializer's alpha-normalized
variables and sorted/deduplicated bounds/effects, with `str_lt` value-name
ordering and first-effective-binding deduplication. Traits, impls, type
definitions, effect declarations, and bodies are out of scope. It is a
trace-only format, explicitly not the production persistent TypeEnv codec.
Schema 5 additionally introduced `persistent_type_env_transport_fingerprint` as
`compact_string_fingerprint(persistent_type_env_cache_text(env))`: at that
revision, the canonical complete persistent TypeEnv v3 transport bytes for the
checked or reused environment. It covered transport state omitted by the
value-only checked-env observation, including trait and impl state. Schema 6
changed only the trace-only interface observation: method-generic provenance was
consumed from the source `STrait` to canonicalize trait methods. The provenance
was also retained in `EnvTraitDef` and the then-current TypeEnv v3 transport,
but no full checked artifact existed. Current production has since moved to
TypeEnv-v9; the transport remains TypeEnv-only—not a `CheckedProgram`, typed IR,
exported interface, cache key, or reuse decision.

These observation identities have intentionally different authorities.
`vibe-module-interface:v7` covers only the exported API surface. In particular,
`SImpl` has no exported/public bit, so impl declarations are excluded from that
interface identity rather than being silently treated as public declarations.
Impl bounds and targets are module-visible trait-resolution state and are
observed by the complete persistent TypeEnv v9 transport identity instead.
Neither identity establishes final linked-artifact freshness: the current
runnable-artifact lane continues to use its whole resolved source-group input
identity and compile configuration. Consequently an impl-only edit is expected
to preserve `interface_fingerprint`, change
`persistent_type_env_transport_fingerprint`, and invalidate linked artifacts
through their existing source-group identity. This distinction does not promote
either observation into a production key or reuse decision.

The token-stream, interface, checked-environment, and transport reconstructions
are not charged to the existing TypeDb `parse_operations` counter. Standalone
incremental telemetry schema 4, used with `VIBE_CHECKED_MODULE_CACHE=off`, retains that historical counter and its
`modules_rechecked` / `modules_reused` decisions, while independently reporting
actual `ModuleJob.source` parse-memo misses, checker calls, conservative
fingerprint reuse, and validated TDRE9 dependency-transport reuse. The two reuse
classes must sum exactly to `modules_reused`. Invalidation trace schema 6
deliberately embeds the legacy schema-1 aggregate; exposing the newer counters
there requires a future explicit trace schema bump.

`parse_operations` covers only the filesystem TypeDb walk — planning and the
walk proper — and that is the whole story for a `vibe check` and was never the
whole story for a `vibe build`. The merge/flatten lane parses through
`parse_program_with_path`, outside the walk, so a warm build used to report
`parse_operations: 0` while parsing every source in its closure (#2766). That
work is `non_walk_parse_operations`, counted only when the parser actually
ran, so a shared-memo or AST-cache hand-out does not inflate it; the two
counters are disjoint and neither subsumes the other. `ast_cache_prefetches`
counts the modules whose stored binary AST was loaded into the shared parse
memo, and is zero unless `VIBE_EXPERIMENTAL_AST_CACHE=1`.

With `VIBE_CHECKED_MODULE_CACHE=on` or `verify`, standalone telemetry uses schema
5 and adds `modules_reused_checked_module_artifact`. This reason is separate:
an exact checked-module input can still match after a private dependency body
edit changes the conservative fingerprint. All three reasons must sum to
`modules_reused`. Verification checks afresh, so it records zero artifact hits.
The [checked-module parity gate](../compiler/checked-body-transport.md) validates these
counts through the real compile CLI; the edit-cycle reader accepts both schemas.
`scripts/ast_cache_prefetch_oracle.mjs` pins the lane signature on a real
build, stated relative to the cold build rather than against zero: a warm
build with the cache reports the same `non_walk_parse_operations` as the cold
one (planning fills the shared memo cold, the prefetch fills it warm), while
the same warm cache with the flag off reports strictly more. The control is
asserted first — if the cache-off run stopped parsing, the claim would be two
runs that both parse nothing.

The `rechecked`/`reused` report describes the completed module walk. Sidecar
encoding, decoding and I/O costs need separate measurement. None of these fields is read by a production
cache lookup, incorporated into a cache key, changes a reuse decision, or
changes a persistent cache format. As with every compiler-source edit, the
regenerated whole-compiler `codegen_fingerprint.vibe` still invalidates existing
compiler artifacts; that ordinary versioning is not evidence that any observed
field became a cache-key input. Consequently current decisions remain
measurements of conservative behavior, not formal conformance assertions.

`formal/IncrementalOracleMain.lean` renders the committed deterministic corpus
at `formal/oracle/incremental-invalidation.tsv`; `formal/check-incremental-oracle.sh`
rejects corpus drift. `scripts/incremental_invalidation_oracle.mjs` runs an
isolated-cache, temporary three-module chain through no-op, comment-only,
private-body, public-interface, and dependency-plan edits. For every warm or
incremental snapshot it also runs an isolated clean-cache counterpart and
compares source, token-stream implementation, interface, checked-value-env, and
persistent-TypeEnv-transport identities module by module; TypeDb decisions are
deliberately excluded from that parity comparison. A private-body regression
proves that a private body can change token-stream identity while leaving
checked-value-env identity unchanged. Trait-header/method-generic cases prove
clean/warm parity, alpha-rename invariance under method-over-header scope, and
identity changes for binder association, arity, bounds, signatures, and free
nominal names. The interface observation deliberately continues to read method
generic rows from source `STrait`; the same provenance is independently retained
in TypeEnv v9. Issue #1379 additionally defines a narrow, length-delimited
`CheckedTypeDefsArtifact` v1 for retained `type_defs`, aligned declaration
binders, and the authoritative semantic `final_subst` chain. `SubstCached`
acceleration-bearing substitutions are rejected rather than normalized or
serialized: no invariant establishes that their maps are semantically equivalent
to the rest chain, and v1 excludes them until the `Map[Type]` codegen issue is
fixed. It is not a full
CheckedProgram/TypeEnv artifact, typed IR, cache key/reuse input, interface,
import contract, or trace schema; that historical slice left schema 6,
interface v2, and the then-current TypeEnv v3 unchanged. Current production has
since moved to TypeEnv-v9 and interface-v7. `TDEffect` operation declarations, `CtFn` effect text,
and accepted final `SubstEffBind` chains are therefore already inside that
narrow artifact. Effect-set declarations are retained separately as the opaque
`CheckedEffectSetDeclarationsObservation`, derived from a successful
`CheckedProgram` without reparsing source. Its deterministic length-delimited
snapshot preserves recursive module-name paths, export bits, declaration order,
and exact ordered/duplicate member text. A separate strict declaration-only
`CheckedEffectSetDeclarationsArtifact` v1 copies that checked-program-derived
observation without sorting, normalization, or deduplication and canonically
encodes the same fields. The artifact does not attest that a manually
constructed `CheckedProgram` passed checking. Its decoder is fail-closed on version/count/length/export-tag
errors, truncation, trailing bytes, and noncanonical encodings (exact
re-encode equality). It is not a CheckedProgram, TypeEnv, inferred/effective
row, typed IR, interface, cache identity, import contract, trace schema, or
reuse input; it changes no runtime or cache policy. Inferred/effective rows remain stringly
`Option[String]` state distributed across final environments, typed occurrences,
and final substitution; typed-occurrence offsets are unstable. A subsequent
narrow #1379 Phase 3 observation records only active root-level direct
`SLet`/`EFn` bindings: its deterministic owner locator is the root statement
index (not edit-stable), and it retains exact source annotation and direct-`EFn`
rows alongside the final substituted `CtFn` row, including a `CtFn` body retained
under a generalized `CtForAll` wrapper. Only the final root binding per name is
observed, and only when that final binding
is itself a direct `SLet`/`EFn`; `SLetMut`, nested lambdas, modules, callback
rows, handlers, and perform sites are excluded. Its length-delimited snapshot preserves raw source
`None` versus `Some("")`, order, and duplicates; it first erases/normalizes
only the effective row with the existing canonical checked-row semantics
(transitive `SubstEffBind`, unordered/deduplicated labels, the current
Error/Exception alias rule, and distinct typed `Exception[E]`). The opaque
observation is fail-closed when owner association is malformed. It has no
decoder or structured EffectRow and is not persistent transport, cache/trace/
interface/import/reuse state. A distinct opaque
`CheckedEffectiveEffectRowArtifact` v1 can deep-copy that existing observation
and strictly transport its exact six tuple fields with a versioned,
length-delimited codec. Its decoder accepts only canonical encodings and the
observer-guaranteed shape (nonnegative strictly increasing owners, unique names,
and annotation kind/presence consistency); it deliberately does not parse row
text or attest that decoded data was produced by checking. It likewise is not
persistent transport, cache/trace/interface/import/reuse state. Consequently
this slice does not claim full effect-row transport or a stable row-to-body
association. The independently opaque
`CheckedTypedOccurrenceExpressionPathArtifact` v1 transports the complete
append-aligned expression-path observation in capture order: retained statement
path, post-desugar `core::expr_children` path, role, lane, and the occurrence
type snapshot after `final_subst`. It deep-copies paths and strings, omits legacy
offsets, and accepts only known role/lane tags and nonnegative path components.
Its strict length-delimited decoder bounds untrusted counts by remaining input,
stops at the first failed parse, rejects integer overflow, truncation, trailing
bytes, and noncanonical equivalents, and requires exact re-encoding. Decoded
bytes do not attest checker success; synthetic/auxiliary checker traversal still
makes the successful-check observation complete-or-none. This artifact remains
post-desugar and capture-order-relative rather than source- or edit-stable, and
is not a complete expression tree, checked body, typed IR, import contract,
interface, cache identity, trace, or reuse input. A separate opaque
`CheckedExpressionStructureObservation` enumerates every expression supplied
through `CheckedProgram.checked_stmts`, including nodes with no legacy
typed-occurrence row, in statement order and depth-first preorder. Production
callers supply retained post-desugar statements, but this structural API does
not attest checker success, post-desugar provenance, or consistency with the
other `CheckedProgram` fields. Its statement paths use the existing
nested-module convention and its expression paths use `core::expr_children`
with root `[]`; each row exposes only the closed expression-constructor kind.
It fails complete-or-none on unlowered `SFnDecl`, cyclic state, or bounded
size/depth exhaustion rather than inventing declaration-only
value/requires/ensures coordinates or risking unbounded traversal. Payloads,
patterns, annotations, names, literals, source offsets, inferred types,
bindings, and effect rows are intentionally absent, so this is only a complete
body-coordinate skeleton—not a checked-body transport or typed IR. Its paths
are post-desugar artifact-local coordinates, not source- or edit-stable
identity, and the observation has no decoder or connection to imports,
interfaces, traces, caches, or reuse policy. A distinct opaque
`CheckedExpressionStructureArtifact` v1 deep-copies exactly that preorder
skeleton and transports only statement path, expression path, and the closed
constructor-kind vocabulary. Its strict length-delimited decoder rejects wrong
versions, unknown tags, negative or overflowing path components,
noncanonical counts and lengths, truncation, trailing bytes, and hostile
unavailable counts, then requires exact re-encoding. Decoded bytes do not
attest checker success or provenance. The artifact remains payload- and
type-free, post-desugar/artifact-local rather than source- or edit-stable, and
is not connected to full checked bodies, typed IR, imports, interfaces, traces,
caches, or reuse policy.
Trait/impl regressions prove impl-bound and impl-target edits change the
complete persistent TypeEnv v9 transport observation while leaving the
exported-interface observation unchanged; the bound case also leaves the
value-only checked-env observation unchanged. Exported type derives,
trait-supertrait edges, effect operation signatures, and effectset members are
separately covered by clean/warm interface-v7 parity and sensitivity checks.
An external
executable shadow planner treats source changes as ingestion telemetry, derives
owner typing invalidation from canonical token-stream implementation changes
and dependency-plan changes, and reverse-closes interface changes over the union of
the before/after dependency graphs. For the bounded corpus it compares that
plan with the relational model rows, requires every planned module to appear as
`rechecked`, and reports additional rechecks as conservative over-invalidation.
A missing required recheck fails the oracle.

With `VIBE_SHADOW_DECISION_DIFF_OUT=<path>` the oracle additionally publishes
that comparison as a versioned `incremental_shadow_decision_diff` v1 JSON
artifact (#1548): per bounded edit case, each module's shadow decision
(`recheck_required`/`typing_reusable`) against the current compiler decision
(`rechecked`/`reused`), classified as agreement or
`conservative_over_invalidation`. A requested stale artifact is deleted before
the run and the new one is published atomically only after every case
succeeded, so a failed run leaves nothing; a missing required recheck fails
the oracle before publication and is never a published row. The gate writes it
to `_build/ci-artifacts/incremental-shadow-decision-diff.json` and CI uploads
it, making the over-invalidation residual visible per run. The artifact
records current conservative behavior only — none of its fields is a
production cache key or reuse decision.

The historical private-body observation is emitted under the explicit
classification `private_dependency_edit_externally_unchanged`. That classifier
fails closed unless `app` has exactly `library` as its sole direct dependency in
both snapshots, the dependency's source and provisional token-stream
implementation identities change, its interface identity does not change,
and all of the consumer's own observed identities stay unchanged. The
persistent TypeEnv-v9 transport result for the dependency is reported as a
separate `changed`/`unchanged` observation rather than being treated as the
exported interface. Production TDRE9 may reuse the unaffected consumer; the
shadow classifier remains observation-only and does not authorize that reuse.
It does not change trace schema 6, cache namespace v23, TypeEnv-v9/TDRE9
transport, production artifact reuse, or default-gate wiring.

For this comparison, `source_fingerprint` is ingestion telemetry only;
`implementation_fingerprint` is the provisional owner-change trigger. It is
not normalized typed IR. The shadow planner is independently implemented bridge
code, not a proved extraction of the Lean relation or a production planner. It
rejects module-universe changes and dependencies outside the observed universe
rather than silently assigning them semantics.

Required properties are:

1. **Clean-build equivalence:** incremental build after edits has the same
   canonical diagnostics, artifact, and modeled execution trace as a clean build
   of the edited snapshot.
2. **Typecheck reuse safety:** unchanged imported interfaces preserve the
   validity of a consumer's cached typing derivation.
3. **Invalidation completeness:** every artifact whose recorded assumption
   changed is included in the invalidated set.
4. **Schedule determinism:** worker order and cache hit/miss choices do not alter
   the canonical result.
5. **Normalization correctness:** local normalization preserves typing,
   interface, and observable evaluation/effect traces.
6. **Generic compatibility:** specializing normalized generic IR is
   observationally equivalent to normalizing the corresponding specialization.

These remain conditional obligations. The current selfhost bridge observes
dependencies, source ingestion fingerprints, provisional canonical token-stream
implementation fingerprints, reuse decisions, and a versioned canonical
exported-interface fingerprint, and the bounded shadow planner performs the
comparison described above. It does not provide normalized typed-IR or
artifact-input identities, canonical-diagnostic trace equivalence, a
compiler-to-Lean proof, or production planner conformance.

### Bounded artifact-input compile trace

Artifact-input tracing is a separate compile-path slice: `vibe check` reaches
the check-only path and does not exercise persistent runnable-artifact
lookup/store. The current bounded implementation opts in only to the
`file_compile` persistent **pre-strip WASI bump** lane:

```text
VIBE_FS_COMPILE=1
VIBE_RC=0
VIBE_ARTIFACT_INPUT_TRACE_OUT=<sidecar.json>
VIBE_ARTIFACT_INPUT_TRACE_NONCE=<unique-non-empty-run-id>
```

It rejects a missing nonce and every incompatible early/special,
LSP/check-only, instrumented/RC/testmeta lane, deletes a requested old sidecar
before any CLI-mode return or validation, writes the wasm first, then writes the
trace as the final sidecar operation. A failed compile or validation therefore
leaves no trace to be mistaken for this run. Ordinary compile dispatch remains
unchanged when `VIBE_ARTIFACT_INPUT_TRACE_OUT` is empty; this wrapper does not
alter a production cache key, on-disk format, or reuse decision, and it does not
instrument `fs_compile`, module, or profiled lanes.

Strict schema version 3 records the nonce and scope disclaimer, exact
`compile_lane`, persistent artifact kind, entry path/name/mode, and the
actual production lookup identity under the explicit name
`production_artifact_input_fingerprint`. The production constructor includes
`exports_stripped` so a cached stripped compile cannot bypass a kept export
root's evidence-lowering diagnostics. Both persistent and in-memory artifact
caches use this complete identity. The trace itself does not select it. It also
records the exact existing
`persistent_cache_version_tag()` (the embedded compiler codegen/cache tag,
**not** #1443's `.generated.stamp`), normalized effective compile
configuration (including the Boolean `exports_stripped` root policy), and only a
fingerprint plus module/edge-occurrence counts for an exact dependency plan. That plan is obtained from `module_plan_data_fs`,
therefore preserves planned module order/ranks and every dependency occurrence
(including duplicates); it is not source-group order.

The schema additionally records `resolution_env_seed()` and the loader's exact
`persistent_resolution_context_fingerprint_fs(entry_path,
grouped_source_paths(source_groups))` authority. Collecting that graph and
context evidence is explicit trace-only extra filesystem work after the
ordinary production compile. Because it is a post-compile recollection, the
sidecar is not an atomic snapshot of the bytes used to produce the wasm; a
concurrent filesystem or resolution-context change may describe a later
snapshot. It never changes cache namespace `v19`, artifact
fingerprints, artifact lookup/store/reuse decisions, interface-v7, TypeEnv-v9,
TDRE5, or trace schema 6. A separately named shadow fingerprint uses a versioned,
fixed-order, length-prefixed `vibe-artifact-input-observation:v2` preimage and
existing compact fingerprint. It is observation-only and is never passed to a
load/store/database reuse API. This remains neither a normalized implementation
identity nor a safe artifact boundary.

`pkf run test-artifact-input-trace` runs strict Node parser/schema tests.
`scripts/artifact_input_trace_oracle.mjs <stage2.wasm>` is the isolated
fresh-stage2 oracle used by `scripts/compiler_gate.sh`: it requires cold miss /
warm hit parity, dependency-content and exact plan sensitivity, config and
resolution-context shadow sensitivity without a corresponding production-key
claim, and failed/no-nonce plus LSP/check-only stale-sidecar removal.

### Incremental typecheck telemetry on a COMPILE (#2735)

The four counters above were readable only from `vibe check`. A build asks a
different question -- how much of the typing walk a `vibe build` / `vibe run`
/ `vibe test` actually reused -- and until #2735 there was no way to answer it
without changing the lane you were measuring.

```text
VIBE_INCREMENTAL_TELEMETRY_OUT=<sidecar.json>
```

On the FS compile lane this publishes the same counter document the check lane
publishes — `schema: 4`, or `schema: 5` with the checked-module cache on. Most
of those counters are CAPTURED at the typing walk's boundary and PUBLISHED at
the compile's, so they describe the walk and nothing after it; the two added by
#2766, `non_walk_parse_operations` and `ast_cache_prefetches`, are the
exception and exist precisely because a build does parser work the walk never
sees. A sidecar exists only for a compile that finished: a throw anywhere above
removes it. Measured on the compiler's own closure, a cold build reports
`modules_planned: 219`, which is `vibe deps` (218) plus the entry.

The sidecar, its encoder and the destination guard below exist only in a
compiler built with the `telemetry` cfg flag, which the generation's stage2 is
by default (#2498). A build without it -- the compile-only artifact -- refuses
`VIBE_INCREMENTAL_TELEMETRY_OUT` by name and never touches the destination,
on the check lane and the compile lane alike.

**The destination is not a free-form path.** It names a file the CLI DELETES
before the compile -- so a sidecar left by an earlier run cannot be read as
this run's result -- and WRITES after it. Both are destructive, so a request
is refused, before anything is removed, when the destination names:

| the destination is | why it is refused |
|---|---|
| the compile input | the clear deletes the entry source, and no later refusal returns it |
| the compile output | the publication replaces the wasm with JSON under a zero exit |
| `<output>.diag` | compiler-owned; `runtime/vibe` removes it once it sees a non-empty artifact, so the build deletes the observation it was asked to produce |
| `<output>.funcmap` | compiler-owned; the map that annotates runtime backtraces is replaced by counters, under a zero exit |
| `VIBE_ARTIFACT_INPUT_TRACE_OUT` | the second write replaces the first observation, and the trace validation admits a telemetry request beside it |
| a directory | `Fs::remove` is recursive, so clearing `lib` deletes the tree |
| anything reached through a symlink | the identity check cannot resolve one, so "different tokens" cannot be read as "different files" |

The list is one function asked at **both** guards, because an entry names
something the invocation would delete or overwrite and both ends can do it.

Aliasing is decided by filesystem identity, not by spelling: equal strings, or
equal `Fs::stat_token` when both paths exist. `stat_token` mixes the inode, so
`build/out.wasm` and `build/./out.wasm` are one file. That is also why the
artifact and the trace are re-checked at the publication boundary -- a first
build has finally put them on disk by then, and it is exactly when they exist
that a write would destroy one.

When one of the two paths is **not** on disk there is nothing to stat, so the
decision moves one level up: the final component is plain text and compares as
text, and the containing directory is on disk in every case this is asked --
the compile writes the artifact and its sidecars into it -- so it has an inode
and `build/.` and `build` compare as one directory. The text test comes first,
which is what keeps this narrow: a destination whose last component differs
from every protected path's is never refused, whatever its directory looks
like. Where the directory cannot be decided -- a parent that is an unresolved
link, or missing -- the answer is "refuse".

This paragraph previously said that needing both paths to exist "is not a gap
where it is asked", because a clear only deletes what exists and a write only
destroys what exists. That is false for `<output>.diag`, the one protected path
a SUCCESSFUL compile never writes: measured, a `build/./out.wasm.diag`
destination passed both guards and the counters landed on the canonical
`<output>.diag`, which `runtime/vibe` then deleted on seeing the artifact.

A **symlink** is refused rather than resolved. `Fs::stat_token` is an lstat by
design (module loading needs a link to be distinguishable from its target, so
a link answers `-1`) and there is no realpath builtin, so a link and its target
answer different tokens -- the identity check reports "different files" for two
names of one file. This paragraph previously said the case "does not need to
be" resolved because `Fs::remove` unlinks the link rather than its target. That
holds only when the LINK is the destination. Measured the other way round, with
the compile entry reached through a link and the destination naming its target,
the clear deleted the real source and left the entry dangling. A dangling link
is still not flagged: nothing it could alias exists.

The other four sidecar clears still accept a directory destination and delete
the tree; that is #2738, which proposes a non-recursive remove builtin rather
than a fifth `is_dir` guard.

`scripts/check_telemetry_sidecar_guards.sh` asks the running compiler for all
of this (`pkf run check-telemetry-sidecar-guards`). Its positive row -- a
plain request publishes a well-formed sidecar -- is what makes the refusals
mean "refused" rather than "not implemented": a compiler that ignores the
variable destroys nothing and would pass every refusal row, which is exactly
what the committed seed does.

## Delivery order

1. Record the current edit-cycle baseline and add cache/invalidation telemetry.
2. Observe source, canonical token-stream implementation, and interface
   identities; prove invalidation-plan properties in Lean and compare real traces
   with the oracle. This observation phase is complete for the bounded corpus;
   the provisional token stream is not production authority.
3. Produce a lossless checked-body or normalized typed-IR identity with
   deterministic round-trip/differential coverage and clean-build artifact
   parity. Only then propose owner cache-key or reuse-policy changes, and cache a
   minimal typed module/SCC artifact.
4. Add generic-template and specialization caches only after their assumptions
   are explicit.
5. Introduce deterministic object fragments and reduce whole-program barriers.
6. Run a package-level Component Model A/B experiment.
7. Apply the same KPI harness to compiler selfbuild and only then set regression
   budgets from repeated measurements on a stable runner.

### Checked expression leaf-payload direct-return artifact

Issue #1379 Phase 3 also provides an opaque
`CheckedExpressionLeafPayloadDirectReturnArtifact` v1 built only from one
complete `CheckedDirectExpressionReturnObservation`. It first reconciles every
observation coordinate with the bounded retained-node preorder and only then
filters to `EInt`, `EBool`, `EString`, `EIdent`, and `EUnit`, preserving exact
payload text and that run's final-substitution canonical direct-return type
text. Its strict length-delimited codec marker is
`vibe-checked-expression-leaf-payload-direct-return-artifact:v1\n`; decoded
bytes do not attest checking, types, provenance, bindings, typed IR, cache,
reuse, imports, interfaces, or trace behavior. This adds no runtime, CLI,
cache, import, interface, or reuse connection.
