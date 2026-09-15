# Allocation verification (ADR-0091)

The linear compiler checks allocation annotations on top-level functions.
This is implemented behavior, with a conservative source-level analysis; it
is not a measurement of allocations remaining after machine-code optimization.
The public syntax is documented in the [cheatsheet](../../user/reference/cheatsheet.md).

## Contract

An annotation immediately precedes the function it marks:

| annotation | meaning |
| --- | --- |
| `#zero_alloc` | Reject general-heap allocation in the analyzed call tree; region storage is permitted. |
| `#zero_alloc(strict)` | Include region/arena allocation in the rejection. |
| `#zero_alloc(assume)` | Publish a trusted summary to callers, while still checking explicit allocation in the marked function's own body. |

Allocation is not an effect-row atom. RC retain/release operations are not
themselves allocations. Builtin classification, constructors, closures and
local callee bodies supply the analysis; an opaque call that cannot be proved
allocation-free is rejected conservatively. A source-owned function must be
resolved before a builtin of the same spelling.

`assume` does not hide an explicitly allocating function from validation.
The importer can trust its summary, but the defining function is still checked.
An imported `assume` function returning an array literal is a regression case
for this distinction.

## Implementation boundary

`zero_alloc_check` and `zero_alloc_fn_summaries` live in
`lib/@vibe/compiler/codegen/common_analysis/common_analysis.vibe`. They inspect
statements and local function bodies. The check returns an empty string on
success or the first allocation diagnostic naming the function and cause;
it does not enumerate every allocation site with a source range.

The linear prelude runs this check before its rewriting passes. The per-module
split driver also checks the whole program before partitioning: checking only
one partition would lose imported callee bodies and reject valid code. The
oracle records partition differences separately. Any future change to this
boundary must preserve diagnostic parity as well as rewritten declarations
([#2826](https://github.com/mizchi/vibe-lang/issues/2826)).

Perceus reuse happens later. A `PaReuseToken`/`PaReuseAlloc` candidate is
conditional on runtime uniqueness and codegen's layout validation, so it is
not evidence that the allocation checker may remove an allocation from its
accounting. Region storage, constructor reuse and this annotation have separate
contracts (ADR-0090/0092).

## Regression evidence

- `lib/@vibe/compiler/runtime/typed_operator_alloc_spans_test.vibe` pins mode
  differences, explicit allocations under `assume`, and source-owned names.
- `lib/@vibe/compiler/runtime/zero_alloc_import_summary_test.vibe` pins
  imported summaries and diagnostics, including allocating `assume` bodies
  and growable Bytes operations.
- `lib/@vibe/compiler/core/builtin_allocates_test.vibe` pins builtin
  classification. A missing classification can reject valid annotated code;
  the registry coverage work is #2584.

The GC backend is not covered by this linear allocation guarantee. Runtime
profiling remains useful for counting actual allocations and measuring reuse;
it does not replace the static contract.
