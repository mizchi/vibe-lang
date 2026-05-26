# vibe profile findings — 2026-05-26

Hot-spot survey driven by `vibe profile` (the wasmtime GuestProfiler
wrapper added in `6ff80cf`). Compares wasm-gc vs wasm-linear backends
on representative CPU-bound workloads.

## Workloads & wall-clock

| Workload | Linear | wasm-gc | Ratio | Notes |
|---|---:|---:|---:|---|
| `fib(25) × 100` (pure i64 arithmetic) | 82 ms | 64 ms | 0.78× | wasm-gc faster (less boxing overhead in tight recursion) |
| String char-code scan (200 iter × 76-char string) | 10 ms | 10 ms | 1.0× | parity — `String::char_code_at` and `String::length` are cheap on both |
| `String::concat` loop (5000 × single-char append) | 2 ms | 71 ms | **35×** | algorithmic O(N²) dominates on wasm-gc |
| SHA-1 × 1000 (20-byte input, full round-set) | 52 ms | 249 ms | **4.8×** | dominated by `String::concat` inside schedule builder |

## SHA-1 self-time breakdown (wasm-gc, 100 µs sampling)

```
  42.0%  expand::lambda@15:1        (inside build_schedule — schedule extend loop)
  26.5%  word_to_bytes              (4 String::from_char_code + 3 concats per word)
   8.2%  pad_zeros::lambda@15:1     (zero-pad message — concat in a loop)
   7.5%  ushr                       (unsigned right shift helper)
   5.2%  to_hex_char                (hex digit lookup)
   3.0%  build_initial::lambda@15:1 (load first 16 words — concat in a loop)
   1.9%  pad_message                (string concat)
   1.6%  byte_to_hex                (hex pair)
   1.4%  word_to_hex                (4× byte_to_hex + 3 concats)
```

Inclusive (frame appears in stack):
```
  100.0%  _start / main / sha1
   89.6%  process_blocks
   77.4%  build_schedule              ← root of the O(N²) concat tower
   68.3%  expand::lambda@15:1
   33.6%  word_to_bytes
   10.2%  pad_message
```

## Root cause

The hot spots all share a single pattern in
`vibe/sha1/sha1.vibe::build_schedule`:

```vibe
let rec expand = (i: Int, arr: String) -> String {
  if i >= 80 { arr } else {
    let w = rotl(...)
    expand(i + 1, arr|>String::concat(word_to_bytes(w)))  // ← O(len(arr))
  }
}
```

Each iteration re-allocates the full accumulator string and copies it.
The 80-word schedule (320 bytes) is rebuilt 80 times, each copy taking
4 bytes more — total O(N²) bytes copied.

`word_to_bytes` adds another 3 concats per word (4 single-char strings
joined → 1 four-char string), each allocating and copying.

The linear backend hides this better because its `String::concat` is a
single `memory.copy` bulk instruction, with Cranelift compiling it into
a `memcpy` syscall (no per-byte work). wasm-gc has to loop over the
codepoint array with `array.get` + `array.set`.

## Codegen mitigations attempted

1. **`array.copy` (wasm-gc bulk op)** in `compile_string_concat`. Tried
   replacing the per-element `array.get/array.set` loops with a single
   `array.copy x y` (dst, dst_off, src, src_off, len). Validates fine;
   semantically equivalent. **Wasmtime 36 (Cranelift) makes things 45×
   _slower_** (3.4 s vs 74 ms on the 5000-iter concat micro-bench).
   Reverted — the loops produced by Cranelift's auto-vectorization beat
   wasmtime's array-copy fast path on small ranges today. Worth
   revisiting once wasmtime's GC bulk-copy lands an optimised path
   (tracked upstream in bytecodealliance/wasmtime).

2. **Coercion in `eq` / `lt`** (committed in `55ab0d4`). Independent
   correctness fix surfaced while profiling — eq/lt didn't unbox eqref
   operands, so `match Some(v) => eq(v, 7)` failed wasm validation
   when run in batch with other tests. Not a perf finding per se but
   was blocking accurate wasm-gc measurements.

## Actionable items for callers

Until wasmtime's GC bulk-copy gets faster, the following user-side
patterns can avoid the 5–35× slowdown:

- **Don't `acc|>String::concat(small)` in a loop.** Use
  `StringBuilder::push` (added in `a84fbd0`) and `StringBuilder::freeze`
  for a single O(N) concat at the end.
- **For algorithms with random word access** (SHA-1, zlib, …), use
  `Array[Int]` rather than `String` as the working buffer. `Array::get`
  / `Array::push` are O(1) on both backends; `String::char_code_at`
  also works but the byte-stream concat is the trap.
- **Hex / digit conversion** done in tight loops: build into an
  `ArrayBuilder[Int]` (codepoints), `String::from_char_codes` at the
  end. (`from_char_codes` builtin still TBD — see `String::join` for
  the existing batch API.)

## Suggested follow-up issues

- **`vibe/sha1` rewrite**: switch `build_schedule` / `build_initial` /
  `pad_zeros` to `Array[Int]` (64-byte word array). Expected: SHA-1 on
  wasm-gc within 1.5× of linear (currently 4.8×). Out of scope for
  this profile commit.
- **Codegen: `array.copy` revisit** when wasmtime PR for bulk-copy
  optimisation lands. The helper byte sequence (`0xfb 0x11 <dst_type>
  <src_type>`) is recorded in `compile_string_concat`'s comment so the
  experiment is repeatable.
- **Codegen: `String::from_char_codes(Array[Int]) -> String`** builtin
  to fold N single-codepoint creations + N-1 concats into one
  allocation. Would also benefit `word_to_bytes`-style helpers.

## Reproduce

```bash
vibe profile path/to/file.vibe --out /tmp/x.json --interval-us 100
# Drop /tmp/x.json into https://profiler.firefox.com/
# Or read self-time top-N via:
node -e '
const p = JSON.parse(require("fs").readFileSync("/tmp/x.json"));
const t = p.threads[0];
const funcs = t.funcTable.name.map(i => t.stringArray[i]);
const self = new Map();
for (const s of t.samples.stack) {
  if (s === null) continue;
  const n = funcs[t.frameTable.func[t.stackTable.frame[s]]];
  self.set(n, (self.get(n) || 0) + 1);
}
[...self.entries()].sort((a,b) => b[1]-a[1]).slice(0,15).forEach(([n,c]) =>
  console.log(`  ${(c/t.samples.length*100).toFixed(1).padStart(5)}%  ${n}`)
);
'
```
