# WasmFX continuation ownership and storage

This is the first decision #2221 needs before a WasmFX emitter exists: where a
stored continuation lives, who owns it, and how one-shot use survives
aliasing. It is a design record with measurements, not a backend. The
feasibility probe is described in
[experimental-wasmfx-effect-backend.md](experimental-wasmfx-effect-backend.md).

## Decision

Recorded as ADR-0123 (proposed) in [adr.md](adr.md).

1. **A stored continuation stays an ordinary closure value.** The checker
   already types a stored `resume` as `(A) -> R`, and every storage position a
   program can reach (a `let`, an array element, a struct field, an enum
   payload, another closure's capture, an argument) holds it through the
   tagged-`i64` value ABI. The WasmFX backend keeps that type and that ABI.
   What changes is the closure's capture.
2. **The `contref` lives in a module-private handle table**: one
   `(table (ref null $k))` per continuation type. The closure captures a
   **handle box**, a small heap object holding the slot and its generation.
   No `contref` ever crosses the `i64` ABI, and the handle is never visible to
   the source program.
3. **One-shot is enforced in the guest before `resume` executes.** Taking a
   continuation checks the generation, nulls the slot and bumps the
   generation. Every alias of the closure shares the one box, so the second
   call is refused with the same diagnostic the suspend-CPS lowering prints
   today. The engine's own check is a backstop, not the mechanism.
4. **Releasing an unresumed continuation cancels it.** When the box is
   dropped, the runtime first unwinds the continuation with `resume_throw` and
   a compiler-private tag, so that frames release what they own, and then
   nulls the slot.
5. **Typed `(ref $k)` storage is used only where the continuation does not
   escape**: in the driver's locals, and in a function's parameters while the
   continuation is being resumed. This is an optimization of the handle table, not a
   second representation.

The rest of this document gives the evidence for each point.

## 1. Inventory: continuations under the suspend-CPS lowering

### Representation

A handle whose arm uses `resume` as a value is rewritten by
`suspend_cps_pass`
(`lib/@vibe/compiler/lowering/effects/suspend/suspend_scps_prepass_expr.vibe`).
The shape is documented at lines 186-197, and lines 717-783 build it:

```text
let rec __scps_driveN = (st) -> match st {
  __ScpsDone_E(v) => v,
  __ScpsY_E_op(payload.., __scps_k) => {
    let __scps_onceN = [false]
    let resume = (rv) -> if __scps_onceN[0] { abort("vibe: resume one-shot continuation called twice") }
                         else { __scps_onceN[0] = true; __scps_driveN(__scps_k(rv)) }
    ARM
  }
}
```

The suspend-CPS representation has four parts.

| Part | Representation | RC drop class ([uniform-value-repr.md](uniform-value-repr.md), lines 133-136) |
| --- | --- | --- |
| The rest of the body after a `perform` (`__scps_k`) | A capturing closure. Its captures are the live locals, and each `let mut` is boxed into a cell. | 7, and 8 for a boxed cell |
| A step (`__ScpsY_E_op(.., k)` / `__ScpsDone_E(v)`) | An enum constructor | 1 |
| The one-shot flag (`__scps_onceN`) | A one-element `Array[Bool]` | 5 |
| `resume` as the program sees it | A capturing closure over `__scps_k`, the flag and the driver | 7 |

The checker binds `resume` in a suspend arm as `CtFn([op result],
handle result, None)`, a plain function type with no row
(`lib/@vibe/compiler/checker/checker_expr_capture_impl.vibe:1715-1744`). The
type does not mark a value as a continuation, so a stored continuation
cannot be told apart from any other closure.

A closure value is a tagged `i64` on every lane, the wasm-gc lane included.
Both backends call through `emit_closure_resolve` /
`emit_closure_call_tail`
(`lib/@vibe/compiler/codegen/common_analysis/common_analysis_free_vars_expr_sc.vibe:691-722`;
the gc backend reaches them from
`lib/@vibe/compiler/codegen/gc/backend_call_named_1.vibe:602`). The table slot
is read with an `i32.load` from a linear-memory environment. On wasm-gc,
closure captures are part of the linear fallback
([memory-contract.md](memory-contract.md), lines 27-35 and 123-131).

### Where a continuation can be stored

Because a stored continuation is a closure, no storage position is refused
for it. The refusals below concern the shape of the handle body. The
following storage shapes were measured with a stage2 built from `ae88b617`,
which is four commits behind this branch's base and has no differences under
`lib/@vibe/compiler/lowering/effects` or in the checker file cited above. Each
shape was measured on the linear RC lane and on the wasm-gc lane:

| Shape | Pinned by |
| --- | --- |
| Array element (the scheduler shape) | `fixtures/effect_resume_store_scheduler.vibe`, `fixtures/effect_resume_store_loop.vibe` and the other `effect_resume_*` fixtures that call `Array::push(.., value = resume)` |
| Arm-local `let k = resume`, called in the arm (post-processing) | `fixtures/effect_resume_value_postprocess.vibe` |
| Captured by a lambda in the arm | `fixtures/handler_arm_resume_in_lambda_test.vibe` |
| Enum payload (`Yielded(x, resume)`) | `fixtures/effect_talk_coroutine_status_test.vibe` |
| `mut` struct field of `Option[(Int) -> Unit]`, taken and nulled before the call, and dropped on cancel | `TaskCell.cont` in `lib/@vibe/concurrent/experimental/concurrent.vibe` (field at line 75, park at 1352, wake at 1393-1400, fail at 460, cancel at 497) |
| Struct field, closure capture and `Option` payload, all in one file | measured for this record; it is not committed, and section 6 makes it acceptance row S1 |
| Two names for one stored continuation, passed to a function that calls both | measured for this record: the second call prints `vibe: resume one-shot continuation called twice` and traps, on both lanes |

### Refusals and the positive pins beside them

| Fixture | What it refuses | Accepted neighbour | Gate row |
| --- | --- | --- | --- |
| `fixtures/err_effect_resume_store_ineligible.vibe` | A capturing arm whose body calls a row-variable function (`with e`) with a capturing closure. The lowering cannot see through the callee. | `fixtures/effect_resume_call_bubbling_test.vibe` (a callee with a concrete row), `fixtures/effect_resume_rowvar_wrapper_normalized_test.vibe` (a trivial wrapper that is normalized away) | `tests/gates/late/adr_0069_fn_main_sugar_entry_top_level_hardening.sh:1249` |
| `fixtures/err_effect_needing_value_escape.vibe` | A function whose row carries the effect, passed as a value into a parameter whose type does not carry the row, from a function that has no evidence in scope | `fixtures/effect_needing_value_escape_wrapped_test.vibe`, `fixtures/effect_needing_value_annotated_test.vibe` | same script, line 1266 |
| `fixtures/err_handle_resume_capture_loop_break_refused.vibe` | A `break` to a loop outside a handle whose arm captures `resume` | none | `tests/gates/early/extended_derive.sh:530` |
| `fixtures/err_resume_non_tail.vibe` | A non-tail direct `resume(v)` call (the value form is the way to post-process) | `fixtures/effect_resume_value_postprocess.vibe` | same script, line 1248 |

None of these refusals is about storage. Each one is about a body or callee
that the static CPS split cannot cross. These are the restrictions that
WasmFX's dynamic forwarding would remove, as the probe shows. #2221 requires
all four to stay unchanged while the WasmFX option is absent.

### One-shot enforcement

The guard is the `__scps_onceN` cell, checked dynamically inside the
`resume` closure. It is not a type. An alias copies the closure pointer, so
every alias shares the cell. Direct tail `resume(v)` calls are routed through
the same closure, so the flag covers them too (lines 225-231 of the lowering
file). The guard is pinned by `fixtures/effect_resume_one_shot_trap.vibe`
(gate script lines 966-975) and, for grouped handlers on the `rc` and `gc`
lanes, by `lib/@vibe/compiler/tests/grouped_handler_evidence_test.vibe:220-236`.
The scheduler adds take-and-null at the cell level as well (`wake` sets
`cont = None` before it calls the continuation).

### Ownership per lane

| Lane | Resumed continuation | Continuation dropped without being resumed |
| --- | --- | --- |
| Linear RC (default) | Perceus releases the closure, its captures and the flag cell. | Released by the ordinary RC drop of the closure graph. There is no finalizer ([effect-evidence-passing.md](effect-evidence-passing.md), lines 262-269). The scheduler's fail and cancel paths depend on this. |
| Linear bump | Kept until the instance is torn down | Kept until the instance is torn down |
| Wasm-GC | The closure graph is in the linear fallback. Perceus does not run on that lane, so it is kept. | Kept |

## 2. What the probe demonstrated before this record

`tools/wasmfx_effect_probe/src/lib.rs` (pinned to `mizchi/wasmtime-threads`
`e1fb408f`) uses `contref` in exactly one way. The continuation arrives as
the result of an `(on $tag $label)` block. It is kept in a typed local,
`(local $k (ref null $resume-cont))`, and resumed once. The probe never stores
a `contref` anywhere but a local. It never resumes one twice, never drops one
without resuming it, and never lets one leave the function that received it.

## 3. Engine measurements

The cases below were run on Linux x64 with rustc 1.98.1, against the pinned
fork. Rows 1 and 3-7 are now probe tests: `cargo test --manifest-path
tools/wasmfx_effect_probe/Cargo.toml` runs seven tests, and all seven pass.
Rows 8 and 9 were measured once, in a scratch copy of the probe that counted
`/proc/self/maps` lines and `VmRSS`. They are not committed, because they
depend on Linux. The
upstream column shows the same WAT run by the installed `wasmtime` 47.0.2 CLI
with `-W stack-switching=y,function-references=y,exceptions=y,gc=y`.

| # | Experiment | Pinned fork `e1fb408f` | Upstream 47.0.2 CLI |
| --- | --- | --- | --- |
| 1 | Resume a `contref` a second time, after it has completed, or while its first resumption is parked elsewhere | trap: `continuation already consumed` | **the host process segfaults** (exit 139, in both variants) |
| 2 | `resume` a null `contref` | trap: `null reference` | trap: `null reference` |
| 3 | `contref` in a `(table (ref null $k))` or a `(global (mut (ref null $k)))` | accepted | accepted |
| 4 | `contref` in a wasm-gc struct field | refused: `Unsupported feature: Stack switching feature not compatible with GC, yet` ([environ/src/gc.rs:269-270](https://github.com/mizchi/wasmtime-threads/blob/e1fb408fb7258ac8d1207084af4e1988b3c7db87/crates/environ/src/gc.rs#L269-L270), [cranelift/src/func_environ/gc.rs:1757-1760](https://github.com/mizchi/wasmtime-threads/blob/e1fb408fb7258ac8d1207084af4e1988b3c7db87/crates/cranelift/src/func_environ/gc.rs#L1757-L1760)) | same refusal |
| 5 | `contref` passed where an `anyref` is expected | refused by validation: `expected anyref, found (ref null $type)`. Continuations form their own type hierarchy, so the value cannot be boxed into `anyref` or `eqref` either. | same |
| 6 | `resume_throw` of a private tag into a parked continuation | the parked frame's `try_table` landing pad runs (probe test) | refused: `resume.throw instructions not supported, yet` |
| 7 | A handle table: park, take-and-null with a generation, a stale alias after the slot is reused, release without resuming | each alias, stale handle and released handle is refused in the guest. The engine is never asked to resume a consumed or foreign continuation. (probe test) | validates |
| 8 | Create and finish 10,000 continuations in one store, or park and drop 10,000 | +20,002 to 20,003 memory mappings and +41.7 MB RSS **in both cases**. These come back only when the `Store` is dropped. | peak RSS 21-27 MB at 1,000 and 58 MB at 10,000, for finished and parked alike |
| 9 | The same with 100,000 | `Cannot allocate memory (os error 12)`, raised as a wasm trap error | host segfault between 20,000 and 40,000 |

Rows 8 and 9 follow from the fork's allocator. `allocate_continuation` pushes
every new continuation, together with its own `async_stack_size` stack, onto
`Store::continuations`
([store.rs:2165-2173](https://github.com/mizchi/wasmtime-threads/blob/e1fb408fb7258ac8d1207084af4e1988b3c7db87/crates/wasmtime/src/runtime/store.rs#L2165-L2173)),
and `Drop for VMContRef` frees nothing
([stack_switching.rs:291-302](https://github.com/mizchi/wasmtime-threads/blob/e1fb408fb7258ac8d1207084af4e1988b3c7db87/crates/wasmtime/src/runtime/vm/stack_switching.rs#L291-L302)).
Each stack costs two mappings, so this host's `vm.max_map_count` of 65530
caps one store at roughly 32,000 continuations over its whole life. Whether
those continuations completed makes no difference. **No guest-side
representation can return a stack to the engine on this revision.** That
limit belongs to the runtime boundary of #2221 (stack sizing and reuse), not
to this decision. It does make the acceptance row for unbounded churn
(section 6, row L3) fail today, whichever option is chosen.

Row 1 is why one-shot cannot be left to the engine. On the upstream release
that a user is most likely to have installed, a double resume brings down the
host instead of trapping.

## 4. The two options

### (a) An explicit typed representation

A stored continuation would be a `(ref null $k)` held in a typed position: a
wasm-gc struct field, or a typed local or parameter.

- **Mapping the storage shapes.** Every shape in section 1 holds the value
  as a `(A) -> R` closure in a position the backends lower as `i64`: array
  elements, struct and enum fields, `Option` payloads, generic `T` slots, and
  captures. Option (a) would therefore need a closure representation with
  typed captures, *and* every position that might hold such a closure would
  have to become ref-typed. The checker cannot tell a continuation from any
  other closure (section 1), so that means every function-typed position.
  This is the uniform-`i64` ABI replaced by typed references: a whole-backend
  change, which #2221 says not to start for this inventory.
- **Linear lanes.** Not available. Linear memory cannot hold a reference, and
  boxing the reference is impossible (row 5).
- **Wasm-GC lane.** Refused today by both engines (row 4). A gc struct is the
  only heap object that could carry a typed reference, and a struct field of
  continuation type is exactly what the engine does not compile.
- **Aliasing.** A typed reference copied into two fields consumes the
  continuation on the first `resume`, and the second resume reaches row 1:
  the fork traps cleanly, while the upstream release segfaults. A guard flag
  would still be needed, beside the reference, to report the vibe diagnostic.
- **Failure modes.** A double resume falls back to the engine's behaviour.
  An unresumed continuation is kept alive by GC reachability. Today nothing
  can run its frames' cleanup, because a GC finalizer cannot call
  `resume_throw`.
- **Where it applies.** Typed locals and parameters, as the probe already
  shows. That covers a continuation that never escapes the arm and its
  driver, such as `let k = resume; k(v)`.

### (b) A runtime handle table

The `contref` lives in a module-private `(table (ref null $k))`. The closure
captures a handle box that holds the slot and its generation.

- **Mapping the storage shapes.** No storage shape changes. `resume` is
  still a `(A) -> R` closure. Its captures change from `__scps_k` and
  `__scps_onceN` to a single handle box, and the closure body becomes
  "take, then resume under this handle's driver". Arrays, struct fields,
  enum payloads, `Option`, captures, arguments and `TaskCell.cont` all hold
  the closure exactly as they do today.
- **Aliasing.** All aliases share the closure, so they share the box.
  Taking checks the generation, nulls the slot and bumps the generation. A
  second call, through any name, finds a stale generation and aborts with
  the existing message (row 7). A stale handle cannot reach a later tenant of
  a reused slot. The engine never sees a consumed `contref`, which also
  avoids the upstream segfault (row 1).
- **Linear lanes.** Supported. A table holds references independently of
  linear memory, and the box is an ordinary heap object. On the RC lane the
  box gets its own drop class, whose drop cancels and releases the slot. On
  the bump lane nothing is released, as with every other object there.
- **Wasm-GC lane.** Supported in the same way, because closures are already
  in the linear fallback there. Release has the same gap as on bump until gc
  closures are collected. Even then, a collected box must trigger an explicit
  release, which needs a finalization hook that the engine does not offer.
- **Host and runtime support needed.** Function references, exceptions and
  stack switching (rows 3 and 6). The table is internal, so no host API is
  involved and nothing goes into the WIT surface. `table.grow` with
  `ref.null` makes the table larger. Only the pinned fork provides
  `resume_throw`, which cancellation needs.
- **Failure modes.**
  - A stale handle is impossible by construction, because the generation
    differs.
  - A double resume aborts in the guest with the vibe message.
  - A continuation that is never resumed is cancelled when its box is
    released. On the bump and gc lanes it is kept until teardown, which is
    no worse than the closure graph today.
  - Cancellation unwinds the frames through `resume_throw`. Each frame's
    landing pad must release the RC references held in its locals, and that
    is emitter work.
  - A forgotten table slot is a leak, the table being a GC root. It is
    observable as the live-slot count.
  - If the handle somehow crossed a shared-nothing worker boundary, it would
    index the wrong instance's table. It cannot cross: the box is inside a
    closure, and closures cross only under ADR-0068's `Spawnable` rules,
    which keep working because the value is still a closure.

### Why (b)

Option (a) is impossible on the default lane, impossible on wasm-gc with
either measured engine, and needs the whole value ABI to change. Option (b)
works on all three lanes with the closure-typed value that the checker,
`Spawnable`, the scheduler and every storage shape already use. It keeps
one-shot in the guest, where its message already lives. Part (a) still
survives as the non-escaping fast path (point 5 of the decision), because a
typed local is what the driver uses anyway.

## 5. The handle box

```text
handle box (RC lane: a new drop class; bump / gc: a plain block)
  +0  slot        i32   index into $conts_<k>; -1 once taken or released
  +4  generation  i32   copied from gen[slot] when the continuation was parked
```

- **park** (in the driver, on `suspend`): store the `contref` in the first
  null slot, growing the table if none is free. Bump `gen[slot]`, and allocate
  the box with `(slot, gen)`.
- **take** (in the resume closure): if `box.slot == -1` or
  `gen[box.slot] != box.generation`, abort with `vibe: resume one-shot
  continuation called twice`. Otherwise read the slot, null it, bump
  `gen[slot]`, set `box.slot = -1` and `resume` under the handler's tag set.
- **release** (the box's RC drop, or the scheduler dropping `cont`): if
  `box.slot != -1`, take the continuation, `resume_throw $vibe_cancel` it,
  and discard the result.

`gen[]` can live in linear memory, as it does in the probe. Keeping both
`box.slot` and the generation is deliberate redundancy. The box alone makes
a stale alias impossible, and the generation catches a compiler bug that
would otherwise resume a stranger's continuation.

## 6. Acceptance tests for the emitter

Each row must pass under the WasmFX option on the RC lane and give the same
observable result as the default backend. Rows marked *(lanes)* must also
pass on bump and gc.

| Row | Case | Expected |
| --- | --- | --- |
| S1 | Every storage shape in section 1: an array element, an arm-local `let`, a lambda capture, an enum payload, a `mut` struct field taken and nulled, `Option`, and a function argument *(lanes)* | the same values as the suspend-CPS fixtures named there |
| S2 | `TaskCell.cont` park, wake, fail and cancel in `@vibe/concurrent/experimental` | the same task results and statuses |
| O1 | A second call of one stored continuation through the same name (`fixtures/effect_resume_one_shot_trap.vibe`) *(lanes)* | stderr `vibe: resume one-shot continuation called twice`, then a trap. No engine trap, and no host crash on upstream wasmtime. |
| O2 | Two names, two containers, or one closure passed as two arguments, then a call through each | the same as O1, on the second call |
| O3 | A stale handle: park, take, park again into the same slot, then the old closure | the same as O1. The new continuation is not resumed. |
| L1 | A continuation dropped without being resumed on the RC lane, with heap values live in its suspended frames | every block those frames own is freed (`VIBE_RC=shadow` is clean, and a churn-reuse probe like `fixtures/rc_user_effect_handle_test.vibe` reads the live value). The table's live-slot count returns to 0. |
| L2 | The scheduler's fail and cancel paths drop parked siblings | the same as L1, for every sibling |
| L3 | 100,000 create-and-finish cycles in one instance | bounded memory. **Fails on `e1fb408f`** (section 3, rows 8-9) until the runtime can reuse or free continuation stacks. |
| R1 | Each refusal fixture in section 1 with the option absent | the same diagnostic as today (#2221's retention clause) |

## What this does not decide

- How deep the handlers are, and how forwarding uses tags: which tag set
  `take` resumes under (#2221's algebraic-lowering boundary).
- What cancellation looks like to the program (`Exception` versus a private
  tag), beyond the requirement that release unwinds.
- Stack sizing, stack reuse, and the L3 limit (#2221's runtime boundary).
- Multi-shot continuations, a public continuation type, and sending a
  continuation across threads. #2221 excludes all three.
