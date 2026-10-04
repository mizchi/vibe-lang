# Mutation authority and collection naming: the measured basis (ADR-0100, ADR-0101)

A design record, not an ADR. It asked whether the several ways of writing
mutable state in vibe — `let mut`, region storage, a state effect, the
`Map` / `MapHamt` / `MutMap` family — could be folded under **one rule**, and
it measured before answering. The decisions are ADR-0100 (mutation authority
and collection naming) and ADR-0101 (the builder family). This document keeps
the measurements and the reasoning those rows cite; the current contracts live
in [region-mutable-state.md](region-mutable-state.md),
[perceus-reuse.md](perceus-reuse.md) and the
[cheatsheet](../../user/reference/cheatsheet.md).

Measurement script: [bench/bench_state_representation.vibe](../../../bench/bench_state_representation.vibe).
Reference for the effect vocabulary: [Verse, "Effects"](https://verselang.github.io/book/13_effects/).

## 0. Summary

1. **Constructor reuse does not bring a state effect to `let mut` speed.** On
   the compiler measured in §2, reuse gained nothing or lost; even perfect
   reuse would stop at the heap-resident floor (`struct mut`, 3.5×); and the
   state effect already sat about 2× above that floor, a gap made of perform
   dispatch, not allocation. (§2)
2. **"Mutable" names two orthogonal axes.** Axis A: does the value change.
   Axis B: can the write be observed outside the scope that created the cell.
   Cost and authority both follow axis B; the surface syntax only spells
   axis A. (§3)
3. **Authority belongs on axis B.** A write needs explicit authority exactly
   when someone other than the cell's creator can observe it. The predicate
   already existed in codegen; it is now visible (`vibe escapes`) and carried
   by the checker's environment. The spelling of authority over a heap cell,
   `with Mut[c]`, is reserved and refused until it is designed. (§4)
4. **Collection names separate mutability from implementation**: a closed set
   of prefixes for mutability, the base name for the interface, a suffix for
   an implementation kept alongside another for performance. The renames have
   landed. (§5)
5. **The fastest form is state in a wasm local that RC never touches.** The
   gap between forms is the price of optimisations not yet written, so the
   plan is to converge the lowering, not the surface. Two pieces have landed:
   the inline tag test on dups (§2.9) and tuple `let mut` unboxing (§6.4).
   (§6)

---

## 1. Inventory: the ways to write mutable state

The cheatsheet's "Choosing a mutation style" lists five. By implementation
there are three: a wasm local, a heap block written in place, and a cell held
by a handler.

| form | implementation | axis A (changes) | axis B (observable outside) | row |
|---|---|---|---|---|
| `let mut x`, not captured | **wasm local** | yes | **no** | none |
| `let mut x`, captured by a closure | heap ref cell (RC class 8) | yes | yes | none |
| `struct S { mut f }` | heap block written in place | yes | yes | none |
| `Array` / `Bytes` | heap block written in place | yes | yes | none |
| `XBuilder` → terminal | heap block until the terminal | yes | yes (until the terminal) | none |
| own effect + `handle` | a cell the handler holds | yes | yes | **yes** |
| `region r { }` (ADR-0090) | arena segment for `MutList` / `MutBytes` | yes | yes (inside the region) | not yet (`with r` is unimplemented) |

- `let mut` is two features under one spelling. Uncaptured, it is a wasm local
  that nobody else can observe. Captured, it becomes a heap cell shared through
  the closure. The decision is `mut_needs_ref_cell`
  (`codegen/common_analysis`).
- Only the handler form puts authority in the row today. ADR-0060's withdrawn
  proposal put a row on *every* `mut`; that was rightly withdrawn, and this
  record re-proposes the narrower form — a row only for a `mut` whose writes
  escape (§4).

---

## 2. Measurement: does FBIP bring a state effect close to `let mut`?

Measured in August 2026 for #1262, on the compiler of that date. Constructor
reuse has since gained the wide tier and the ownership-correct Array
higher-order lowerings ([perceus-reuse.md](perceus-reuse.md)), so the reuse
rows below describe the Phase-1 implementation; the floor rows and the
conclusions about authority do not depend on it.

### 2.1 Method

[bench/bench_state_representation.vibe](../../../bench/bench_state_representation.vibe).
`state/*` computes the same `sum(0..999)` and varies only where the loop state
lives; `fbip/*` is an A/B of shapes where reuse does and does not fire.

```bash
VIBE_RC=0 vibe bench bench/bench_state_representation.vibe --iters 400   # bump
VIBE_RC=1 vibe bench bench/bench_state_representation.vibe --iters 400   # Perceus RC + reuse
```

Whether reuse was emitted was confirmed by counting the uniqueness-test
constant (`i32.const 16777217` = `1 | class1 << 24`) in the code section.
`bytes_per_op` is the advance of the bump pointer, so it does **not**
distinguish in-place reuse from free-list reuse; the fixture says so itself.

> Environment: the development container, node/viberun, p50 of `--iters 400`.
> `ns_p50` is runner wall time (±3% on repeats). A "difference" below is one
> whose sign held over three repeats.

### 2.2 Where the loop state lives (1000 iterations = 1 op)

| # | form | RC=0 p50 | ×base | B/op | RC=1 p50 | ×base | B/op |
|---|---|---|---|---|---|---|---|
| 1 | `let mut`, not captured | 738 ns | **1.00** | 0 | 740 ns | **1.00** | 0 |
| 2 | `loop` parameters (scalar) | 738 | 1.00 | 0 | 741 | 1.00 | 0 |
| 3 | `struct { mut n }` | 2599 | 3.52 | 16 | 2605 | 3.52 | 24 |
| 7 | `let mut`, captured by a closure | 2794 | 3.79 | 24 | 3620 | 4.89 | 0 |
| 6 | **state effect + handler** | 5795 | **7.85** | 64 | 5599 | **7.57** | 96 |
| 4 | rebuild a value state each step (inline) | 12410 | 16.8 | 24024 | 22179 | 30.0 | 0 |
| 5 | same, through a step function (reuse-ineligible) | 12929 | 17.5 | 24024 | 21128 | 28.6 | 0 |
| 9 | same, **reuse-eligible shape** | 12831 | 17.4 | 24024 | 34171 | 46.2 | **32032** |
| 8 | keep every value state alive | 21823 | 29.6 | 40356 | 40836 | 55.2 | 32032 |

### 2.3 The eligible shape was slower

#5 and #9 differ by one line of source (`let s = s0`, because Phase 1 required
a `let`-bound scrutinee); the work is identical.

| | RC=0 (no fusion) | RC=1 (fusion) |
|---|---|---|
| #5 ineligible | 12929 ns / 24024 B | **21128 ns / 0 B** |
| #9 eligible | 12831 ns / 24024 B | **34171 ns / 32032 B** |

- On bump there is no difference (the extra `let` costs nothing).
- On RC the fused shape was 1.62× slower and allocated 32 KB/op instead of 0
  (p50 over three repeats: 32977 / 34177 / 32254).
- The caller of `step_fused(s)` keeps `s`, so the run-time `rc == 1` test
  fails every time and the shared fallback (payload dups, guarded release,
  fresh allocation) runs — and that allocation disturbs the free-list steady
  state the ineligible shape enjoyed. **Static eligibility (a syntactic shape)
  and dynamic uniqueness (ownership) did not coincide.** That lesson stands
  for the current implementation as well: reuse pays only on uniquely held
  inputs.

### 2.4 List `map`, the canonical FBIP workload

`map_inc_fused` met every Phase-1 condition (one uniqueness-test site was
emitted); `map_inc_plain` did not fire because its scrutinee was a parameter.

| form | RC=0 p50 / B | RC=1 p50 / B |
|---|---|---|
| `array_inplace` (mutable array in place) | 11831 / 16332 | 16452 / 8284 |
| `list_map_plain` (ineligible) | 37334 / 48016 | 59897 / 32016 |
| `list_map_fused` (eligible) | 36557 / 48016 | 60389 / 32016 |
| `list_map5_plain` (five maps, intermediates unnamed) | 146889 / 144048 | 103102 / **0** |
| `list_map5_fused` (same, eligible) | 150780 / 144048 | 104709 / **0** |

- Eligible versus ineligible differed by ±1.6%, inside the noise band.
- Allocation was identical. The 0 B/op of `map5` came from free-list reuse in
  **both** forms, not from in-place reuse.
- `map5` was faster on RC than on bump (103 µs against 147 µs): on
  allocation-heavy code RC already won, so "RC costs 1.6–2.1× bump" held only
  for code that allocates little.

### 2.5 Where the state effect sits

| comparison | ratio |
|---|---|
| state effect ÷ uncaptured `let mut` | 7.6–7.9× |
| state effect ÷ `struct mut` (heap-resident floor) | **2.15–2.23×** |
| state effect ÷ captured `let mut` (**the form solving the same problem**) | **1.55–2.07×** |
| value rebuilding (#4/#5) ÷ state effect | 2.1–4.0× |

Compare like with like. An uncaptured `let mut` does not solve "share state
across a call boundary"; nobody can observe it. What a state effect can
replace is a captured `let mut`, and against that it costs about 2× with a
constant 64–96 B/op of allocation. The handler in this bench itself keeps its
state in a captured `let mut`, so both sides pay the same cell and the
difference is the effect layer: dispatch through the evidence dictionary, not
allocation. FBIP reduces allocation and cannot touch it. Narrowing it means
inlining a tail-resumptive handler into the caller so that get and put become
local reads and writes — a handler-inlining problem, not a memory problem. A
`perform` written directly inside the handler body is already inline-eliminated
(see the cheatsheet's mutation-style table).

### 2.6 Summary

```text
1.00×      let mut (not captured)   a wasm local; never touches the heap
3.5×       struct mut               the floor for heap-resident state
3.8–4.9×   let mut (captured)       the same band; the `mut` spelling is irrelevant
7.6–7.9×   state effect             about 2× the floor; the gap is perform dispatch
17–46×     value rebuilding         FBIP's target; Phase 1 gained nothing or lost
```

`let mut`'s 1.00× is not a property of the keyword. It is the property "an
uncaptured scalar lives in a wasm local", and capturing it drops it into the
3.8–4.9× band — the direct evidence that axis B decides cost (§3).

### 2.7 The fastest form, and what the gaps are made of

The `floor/*` benches do the same work and vary only where it lives.

| form | RC=0 p50 | RC=1 p50 | B/op |
|---|---|---|---|
| loop skeleton only (no add) | 388 ns | 388 ns | 0 |
| **two `let mut` (the fastest form)** | **738** | **740** | 0 |
| four `let mut` | 499 | 721 | 0 |
| top-level call, constant arguments | 1390 | 1389 | 0 |
| top-level call, loop-borrowed arguments | 1052 | **6750** | 0 |
| closure call | 2061 | 6072 | 0 |
| four `mut` fields of a struct | 2719 | 2753 | 40/48 |
| `loop` parameters packed in one tuple | 7900 | 21120 | 16016/0 |

- The fastest form is state in wasm locals that RC never touches: 0.39 ns per
  iteration for the skeleton plus 0.35 ns for the add, the hardware floor.
  More locals cost nothing.
- A struct's `mut` fields cost about the same with one field or four (2604 /
  2719 ns): the price is the heap block, not the fields. The struct never left
  the function, so scalar replacement would remove it.
- `loop (s = (0, 0))` boxed its state (16 B per iteration) while
  `loop (i = 0, acc = 0)` stayed in locals at 738 ns: the same meaning,
  10–28× apart. §6.4 removed that gap for tuple state.
- Every gap was the price of a missing optimisation rather than a cost
  intrinsic to the form. At the time vibe had no escape analysis, scalar
  replacement, unboxing or user-function inlining.

### 2.8 The largest single factor: `__rt_rc_dup` on scalar arguments

One row in §2.7 is an order of magnitude off: a top-level call whose
arguments are loop-borrowed locals cost 6.4× on RC (1052 → 6750 ns), while the
same call with constant arguments cost the same on both lanes (1390 / 1389).

The disassembly showed why. Before `add2(acc, i)`:

```wasm
local.get 2 / local.tee 4 / local.get 4 / call __rt_rc_dup   ; acc is an Int
local.get 3 / local.tee 5 / local.get 5 / call __rt_rc_dup   ; i   is an Int
i64.const 0 / call add2
```

Two out-of-line `__rt_rc_dup` calls on tagged immediates. An `Int` is even, so
the dup is a no-op and the helper returns after its tag test — but the call
itself cost about 2.2–2.9 ns each time.

| ns per 1000 iterations | RC=0 | RC=1 | attribution |
|---|---|---|---|
| `floor/0` no call | 388 | 388 | — |
| `floor/2b` one call, **no dup** (constant arguments) | 1390 | **1389** | the call is +1.0 ns/iteration and does not grow under RC |
| `floor/2` one call, **two scalar dups** | 1052 | **6750** | dups +5.4 ns/iteration (about 2.7 ns each) |

(A standalone module gave the same picture: 404 / 1433 / 5919–7323.)

The whole RC penalty on that call was the scalar dups; the calling convention
itself carried no RC cost. Codegen decided the guard at run time from the tag,
which is what §2.9 made cheap.

### 2.9 Implemented: the tag test inline, the rest out of line

The out-of-line arm of `emit_rc_dup_guarded` is `emit_rc_dup_tagtest_call`:

```wasm
local.get v; i64.const 1; i64.and; i32.wrap_i64
if (void)  local.get v; call __rt_rc_dup  end
```

This is the first test of `emit_rc_dup_inline` (odd = heap candidate, even =
tagged immediate) moved to the call site; only the heap path calls the helper,
which re-tests on entry because it is generated from `emit_rc_dup_inline`
itself. Semantics are unchanged, including the `VIBE_RC=shadow` guard inside
the helper, and no static analysis is involved.

Microbenchmark (ratios within one binary; absolute ns across binaries move
±15% with code placement):

| RC=1, min ns per 1000 iterations | before | after |
|---|---|---|
| `floor/2b` call only (no dup) | 1341 | 1224 |
| `floor/2` call + two scalar dups | 6077 | **2101** |
| **per dup** | **2.37 ns** | **0.44 ns** |
| `floor/2` ÷ `floor/2b` | 4.53× | **1.72×** |

Size: +9 B per site (full inlining is +67 B per site); `VIBE_RC=0` output was
byte-identical. Correctness: `rc_corpus_parity` 141/141, `rc_cutover_readiness`
READY, `pkf run test` (stage2 == stage3 fixpoint) green.

The self-compile ratio moved in the right direction (paired ratio 2.605 →
2.399 over five interleaved rounds) but the distributions overlapped, so it
was not significant at n = 5. Most of the compiler's dups are real heap values
(strings, arrays, AST nodes) that pass the tag test and still call the helper;
the microbenchmark, all `Int`, measures the upper bound.

---

## 3. The problem: two orthogonal axes collapsed into one word

- **Axis A (mutability)**: does this value change? This is what `mut` versus
  persistent says.
- **Axis B (observability)**: can anyone other than the cell's creator observe
  the write?

§2 showed that cost follows axis B alone (`let mut` changes nothing on axis A
and pays 3.8× when it crosses axis B). The requirement "writing through an
external reference needs explicit authority" is, word for word, a definition
of axis B.

Before §4.5–4.7, axis B existed only as the codegen predicate
`mut_needs_ref_cell`: it appeared in no type, no diagnostic and no
`vibe type-at` answer; `TypeEnv` carried no mutability, so the spawn check
re-walked the AST for captured `let mut`; and region escape was the same
question asked from another side. vibe already computed the predicate it
needed. It did not tell the type system.

---

## 4. The rule: authority follows axis B

### 4.1 What to take from Verse, and what not

Verse's heap effects are `<computes>` (reads and writes no state), `<reads>`,
`<writes>`, `<allocates>` and `<transacts>` (the default, all three), and
`set` is `<transacts>` by default.

**Not taken: an effect on every write.** Verse can afford that because its
annotations are subtractive — `<transacts>` is the default and purity is
claimed by writing `<computes>`. vibe's rows are additive: authority is
claimed by writing it. Additive rows on every `set` would put `with Write` on
nearly every function, which is the same reason ADR-0091 made allocation an
attribute rather than a row atom.

**Taken: the staging, and unannotated as the default.** Staying additive while
expressing authority means narrowing where the authority is required, and the
only narrowing that matches cost is axis B. Verse does not distinguish a local
`var` from a field; this rule makes locals explicitly authority-free, so it is
looser than Verse and shares only "no annotation by default".

### 4.2 One ladder

```text
step 0  local mut          no authority    uncaptured `let mut`, `loop` parameters
                                           -- only the creator can observe it
step 1  region-bound mut   `with r`        mutable collections inside `region r { }`
                                           -- always discharged at the region's end
step 2  heap mut           via a handler   an effect + `handle`
                                           -- authority in the row, held by the handler
step 3  host mut           `with Fs` etc.  state outside the process (existing)
```

> **If anyone other than the cell's creator can observe a write, it needs
> authority, and the authority names who holds the cell (a region, a handler,
> the host).**

| today | step | status |
|---|---|---|
| `let mut`, not captured | 0 | unchanged; most code |
| `let mut`, captured | 1-like | its escape is now a checker fact (§4.6); no row |
| `struct { mut f }` | 1 or 2 | not covered by the escape predicate (ADR-0100 (1)) |
| `Array` / `Bytes` | 1 or 2 | not covered by the escape predicate (ADR-0100 (1)) |
| `region r { }` (ADR-0090) | 1 | implemented for `MutList` / `MutBytes`; `with r` in public rows is not |
| own effect + handler | 2 | already in the right shape |
| `Fs` / `Env` / … | 3 | unchanged |

This is ADR-0060 in its narrowed form: a row only for a `mut` whose writes
escape, which is consistent with §2.6 — an escaping `mut` already sits in the
3.8× band with step 1's cost structure.

### 4.3 Relation to regions

Region inference and `let mut` mutability looked like separate features
because each answered axis B separately. On the ladder:

- `region r { }` is the explicit spelling of step 1.
- A captured `let mut` is step 1 with its declaring scope as an implicit
  region.
- ADR-0071's reserved region-argument kind is the vehicle for `with r`.

### 4.4 Implementation steps

1. **Make the predicate visible without changing types.** Done: `vibe escapes`
   (§4.5) and the strict fact in `TypeEnv` (§4.6). The rule here was to keep
   one source of truth per direction rather than re-derive the predicate.
2. **Make the step 0 / step 1 boundary an error**, starting as an opt-in lint.
   Not implemented.
3. **Implement `region r { }` as the explicit step 1** and put captured
   `let mut` under the same check. Regions landed for collection storage
   (ADR-0090); the captured-`let mut` half has not.
4. **Enable step 1's row form (`with r`).** Not implemented; it changes the
   surface and needs a bootstrap bump.

The authority spelling for step 2 is `with Mut[c]` (ADR-0100 (2)). It is
reserved: a row naming `Mut` and a user `effect Mut` are refused by the
checker (`collect_unknown_effect_label_errors`, #3045), so the marker can land
later as a compatible addition. Until then an empty row promises no host
capability and no algebraic effect, not the absence of mutation through the
arguments.

### 4.5 `vibe escapes` and the two predicates

`vibe escapes <file.vibe>` (`lib/@vibe/compiler/query/escape_spans.vibe`)
prints each escaping `let mut` as `NAME START END` (the byte offsets of the
name). It changes no type, no row and no error; it makes the lowering decision
visible.

```text
$ vibe escapes bench/bench_state_representation.vibe
acc 4019 4022      # of 25 `let mut`, only this one escapes
                   # (the acc of state/7_let_mut_captured)
```

The default lane calls codegen's `is_mut_captured_in` directly, so its answer
is by construction what codegen boxes. There are two live predicates, and
they differ on purpose:

| predicate | home | direction |
|---|---|---|
| `is_mut_captured_in` | `codegen/common_analysis` | **conservative**: it does not subtract `match`-arm or `for-in` binder shadowing, so a closure capturing an inner binding that reuses an outer `let mut`'s name counts as a capture. That boxes more than needed — slower, never wrong |
| `mut_binding_escapes` | `checker/checker_escape.vibe` | **strict**: a false positive would be a wrong diagnostic, so shadowing is subtracted |

Lowering must box when unsure; a diagnostic must stay silent when unsure.
`vibe escapes` answers the cost question with the first, and
`vibe escapes --strict` answers the authority question with the second; the
strict output is always a subset of the default. A third copy
(`checker_capture.vibe`) was dead and wrong — it never descended into `EFn` —
and has been deleted.

### 4.6 The strict fact lives in `TypeEnv`

`TypeEnv` carries **`EnvMutCell(name, escapes, rest)`**. `env_bind_mut` pushes
it in front of the ordinary `EnvBind`, so type lookup (`env_lookup`) is
unchanged and only `env_mut_escape` reads it. The checker computes
`mut_binding_escapes` where it checks an `ELetMut` and records the answer
there.

Shadowing is then a property of the environment chain rather than of a walk
that has to re-derive it: an inner immutable binding of the same name sits in
front as an `EnvBind`, so `env_mut_escape` answers `None` by chain order
alone. The spawn check's second whole-program walk was deleted; the Spawnable
check is one `env_mut_escape` lookup at the capture site, and its diagnostic
carries a location. `escape_spans_test.vibe` pins where the two lanes differ —
only on binder shadowing, strict ⊆ default — because two predicates that
differ on purpose become two predicates that differ by accident if the
difference is not pinned.

### 4.7 Region escape through closures

Regions and captured `let mut` meet at closure capture, and that is where a
hole was. A closure that captures region storage can leave the region with a
result type that mentions no region:

```text
region r {
  let l = MutList::empty(r)
  () -> Array[Int] { MutList::to_array(l) }   // result type: () -> Array[Int]
}
```

Once the arena resets its watermark at the region's end, such a closure would
read reused memory. A capturing closure that stays inside the region is
legitimate (`let add = (v: Int) -> Unit { MutList::push(l, v) }`), so the rule
is "a closure that captured region storage does not leave the region", not
"a closure may not capture region storage".

The checker enforces it through capture provenance carried in checked
function types (#1938): region skolems a closure captured travel with its type,
so the result scan sees them wherever the closure goes. The
`fixtures/err_region_escape_*` cases and the positive region-local closures
pin both directions ([region-mutable-state.md](region-mutable-state.md)).

---

## 5. Collection naming: one position per axis

### 5.1 The rule

- **Mutability is a prefix from a closed set**: none = persistent, `Mut` =
  mutable handle, `Frozen` = persistent and `Send`, and the `Builder` suffix
  for an accumulator that ends in a terminal.
- **The interface is the base name**: `Map` (unordered), `SortedMap` (ordered,
  with ranges), `Set`, `SortedSet`, `Array`, `List`.
- **An implementation is a suffix, used only when two implementations are kept
  side by side for performance**: `Hamt`, `Avl`. That is the rule's own escape
  hatch, not an exception to it.

`Mut-` covers both a region-bound collection and a general mutable handle; the
region parameter tells them apart on the ladder (`MutList[T, r]` is step 1,
`MutMap[K, V]` step 2). `Array` and `Bytes` are not renamed: they are the
low-level primitives outside the rule.

### 5.2 Names today

| name | contract | where |
|---|---|---|
| `Map[K, V]` | persistent; `set` returns a new map | builtin |
| `MapBuilder[K, V]` | builder; terminal `freeze` → `Map` | builtin |
| `MapHamt[V]` | persistent HAMT, `String` keys | `@vibex/immut` |
| `MutMap[K, V]`, `MutSet[T]` | mutable handles, explicit hash / eq | `@vibe/core` |
| `MutSortedMap[K, V]`, `MutSortedSet[T]` | mutable ordered handles, explicit comparator | `@vibe/core` |
| `MutList[T, r]`, `MutBytes[r]` | region-bound mutable storage (ADR-0090) | builtin |
| `FrozenArray[T]` | persistent, `Send` | builtin |
| `ArrayBuilder[T]`, `StringBuilder` | builders | builtin |

The old spellings remain as deprecated aliases: functions such as
`HashMap::new_string` carry `#deprecated` and `vibe check` names the
replacement; the type names (`HashMap`, `HashSet`, `SortedMap`, `SortedSet`,
`ImmutMap`) are transparent aliases declared in the package contracts (#1700),
so an old annotation and a new constructor are the same type across an
`index.vpkg` boundary. The contract parser of the committed seed rejects `#`
on a type row, so `query/deprecated_scan.vibe` warns on those names through
a table until a bootstrap bump.

### 5.3 Why the old names broke the rule

The previous rule (bare = persistent, `Hash-` / `Sorted-` = mutable) had three
breaks: `ImmutMap` carried a prefix for the same contract as `Map`, because the
rule had no way to say "same contract, different implementation"; `Hash-` and
`Sorted-` each carried two axes at once (an implementation or an interface,
plus mutability), so neither a persistent hash map nor a mutable sorted map
could be spelled; and ADR-0090's region-bound `Mut-` would have made `MutMap`
and `HashMap` two mutable maps.

### 5.4 Builders (ADR-0101)

A builder is a kind of mutation, so each was measured before being placed on
the axes: accumulation of n = 1000,
[bench/bench_builder_vs_mut.vibe](../../../bench/bench_builder_vs_mut.vibe),
B/op on `VIBE_RC=0` (bump, so the frontier is the true allocation), August
2026:

| material | builder | `Mut-` equivalent | persistent equivalent |
|---|---|---|---|
| array | 17.2 µs / 16332 B | `Array::push` 13.6 µs / **16332 B (identical)** | concat 90 ms / 10.8 MB |
| string | **23 µs / 17 KB** | (there is no mutable `String`) | concat 250 µs / 492 KB |
| map | 2.43 ms / 71 KB | `HashMap` (now `MutMap`) **1.49 ms** / 337 KB | `Map::set` 133 ms / 18 MB |

Decisions:

- **`ArrayBuilder` and `MapBuilder` are to be retired** through deprecated
  aliases. `ArrayBuilder` matched `Array::push` within noise and to the byte; it
  was only a contract signal. `MapBuilder` was 1.6× slower than the mutable
  map. The contract signal (do not keep it, finish it) is to be carried by the
  region-bound `MutList[T, r]` and a future `MutMap[K, V, r]`. The deprecation
  has not landed: both builders are still the documented accumulators, with
  `freeze` as their terminal.
- **`StringBuilder` stays as a performance exception**: 10.6× faster than the
  only alternative and 29× less allocation, and there is no mutable `String`.
  The rule for the family is one sentence: *a builder is an accumulator that
  exists for a performance exception*.
- **Verbs**: a builder's terminal is **`build`**; **`freeze`** is reserved for
  producing a `Frozen-` (persistent and `Send`) value; a non-consuming
  `Mut-` → persistent conversion is **`snapshot`**. `StringBuilder::build` is
  implemented; `ArrayBuilder::build` and `MapBuilder::build` are not, and
  `XBuilder::freeze` remains their terminal.
- **Fixed-length arrays**: code whose length is known in advance should use
  `FixedArray` (`make` / `get` / `set` / `blit`), whose bounds are static and
  whose length invariant can later be proved; unknown-length accumulation uses
  `Array::push`; string accumulation uses `StringBuilder`.

### 5.5 `ImmutMap` became `MapHamt` (ADR-0100 (3))

ADR-0100 (3) asked whether `ImmutMap` could be merged into builtin `Map`, with
an implementation suffix as the fallback if both were needed for performance.
[bench/bench_map_vs_immutmap.vibe](../../../bench/bench_map_vs_immutmap.vibe),
n = 1000, `VIBE_RC=0`, `--iters 20`, August 2026:

| | builtin `Map` (flat assoc list) | `MapHamt` (HAMT) | |
|---|---|---|---|
| build p50 | 18.08 ms | **653 µs** | **27.7× faster** |
| build B/op | 18,822,984 | **856,828** | **22.0× less** |
| build + lookup p50 | 17.91 ms | **755 µs** | **23.7× faster** |
| build p50 (n = 64) | 75.4 µs | **24.8 µs** | 3.0× faster |

**Decision: keep both.** `ImmutMap` was renamed `MapHamt`: `Map` is the
interface and `-Hamt` the implementation suffix. A persistent map of any size
should be a `MapHamt`. Since this measurement `Map` gained a side index for
eight or more entries and in-place update of a uniquely held map on the RC
lane (#2683, [perceus-reuse.md](perceus-reuse.md)), so the numbers describe
the `Map` of that date; whether to replace `Map`'s implementation is a
separate decision.

---

## 6. Converging on the fastest form

§2.7 established that the fastest form is state in a wasm local that RC never
touches, and that every gap is the price of an optimisation not yet written:

| gap (RC) | price | what it pays for | what removes it |
|---|---|---|---|
| dup of a scalar argument | +2.2–2.9 ns per argument per call (+0.44 ns after §2.9) | a no-op dup on a tagged immediate | the argument's static type at the dup site |
| user function call | +1.0 ns per call | the calling convention | inlining |
| `mut` field of a non-escaping struct | +2.0 ns per iteration | the heap block | escape analysis + scalar replacement |
| captured `let mut` | +2.9 ns per iteration | closure environment + ref cell | the same (+ closure inlining) |
| tuple `loop` parameters | +7–21 ns per iteration | the box | unboxing (landed for tuple `let mut`, §6.4) |
| enum value rebuilding | +20–33 ns per iteration | box + RC traffic | unboxing / FBIP |
| state effect | +4.9 ns per iteration | evidence dispatch | handler inlining |

### 6.1 The shape of convergence

**Keep the surfaces distinct; converge the lowering.** Folding `let mut` into
effects, or the reverse, makes one of them unnatural and none of them faster:
an uncaptured `let mut` and a state effect solve different problems (§2.5).
What converges is the target:

```text
surface (chosen by meaning, per the ladder in §4)
  step 0  uncaptured let mut / loop parameters
  step 1  region r { } / captured let mut
  step 2  effect + handle
  step 3  host capability
        |
        |  whatever escape analysis proves stays inside
        v
lowering (one target)
  a wasm local: no RC, no heap, 0.74 ns per iteration
```

The surface should not decide performance. `loop (s = (0, 0))` and
`loop (i = 0, acc = 0)` meant the same and differed 10–28×, an implementation
detail leaking into the language; §6.4 removed that instance.

### 6.2 Order: cheapest first, laying the same plumbing

Every optimisation in §6's table needs the same precondition: facts the
checker has (types, escape) must reach codegen. §4's step 1 is therefore also
the performance groundwork; the same plumbing serves the authority rule and
the optimisations.

| order | work | gain | status |
|---|---|---|---|
| 1 | remove dups on statically scalar arguments | the remaining 0.44 ns per dup, and less code than 1′ | not implemented |
| 1′ | tag test inline, slow path out of line | 2.37 → 0.44 ns per dup, +9 B per site (§2.9) | **implemented** |
| 2 | expose the escape predicate and carry the strict side in `TypeEnv` | the base of the authority rule; three copies → two (§4.5, §4.6) | **implemented** |
| 3 | scalar replacement of non-escaping structs | struct `mut` and captured `let mut` drop to step 0 cost | not implemented |
| 4 | unboxing of non-escaping tuples / enums | the 10–28× surface gap disappears | **implemented for tuple `let mut`** (§6.4) |
| 5 | inlining monomorphic tail-resumptive handlers | the state effect drops to step 0 cost | not implemented |

### 6.3 What becomes one

- **Performance**: written at step 0, 1 or 2, non-escaping state costs the
  same; the surface is chosen by meaning.
- **Authority**: only escaping state appears in the row (§4). One escape
  analysis answers both "is it fast" and "does it need authority".
- **Duplication**: `let mut` mutability, region inference (ADR-0090) and FBIP
  (ADR-0092) each answered "does this value leave?". With one analysis, regions
  become the explicit syntax of step 1 and FBIP the fallback for what unboxing
  cannot reach.

### 6.4 Tuple `let mut` unboxing

`normalize/unbox_tuple_loop.vibe` rewrites `ELetMut(s, ETuple(..), body)` when
every occurrence of `s` is a read through a single-arm tuple match or a `.K`
projection, or a write of a tuple literal (directly, or through a single-use
`__lt` temporary). The rewrite is N scalar `let mut`s, the match turned into
`let`s, and an element-wise assignment; a direct assignment goes through fresh
temporaries so a swap `s = (s.1, s.0)` stays correct.

Soundness is an occurrence count: `utl_count` walks every `Expr` variant
(rebinding a binder or mentioning `s` in a closure poisons the count) and
`utl_recognized` counts only the recognised shapes. The rewrite fires only
when the two agree, so an unrecognised occurrence leaves the code as it was.

Three facts decide where such a pass has to sit, and each was learned the hard
way:

- **`loop` never reaches codegen as `ELoop`.** The parser
  (`parse_loop_primary`) lowers every `loop (params)` to `let mut` parameters,
  a `let mut __loop_result`, and `while true`; `continue(args)` becomes
  `let __ltK = argK; pK = __ltK; continue`, and `let (i, acc) = s` a single-arm
  tuple match. The target is therefore the tuple-initialised `ELetMut`.
- **The linear backend has two codegen entry points.** Entry compilation and
  the test/bench module lane (`__no_entry__`) are separate and desugar in
  different places, so the pass is wired into both.
- **Only the bump lane's heap delta proves an allocation is gone.** On RC the
  free list recycles a freed tuple at once, so the heap frontier advances by
  the live set only; a boxed loop and an unboxed one look alike.

Result: `floor/8_tuple_loop` 12548 → 930 ns and 16016 → 0 B on bump, level
with `state/2_loop_param` (931 ns), on both the entry lane and the module
lane; `fixtures/unbox_tuple_loop_test.vibe` pins eight eligible and ineligible
shapes. Not covered: enum value rebuilding (FBIP's domain), nested loops with
same-named `__lt` temporaries (declined conservatively), and the Wasm-GC lane
(left as it was; the rewrite preserves meaning, so the differential gates
agree).

---

## 7. Settled questions (ADR-0100)

- **The step 0 / step 1 boundary** is closure capture only. Passing a
  `struct { mut f }`, an `Array` or a `Bytes` to a function is outside the
  predicate; extending it is a separate decision. Starting from the predicate
  the implementation already used kept every existing program legal.
- **The step 2 spelling** is a row atom naming the cell, `with Mut[c]`, with
  effect + handler kept as the mechanism. The cell-name kind, scoping and the
  interaction with resource kinds (ADR-0075) need their own design before
  implementation; the spelling is reserved meanwhile (§4.4).
- **No `reads` authority.** Verse separates `<reads>`; in vibe only host
  resources need read authority (`Env::Read`, ADR-0075's path-scoped reads),
  and no measurement has shown a reason to gate in-process reads.
- **Handler inlining** is the only way to close §2.5's remaining 2×. With
  ADR-0076's evidence passing a tail-resumptive handler is already a direct
  call; what remains is inlining it at the call site, to be decided by
  measurement.
- The measurements are from one machine and one set of shapes. Before
  inlining handlers or extending regions, confirm the order on a real
  application shape (the compiler itself).
