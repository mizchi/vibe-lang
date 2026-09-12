# Incremental build design

Status: design and measurement plan. The current compiler has persistent loader
and type-environment caches, but the final build still merges and code-generates
the whole program. This document defines the user-visible target before changing
that architecture.

Related documents:

- [Build cache layering](build-cache.md)
- [Compiler parallelism](compiler-parallelism.md)
- [Bootstrap and generation builds](bootstrap.md)
- [Editor and LSP behavior](editor-and-debugging.md)
- [Component Model target](vibec-component.md)
- [Lean formal model](../formal/README.md)

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
only. They are not wired to TypeDb, the TypeEnv v5 transport and persistent cache
namespace v19, TDRE5, interface-v2, artifact-input traces, planner decisions,
reuse, CLI, or a persistent cache namespace. Decoded values establish canonical
bytes, not a checker invocation. Runtime retains v2 bytes only in an opaque,
in-memory successful `ModuleOutcome`; it does not publish or persist them.

## What a module must see (#2388, #2575 item 2)

The per-module prelude is measured by an oracle that runs every pre-codegen
pass twice over the same program: once whole, once on each file alone, then
links the per-module results and compares by declaration key
(`prelude_module_full_oracle_report_fs`). What each file is given as *context*
decides what its green means.

That context is each module's **own direct imports**, taken from the loader's
header scan (`load_or_parse_module_header_fs` — the same scan the FS typecheck
lane plans module order with), with a dependency that names a `.vpkg` contract
expanded to that package's sibling implementations. It has to come from the
loader because the merge drops `SImport` / `SReExport` as already resolved, so
the edges cannot be read back off the merged program. The counters only mean
what they say under a rule that matches a real compile; what that takes is
[The context rule](#the-context-rule) below.

**One hop, not transitive.** Closing transitively hands A the declarations of a
module C that A's dependency B imports *privately* — context no real compile of
A exposes. Closing only across re-export edges would be the exact rule, and the
header scan does not distinguish them (it returns a module's deps and its export
*names*, with no record of which deps a dep re-exports), so this takes the
narrower side. That narrowing is not free of consequences in either direction —
[The context rule](#the-context-rule) below says what it can and cannot hide.
`edges_unresolved` is reported for its own reason: a dropped edge narrows a
module's context further, and a closure built from every edge and one built from
half of them otherwise look identical.

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
survived the narrowing that took `invisible_split` from 2 to 15.

The link still folds only by a key a module reported as **synthesized**, and
still content-checks the bodies under it. That is not redundant with the above:
it is what turns the next such divergence into a refusal instead of a silently
kept body.

### The per-module prelude reproduces the whole-program prelude exactly

```
CLOSURE files=365 edges=11342 unresolved=0
FULL stmts=9876 split=10033 linked=9876 folded=157 modules=365 collisions=0
     invisible_whole=0 invisible_split=8 linked_dups=5
keyed missing=0 extra=0 copies=444 content=0 renames=0 dup_keys=451 dup_defs=5
EVIDENCE declared=6 handled=4 performed=3
```

`lib/@vibe/cli/entry.vibe`, 365 modules. **`linked` equals `stmts`, and
`missing`, `extra`, `content` and `renames` are all zero.** Compiling the
compiler's own CLI closure per module and linking produces every declaration the
whole-program prelude produces, name for name and body for body.

`copies=444` is what remains after the link and is not a difference: each is a
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

#### What the per-module lane costs before any cache (#2510)

#2510 frames the work as "make the prelude per-module AND cache it", and sizes
it against 1.3-1.5 s spent in `effect_lowering_prelude` on a warm compile. What
it does not say is what the per-module decomposition costs on its own, which the
FS-lane split now makes measurable. Compiler's own closure, `cache_mode = "off"`
(a real bypass since #2647 round 5), a fresh `VIBE_BUILD_CACHE_DIR` per run,
cold vs cold, three runs each:

| lane | mean | min | max |
|---|---:|---:|---:|
| whole-program | 49,994 ms | 49,291 | 50,372 |
| per-module (split) | 52,631 ms | 51,837 | 53,445 |

**5.3% overhead.** Running 365 modules through passes 0..11 individually,
building each module's interface context, and linking, costs about a twentieth
more than one whole-program pass -- not the multiple that would force a cache to
clear a deficit before winning anything. The decomposition is close to free, so
the cache is upside rather than a rescue, and there is no schedule pressure to
force pass 4 per-module if it turns out not to fit (see the audit above).

This is a whole-compile wall time, so the prelude's own share of the change is
smaller than the 5.3% suggests; it bounds the cost rather than attributing it.

**The consequence for the cache (#2510) is the useful part.** A cached function
body contains call immediates, and those depend on GLOBAL function index
assignment. A per-module body cache therefore cannot store a body and replay it
into a build where indices moved — the stored form or the cache key has to
account for index assignment. That constraint came out of this measurement; no
amount of comparing declarations would have produced it.

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
only lane with an `Fs` row, is 0.1%. That is the direct measurement behind the
observation in #2668 that turning the AST cache on left the warm heap
byte-identical: the code that consults it barely runs.

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
performed) facts equals the whole-program facts (`EVIDENCE declared=6 handled=4
performed=3`), sampled immediately before the pass runs. So the module collects,
the link unions and decides, and the link rewrites — with the rewrite then
cacheable per function keyed on (body fingerprint, migration set). #2633.

Three of the nine content rows were read as rendered diffs; the other six are
classified by declaration name, which is why the excerpt block still prints the
first three in full.

### The phases after the prelude (#2575 item 4)

Between the prelude and codegen `linked_compile` runs three whole-program
analyses: `compute_borrow_returning_names`, `compute_borrow_param_user_fns`
(ADR-0092, per-position masks) and `compute_may_return_view_fns`. The oracle
samples all three on both lanes after all 17 prelude passes, which is where the
real compile runs them, and compares the whole-program answer against the union
of the per-module ones.

Unlike the evidence facts above, all three are **interprocedural** — each reads
the classification of callees that may live in another module — so the two lanes
differ in both directions and the directions do not mean the same thing.

Two of them iterate to a fixpoint (`compute_borrow_returning_names`'s `while
changed`, `compute_may_return_view_fns`' callee-edge worklist).
`compute_borrow_param_user_fns` does **not**: it is round 0 plus **one bounded
transitive round** reading round 0's immutable snapshot, and deliberately stops
there. That distinction constrains the link-time design below — closing it
transitively would compute a larger borrow set than today's ABI, which is a
behaviour change rather than the same answer computed differently.

Measured on `lib/@vibe/cli/entry.vibe`, 365 modules:

```
ANALYSIS dce_entry=0 borrow_ret=378/363:-15:MutSortedSet::delete+0:
         borrow_fns=2706/2627:-167:alloc_site_kind_dep_...+88:__arr_equals__N4_Expr
         borrow_masks=2706/2627:-197:agg_expr_of_ident_exp_...#12+118:__arr_equals__N4_Expr#3
         view_ret=2123/1943:-180:HashSet::size+0:
```

- **A name the whole program has and the union lacks** is a module being
  conservative about a callee it cannot see: `via(xs) = pick(xs)` is not
  classified view-returning by its own module when `pick` lives across the
  import. Slower, sound; 167 on the borrow set and 180 on the view set.
- **A name the union has and the whole program lacks** is a module qualifying a
  function the whole program **disqualified**. `ca_collect_nonident_args`
  disqualifies a callee from a *call site*, which may live in another module, so
  a module reading only its own statements hands back the borrowed ABI for a
  parameter the program says is consumed. 88 of them, and this is the unsound
  direction.

The net (2706 − 2627 = 79) hides all 88 behind the 167, which is why both
directions are counted rather than subtracted. The mask row is the same question
one level finer: 118 against 88 means 30 functions are in **both** sets under
**different** masks — the names agree and the ABI does not, which a comparison on
names alone reports as agreement.

`dce_entry` is the sample point's own caveat. Production runs
`fold_const_bool_params` and `dce_stmts` between the prelude and these
analyses, gated on the merged program defining `entry_name`; a folded constant
`Bool` argument can delete a consuming branch and change a borrow mask, and DCE
can delete a generated helper outright. The oracle cannot reproduce either —
`dce_stmts` is rooted at the entry and the split lane has no per-module entry —
so it reports the condition and prints `unmeasured` instead of counts when it
holds. The closure numbers above are a `dce_entry=0` measurement: the same
closure through `vibe build` would give different sets, though not a different
conclusion, since neither transform makes an interprocedural analysis
decompose.

So these phases do not decompose as written. What a module can compute alone is
its own contribution; the disqualifications and the callee edges are the
program's. That makes them the same shape as the evidence pass (#2633) — the
module collects, the link unions and decides — with two differences that matter.
An evidence disagreement produces two programs that cannot link, and a borrow
disagreement produces two that link and disagree about ownership. And the link's
closing step is not one shape: a fixpoint for the two analyses that iterate, and
**exactly one** bounded transitive round for the borrow masks, because that is
what the shipped ABI is.

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
semantic parses must equal schema-2 current-source parse executions. These
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
TypeEnv-v5 authority lets unchanged consumers reuse their existing typing
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

TDRE9 TypeEnv reuse is enabled by default for the `vibe check` filesystem
check-only lane. Build, codegen, LSP, and direct FS typecheck consumers remain
conservative pending a compact exact-publication design: publishing the current
exact TDRE9A/TDRE9W texts on a fresh selfcompile exceeds the signed 2 GiB guest
heap boundary, while the conservative compile lane remains near 1.11 GB.
`VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE=1` is the strict emergency opt-out for
check-only reuse; any other nonempty value is rejected. An incremental
invalidation trace automatically forces reuse off so the trace stays
observation-only.

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
trace-only `vibe-module-interface:v4` observation as a production key, and
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

A witness is published only after that module's canonical TypeEnv-v9 target and
when every direct dependency already has a validated witness for its conservative
fingerprint. Alias and witness both bind the logical input, target conservative
fingerprint, and exact canonical target text. Reuse reads the raw target,
strictly decodes it, requires an exact canonical re-encode, and verifies the
three-way alias/witness/target binding. Publication order is target, witness,
alias; diagnosed or failed modules publish none of those rows. The production
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

The sidecar is schema version 6 and is written **only after a successful
check**. It includes the nonce, canonical module path, direct dependencies,
`compact_string_fingerprint` of each module's **ingested source**, distinct
version-tagged `implementation_fingerprint`, `interface_fingerprint`,
`checked_env_fingerprint`, and `persistent_type_env_transport_fingerprint`,
the observed current TypeDb decision (`rechecked`
or `reused`), and aggregate work telemetry. The interface identity hashes a canonical
`vibe-module-interface:v2` serialization of exported inferred value/function
types (including effects), exported public type/trait/effect/effectset
declarations, and re-exports. For exported traits, schema 6 serializes
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
TypeEnv-v5; the transport remains TypeEnv-only—not a `CheckedProgram`, typed IR,
exported interface, cache key, or reuse decision.

These observation identities have intentionally different authorities.
`vibe-module-interface:v2` covers only the exported API surface. In particular,
`SImpl` has no exported/public bit, so impl declarations are excluded from that
interface identity rather than being silently treated as public declarations.
Impl bounds and targets are module-visible trait-resolution state and are
observed by the complete persistent TypeEnv v5 transport identity instead.
Neither identity establishes final linked-artifact freshness: the current
runnable-artifact lane continues to use its whole resolved source-group input
identity and compile configuration. Consequently an impl-only edit is expected
to preserve `interface_fingerprint`, change
`persistent_type_env_transport_fingerprint`, and invalidate linked artifacts
through their existing source-group identity. This distinction does not promote
either observation into a production key or reuse decision.

The token-stream, interface, checked-environment, and transport reconstructions
are not charged to the existing TypeDb `parse_operations` counter. Standalone
incremental telemetry schema 2 retains that historical counter and its
`modules_rechecked` / `modules_reused` decisions, while independently reporting
actual `ModuleJob.source` parse-memo misses, checker calls, conservative
fingerprint reuse, and validated TDRE5 dependency-transport reuse. The two reuse
classes must sum exactly to `modules_reused`. These counters cover only the
filesystem TypeDb walk: loader/source-group parsing and later linked validation
remain outside this boundary. Invalidation trace schema 6 deliberately embeds
the legacy schema-1 aggregate; exposing schema-2 counters there requires a
future explicit trace schema bump.

The existing `rechecked`/`reused` report therefore remains the current
conservative cache-path observation rather than a claim about total sidecar
work. None of these fields is read by a production
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
in TypeEnv v5. Issue #1379 additionally defines a narrow, length-delimited
`CheckedTypeDefsArtifact` v1 for retained `type_defs`, aligned declaration
binders, and the authoritative semantic `final_subst` chain. `SubstCached`
acceleration-bearing substitutions are rejected rather than normalized or
serialized: no invariant establishes that their maps are semantically equivalent
to the rest chain, and v1 excludes them until the `Map[Type]` codegen issue is
fixed. It is not a full
CheckedProgram/TypeEnv artifact, typed IR, cache key/reuse input, interface,
import contract, or trace schema; that historical slice left schema 6,
interface v2, and the then-current TypeEnv v3 unchanged. Current production has
since moved to TypeEnv-v5. `TDEffect` operation declarations, `CtFn` effect text,
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
complete persistent TypeEnv v5 transport observation while leaving the
exported-interface observation unchanged; the bound case also leaves the
value-only checked-env observation unchanged. Exported type derives,
trait-supertrait edges, effect operation signatures, and effectset members are
separately covered by clean/warm interface-v2 parity and sensitivity checks.
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
implementation identities change, its interface-v4 identity does not change,
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

Strict schema version 2 records the nonce and scope disclaimer, exact
`compile_lane`, persistent artifact kind, entry path/name/mode, and the
unchanged production lookup identity under the explicit name
`production_artifact_input_fingerprint`. It also records the exact existing
`persistent_cache_version_tag()` (the embedded compiler codegen/cache tag,
**not** #1443's `.generated.stamp`), normalized effective compile
configuration, and only a fingerprint plus module/edge-occurrence counts for
an exact dependency plan. That plan is obtained from `module_plan_data_fs`,
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
fingerprints, artifact lookup/store/reuse decisions, interface-v2, TypeEnv-v5,
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
