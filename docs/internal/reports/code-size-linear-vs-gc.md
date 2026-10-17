# Generated code size: linear backend vs wasm-gc backend

Measured: 2026-10-17 (small programs and synthetic benches, after the wasm-gc
lane started pruning unreachable functions) / 2026-08-16 (application scale)

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
  (`__rt_rc_alloc` 319 B + `__rt_rc_drop` 571 B) the moment one heap value
  exists. `closure_indirect` is 809 B on gc against 1,822 B on linear;
  `variant_float` 1,299 B against 3,051 B.
- **Programs that only print are smaller on linear.** Linear lowers
  `println("...")` of a literal to a static write; the gc lane routes it
  through a general string helper (302 B), so `hello_world` is 1,102 B on gc
  against 691 B on linear.
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
| `empty` | `() -> 0` (fixed-cost control) | 602 | 527 | −12.5% | 0 |
| `hello_world` | single `println` | 691 | 1,102 | +59.5% | 0 |
| `fib` | recursive calls | 655 | 589 | −10.1% | 6765 |
| `fizzbuzz` | loop + branches + printing | 1,211 | 1,490 | +23.0% | 0 |
| `closure_indirect` | higher-order / indirect call | 1,822 | 809 | −55.6% | 31 |
| `variant_float` | algebraic match + floats | 3,051 | 1,299 | −57.4% | 31 |
| `scaled10` | synthetic ×10 | 6,133 | 4,969 | −19.0% | 105 |
| `scaled40` | synthetic ×40 | 16,897 | 15,908 | −5.9% | 255 |
| `scaled80` | synthetic ×80 | 31,354 | 30,605 | −2.4% | 455 |
| `scaled160` | synthetic ×160 | 60,381 | 60,688 | +0.5% | 855 |

`empty` is generated by the measurement script, not the existing case set —
even the smallest `hello_world` calls `println`, so you cannot read the fixed
cost itself unless you keep a "program that uses nothing" on the side.

`scaledN` is N copies of one set: struct definition + projection + array-alloc
loop + string build. The existing case set is fixed-size, so it cannot give a
slope; only these rows can.

```
slope:     linear 361.7 B/copy, wasm-gc 371.5 B/copy (gc = 102.7% of linear)
intercept: linear 2516 B, wasm-gc 1254 B (fitted, NOT the empty-program size)
residual:  max 366 B off the fitted line (0.6% of the largest point)
crossover: none -- wasm-gc grows at least as fast as linear
```

So on this workload gc starts ~1.3 KB smaller (the helpers each lane links for
"struct + array + string build") and linear catches up by ~10 B per copy; the
two meet around `scaled160`.

## Why it looks like this

Breaking it down by section and by function
(`node scripts/wasm_section_sizes.mjs <file.wasm>`):

| | `empty` linear | `empty` gc | `closure_indirect` linear | `closure_indirect` gc |
|---|---:|---:|---:|---:|
| total | 602 | 527 | 1,822 | 809 |
| code section | 177 | 185 | 1,367 | 441 |
| data section | 171 | 106 | 171 | 106 |
| function count | 3 | 3 | 9 | 6 |
| largest bodies | 154, 10, 8 | 154, 22, 4 | 571, 319, 154, 140, 74 | 163, 154, 57, 23 |

**Both lanes now emit a helper only when something reachable calls it.**
`empty` keeps the same three functions on both lanes (the integer printer
`_start` uses for `main`'s result, `main`, `_start`).

**The allocation runtime is where they part.** On linear, the first heap value
links `__rt_rc_alloc` (319 B: a size-segregated bin pop, then a bounded
free-list walk, then the bump) and `__rt_rc_drop` (571 B: the recursive
per-class release; 870 B for a program that can make a map, whose two arms
are emitted only then). `closure_indirect` carries both, plus `__rt_rc_dup`.
On gc a struct, enum or closure is a `struct.new` the engine collects, so the
same program carries none of it -- the 571 + 319 + 74 B are the bulk of its
1,013 B gap.

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
  allocates** (~1 KB: `__rt_rc_alloc` + `__rt_rc_drop` + `__rt_rc_dup`).
  `__rt_rc_drop` still carries its array, closure, field-vector and ref-cell
  arms whenever it is linked; narrowing those needs the same "can this
  program make that block" evidence the map arms use.
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
