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
proposed here is a native scalar builtin implemented in the compiler**, and
against that baseline the margins collapse: `String::index_of` (native, scalar)
runs a 4 KiB search in 352 ns where a hand-written SIMD kernel takes 248 ns —
1.4x, not 100x.

## 2. Where vibe's SIMD support actually is

Two unrelated mechanisms exist today, and they are very far apart in quality.

**Fused builtins written in the compiler** (`codegen/builtin_bodies/`,
`codegen/expr/compile_call.vibe`). Five exist: `simd_skip_ws`,
`simd_scan_alnum`, `simd_scan_alnum_str`, `simd_scan_string_special_str`,
`simd_scan_line_end_str`. They keep the `v128` on the operand stack for the
whole loop and are fast. Two of the five have a production caller
(`lib/@vibe/parser/lexer.vibe:653,750`); the other three have only fixtures.
This mechanism works, but every kernel costs a compiler change, a registry row,
and a per-lane index arm — it does not scale to a data-structure library.

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

## 3. Measured: four gaps

### 3.1 The `V128` intrinsics were the wrong shape (retired, #2342)

`bench/bench_simd_bytes_find.vibe`, 4 KiB single-byte search, 500 iters:

| lane | ns/op (mean) | B/op | vs. best |
| :--- | ---: | ---: | ---: |
| inline-wasm SIMD kernel | **248** | **0** | 1.0x |
| native `String::index_of` (scalar builtin) | 352 | 0 | 1.4x |
| same algorithm through `v128_*` intrinsics | 5564 | **8048** | 22x |
| vibe-level scalar loop over `Bytes::get` | 25001 | 0 | 101x |

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
rejection evidence, recorded in the bench file's header and in
`docs/spec/simd-api-design.md` §4. `tests/gates/mid/run.sh` step 40 now asserts
the names stay unresolvable, because a retired surface that quietly comes back
is worse than one that never left.

The alternative was to keep `V128` and require it to stay in a wasm local —
reject, with a located diagnostic, any value of that type that escapes a
function body, the shape of ADR-0090's `let mut` escape analysis. That buys a
composable vector type that inline wasm already provides at zero cost, and pays
a new analysis pass and a new diagnostic class for it. Retiring is also jsimd's
own answer: "the package intentionally exports algorithms rather than raw
`v128` values".

### 3.2 The bit primitives are missing, and they matter more than SIMD

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

And vibe does not expose popcount. `declarations.vibe` has a
`//# WASM intrinsics (low-level)` block of ~50 names (`i32_eqz`, `i32_load8_u`,
`int_ctz`, `f32_sqrt`, …) described as the "Single Source of Truth for all
builtin function signatures" — measured, **none of them resolve from user
code**:

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

**Proposal.** Add a small, stable, scalar bit surface on `Int`, lowered to the
corresponding wasm opcode:

```
Int::popcount(Int) -> Int      // i64.popcnt on the untagged value
Int::ctz(Int) -> Int           // define the zero case (wasm i64.ctz gives 64)
Int::clz(Int) -> Int
Int::select1(Int, Int) -> Int  // position of the k-th set bit, -1 if absent
```

`~` (bit-not) is also still missing — `CLAUDE.md` tells readers to spell it
`x ^ mask`, and measured, `~x` is a parse error ("unexpected token: ~"); it
belongs in the same change. These four are cheap, they are
tag-safe (untag, operate, retag), they work on both backends, and they unblock
every bit-level structure in §4 without any SIMD at all.

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

The case for changing `MutMap` is therefore structural, not measured here.
`lib/@vibe/core/hashmap.vibe` stores slot state as `Array[Int]` — one tagged
i64, **8 bytes per slot**, for a value with three possible states. A SwissTable
control byte is 1 byte and carries a 7-bit fingerprint as well, so one
`v128.load` covers 16 slots where `Array[Int]` covers 2, and the fingerprint
skips most of the `eq_fn` indirect calls. Even with no SIMD, that is an 8x cut
in probe-metadata traffic. What it is *worth* is [#2346](https://github.com/mizchi/vibe-lang/issues/2346)'s
job to measure, with the rest of `MutMap` held fixed.

## 4. Proposal: five layers, bottom-up

Each layer is useful on its own and each is a precondition for the next. The
ordering is deliberate — it puts the cheapest and least SIMD-dependent work
first, because that is where the measurements say the value is.

### Layer 0 — decide the SIMD surface (§3.1)

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

`Int::popcount` / `Int::ctz` / `Int::clz` / `Int::select1`, plus `~`. No SIMD,
both backends, ~344x on rank.

### Layer 2 — `Bytes` bulk kernels

`Bytes` today has `get`/`set`/`push`/`slice`/`concat`/`fill`/`blit` and
structural `==`. It has **no search, no ordering, no counting** — so any library
that scans bytes writes the 6.1 ns/byte loop from §3.1 by hand. This is jsimd's
best-measured group (4.9–18.1x) and the one moonbitlang/core already covers with
the patterns jsimd inventories in its `CORE_PATTERNS.md`:

```
Bytes::index_of(Bytes, Int) -> Int              // single byte
Bytes::index_of_bytes(Bytes, Bytes) -> Int      // first/last-byte SIMD prefilter,
                                                // then verify the middle
Bytes::last_index_of(Bytes, Int) -> Int
Bytes::count(Bytes, Int) -> Int
Bytes::compare(Bytes, Bytes) -> Int             // lexicographic, first differing lane
```

Two design notes. `String` is a byte string since ADR-0098, so
`String::index_of` / `contains` / `split` / `starts_with` should route through
the same kernels rather than keeping a second scalar implementation — that is
where the 1.4x of §3.1 gets collected, across a surface that already has
callers. And a kernel wants to over-read its tail: guaranteeing at
least 15 bytes of readable slack past `len` would let every kernel drop its
scalar tail loop. Today's block is `[alloc@0][len@4][data@8]` with capacity
seeded at 64 and doubling, always a multiple of 8
(`gen_bytes_push_body`) — so the slack is 0..7 bytes and a 16-byte tail load
can read past the block.

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

Separately and independently of any of this: **change `MutMap`'s `state:
Array[Int]` to a `Bytes` control array carrying a 7-bit fingerprint.** It is a
local change to one file, it needs no new language surface, and it cuts
probe-metadata traffic 8x with the fingerprint skipping most `eq_fn` calls. It
is the cheapest change proposed here by a wide margin — but §3.4 does not price
it, so it ships with its own before/after bench or not at all.

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
