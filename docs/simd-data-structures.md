# SIMD-first data structures: where vibe stands and what to build

Written 2026-08-26. Every number below was measured on this checkout with
`vibe bench`; the benches are committed next to the claims (`bench/bench_simd_*.vibe`)
so any of them can be re-run or refuted.

The starting point is [`mizchi/jsimd`](https://github.com/mizchi/jsimd), which
asked "how much do succinct/SIMD data structures actually buy?" for JavaScript
hot paths and answered it with ~30 measured subpaths and a written admission
policy. This document asks the same question for vibe, keeps the parts of
jsimd's answer that transfer, and proposes what to add or change in vibe's
own data-structure foundation.

## Re-running the evidence

```bash
vibe test  bench/bench_simd_bytes_find.vibe   # every lane agrees
vibe bench bench/bench_simd_bytes_find.vibe --iters 500
vibe bench bench/bench_simd_rank.vibe --iters 500
vibe bench bench/bench_simd_int_column.vibe --iters 500
vibe bench bench/bench_simd_hash_probe.vibe --iters 500
```

All four files are linear-backend only (they use inline wasm), which is
`vibe bench`'s default lane.

## 1. What jsimd established, and what transfers

jsimd's headline results (Apple M5, Node 24 / Deno 2.6; its READMEs carry the
setups) cluster into three groups:

| group | jsimd result |
| :--- | :--- |
| byte-level scanning (`bytes`, `json`) | 4.9–18.1x over the JS baseline |
| frozen, resident, bulk-queried structures (wavelet matrix, roaring, bit-sliced column, flat hash) | 2–100x+ on bulk, **slower** on point access and on construction |
| symmetric "SIMD versions of things that already exist" (`SuccinctTrie`, `LoudsTree`, `StringInterner`, `PackedUint32Array`, `PackedDeltaArray`, `StaticMphfBytes`) | **rejected** — lost to the JS builtin |

Three of its conclusions transfer to vibe unchanged, and one does not.

**Transfers — separate the mutable builder from the frozen query
representation.** Their layouts conflict; a structure that tries to be both is
worse at both. vibe already has the vocabulary for this
(`ArrayBuilder::freeze`, `MapBuilder::freeze`, `StringBuilder::freeze`), so
nothing new has to be invented — the discipline just has to be applied to the
new structures.

**Transfers — design bulk operations first, point conveniences second.**
Measured here on a 4000-key lookup (§3.4), same table, same packed query
column, the only difference being where the loop lives: 2.7 ns/lookup with the
loop inside the kernel, 3.6 ns/lookup with it in vibe. **1.32x** for the
per-call boundary alone. A third lane that also moves the queries back into an
`Array[Int]` costs 6.6 ns/lookup — so in the first draft of this document, which
had no packed-query point lane, the boundary looked like 1.9x because it was
carrying the query representation with it. Two variables, one number; the fix
was another lane, not a softer sentence. jsimd states the bulk-vs-point rule as
a contract — "individual gets were 12.5x slower" is written into
`byte-key-flat-hash`'s own row — and vibe should do the same rather than let a
fast structure be quoted at its slowest call.

**Transfers — export algorithms, not vector values.** jsimd deliberately does
not export `v128`: "JavaScript cannot pass `v128` across the Wasm boundary, and
copying is only worthwhile when one call performs enough work." vibe hit the
same wall from the other side and has since drawn the same conclusion: §3.1
measured its `v128_*` intrinsics at 22x the algorithm they existed to express,
and #2342 removed them.

**Does NOT transfer — the baseline.** jsimd's rejections are measured against
V8's `Map`, `Set`, typed arrays and `TextDecoder`: hand-tuned native code. A
vibe library's baseline is usually a **vibe-level loop**, which is roughly two
orders of magnitude slower (§3.1 measures 6.1 ns per byte scanned). So a
structure jsimd rejected can still win handily in vibe — and that is a trap,
not an opportunity: winning against a vibe loop proves nothing except that the
loop was never the right implementation. **The honest baseline for anything
proposed here is a native scalar builtin implemented in the compiler**, not a
vibe loop.

That baseline is `find_4k_native_scalar` in
`bench/bench_simd_bytes_find.vibe`: a byte loop in inline wasm, native and
scalar, compiled the way the kernels are. Measured on 4 KiB, p50,
`Bytes::index_of` is **~11x** it — and ~109x the vibe loop.

**`String::index_of` is not a scalar baseline**, despite the name suggesting a
plain builtin: `gen_string_index_of_body` calls
`emit_windowed_substring_search`, a v128 scan (ADR-0054). Comparing a kernel
against it measures specialisation, not SIMD. The ~11x is the number a SIMD
kernel has to earn; the ~109x only proves the vibe loop was never the right
implementation.

## 2. Where vibe's SIMD support actually is

Two unrelated mechanisms exist today, and they are very far apart in quality.

**Fused builtins written in the compiler** (`codegen/builtin_bodies/`,
`codegen/expr/compile_call.vibe`). Nine exist. Five are lexer-shaped scans with
their needle baked in: `simd_skip_ws`, `simd_scan_alnum`, `simd_scan_alnum_str`,
`simd_scan_string_special_str`, `simd_scan_line_end_str`. Four are the Layer 2
`Bytes` searches this document proposed, landed in #2372: `Bytes::index_of`,
`Bytes::last_index_of`, `Bytes::count`, `Bytes::index_of_bytes`. They keep the
`v128` on the operand stack for the whole loop and are fast.

Every kernel costs a compiler change, a registry row, a per-lane index arm, and
a name in each of several hand-maintained declaration lists that nothing points
at — two effect-lowering allowlists, four borrow-arg0 masks, a `.vpkg` contract
(#2373). **This does not scale to a data-structure library**: adding four
builtins meant editing eleven places, and every one that was missed was caught
by a human rather than by a gate.

**Inline wasm** (`fn f(b: Bytes, n: Int) -> Int = wasm "..."`, #805/ADR-0072).
A ~600-line WAT assembler with the full integer/float/SIMD opcode set, `v128`
locals, `i8x16.shuffle`, structured control flow. This is the mechanism that
makes a SIMD data-structure library possible in *library* code —
`lib/@vibe/blake3/simd.vibe` already proves it at scale, and every kernel in the
benches here is written this way. It is linear-backend only (the wasm-gc backend
rejects it).

**The `V128` intrinsic surface** (`v128_load`, `v128_eq_i8x16`, … — 12 names)
sat between the two and belonged to neither. It is measured in §3.1 and has
since been **removed** (#2342).

## 3. Measured: four gaps, two of them now closed

### 3.1 The `V128` intrinsics were the wrong shape (retired, #2342)

`bench/bench_simd_bytes_find.vibe`, 4 KiB single-byte search, 500 iters:

The intrinsic lane no longer exists; this table is the evidence that retired
it (`bench/bench_simd_bytes_find.vibe`, 500 iters, mean, at the time):

| lane | ns/op (mean) | B/op | vs. best |
| :--- | ---: | ---: | ---: |
| inline-wasm SIMD kernel | **248** | **0** | 1.0x |
| `String::index_of` (a SIMD builtin — see §1) | 352 | 0 | 1.4x |
| same algorithm through `v128_*` intrinsics | 5564 | **8048** | 22x |
| vibe-level scalar loop over `Bytes::get` | 25001 | 0 | 101x |

Current numbers, including the native scalar baseline, are in that file's
header.

The intrinsic lane ran the *identical algorithm* as the kernel lane and was 22x
slower, because each `v128_load` / `v128_eq_i8x16` / `v128_and` returned a
tagged pointer to a freshly bump-allocated 16-byte box. The box deliberately
carried no RC header — Perceus had to classify these values as scalar, since a
dup/drop would have misread the vector's payload bytes as a refcount — which
also meant nothing ever reclaimed one. Scanning 4096 bytes allocated 8 KiB. The
compiler's own fused builtins avoid this by never letting the vector become a
value at all.

(No line citations here on purpose. This paragraph described code that #2342
deleted, and the ranges it used to cite now land on pattern environments and
closure ownership — pointing a reader at unrelated current code is worse than
pointing at nothing. `git log` is the archive; the same rule the `docs/` policy
in `CLAUDE.md` states for whole documents applies to a line number inside one.)

So the intrinsics were documented, type-checked, reachable from user code, and
wrong to use. They never gave a wrong answer, so this was not a P0 by the triage
rules — but it is the shape the design policy cares about for a different
reason: the surface read as the supported way to write SIMD, and taking it cost
22x and 2 bytes of unreclaimable heap per byte scanned. Nothing in the tree used
them except their own fixture.

**Resolved: retired** (#2342). The 12 names, the `CtNamed("V128", [])` type
behind them, their checker lookup, their inline lowering, and the Perceus and
gc-backend special cases they needed are gone — and so is the bench lane that
measured them, which cannot be rebuilt without them; the numbers above are the
rejection evidence, recorded here and in the bench file's header. `tests/gates/mid/run.sh` step 40 now asserts
the names stay unresolvable, because a retired surface that quietly comes back
is worse than one that never left.

The alternative was to keep `V128` and require it to stay in a wasm local —
reject, with a located diagnostic, any value of that type that escapes a
function body, the shape of ADR-0090's `let mut` escape analysis. That buys a
composable vector type that inline wasm already provides at zero cost, and pays
a new analysis pass and a new diagnostic class for it. Retiring is also jsimd's
own answer: "the package intentionally exports algorithms rather than raw
`v128` values".

### 3.2 The bit primitives matter more than SIMD (added, #2344)

`bench/bench_simd_rank.vibe`, rank1 over 32 Kibit, 500 iters:

| lane | ns/op (mean) | vs. scalar |
| :--- | ---: | ---: |
| vibe loop over `Bytes::get`, bit by bit | 159834 | 1x |
| `i64.popcnt`, 8 B/iter | 465 | **344x** |
| `v128.load` + 2x `i64.popcnt`, 16 B/iter | **365** | 438x |
| `i8x16.popcnt` + horizontal sum, 16 B/iter | 518 | 309x |

This is the most useful negative result in the set. **Essentially the whole win
is one scalar instruction**; widening the load to `v128` adds 27%, and the
dedicated `i8x16.popcnt` adds nothing at all. rank/select, and therefore every
succinct structure built on it, is a *popcount* story, not a SIMD story.

vibe had no popcount when this was measured, and `declarations.vibe` looked
like it did: its `//# WASM intrinsics (low-level)` block declares ~50 names
(`i32_eqz`, `i32_load8_u`, `int_ctz`, `f32_sqrt`, …) under a header calling the
file the "Single Source of Truth for all builtin function signatures". Measured,
**none of them resolve from user code**, and that is still true:

```
$ vibe check probe.vibe        # fn f(x: Int) -> Int { let _ = int_ctz; 0 }
line 1:31-38: unknown name: int_ctz
```

Reachability is **per block**, and the file does not say which is which.
Measured on the same compiler: `simd_skip_ws`, declared a few lines below in
that same file, resolves clean — it has a row in `core/builtin_registry.vibe`,
which is what the checker actually consults. The low-level block has no such
row, so those names exist only as signatures. (The `v128_*` block was the other
reachable example until #2342 retired it; §3.1.)

So the surface #2344 added is a designed one on `Int`, lowered to the
corresponding wasm opcode — not those raw names un-hidden (#2343 covers the
declarations that still overstate themselves):

```
Int::popcount(Int) -> Int      // i64.popcnt on the untagged value
Int::ctz(Int) -> Int           // define the zero case (wasm i64.ctz gives 64)
Int::clz(Int) -> Int
Int::select1(Int, Int) -> Int  // position of the k-th set bit, -1 if absent
```

`Int::popcount` / `ctz` / `clz` are registry builtins on **both** lanes;
`Int::select1` is a prelude function on top of them, since wasm has no select
instruction to lower to. All are tag-safe (untag, operate, retag) and answer at
the 63-bit width — `popcount(-1)` is 63, not 64 — with the zero cases defined
rather than inherited. Together they unblock every bit-level structure in §4
without any SIMD at all.

`~` (bit-not) is still missing: `CLAUDE.md` tells readers to spell it
`x ^ mask`, and measured, `~x` is a parse error ("unexpected token: ~"). It is
a new **operator**, touching the lexer, parser and printer, so it is tracked as
its own slice rather than bundled with a builtin addition.

### 3.3 There is no packed numeric buffer

`bench/bench_simd_int_column.vibe`, sum of 4096 `Int`s, 500 iters:

| lane | ns/op (mean) | vs. loop |
| :--- | ---: | ---: |
| vibe loop over `Array[Int]` | 9240 | 1x |
| SIMD over vibe's 8-byte tagged slots | 1541 | 6.0x |
| SIMD over a packed i32 column in `Bytes` | **630** | **14.7x** |

Two things to read out of this.

First, **vibe's tag choice is already SIMD-friendly**: `Int` n is represented
`n<<1`, and addition is tag-transparent, so `i64x2.add` straight over an array's
raw slots is correct with no untag/retag at all. That is a genuine asset and
should be written down before someone "fixes" the representation.

Second, the remaining 2.4x is pure memory traffic: 8 bytes per element where 4
would do, and 2 lanes per vector where 4 would fit. vibe has exactly two array
shapes — `Array[T]` (tagged 8-byte slots) and `Bytes` (u8) — and nothing in
between. jsimd's entire middle layer (`i32-array`, `f32-vector`, `columnar`,
`bit-sliced-column`, `blocked-vector-array`, `matrix2d/3d`) is built on typed
arrays that vibe has no type for.

There is a second, harder edge here: **a SIMD kernel cannot see an `Array[T]`
at all.** Inline wasm accepts only `Int` and `Bytes` params —
`fn f(xs: Array[Int]) -> Bytes = wasm "..."` is rejected with "param must be
typed Int or Bytes". So the tagged lane above had to rebuild the tagged layout
inside a `Bytes` by hand to be measurable.

### 3.4 `MutMap`'s probe metadata is 8x wider than it needs to be

`bench/bench_simd_hash_probe.vibe`, 4000 membership tests against 4000 `Int`
keys, 500 iters:

| lane | ns/op (mean) | ns/lookup | B/op |
| :--- | ---: | ---: | ---: |
| stdlib `MutMap[Int, Int]` (`MutMap::has` in a vibe loop) | 149739 | 37.4 | 0 |
| frozen table, point API, queries in an `Array[Int]` | 26293 | 6.6 | 0 |
| frozen table, point API, queries in the packed column | 14284 | 3.6 | 0 |
| frozen table, bulk kernel | **10850** | **2.7** | 0 |

**Read the 13.8x between the first and last rows as aggregate headroom and
nothing finer.** The two ends differ in at least eight ways at once: generic
`K`/`V` vs monomorphic `Int`; a map vs a set; `Option`-wrapped slots vs raw
ones; closed-over `hash_fn`/`eq_fn` indirect calls vs an inlined multiply; a
different hash; linear probing vs group-of-16; an 8-byte state slot vs a
1-byte control byte; and tagged 8-byte keys vs a packed i32 column. **Not one of
those is isolated by this bench**, so no single one of them can be credited with
a share of the 13.8x. It sizes what a specialized frozen representation can
reach; it does not indict the stdlib and it does not price any individual
change.

The three frozen rows *are* controlled against each other, and that is where
the readable numbers are: same table, same probe, same hash. Loop-in-kernel vs
loop-in-vibe is **1.32x**; moving the queries from an `Array[Int]` to the packed
column is another **1.84x**.

The case for changing `MutMap` was therefore structural, not measured here —
so [#2346](https://github.com/mizchi/vibe-lang/issues/2346) measured it, with
the rest of `MutMap` held fixed. It landed: `state: Array[Int]` (one tagged
i64, **8 bytes per slot**, for a value with three possible states) is now
`ctrl: Bytes`, one byte per slot, carrying a 7-bit fingerprint of the key's
hash. `bench/bench_mutmap_probe.vibe` touches only MutMap's public API, so the
same source measures both representations; best-of-3, alternating A/B/A/B so
machine drift cannot produce the result:

| lane | before (ns) | after (ns) | |
| :--- | ---: | ---: | ---: |
| `get` hit, sequential keys (**zero-collision control**) | 219950 | 215684 | 1.02x |
| `get` hit, random keys | 327233 | 306711 | **1.07x** |
| `get` miss, random keys | 720554 | 705474 | 1.02x |
| `get` hit, half the entries deleted | 514431 | 480477 | **1.07x** |
| `get` hit, `String` keys | 634086 | 525831 | **1.21x** |
| `get` miss, `String` keys | 938037 | 749352 | **1.25x** |
| build 5000 entries | 1689725 | 1605349 | **1.05x** |

Build also allocates 11% less (910496 -> 811008 B/op): the control arrays are
an eighth of their former size, across the whole rehash history.

The shape of the result is the point, more than its size. The win tracks **the
cost of the compare that the fingerprint skips** — largest on `String` keys
(1.21x / 1.25x, where the skipped call is `eq_string`), modest on `Int` keys
(1.07x, where `eq_int` is nearly free), and a wash on the sequential-key
control lane, which is exactly right: `hash_int` is the identity below 2^33, so
a table keyed 0..N-1 has no collisions at all and there is nothing for a
fingerprint to filter. A lane that showed a large win *there* would have been
evidence of a broken measurement, not of a fast table.

Two things had to be got right for the number to mean anything, and both were
initially wrong:

- **The fingerprint cannot come from the low bits of the hash.** The home slot
  is `h % cap`, so for a power-of-two capacity, two keys that collide already
  agree on exactly those bits — `h & 0x7f` would be identical for every key in
  a chain and would filter nothing. `ctrl_tag` folds the high bits down first.
- **Naming the control constants cost more than the fingerprint saved.** The
  first implementation had `ctrl_empty()` / `ctrl_tomb()` / `is_occupied(c)`
  helpers where the original compared against literals `0`/`1`/`2`. Measured,
  that turned a 1.05x build into a 0.94x *regression* and halved the String
  win; a zero-argument constant function in the innermost probe loop is not
  free. The constants are spelled as literals with a comment instead.

## 4. Proposal: five layers, bottom-up

Each layer is useful on its own and each is a precondition for the next. The
ordering is deliberate — it puts the cheapest and least SIMD-dependent work
first, because that is where the measurements say the value is.

### Layer 0 — the SIMD surface (decided, §3.1)

**Done: `V128` is retired** (#2342), leaving inline wasm as the one way to
write a kernel. Independently, three inline-wasm gaps block kernels in library
code:

1. ~~**Out-of-range `i32.const` produces an invalid module with no
   diagnostic.**~~ **Fixed** (#2341). It used to be: `(i32.const 2654435761)` —
   in range for a vibe `Int`, out of range for a *signed* `i32` — passed
   `vibe check` **clean** and then failed at load with `viberun: from_file:
   failed to compile: wasm[0]::function[70]::f` and a Rust backtrace, which is
   `vibe check` lying about whether a program builds. The fix accepts both
   spellings the text format defines (`iN ::= n:uN | i:sN`, so that literal now
   assembles to the same bytes as `-1640531535`) and gives a located error for
   what is genuinely out of range — for `v128.const` lanes, which silently
   truncated, and for an integer literal longer than a vibe `Int`, which
   silently wrapped, as well. Until the next bootstrap bump the committed seed
   predates the fix, and `vibe test` compiles with the seed by default — so the
   benches here still spell that constant the signed way, and
   `bench/bench_simd_hash_probe.vibe` says why at the top.
2. **No `call`.** Kernels cannot compose, so every structure re-inlines its own
   hash, its own group probe, its own tail handling. Allowing a call to another
   inline-wasm `fn` in the same module would remove most of the duplication.
3. **`Bytes` params only.** See §3.3. At minimum, a supported way to hand a
   kernel the payload pointer and length of an `Array[T]`.

### Layer 1 — scalar bit primitives (§3.2)

**Done** (#2344): `Int::popcount` / `Int::ctz` / `Int::clz` / `Int::select1`.
No SIMD, both backends, ~344x on rank. `~` remains open as its own slice.

### Layer 2 — `Bytes` bulk kernels

**Landed** in #2372, on both backends:

```
Bytes::index_of(Bytes, Int) -> Int              // single byte
Bytes::last_index_of(Bytes, Int) -> Int
Bytes::count(Bytes, Int) -> Int
Bytes::index_of_bytes(Bytes, Bytes) -> Int      // substring; calls String::index_of
```

**Still open:**

```
Bytes::compare(Bytes, Bytes) -> Int             // lexicographic, first differing lane
```

`Bytes` still has no ordering: `Bytes < Bytes` is a type error and
`Bytes::compare` is the builtin that would fix it. Everything else in this
layer is served, so a library no longer writes the 6.1 ns/byte loop by hand.
Measured on a 4 KiB buffer (`bench/bench_simd_bytes_find.vibe`, p50): that loop
is 23600 ns and `Bytes::index_of` is 216 ns.

Against `find_4k_native_scalar` (§1) `Bytes::index_of` is ~11x; against
`String::index_of` it is ~1.7x, which measures specialisation — a single byte
needs no needle span verified through `str_eq` — not SIMD.

**Routing is the open half.** `String` has been a byte string since ADR-0098,
so `String::count` / `split` / `replace` should go through these kernels rather
than keep a second implementation. Those three are the ones that matter:
ADR-0054 already made `String::index_of` / `equals` / `starts_with` /
`ends_with` SIMD, while `count` / `replace` / `replace_all` are library
functions in `@vibe/builtin` — i.e. exactly the hand-written loop this layer
replaces, on a surface that already has callers.

**Tail slack is still undecided.** A kernel wants to over-read its tail:
guaranteeing at least 15 bytes of readable slack past `len` would let every
kernel drop its scalar tail loop. Today's block is `[alloc@0][len@4][data@8]`
with capacity seeded at 64 and doubling, always a multiple of 8
(`gen_bytes_push_body`) — so the slack is 0..7 bytes and a 16-byte tail load
can read past the block. The four landed kernels all keep a scalar tail
instead, so none of them depends on this being resolved.

### Layer 3 — packed columns (§3.3)

Not a new primitive type: a **frozen typed view over `Bytes`, built through a
builder**, matching vibe's existing `Builder::freeze` idiom.

```
I32Column::builder() -> I32ColumnBuilder
I32ColumnBuilder::push(I32ColumnBuilder, Int) -> Unit
I32ColumnBuilder::freeze(I32ColumnBuilder) -> I32Column

I32Column::length(I32Column) -> Int
I32Column::get(I32Column, Int) -> Int          // point convenience, outside the contract
I32Column::sum(I32Column) -> Int               // bulk: the operations that earn the type
I32Column::min / max / count_eq / count_lt
I32Column::mask_range(I32Column, Int, Int) -> Bitmap
```

`F32Column` and `U8Column` follow the same shape. `I32Column` first: it is the
one the compiler itself would use (token offsets, span tables, module indices).

### Layer 4 — bit-level structures

```
Bitmap                 // mutable dense bitmap: set/clear/test, bulk and/or/andnot/count
BitVector              // frozen packed bits + rank/select index
```

Built on Layer 1, not on SIMD (§3.2). `Bitmap`'s bulk set operations
(`and`/`or`/`andnot` over whole words) are where `v128` genuinely pays, and
jsimd measures that group at 9.8–19.8x.

Name them exactly this way and reserve them: jsimd spent a release cycle
cleaning up `bitset` / `bit-vector` / `rank-select-bitvector` /
`rank-select-bitmap` aliases and concluded "do not add compatibility aliases
before a real compatibility obligation exists". vibe can start there.

### Layer 5 — frozen collections (§3.4)

```
FrozenIntSet           // control byte + i32 key column, group-of-16 probe
FrozenIntMap[V]
```

with bulk entry points (`contains_many`, `get_many`) as the documented contract
and point access as a convenience that is explicitly *not* in the contract.

Separately and independently of any of this, and now **done** (#2346):
`MutMap`'s `state: Array[Int]` is a `Bytes` control array carrying a 7-bit
fingerprint. One file, no new language surface, and it shipped with the
before/after bench §3.4 demanded — 1.02x to 1.25x depending on how expensive
the key compare it skips is, plus 11% less allocation on build. It remains the
cheapest change proposed here by a wide margin, and `MutSet` got it for free by
being a thin wrapper over `MutMap`.

## 5. Admission policy

Adapted from jsimd's, which exists because it kept the package honest — seven
prototypes are recorded there as *rejected*, with the numbers that rejected
them. The adaptation is §1's transfer caveat:

1. A new structure or bulk operation must beat **the best existing vibe
   spelling** on a documented end-to-end workload. Where a native builtin
   exists, that builtin is the baseline — **not** a vibe-level loop.
2. Where the documented usage does not amortize them, the measurement includes
   construction, key conversion, and materializing the result.
3. Storage savings alone, or an isolated kernel win alone, is not sufficient.
4. A bulk structure may keep slower point conveniences, but the documentation
   must name them as outside the performance contract.
5. The bench that justifies the claim is committed next to it in `bench/`, and
   the claim cites its numbers.
6. If nothing wins, the prototype is deleted and only the bench survives, as
   rejection evidence.

Rule 5 is the one this repository will feel most: a performance claim with no
committed bench is folklore, and `CLAUDE.md` already treats folklore as a
defect.

## 6. What not to build

jsimd rejected `SuccinctTrie`, `LoudsTree`, `StringInterner`,
`PackedUint32Array`, `PackedDeltaArray`, `StaticMphfBytes`, and sparse-matrix
BFS — each lost to the JavaScript builtin it was meant to replace. Per §1 those
rejections do **not** carry over automatically, since vibe's builtins are
weaker. But they carry over as a warning about *shape*: every one of them is a
compressed representation whose decode cost exceeded what the compression saved.
Any vibe proposal with that shape should be measured against a native builtin
before it is written, not after.

The same goes for symmetric naming. jsimd's queue ends with "do not add
symmetric names such as `SimdFloat32Array`, `SimdInt32Vector`, or a standalone
`BitVector` without a measured workload that wins after boundary costs." The
layers above are proposed in dependency order for that reason, and Layer 3's
`F32Column` and `U8Column` are explicitly gated behind a workload that wants
them.

## 7. Issue tree

Parent [#2340](https://github.com/mizchi/vibe-lang/issues/2340), three-axis
labels per [docs/issue-triage.md](issue-triage.md). Priority is the symptom the
issue states and nothing else, so most of this is P2 — almost none of it is
something that works today being broken.

| # | item | kind | priority |
| :-- | :--- | :--- | :--- |
| [#2340](https://github.com/mizchi/vibe-lang/issues/2340) | SIMD-first data-structure foundation (index) | `epic` | P2 |
| [#2341](https://github.com/mizchi/vibe-lang/issues/2341) | inline wasm: out-of-range `i32.const` passes `vibe check`, fails at module load (§4/Layer 0) | `bug` | **P0** |
| [#2342](https://github.com/mizchi/vibe-lang/issues/2342) | `V128` intrinsics heap-box every vector and never reclaim it — **retired** (§3.1) | `bug` `performance` | P1 |
| [#2343](https://github.com/mizchi/vibe-lang/issues/2343) | the low-level wasm intrinsic block in `declarations.vibe` does not resolve from user code (§3.2) | `bug` | P2 |
| [#2344](https://github.com/mizchi/vibe-lang/issues/2344) | `Int::popcount` / `ctz` / `clz` / `select1`, and `~` (§3.2) | `enhancement` `blocker` | P2 |
| [#2345](https://github.com/mizchi/vibe-lang/issues/2345) | `Bytes` search/compare/count kernels; route `String::*` through them (§4/Layer 2) | `enhancement` | P2 |
| [#2346](https://github.com/mizchi/vibe-lang/issues/2346) | `MutMap`: `Array[Int]` state -> `Bytes` control byte + fingerprint (§3.4) | `performance` | P2 |
| [#2347](https://github.com/mizchi/vibe-lang/issues/2347) | `I32Column` builder/frozen pair (§4/Layer 3) | `enhancement` | P2 |
| [#2348](https://github.com/mizchi/vibe-lang/issues/2348) | inline wasm: no `call` between kernels, no `Array[T]` param (§3.3, §4/Layer 0) | `enhancement` | P2 |

Layers 4 and 5 have no issue yet, deliberately: by §5 each needs a documented
end-to-end workload that wins against a native builtin before it is written.

The order falls out of the triage rules — #2341, then #2342, then #2344 (the
`blocker`), then the rest. #2341 and #2342 are done. None of
#2343 / #2344 / #2345 / #2346 waited on the #2342 decision. Of those, #2343, #2345 and #2346 need no new language surface
at all; #2344 does — `Int::popcount` and friends are builtin additions, and `~`
is a new operator, so it touches the lexer, the parser and the printer as well.
