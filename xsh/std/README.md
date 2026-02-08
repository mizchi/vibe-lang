# xsh Core Library (Self-hosted std)

This directory is the xsh core library, self-hosted by porting selected parts of the MoonBit core library.

## Implemented Modules

| Module | Test Count | Description |
|--------|-----------:|-------------|
| `trait_api.xsh` | 6 | Trait-oriented generic API (`Eq`/`Ord`/`Add`/`Signed`, `ord_clamp`, `num_abs`) |
| `option.xsh` | 8 | Generic Option helpers (`option_map`, `option_flatmap`, `option_zip`, `option_equals`) |
| `int.xsh` | 11 | Integer helpers (`abs`, `max`, `min`, `clamp`, `pow`, `gcd`, `lcm`, `factorial`, `fibonacci`) |
| `float.xsh` | 7 | Float helpers (`abs`, `signum`, `clamp`, `square`, `lerp`) |
| `double.xsh` | 10 | Double helpers (`abs`, `signum`, `floor`/`ceil`/`round`, `lerp`) |
| `list.xsh` | 13 | Generic Cons list helpers (`List[T]`, `map`, `fold`, `filter`, `append`, `contains_by`) |
| `bool.xsh` | 8 | Boolean helpers (`to_int`, `implies`, `xor`, `nand`, `nor`) |
| `string.xsh` | 10 | String helpers (`head`, `tail`, `take`, `drop`, `repeat`, `pad`, `contains`, `replace`) |
| `io.xsh` | 4 | High-level stdio (`stdout_write`, `stdout_writeln`, `stdin_read`, `stdin_read_line`) |
| `wasm/types.xsh` | 6 | WASM type alias entrypoint (`i32`/`f32`/`f64`, `I32`/`F32`/`F64`) |
| `wasm/opcodes.xsh` | 5 | Opcode-style API (`i32_add`, `i32_div_s`, `f64_promote_f32`, etc.) |
| `wasm/io_stream.xsh` | 3 | WASM stream I/O and ANSI/TUI helpers (`stdin_read`, `stdout_write`, `ansi_escape`) |

**Total: 91 tests**

## Trait-oriented API Surface

`trait_api.xsh` provides the canonical trait-first API:

- `cmp_eq`, `cmp_ne` for equality (`T: Eq`)
- `ord_min`, `ord_max`, `ord_clamp`, `ord_between` for ordering (`T: Ord`)
- `num_add`, `num_sub`, `num_mul`, `num_div`, `num_abs`, `num_square`, `num_clamp`

`option.xsh` now uses generic signatures:

- `option_is_some`, `option_is_none`, `option_unwrap_or`
- `option_map`, `option_flatten`, `option_flatmap`, `option_filter`
- `option_zip`, `option_equals`
- Compatibility aliases (`is_some`, `is_none`, `unwrap_or`) are kept.

## Current Language Gaps Found During Porting

### 1. Trait import/export across modules

- Trait definitions and impls are currently most reliable when kept in the same module where they are used.
- A trait-bounded function imported from another module can require the caller module to re-declare the same trait name.
- Because of this, `trait_api.xsh` is intentionally self-contained for now.

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
  xsh/std/trait_api.xsh \
  xsh/std/bool.xsh \
  xsh/std/int.xsh \
  xsh/std/float.xsh \
  xsh/std/double.xsh \
  xsh/std/list.xsh \
  xsh/std/option.xsh \
  xsh/std/string.xsh \
  xsh/std/io.xsh \
  xsh/std/wasm/types.xsh \
  xsh/std/wasm/opcodes.xsh \
  xsh/std/wasm/io_stream.xsh

# Validate WASM compilation (import/export usage)
just run compile --wasm xsh/std/test_import.xsh -o /tmp/test.wasm
wasmtime run --invoke run /tmp/test.wasm  # -> 484 (untagged: 121)
```

## Notes

- `xsh/std/test_import.xsh` is only for compilation validation (no `test` blocks).
- `xsh/std/io.xsh` depends on `string_*` builtins, so it is primarily interpreter-oriented rather than pure Core WASM (`--wasm`) today.
- `xsh/std/wasm/io_stream.xsh` is a stream I/O / TUI helper API for Core WASM components.
