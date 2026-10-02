# Value and object representation on the linear backend (ADR-0055)

This is the representation contract of the linear backend as the compiler
under `lib/@vibe/compiler/` emits it. The linear RC lane is the default for
user programs (`VIBE_RC` unset or `1`); the bump lane is `VIBE_RC=0`. Lane
selection, the Wasm-GC backend and region storage are in the
[memory contract](memory-contract.md); the Perceus plan that decides where
retains, releases and reuse happen is in [perceus-reuse.md](perceus-reuse.md).

The RC lane needs every runtime `i64` to describe itself: the generic release
helper is handed a field value with no static type and must decide whether it
is a heap pointer to follow. The compiler's AST carries no element types, so
the decision is made from the value's low bit rather than from a per-object
pointer bitmap.

## Values

| value | RC lane | bump lane |
| --- | --- | --- |
| `Int` | `n << 1` (even) | `n`, untagged |
| `Bool` | `0` / `2` | `0` / `1` |
| `Double` | pointer to a 16-byte leaf block holding the f64 bits (odd) | f64 bits inline |
| heap object (tuple, record, constructor, array, map, capturing closure, ref cell) | `(block + 8) \| 1` (odd) | pointer into the bump heap, no RC header |
| function value with no captures | `(table_slot << 2) \| 2` | same |
| `String` | fat pointer `(offset << 32) \| length` | same |
| `Bytes` | pointer to a bump-allocated buffer object, not an RC block | same |

- The RC helpers skip a value that is even, and skip an odd value whose high
  32 bits are non-zero: every RC block address is below 2^32, while a string
  fat pointer carries its data offset there. A capture-less function value is
  even, so it is skipped as well.
- Perceus classifies `Int`, `Bool`, `Char`, `String`, `Bytes` and `Unit` as
  non-heap (`type_name_is_heap`, `perceus/perceus_analyze_calls.vibe`) and
  plans no retain or release for them. `Double` is heap on the RC lane because
  every double is boxed.
- `Int` is 63-bit on every lane and arithmetic wraps as 63-bit two's
  complement. The RC lane gets that width from the tag for free; the untagged
  lanes renormalize after `+ - * / <<` and unary `-`
  (`emit_arith_wrap_int`). The literal bound is 2^62-1. An integer literal is
  tagged by a run-time `i64.shl 1`, so a near-bound literal never has to be
  doubled by the compiler's own `Int`.
- A `Bytes` buffer object is `[header@0][length@4][data pointer@8]`, with the
  initial data inline after the header. The inline-wasm ABI hands a kernel the
  raw object pointer (see the cheatsheet's inline-wasm section).

## Integer operations on the tagged lane

Operands arrive tagged (`a = x << 1`, `b = y << 1`). Most operators are
tag-transparent:

| operator | lowering on the RC lane |
| --- | --- |
| `+` `-` `%` `&` `\|` `^` | no correction |
| `&&` `\|\|` | short-circuit; `{0, 2}` is closed under both |
| `*` | untag the left operand first (`(a >> 1) * b`), so the product overflows exactly at the payload's 63-bit boundary |
| `/` | `a / b` is the untagged quotient; retag the result (`<< 1`) |
| `<<` | untag the shift count only |
| `>>` | untag both operands, shift, retag |
| `==` `!=` `<` `>` `<=` `>=` | compare tagged operands; retag the 0/1 result to `0` / `2` |
| unary `!` | retag the result |
| unary `-` | `0 - a`; already tag-correct |
| unary `~` | `a ^ -2`: the complement of a tagged value needs tagged(-1). Xoring with a raw `-1` sets the tag bit and yields a malformed `Int` |

A comparison result must be tagged: a raw `1` stored into a heap field would be
read back as an odd pointer. A float comparison unboxes both operands, compares
with the f64 instruction and tags the result the same way.

### Where tagging stops

- **Indices and lengths.** The RC bodies of the array, `Bytes` and `String`
  builtins untag an index or count argument before using it as an address,
  and tag a count they return.
- **Entry result.** An exported entry's `Int` result is untagged after the
  body, including on a `return` that jumps past it (#1696).
- **Inline wasm.** Parameters and results are raw tagged `i64` values; there
  are no shims (cheatsheet, "Inline wasm").

## Doubles

On the RC lane every `Double` is a 16-byte block allocated through
`__rt_rc_alloc`: `[alloc_size=16][rc=1, class 0][f64 bits]`, value
`(block + 8) | 1`. Writing the rc word as a full `1` leaves the class byte 0,
so the block is a leaf: the generic release frees it without following
anything, and a container that holds a double releases the box with itself.
`emit_box_float` / `emit_unbox_float` (`codegen/common_base`) are the two
helpers. Producers box (literals, float arithmetic, `Int::to_double`);
consumers unbox (float operands, `Double::to_int`, the bit accessors).

A floating-point literal's bit pattern does not fit an `Int` (`2.0` is
`0x4000000000000000` = 2^62, above `Int::max_value`), so no codegen site may
carry the full pattern through an `Int`. Literals are emitted from two 32-bit
halves: `emit_f64_const_lohi(buf, Double::to_i64_bits_lo(v),
Double::to_i64_bits_hi(v))`. Section 89 of the compiler gate
(`tests/gates/late/typed_exception_e_rows.sh`) rejects any
`emit_f64_const_bits(` or `Double::to_i64_bits(` call under
`lib/@vibe/compiler` as a static check, because the failure appears only when
the compiler itself is RC-built and the default self-build is bump.

NaN-boxing (#510) was rejected. An inline f64 needs all 64 bits, so the whole
value world would have to become f64-centric: the `Int` range would shrink to
the NaN payload width (about 2^51), and every numeric operation, pointer
encoding and comparison would change. The free list already recycles 16-byte
float boxes. Revisit only with a measured float-heavy RC workload that the
free list does not absorb, and with explicit sign-off on the `Int` range.

## Heap objects on the RC lane

Every RC block starts with an eight-byte header; the value points just past
it, with the low bit set:

```text
block + 0   alloc_size (i32)            = value - 8 (after untagging)
block + 4   rc word (i32)               = value - 4
              bits 0..23   reference count
              bits 24..31  drop class   (the byte at value - 1)
block + 8   payload                     = value (untagged)
```

A decrement subtracts 1 from the whole word; a non-zero count never borrows
into the class byte. The zero test is `(rc_word * 256) == 0`, which shifts the
class byte out. A count that reaches `0xFFFFFF` saturates: the block becomes
immortal and is never incremented, decremented or freed (#720,
`emit_rc_word_inc_saturating`).

### Drop classes

The class byte is written at construction and tells `__rt_rc_drop` how to
release the payload when the count reaches zero.

| class | object | payload layout (offsets from the untagged value) | released on free |
| --- | --- | --- | --- |
| 0 | leaf: boxed `Double`, map side index, `MapBuilder` storage | — | nothing |
| 1 | field vector: tuple, record, constructor (nullary included) | `[type id or ctor tag@0][count@4][fields@8 + 8i]` | each of `count` fields |
| 5 | array | `[capacity@0][length@4][data_ptr@8][inline elements@12…]` | each of `length` elements, then a grown data buffer (`data_ptr != value + 12`), which is its own headered block |
| 6 | `Map` | `[count@0][side index@4][entries@8, 16-byte stride: key@+0, value@+8]` | every key and value, then the side index |
| 7 | capturing closure | `[table slot@0][count@4][captures@8 + 8i]` | each capture except the `let rec` self capture (a slot whose untagged pointer is the closure itself) |
| 8 | ref cell for a captured `let mut` | `[payload@0]` | the payload |
| 9 | `MapBuilder` handle | `[count@0][capacity@4][storage@8]` | every stored key and value, then the storage block |

A tuple's type id is 3. A nullary constructor is a 16-byte class-1 block with
`count = 0`, so it is reclaimed like any other constructor. Tagged values in a
field are released through the same entry checks, so a scalar or string field
is skipped and an aggregate with a closure payload releases the closure
(#3241, `fixtures/rc_option_payload_return_test.vibe`).

A ref cell's local holds the even value pointer, so reads and writes are the
same instructions as the bump lane's raw box; the capture slot of a closure
holds it with the low bit set. Every closure-captured `let mut` on the RC lane
gets a headered class-8 cell. The predicate that decides "this capture is RC
owned" (`ref_cell_names`) and the predicate that decides "this cell has a
header" must be the same one; see [perceus-reuse.md](perceus-reuse.md) for the
ownership rules of the cell.

### Allocation and free

`__rt_rc_alloc(size)` (`gen_rc_alloc_body`,
`codegen/builtin_bodies/bodies_core_a1a2.vibe`) returns a block start:

1. An 8-aligned size from 16 to 264 bytes first pops its exact-size bin
   (32 bins of 4 bytes at `bins_base`, index `(size - 16) >> 3`).
2. Otherwise it walks the legacy LIFO list (global 2) for an exact fit, up to
   16 nodes. The bound keeps a miss O(1); a deeper exact fit is abandoned.
3. Otherwise it bumps the main heap.

There is no splitting. Free (`emit_rc_free_push`) pushes a small block onto
its bin and anything else onto the legacy list, linking through the rc word
at `value - 4`. A fresh block starts at an eight-byte boundary.

`__rt_rc_dup` and `__rt_rc_drop` are generated per module. A dup site emits
the low-bit test inline and calls `__rt_rc_dup` only for an odd value
(`emit_rc_dup_guarded`); the helper repeats the full checks, so the two forms
cannot disagree. `__rt_rc_drop` checks the low bit, the string high word and
saturation at entry, decrements, and dispatches on the class byte at zero.
Under `VIBE_RC=shadow` both helpers also trap on a block the shadow table
marks freed (ADR-0062).

## Bump lane

The bump lane allocates every object from the main heap and never frees one.
`Int` and `Bool` are untagged, `Double` is inline bits, and objects carry no
RC header or drop class. Within one execution the heap frontier is therefore
the total allocation, which is why allocation measurements are taken on this
lane (see [profiling](profiling.md)).

## Rejected alternative: a static pointer bitmap

Recording which fields are pointers at construction time would avoid tagging
arithmetic, but it needs header space, covers only fields whose heap-ness is
known statically (a call result stored into a field is missed), and does not
address the ownership of escaping projections, which Perceus has to handle in
either design.

## Checks

- [`codegen_heap_e2e_test.vibe`](../../../lib/@vibe/compiler/tests/codegen_heap_e2e_test.vibe)
  compares bump and RC results for every operator, field round trips, nested
  drops, escaping projections and floats.
- [`int_overflow_wrap_test.vibe`](../../../lib/@vibe/compiler/tests/int_overflow_wrap_test.vibe)
  and [`bit_not_test.vibe`](../../../fixtures/bit_not_test.vibe) pin 63-bit
  wrapping and the tagged `~` constant.
- [`rc_reclaim_leak_test.vibe`](../../../fixtures/rc_reclaim_leak_test.vibe)
  bounds the heap of allocation loops; `scripts/verify_rc.sh` runs the heap e2e
  suite on both lanes.
- [`rc_shadow_regression_test.vibe`](../../../fixtures/rc_shadow_regression_test.vibe)
  runs the RC bug-shape corpus under `VIBE_RC=shadow`.
- Sections 88 and 89 of `tests/gates/late/typed_exception_e_rows.sh` pin the
  headered ref cell and the f64 literal rule.
