# blake3 vs sha1 vs compact_string_fingerprint — bench (2026-08-01)

Primary measurement for replacing the cache/fingerprint hash with blake3
(or an algorithm that SIMD-izes more readily). `lib/@vibe/blake3` holds a
pure-vibe BLAKE3 (spec-complete, checked against the official test vectors
in `blake3_test.vibe`), compared with the existing implementations via
`vibe bench` (linear backend, 1000 iters, viberun/wasmtime).

New writes later switched to `pkg:b3:` / `ct:b3:` (#2829). The pin
spellings below are the 2026-08-01 state this measurement was taken in.

## Setup: where sha1 is actually used

- **The runtime cache key is not sha1**: the persistent-cache fingerprint
  (`lib/@vibe/cache/cache.vibe`) is `compact_string_fingerprint` — two
  31-bit polynomial rolling hashes (`len:h1:h2`, effectively ~62-bit).
- **sha1's real uses** are the contract/package content hashes
  (`ct:sha1:<40hex>` / `pkg:sha1:<40hex>`, the pin check in ADR-0004 /
  ADR-0065, `lib/@vibe/compiler/contract/contract.vibe`) and the generated
  artifact fingerprint in `scripts/generate_bundle.sh`. Collision
  resistance only matters on that side.

## Results (mean ns/op; alloc is bump-heap delta bytes/op)

Input construction happens inside the bench block, so a net figure that
subtracts `baseline make_a` (construction only) is listed as well. The
three bench files share the same 1KiB/8KiB + baseline cases
(`sha1_bench.vibe` / `blake3_bench.vibe` / `cache_bench.vibe`).

| case | sha1 | blake3 | compact_string_fingerprint |
|---|---:|---:|---:|
| empty | 17.6 µs / 3.4 KiB | 8.4 µs / 2.2 KiB | 0.23 µs / 56 B |
| medium (108 B) | 27.9 µs / 3.4 KiB | 15.6 µs / 3.2 KiB | 1.11 µs / 128 B |
| 1 KiB (net) | ~221 µs / ~20.8 KiB | ~101 µs / ~18.2 KiB | ~9.8 µs / ~0.1 KiB |
| 8 KiB (net) | ~1593 µs / ~142 KiB | ~891 µs / ~145 KiB | ~76 µs / ~0.1 KiB |
| throughput (8 KiB net) | ~5.1 MB/s | ~9.2 MB/s | ~107 MB/s |

## Addendum (same day): remeasure after scratch reuse

Net figures after packing compress working arrays (state/message words)
into a per-call `Scratch` reused across every block/chunk, and pre-sizing
the String→Bytes conversion (`blake3.vibe`):

| case | blake3 (first cut) | blake3 (scratch reuse) |
|---|---:|---:|
| 1 KiB net | ~101 µs / ~18.2 KiB | ~92 µs / **~4.3 KiB** |
| 8 KiB net | ~891 µs / ~145 KiB | ~751 µs / **~22.5 KiB** |

Allocations drop to about 1/6 (what remains is mostly the input Bytes
conversion plus per-chunk/parent CVs and deferred blocks). Time improves
~16%. The ratio vs sha1 widens to **2.1×**.

## Addendum (same day): SIMD ceiling (wasmtime, native-quality codegen)

To bound "an algorithm that is fast with SIMD", the Rust blake3 crate
(official SIMD) and sha1 crate were compiled to wasm32-wasip1 and measured
on the same wasmtime (input = `i % 251` pattern):

| case | sha1 (scalar) | blake3 (scalar) | blake3 (+simd128, wasm32_simd) |
|---|---:|---:|---:|
| 1 KiB | 2.68 µs (382 MB/s) | 1.90 µs (539 MB/s) | 1.38 µs (740 MB/s) |
| 8 KiB | 20.5 µs (400 MB/s) | 16.2 µs (506 MB/s) | **6.86 µs (1195 MB/s)** |
| 64 KiB | 161 µs (408 MB/s) | 129 µs (509 MB/s) | **56.7 µs (1157 MB/s)** |

- BLAKE3 is **2.3–2.4× scalar** with simd128. SHA-1 gets nothing from SIMD
  (it does not vectorize structurally).
- The ~46× gap between pure-vibe blake3 (~11 MB/s) and native-quality
  scalar (506 MB/s) is codegen quality (bounds checks / boxing / call
  cost). Headroom on the codegen side dominates before SIMD.

### Addendum (same evening): SIMD compress via inline wasm — 4–6.6× scalar

The three walls in the "not possible yet" section below were lifted by a
compiler extension (same branch):

1. **`(local ...)` declarations for v128/i32/i64** in inline wasm
   (`compile_inline_wat_full` plus a v128 run in the code-entry locals
   header, with `meta_v128` running alongside `bodies` / `meta_i32` /
   `meta_i64`).
2. **Bytes params allowed** — a raw untagged object pointer is passed;
   `i32.load offset=8` is the data pointer and `offset=4` is the length
   (the buffer-address intrinsic is this shape, not a new builtin).
3. **`i8x16.shuffle`** (16 lane-byte immediates) added to the WAT
   assembler.

That let a 1-block full BLAKE3 compression land as a flat WAT kernel in
`lib/@vibe/blake3/simd/simd.vibe` (the instruction stream is a Python
generator plus an instruction-level simulator, checked against every
official vector before emission. Rows layout; the message schedule
gathers each round's 4 vectors from m0..m3 through a 2-input shuffle
tree; diagonalize is r1/r2/r3 lane rotation). `simd_test.vibe` pins the
official vectors and scalar/simd agreement on hardware.

vibe bench (net of baseline, same wasmtime):

| case | scalar blake3 | **simd blake3** | sha1 | current cache key |
|---|---:|---:|---:|---:|
| 1 KiB | ~94 µs | **~14 µs (~72 MB/s)** | ~221 µs | ~9.8 µs |
| 8 KiB | ~799 µs | **~202 µs (~41 MB/s)** | ~1593 µs | ~76 µs |

- The SIMD kernel is **4–6.6×** scalar vibe and **8–16×** sha1.
- It is nearly even with the current `compact_string_fingerprint`
  (14 vs 9.8 µs at 1KiB), so a collision-resistant hash is in the
  practical range.
- Residual vs the native SIMD ceiling (~1.2 GB/s) is per-call overhead
  (RC dup/drop + call) and Bytes construction on the driver side.
  Thickening the kernel to a chunk would shrink that further.

### (History) SIMD compress via inline wasm (`= wasm`, ADR-0072) was initially impossible

Matching the then-current inline wasm constraints (v0.3 slice) against
`fixtures/inline_wasm_test.vibe`:

1. **No v128 locals** — locals were only the fn's i64 params. BLAKE3
   compress has to keep 4 v128 rows across 7 rounds; a folded expression
   with no locals cannot reuse a row (fan-out).
2. **No pointer** — there was no way to get the linear-memory address of
   a `Bytes` / `Int64Array`, so `v128.load` could not read message words.
   Passing them as params would unroll to 27 i64 params (16 words + cv 8
   + counter/blen/flags) and the re-pack into SIMD lanes would eat the
   win.
3. No `call`, so the G function could not be split into functions either.

→ In-vibe SIMD needed a compiler extension (v128 locals / a buffer-address
intrinsic / allowing `call`). Until then the realistic speedups were
(a) codegen quality (eliding bounds checks, etc.) or (b) a host builtin
on viberun (native blake3) — but (b) forces a host import onto the
pure/component target, so it should stay limited to contract hashing
(closed inside the compiler).

## How to read this

1. **blake3 is 1.8–2.2× faster than sha1** (same-condition pure-vibe
   implementations). BLAKE3's round structure is shallower (7
   rounds/block vs 80), so the gap shows even under 32-bit emulation.
   The digest is 256-bit and collision-resistant in a way sha1 (known
   collisions) is not.
2. **Allocations are roughly equal** (~18 B / input byte). Both allocate
   a per-block word array each time. blake3's main cost is
   state/m1/m2 (48 words) + block words per compress; a scratch buffer
   reused across chunk processing can cut that a lot.
3. **The current runtime cache key (`compact_string_fingerprint`) is
   about 10× faster than blake3 and essentially zero-alloc**. Replacing
   the hot path of the runtime cache with blake3 is a pure performance
   regression; the only motive is "do we need collision resistance?"
   While a ~62-bit weak hash is enough, there is little reason to
   switch.
4. **The real replacement target is the contract/pin hash
   (`ct:sha1:` / `pkg:sha1:`).** Collision resistance matters there, and
   the frequency is low (publish / pin check only), so blake3's speed
   edge is a bonus. The hash form is frozen as `#pkg:sha1:<40hex>` in
   ADR-0004/0065 and `vibe hash`, so the move is a format migration
   (`pkg:b3:<64hex>`) — every pin has to be rewritten.
5. **SIMD path**: inline wasm (`= wasm`, ADR-0072, linear backend only)
   already supports v128/SIMD opcodes. BLAKE3 is designed for SIMD
   (4-lane G function in parallel), so writing one compression as
   inline wasm is the next step. The then-current inline wasm could not
   `call` and locals were params only, so an 80+ instruction compress
   would have to expand inside one function.

## Reproduce

```bash
bash scripts/build_cli_wasm.sh            # dist/cli/vibe-cli.wasm
bash install/install.sh --cli-wasm dist/cli/vibe-cli.wasm
vibe test  lib/@vibe/blake3/blake3_test.vibe
vibe bench lib/@vibe/blake3/blake3_bench.vibe
vibe bench lib/@vibe/core/sha1_bench.vibe
vibe bench lib/@vibe/cache/cache_bench.vibe
```
