# Perceus RC — design record

RC is the linear default (`VIBE_RC` unset == `VIBE_RC=1`, byte-identical;
pinned by `scripts/check_rc_default.sh`). Status and residual leaks:
[rc-cutover-readiness.md](rc-cutover-readiness.md). Backend contract table:
[memory-contract.md](memory-contract.md). Value representation:
[uniform-value-repr.md](uniform-value-repr.md).

This file holds the two pieces of the design that are not recorded anywhere
else: why RC could not be ported as code, and what the rc-check elision does.
The staged Phase 1-4 plan that used to make up most of the file is gone — it
described work that is finished, and `git log` and #493 have the route.

The MoonBit `src/` backend below is historical: it was retired in #594, and
appears here only because the layout argument is about the difference between
its heap objects and the compiler's.

## Why this is not a straight code port

The `src/` linear backend and the compiler's linear backend use **different
heap object layouts**, and RC's correctness depends on the `src/` layout.

### `src/` linear layout (RC-ready)

Every heap object carries a header, and RC prepends a refcount:

```
[alloc_size@-8][rc_count@-4][type_id@0][length@4][payload@8...]
```

`type_id` (tuple=3, array=5, record=4, map=6, enum=10, closure=7, view=11/12/14,
string=1, bytes=13) lets the RC drop helper dispatch and **recursively drop the
right fields**; `length` bounds the field loop. This is what
`emit_rc_drop_fields` / `compile_rc_drop_function` rely on.

### Compiler linear layout (no headers)

The compiler's linear backend is a pure bump allocator with **no type-id / length
headers**:

- tuple: bare sequential `i64` slots (no header)
- closure (`obj_fn`-equivalent): `[table_slot@0][num_captures@4][captures@8...]`
- constructor: `[tag@0][pad@4][values...]`
- string: `(offset << 32) | length` fat pointer (no heap header)
- objects are tagged only by OR-ing the low bit; there is **no way at runtime
  to tell a tuple from a record from an enum**, nor how many fields it has.

Without a type-id + length header there is no way for a generic `drop` to know
how to recurse, so the RC drop helper cannot be ported as-is.

## Consequence: the prerequisite is a layout change

The first real domino is **adding a uniform object header to every compiler
linear allocation** and updating every field-access offset accordingly. This
is large and touches every allocation/access site, so it must land behind a
flag and be proven output-equivalent by the parity gates before any RC code
is added.

## rc-check elision (almide comparison, #1056)

- `build_perceus_plan`'s `ELet` alias handling (`lib/@vibe/compiler/perceus/perceus.vibe`)
  now elides the dup+drop pair for an alias binding (`let a = t`) that would
  otherwise duplicate `t`'s reference but is never itself referenced in its
  body: the dup and the alias's own unconditional scope-end drop are a
  provable no-op on the same memory with no intervening read. Occurrence-local
  (uses the per-binding-id `uses`/`remaining` bookkeeping the analysis already
  computes), so it needs no whole-function alias/escape analysis and carries
  no new shadowing risk beyond what the existing name-keyed
  `rc_alias_dup_names`/`rc_drop_names` codegen sets already have. Tested in
  isolation (`perceus_rc_test.vibe`) and verified zero-regression: stage2==stage3
  self-host fixpoint, `scripts/verify_rc.sh` byte-identical whole-compiler-under-RC
  reproduction, and all `fixtures/rc_*_test.vibe` / shadow-liveness / reclaim-leak
  gates unaffected.
- This is the narrow, occurrence-local slice of what almide's
  `alias_safety.rs` does with a full function-local fixpoint dataflow (eliding
  redundant `MakeUnique`/COW rc-checks on provably-unaliased values) — see
  `docs/pl-survey-2026-07.md` and `docs/BENCHMARKS.md`. vibe's RC has no
  COW/`MakeUnique`-equivalent construct yet (arrays/maps are mutated in place
  unconditionally, never copy-on-write-guarded), so a literal port of the rest
  of almide's pass has no target to elide; this slice covers the one case
  vibe's existing per-binding-id bookkeeping already has the data to prove
  safe without new infrastructure.
- Measured impact on `bench/binary_size/`'s 5-program suite and on the
  compiler's own self-hosted source under RC: **none today** — neither
  contains the target pattern (see `docs/BENCHMARKS.md`). Kept as a
  zero-cost-when-unused safety net; broader rc-check elision (a real
  alias/escape fixpoint, or COW guards once arrays/maps grow them) remains
  future work.
