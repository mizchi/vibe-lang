# Generated code size: linear backend vs wasm-gc backend

Measured: 2026-10-18 (small programs and synthetic benches, after the linear
lane's runtime helpers were trimmed; the wasm-gc column is unchanged since
the gc lane started pruning unreachable functions on 2026-10-17) / 2026-08-16
(application scale)

Reproduce:

```bash
# Synthetic benches (the small-program and scaled* table below)
bash scripts/measure_backend_code_size.sh

# Real application scale (the application table) -- compile the compiler itself on both lanes
bash scripts/test_gc_selfbuild.sh          # produces bundle_gc.wasm on the gc side
node scripts/wasm_section_sizes.mjs \
  _build/gc_selfbuild/bundle_gc.wasm \
  "$(ls -t _build/selfhost/generations/*/stage2.wasm | head -1)"
```

Related: [gc-value-abi.md](../compiler/gc-value-abi.md) (#1331), [feature-levels.md](../../user/reference/feature-levels.md),
[../BENCHMARKS.md](../operations/BENCHMARKS.md) (time-axis regression signal on the linear lane)

## Conclusion

**Neither lane has a fixed runtime cost any more; what differs is which
helpers a program pulls in, and how dense each lane's function bodies are.**

- **Small programs that allocate are smaller on wasm-gc.** A struct, an
  array, an enum or a closure costs the gc lane nothing beyond `struct.new` /
  `array.new`, while the linear RC lane links its allocator and its drop
  (`__rt_rc_alloc` 263 B + `__rt_rc_drop` 208 B and up) the moment one heap
  value exists. `closure_indirect` is 809 B on gc against 1,272 B on linear;
  `variant_float` 1,299 B against 2,673 B.
- **Programs that do not allocate are smaller on linear.** The empty program
  is 399 B on linear against 527 B on gc, `fib` 452 B against 589 B: linear
  emits a data segment only for what a reachable helper can read (the
  out-of-bounds message fragments go with `__rt_oob_abort`), while gc still
  writes its `Bytes::with_capacity` message (106 B of data in every module).
- **Printing a non-literal string still costs gc a renderer.** Both lanes
  write a literal `println("...")` directly (`hello_world` is 615 B on gc,
  488 B on linear). For any other argument the gc lane calls `__to_string`
  (302 B) before writing, because its backend probes print unchecked values;
  linear passes the string straight to the host. So `fizzbuzz`, which prints
  the result of a call, is 1,310 B on gc against 991 B on linear.
- **Per byte of user code, the two are about even** (gc = 102.7% of linear on
  the synthetic slope), and at real application scale **gc is +37% larger**
  (the table below). That gap is function-body density, not a fixed cost, so
  it is unchanged by the pruning that removed the fixed cost.

The gc lane used to carry 57 runtime helper bodies whether a program called
them or not (~5.9 KB: the empty program was 6,395 B). It now runs the linear
lane's #2359 pass on its finished module (`gc_prune_unreachable_functions`,
`codegen/gc/backend_body_gc_unresolved_import_message.vibe`), which keeps only
what the exports and the table can reach. The empty program is 527 B.

### Application scale (2026-08-16, not remeasured)

The largest real program we can measure -- the compiler itself (a flat bundle,
5.1 MB of source) -- compiled from the same source on both lanes:

| | linear | wasm-gc | Δ |
|---|---:|---:|---:|
| total size | 2,220,575 | 3,051,650 | **+37.4%** |
| code section | 2,109,773 | 2,940,289 | **+39.4%** |
| function count | 4,454 | 4,519 | +1.5% |
| **mean bytes per function** | **474** | **651** | **+37.3%** |

**99.9% of the gap is the code section.** Type metadata (type section +915 B) is noise.
Function count and stub count are almost the same, so **gc is emitting more bytes for the
same functions**. The largest function goes 64,921 → 119,372 B (1.84×). The
helper pruning above removes at most the ~6 KB of unreachable helpers here,
0.2% of the module.

> **These numbers are after #1985 (sibling-branch local-slot reuse).** Before that the
> gc module was 3,086,780 B (+39.0%): the gc lane assigned each arm slots above its
> siblings' high-water mark, which grew as 2^d in nesting depth. The fix dropped
> declared locals across the module from 92,071 → 53,280 slots (**−42%**), and the
> largest function from 2,651 → 1,986, but **size only fell 35 KB (1.1%)**. A local
> declaration is 2–3 B per slot, so this was never the main driver of the gap. The
> remaining +37% is the "bytes per function" density.

> **Do not extrapolate a slope measured on synthetic scaling onto a
> different kind of code.** The synthetic source is N copies of "struct +
> projection + array loop + string build" with shallow branches and matches.
> On code like the real compiler -- lots of matches, deep branches, and
> locals -- gc's value-representation traffic makes code density worse.

## Measurements

Byte sizes of `.wasm` compiled from the same source on both backends. The case set
is `bench/binary_size/` (#1056) as-is, so it is comparable to the linear
numbers in [../BENCHMARKS.md](../operations/BENCHMARKS.md). The `result` column is the
execution result on both lanes; a row where those disagree is invalid as a size
comparison too (a broken wasm is naturally small, so always read size next to the result).

| program | dominant shape | linear | wasm-gc | Δ | result |
|---|---|---:|---:|---:|---:|
| `empty` | `() -> 0` (fixed-cost control) | 399 | 527 | +32.1% | 0 |
| `hello_world` | single `println` | 488 | 615 | +26.0% | 0 |
| `fib` | recursive calls | 452 | 589 | +30.3% | 6765 |
| `fizzbuzz` | loop + branches + printing | 991 | 1,310 | +32.2% | 0 |
| `closure_indirect` | higher-order / indirect call | 1,272 | 809 | −36.4% | 31 |
| `variant_float` | algebraic match + floats | 2,673 | 1,299 | −51.4% | 31 |
| `scaled10` | synthetic ×10 | 5,755 | 4,969 | −13.7% | 105 |
| `scaled40` | synthetic ×40 | 16,519 | 15,908 | −3.7% | 255 |
| `scaled80` | synthetic ×80 | 30,976 | 30,605 | −1.2% | 455 |
| `scaled160` | synthetic ×160 | 60,003 | 60,688 | +1.1% | 855 |

`empty` is generated by the measurement script, not the existing case set —
even the smallest `hello_world` calls `println`, so you cannot read the fixed
cost itself unless you keep a "program that uses nothing" on the side.

`scaledN` is N copies of one set: struct definition + projection + array-alloc
loop + string build. The existing case set is fixed-size, so it cannot give a
slope; only these rows can.

```
slope:     linear 361.7 B/copy, wasm-gc 371.5 B/copy (gc = 102.7% of linear)
intercept: linear 2138 B, wasm-gc 1254 B (fitted, NOT the empty-program size)
residual:  max 366 B off the fitted line (0.6% of the largest point)
crossover: none -- wasm-gc grows at least as fast as linear
```

So on this workload gc starts ~0.9 KB smaller (the helpers each lane links for
"struct + array + string build") and linear catches up by ~10 B per copy; the
two meet between `scaled80` and `scaled160`.

## Why it looks like this

Breaking it down by section and by function
(`node scripts/wasm_section_sizes.mjs <file.wasm>`):

| | `empty` linear | `empty` gc | `closure_indirect` linear | `closure_indirect` gc |
|---|---:|---:|---:|---:|
| total | 399 | 527 | 1,272 | 809 |
| code section | 138 | 185 | 981 | 441 |
| data section | 8 | 106 | 8 | 106 |
| function count | 3 | 3 | 9 | 6 |
| largest bodies | 116, 10, 8 | 154, 22, 4 | 297, 263, 140, 116, 57 | 163, 154, 57, 23 |

**Both lanes now emit a helper only when something reachable calls it.**
`empty` keeps the same three functions on both lanes (the integer printer
`_start` uses for `main`'s result, `main`, `_start`).

**The allocation runtime is where they part.** On linear, the first heap value
links `__rt_rc_alloc` (263 B: a size-segregated bin pop, then a bounded
free-list walk, then the bump) and `__rt_rc_drop`, the recursive per-class
release. `__rt_rc_drop` carries only the arms for blocks the program can
make: 208 B with structs and enums alone, +89 B for closures and ref cells
(a lambda nested in an expression), +142 B for arrays (an array literal, or
a reachable `arr_new` / `Array::slice` / `Array::with_capacity`), +244 B for
maps -- 683 B with all of them. `closure_indirect` carries rc_drop at 297 B,
`__rt_rc_alloc`, and `__rt_rc_dup` (57 B). On gc a struct, enum or closure
is a `struct.new` the engine collects, so the same program carries none of
it -- the 297 + 263 + 57 B are the bulk of its 463 B gap.

`empty` is smaller on linear because nothing in it is unreachable: the
integer printer (116 B) is the only runtime body, and the one data segment
left is the `"\n"` other helpers write directly. gc's 106 B data section is
the `Bytes::with_capacity` message it emits unconditionally -- the next fixed
cost to remove on that lane.

On `scaled160`:

- code section: linear 59,284 → gc 58,068 B (**−2.1%**)
- type section: linear 67 → gc 1,050 B (declaring nominal struct types in the type section)
- func section: linear 659 → gc 1,295 B (more type indices, longer LEBs)

gc wins slightly on the function bodies, then gives that back as type
metadata.

## How to measure, and the pitfalls

```bash
bash scripts/measure_backend_code_size.sh [stage2.wasm]
MEASURE_SCALES="10 20 40 80" bash scripts/measure_backend_code_size.sh
# Resolve imports before both final backends (for application measurements):
MEASURE_FS_COMPILE=1 bash scripts/measure_backend_code_size.sh
node scripts/wasm_section_sizes.mjs _build/backend_code_size/empty.gc.wasm
```

Two things are easy to step on when remeasuring. Both can produce a wrong
number, so keep them recognizable from the shape of the result.

**1. Select module loading and codegen independently.** Use
`VIBE_FS_COMPILE=1` for filesystem imports; choose the final backend separately
with `VIBE_BACKEND=linear` or `VIBE_BACKEND=gc`. This resolves and projects the
same module graph before either code generator runs. The measurement script's
default keeps direct compilation for reproducibility with the committed table;
set `MEASURE_FS_COMPILE=1` to measure both backends after filesystem resolution.
The committed cases remain import-free on purpose: they isolate the per-copy
codegen slope and keep the historical series comparable, rather than reflecting
a compiler limit.
If the two artifacts match byte-for-byte, backend selection did not take
effect; a gc artifact differs at least in its type and data sections.

**2. The entry name must be `main`.** The `__no_entry__` sentinel that
doctests use works on linear and fails on gc with
`entry function not found: __no_entry__`. The gc side coming out 0 bytes is
noticeable, but swallowing it with `|| true` turns into a meaningless "gc
is 0 B" win. The script keeps 0-byte outputs out of the size table and
reports COMPILE FAILED. The correct invocation is the same as
`scripts/compiler_gate.sh` 40h (wasm-gc backend smoke) and
`scripts/bench_binary_size.sh`.

## How to use these numbers

- **Size is a reason to pick the gc lane only for small programs that
  allocate.** The general reason to pick it is the representation in
  [gc-value-abi.md](../compiler/gc-value-abi.md) (native references,
  collecting cyclic structure, dropping RC). At application scale it is
  larger.
- **What P5 (size reduction) should cut on gc is bytes per function.** The
  fixed cost is gone; almost all of the +866 KB application-scale gap is
  function bodies. **First pin down, per function, why one function becomes
  1.4×** -- that is uninvestigated today, and `wasm_section_sizes.mjs` only
  reports sizes (artifacts have the name section stripped, so you need a
  function-index-to-source map).
- **On linear, the allocation runtime is the floor for any program that
  allocates** (`__rt_rc_alloc` 263 B + `__rt_rc_drop` 208–683 B, plus
  `__rt_rc_dup` where a value is shared). What remains in the smallest
  rc_drop is the field-vector arm and the free path every block needs; the
  next cut would be the allocator's bounded free-list walk, which every
  freed block outside the size bins (16..264 B, 8-aligned) feeds.
- **Local-slot count is no longer the main driver (confirmed in #1985).**
  Cutting declared locals 42% moved total size only 1.1%.
  `node scripts/wasm_local_counts.mjs <file.wasm>` reports slots per body, so
  when you next suspect something, check "is this even a size-shaped amount"
  there first. The remaining ceiling is 45,937 slots (the cap if sibling
  reuse is enabled unconditionally; linear is 41,953), and packing that far
  would buy about another 20 KB.
- **Watch size regressions on both lanes now.** With no fixed prelude, user-code
  growth shows up on gc too; `scripts/size_ratchet.sh` still gates only the
  linear lane.
