# xsh Core Library (Self-hosted std)

This directory is the xsh core library, self-hosted by porting selected parts of the MoonBit core library.

## Implemented Modules

| Module | Test Count | Description |
|--------|-----------:|-------------|
| `builtin_traits.xsh` | 7 | Trait-oriented generic API (`Eq`/`Ord`/`Add`/`Signed`, `ord_clamp`, `num_abs`) |
| `option.xsh` | 13 | Generic Option helpers (`is_some`, `unwrap_or`, `map_opt`, `map_or`, `or_else`, `equals`) |
| `int.xsh` | 14 | Integer helpers (`abs`, `max`, `min`, `clamp`, `pow`, `gcd`, `lcm`, `factorial`, `fibonacci`) |
| `float.xsh` | 7 | Float helpers (`abs`, `signum`, `clamp`, `square`, `lerp`) |
| `double.xsh` | 12 | Double helpers (`abs`, `signum`, `floor`/`ceil`/`round`, `lerp`) |
| `list.xsh` | 13 | Generic Cons list helpers (`List[T]`, `map`, `fold`, `filter`, `append`, `contains_by`) |
| `bool.xsh` | 8 | Boolean helpers (`to_int`, `implies`, `xor`, `nand`, `nor`) |
| `string.xsh` | 16 | String helpers (`head`, `tail`, `take`, `drop`, `contains`, `count`, `replace`, `replace_all`) |
| `io.xsh` | 4 | High-level stdio (`stdout_write`, `stdout_writeln`, `stdin_read`, `stdin_read_line`) |
| `threads.xsh` | 7 | Experimental threads contracts (`task/channel/actor/deployment_plan`) + runtime wrappers (`probe_wat`, `runtime_hints`, `channel_new`, `spawn`, `send`, `recv`, `wait`) |
| `wasm/types.xsh` | 6 | WASM type alias entrypoint (`i32`/`f32`/`f64`, `I32`/`F32`/`F64`) |
| `wasm/opcodes.xsh` | 5 | Opcode-style API (`i32_add`, `i32_div_s`, `f64_promote_f32`, etc.) |
| `wasm/io_stream.xsh` | 3 | WASM stream I/O and ANSI/TUI helpers (`stdin_read`, `stdout_write`, `ansi_escape`) |

**Total: 115 tests**

Tests are separated into `*_test.xsh` files (for example, `string_test.xsh` for `string.xsh`).

## Trait-oriented API Surface

`builtin_traits.xsh` provides the canonical trait-first API:

- `cmp_eq`, `cmp_ne` for equality (`T: Eq`)
- `ord_min`, `ord_max`, `ord_clamp`, `ord_between` for ordering (`T: Ord`)
- `num_add`, `num_sub`, `num_mul`, `num_div`, `num_abs`, `num_square`, `num_clamp`

`option.xsh` now exposes short names as the preferred API:

- `is_some`, `is_none`, `unwrap_or`, `unwrap_or_else`
- `map_opt`, `map_or`, `flatten`, `flatmap`, `filter`, `zip`
- `and`, `or`, `or_else`, `equals`, `zip_sum`
- `option_*` prefixes are no longer exported.
- `map` itself is reserved in xsh syntax, so Option map is named `map_opt`.

Recommended usage (collision-safe, method-style):

```xsh
import { is_some, unwrap_or } from "./xsh/std/option.xsh"
let ok = Some(1).is_some()
let v = None.unwrap_or(0)
```

## Current Language Gaps Found During Porting

### 1. Trait import/export across modules

- Trait definitions and impls are currently most reliable when kept in the same module where they are used.
- A trait-bounded function imported from another module can require the caller module to re-declare the same trait name.
- Because of this, `builtin_traits.xsh` is intentionally self-contained for now.

### 1.5 Polymorphic recursion

- Basic `let rec [T] ...` recursion is supported.
- Calling the same recursive function at *different* type instantiations inside one body (true polymorphic recursion) is still unsupported.

### 2. Large negative integer literals

- `-2147483648` is rejected with an overflow parse error
  (`2147483648` exceeds Int range).
- Workaround: `0 - 2147483647 - 1`.

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
  xsh/std/builtin_traits_test.xsh \
  xsh/std/bool_test.xsh \
  xsh/std/int_test.xsh \
  xsh/std/float_test.xsh \
  xsh/std/double_test.xsh \
  xsh/std/list_test.xsh \
  xsh/std/option_test.xsh \
  xsh/std/string_test.xsh \
  xsh/std/io_test.xsh \
  xsh/std/threads_test.xsh \
  xsh/std/wasm/types_test.xsh \
  xsh/std/wasm/opcodes_test.xsh \
  xsh/std/wasm/io_stream_test.xsh

# Validate WASM compilation (import/export usage)
just run compile --wasm xsh/std/test_import.xsh -o /tmp/test.wasm
wasmtime run --invoke run /tmp/test.wasm  # -> 484 (untagged: 121)
```

## Notes

- `xsh/std/test_import.xsh` is only for compilation validation (no `test` blocks).
- `xsh/std/io.xsh` depends on `string_*` builtins, so it is primarily interpreter-oriented rather than pure Core WASM (`--wasm`) today.
- `xsh/std/threads.xsh` では runtime wrappers
  (`probe_wat` / `runtime_hints` / `channel_new` / `spawn` / `send` / `recv` / `wait`)
  の実行に `--unstable-threads` が必要。
  `task_spec` / `channel_spec` / `actor_spec` / `deployment_plan` / `recommended_*` は通常テストで実行可能。
- `xsh/std/wasm/io_stream.xsh` is a stream I/O / TUI helper API for Core WASM components.
