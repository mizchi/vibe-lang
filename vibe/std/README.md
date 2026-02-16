# vibe Core Library (Self-hosted std)

This directory is the vibe core library, self-hosted by porting selected parts of the MoonBit core library.

## Implemented Modules

| Module | Test Count | Description |
|--------|-----------:|-------------|
| `builtin_traits.vibe` | 7 | Trait-oriented generic API (`Eq`/`Ord`/`Add`/`Signed`, `ord_clamp`, `num_abs`) |
| `option.vibe` | 13 | Generic Option helpers (`is_some`, `unwrap_or`, `map_opt`, `map_or`, `or_else`, `equals`) |
| `result.vibe` | 7 | Generic Result helpers (`is_ok`, `is_err`, `map_ok`, `map_err`, `bind`, `unwrap_or`, `to_option`) |
| `cmp.vibe` | 4 | Compare helpers (`int/float/double/string_compare`, `maximum/minimum`, `*_by`, `*_by_key`) |
| `int.vibe` | 14 | Integer helpers (`abs`, `max`, `min`, `clamp`, `pow`, `gcd`, `lcm`, `factorial`, `fibonacci`) |
| `float.vibe` | 7 | Float helpers (`abs`, `signum`, `clamp`, `square`, `lerp`) |
| `double.vibe` | 12 | Double helpers (`abs`, `signum`, `floor`/`ceil`/`round`, `lerp`) |
| `array.vibe` | 3 | Generic array helpers (`length`, `get`, `head`, `last`, `append`, `slice`, `reverse`, `array_map`, `filter`, `fold`, `find`, `any`, `all`) |
| `bool.vibe` | 8 | Boolean helpers (`to_int`, `implies`, `xor`, `nand`, `nor`) |
| `char.vibe` | 3 | ASCII classification/conversion helpers (`is_ascii_*`, `to_ascii_*`, `to_string`, `from_string`) |
| `bytes.vibe` | 5 | Byte array helpers (`is_byte`, `clamp_byte`, `from_ascii`, `to_ascii`, `to_hex`, `from_hex`) |
| `string.vibe` | 19 | String helpers (`equals`, `compare`, `utf8/utf16/unicode length`, `is_blank`, `trim*`, `head`, `tail`, `contains`, `replace*`, `from_char_code`) |
| `io.vibe` | 4 | High-level stdio (`stdout_write`, `stdout_writeln`, `stdin_read`, `stdin_read_line`) |
| `path/ref.vibe` | 2 | PathRef/DynamicPath pure model (`from_literal`, `dynamic`) + member APIs (`as_string`, `is_absolute`) |
| `path/runtime.vibe` | 2 | Path runtime bridge (`resolve`, `DynamicPath::resolve`) |
| `path.vibe` | 3 | Compatibility facade for legacy path API shape |
| `threads/spec.vibe` | 4 | Pure thread deployment specs (`task/channel/actor/deployment_plan`, recommended flags/env) |
| `threads/runtime.vibe` | 2 | Runtime bridge (`probe_wat`, `runtime_hints`, `channel_new`, `spawn`, `send`, `recv`, `wait`) |
| `threads.vibe` | 7 | Compatibility facade for legacy threads API shape |
| `wasm/types.vibe` | 6 | WASM type alias entrypoint (`i32`/`f32`/`f64`, `I32`/`F32`/`F64`) |
| `wasm/opcodes.vibe` | 5 | Opcode-style API (`i32_add`, `i32_div_s`, `f64_promote_f32`, etc.) |
| `wasm/io_stream.vibe` | 3 | WASM stream I/O and ANSI/TUI helpers (`stdin_read`, `stdout_write`, `ansi_escape`) |

`list.vibe` / `map.vibe` / `set.vibe` moved to `vibe/collection`.

Tests are separated into `*_test.vibe` files (for example, `string_test.vibe` for `string.vibe`).

## Module Boundary (Layered Responsibilities)

`vibe/std` is managed as layered modules. See `docs/std-module-boundaries.md` for the canonical table and allowed import matrix.

- `trait-contract`: contracts (`builtin_traits.vibe`)
- `pure-primitive`: pure scalar/string operations (`bool/cmp/char/int/float/double/string`)
- `pure-data`: pure ADT/data operations (`array/option/result/bytes`)
- `ref-model`: path and module reference model (`path/ref` + `path` facade)
- `effect-boundary`: runtime side-effect bridge (`io/path/runtime/threads/runtime`)
- `backend-specific`: backend-specific experimental APIs (`wasm/*`)

Compatibility facades:

- `path.vibe` delegates conceptually to `path/ref.vibe` + `path/runtime.vibe`.
- `threads.vibe` delegates conceptually to `threads/spec.vibe` + `threads/runtime.vibe`.

Boundary enforcement is active in:

- `vibe check`
- `vibe normalize`

## Trait-oriented API Surface

`builtin_traits.vibe` provides the canonical trait-first API:

- `cmp_eq`, `cmp_ne` for equality (`T: Eq`)
- `ord_min`, `ord_max`, `ord_clamp`, `ord_between` for ordering (`T: Ord`)
- `num_add`, `num_sub`, `num_mul`, `num_div`, `num_abs`, `num_square`, `num_clamp`

`option.vibe` now exposes short names as the preferred API:

- `is_some`, `is_none`, `unwrap_or`, `unwrap_or_else`
- `map_opt`, `map_or`, `flatten`, `flatmap`, `filter`, `zip`
- `and`, `or`, `or_else`, `equals`, `zip_sum`
- `option_*` prefixes are no longer exported.
- `map` itself is reserved in vibe syntax, so Option map is named `map_opt`.

`result.vibe` now exposes short names compatible with current vibe parser constraints:

- `is_ok`, `is_err`, `ok`, `err`
- `map_ok`, `map_err`, `map_or`, `bind`, `and_then`, `flatten`
- `unwrap_or`, `unwrap_or_else`, `or`, `or_else`
- `to_option`, `from_option`, `equals_by`
- `map` itself is reserved in vibe syntax, so Result map is named `map_ok`.

Recommended usage (collision-safe, method-style):

```vibe
use ./vibe/std/option.vibe { is_some, unwrap_or }
let ok = Some(1).is_some()
let v = None.unwrap_or(0)
```

## Current Language Gaps Found During Porting

### 1. Trait import/export across modules

- Trait definitions and impls are currently most reliable when kept in the same module where they are used.
- A trait-bounded function imported from another module can require the caller module to re-declare the same trait name.
- Because of this, `builtin_traits.vibe` is intentionally self-contained for now.

### 1.5 Polymorphic recursion

- Basic `let rec [T] ...` recursion is supported.
- Calling the same recursive function at *different* type instantiations inside one body (true polymorphic recursion) is still unsupported.

### 2. Tagged-int range limits (WASM backend)

- Current runtime representation uses 2-bit tagged i64 integers.
- Safe Int range is `-2305843009213693952 .. 2305843009213693951` (62-bit tagged).
- std `int.max_value` / `int.min_value` and double-to-int saturation follow this range.
- Hex literals are supported: `0xFF`, `0X1A2B`.

### 3. `loop` expression (unverified)

- MoonBit-style `loop` expression (tail-recursive optimization syntax) is not available.
- Use `let rec` + pattern matching instead.

### 4. Mutable tail fields (in-place list updates)

- MoonBit-style mutable fields like `More(_, tail~)` are not available.
- Use pure recursive reconstruction instead (less efficient).

## Desired Features (Priority Order)

### Phase 1: Basic language features

1. **Bitwise operators** (`>>`, `<<`, `&`, `|`, `^`) - already planned
2. **`loop` expression** - tail recursion optimization

### Phase 2: Generic improvements

3. **Cross-module trait import/export** - make trait-bounded APIs reusable across module boundaries
4. **Typeclass-style trait methods** - trait contracts with member APIs


### Phase 3: Data structure improvements

5. **Mutable fields** - `enum List { Cons(Int, mut tail: List); Nil }`
6. **Array builtin expansion** - `iter`, `zip`, `flatmap`

## Running Tests

```bash
# Run in interpreter
just run test \
  vibe/std/builtin_traits_test.vibe \
  vibe/std/bool_test.vibe \
  vibe/std/cmp_test.vibe \
  vibe/std/char_test.vibe \
  vibe/std/bytes_test.vibe \
  vibe/std/int_test.vibe \
  vibe/std/float_test.vibe \
  vibe/std/double_test.vibe \
  vibe/std/array_test.vibe \
  vibe/std/option_test.vibe \
  vibe/std/result_test.vibe \
  vibe/std/string_test.vibe \
  vibe/std/io_test.vibe \
  vibe/std/threads_test.vibe \
  vibe/std/wasm/types_test.vibe \
  vibe/std/wasm/opcodes_test.vibe \
  vibe/std/wasm/io_stream_test.vibe

# Validate WASM compilation (import/export usage)
just run compile --wasm vibe/std/test_import.vibe -o /tmp/test.wasm
wasmtime run --invoke run /tmp/test.wasm  # -> 484 (untagged: 121)
```

## Notes

- `vibe/std/test_import.vibe` is only for compilation validation (no `test` blocks).
- `vibe/std/io.vibe` depends on `string_*` builtins, so it is primarily interpreter-oriented rather than pure Core WASM (`--wasm`) today.
- `vibe/std/threads.vibe` では runtime wrappers
  (`probe_wat` / `runtime_hints` / `channel_new` / `spawn` / `send` / `recv` / `wait`)
  の実行に `--unstable-threads` が必要。
  `task_spec` / `channel_spec` / `actor_spec` / `deployment_plan` / `recommended_*` は通常テストで実行可能。
- `vibe/std/wasm/io_stream.vibe` is a stream I/O / TUI helper API for Core WASM components.
