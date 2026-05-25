# Codegen Dual Backend: structural overview & reduction plan

The vibe codegen currently has **two parallel implementations** of
roughly the same surface area:

- **linear backend** (`src/codegen/wasm_codegen_*.mbt`, 35k lines):
  classic linear-memory wasm with hand-rolled allocator, obj-type
  tagged values, generates `--wasm` / `--wasm-js-string` output. This
  is the default backend for `vibe build --release`, `vibe test`, and
  `vibe bench` today.
- **wasm-gc backend** (`src/codegen/wasm_gc_codegen.mbt`, 9.5k lines):
  uses wasm-gc reference types (struct / array refs) and the wasm-gc
  proposal. Per ADR-0036 this is the "main backend" for the future,
  but in practice the linear backend remains canonical for production.

Most logic is duplicated between them: builtins, type representations,
struct field accessors, closure dispatch, DCE, etc. The dogfood
report (`docs/report/zlib-dogfood-2026-05-23.md`) and follow-on work
hit several bugs that existed in one backend but not the other —
maintenance cost is approximately 2× per change.

## Current parity (measured)

Run `scripts/check_codegen_parity.sh` for an up-to-date picture. As
of 2026-05-25:

| | linear | wasm-gc | both |
|---|---:|---:|---:|
| `*::*` builtins recognized | 169 | 53 | 52 |

Of the 117 linear-only builtins, ~80 are host imports (`Fs::*`,
`Env::*`, `Http::*`, `Io::*`, `Socket::*`) that wasm-gc doesn't yet
plumb. The remaining ~30 are **real core-namespace gaps** that user
code routinely hits on wasm-gc:

- `StringBuilder::{new, push, freeze}` — the whole builder is missing
  in wasm-gc
- `Int::{parse, abs, min, max, clamp, signum, is_even, is_odd}` —
  conversion / utility methods
- `String::{to_lower, to_upper, trim_start, trim_end, count, unicode_length}`
- `Map::{set, delete, has, values}` — mutation API
- `Char::{from_int, to_int}` / `Float::{to_double, to_int}` /
  `Double::{from_i64_bits, to_float}`
- `Bytes::{from_string, to_string}`

## Other parallelism (not just builtins)

Builtins are the visible tip. Behind them, the same concept gets
implemented twice in many places:

| Concern | linear | wasm-gc |
|---|---|---|
| `__index(string, i)` semantics | `wasm_codegen_builtin_collection.mbt:2828` | `wasm_gc_codegen.mbt:6749` |
| `__set_index` | same file | same file, line 7237 |
| `record_set` / struct field assign | none historically; now via `__set_index` (ADR-0052) | dedicated `try_compile_struct_field_set_gc` |
| Bytes data layout | `obj_bytes` tag + linear memory | struct `{ len, cap, data: array<i32> }` |
| String layout | `obj_string` tag + linear memory | struct `{ len, data: array<i32> }` |
| Array layout | `obj_array` + linear memory; growable | raw `array<T>` (fixed-size!); `Array::push` rebinds local |
| Closure | function table + linear-memory env | typed `(ref struct { fn_ref, env })` |
| DCE entry root selection | `dce_module` | `dce_module_gc` |
| iter dispatch | rewrite `iter_get` → `String::iter_get` in monoify | same |
| Coverage instrumentation | implemented | **not implemented** |

## Why this happened

History: linear backend was implemented first (pre-wasm-gc was widely
available). When wasm-gc support landed, it was added as a *second*
backend rather than a refactor of the first — partly because the type
representations are too different (tagged i64 vs typed refs) and
partly because rewriting the linear backend would have been a much
bigger PR.

## Reduction plan (recommended)

### Phase A: visible & cheap (week 1-2)

1. **Parity gate in CI**. Run `scripts/check_codegen_parity.sh` on
   each PR. Exit code 2 if a core-namespace gap appears (i.e., new
   linear builtin without wasm-gc counterpart, or vice versa). Tracks
   new divergence without forcing the existing 30 to be fixed first.
2. **Fill in the cheap core-namespace gaps** in wasm-gc: anything
   that can be implemented in terms of existing wasm-gc primitives
   (StringBuilder ↔ Bytes, Int::abs/min/max ↔ existing arithmetic,
   Map::has ↔ Map::get + null check). ~30 small additions, each a
   one-off PR. Brings wasm-gc up to feature parity for user code that
   doesn't need host imports.

### Phase B: dispatch unification (week 3-6)

3. **Builtin registry**. Introduce a single
   `pub let builtins : Array[BuiltinDecl]` source-of-truth (probably
   in `src/checker/builtin_*.mbt` since the checker already needs
   to know each builtin's type signature). Each entry has:
   - name
   - signature
   - `compile_linear : (Codegen, Args) -> Unit`
   - `compile_gc : (GcCodegen, Args) -> Unit` (or `None` if linear-only)

   The big match-on-name in each backend becomes a table lookup. The
   parity check becomes a static guarantee: each registered builtin
   either has both compile fns or is explicitly marked linear-only
   (with reason).

4. **Migrate one namespace at a time** (Array → Bytes → String → Map →
   Int/Char/Float). Each PR moves N existing handlers into the
   registry without changing behavior, removes the corresponding
   match arms. Ends with the two big switch statements gone.

### Phase C: shared frontend pipeline (week 7+)

5. **Reuse DCE / monoify across backends**. Today `dce_module_gc`
   vs `dce_module` differ only in whether they keep `for-in` helper
   bodies — a flag rather than a separate fn would suffice. Similar
   small unifications for monoify, type-erasure decisions, etc.
6. **Coverage on wasm-gc**. Currently the `--coverage` flag instruments
   only the linear backend. Once #5 is in place, the instrumentation
   pass can be backend-agnostic. Lets selfhost coverage gate move to
   wasm-gc when ready.

### Phase D: cutover (when comfortable)

7. **Switch `vibe build --release` / `vibe test` / `vibe bench`
   defaults to wasm-gc**. Linear remains opt-in via `--wasm` for
   `compile`, and via env vars for test/bench, but isn't the path of
   least resistance. Phase out linear-only host imports
   (`Fs::*` etc.) — wasm-gc components can do FS via WASI P2.
8. **Eventually deprecate linear backend** if there's no clear use
   case left.

Total: 3-6 months of focused work; today's situation is sustainable
short-term as long as Phase A's parity gate is in place.

## Out of scope here

- Component model output is separate (`src/codegen/component_codegen.mbt`),
  wraps either linear or gc into a component. Not part of the dual
  backend problem.
- Selfhost (`vibe/compiler/`) is a separate concern (see AGENTS.md);
  it currently mirrors the linear backend.
