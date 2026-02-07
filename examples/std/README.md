# xsh Standard Library (Self-hosted)

This directory is an attempt to self-host xsh by porting parts of the MoonBit core library.

## Implemented Modules

| Module | Test Count | Description |
|--------|-----------:|-------------|
| `option.xsh` | 8 | Option helpers (`is_some`, `unwrap_or`, `map`, `flatmap`, `filter`) |
| `int.xsh` | 11 | Integer helpers (`abs`, `max`, `min`, `clamp`, `pow`, `gcd`, `lcm`, `factorial`, `fibonacci`) |
| `float.xsh` | 7 | Float helpers (`abs`, `signum`, `clamp`, `square`, `lerp`) |
| `double.xsh` | 10 | Double helpers (`abs`, `signum`, `floor`/`ceil`/`round`, `lerp`) |
| `list.xsh` | 11 | Cons list helpers (`map`, `fold`, `filter`, `reverse`, `append`, `take`, `drop`) |
| `bool.xsh` | 8 | Boolean helpers (`to_int`, `implies`, `xor`, `nand`, `nor`) |
| `string.xsh` | 10 | String helpers (`head`, `tail`, `take`, `drop`, `repeat`, `pad`, `contains`, `replace`) |
| `io.xsh` | 4 | High-level stdio (`stdout_write`, `stdout_writeln`, `stdin_read`, `stdin_read_line`) |
| `wasm/types.xsh` | 6 | WASM type alias entrypoint (`i32`/`f32`/`f64`, `I32`/`F32`/`F64`) |
| `wasm/opcodes.xsh` | 5 | Opcode-style API (`i32_add`, `i32_div_s`, `f64_promote_f32`, etc.) |
| `wasm/io_stream.xsh` | 3 | WASM stream I/O and ANSI/TUI helpers (`stdin_read`, `stdout_write`, `ansi_escape`) |

**Total: 83 tests**

## Language Gaps Found During Porting

During porting, the following language limitations became visible:

### 1. Generic limitations
- `Option[Int]` and `Option[(Int, Int)]` are distinct types, but cannot currently be handled by one shared function in all cases.
- There is no full parametric polymorphism flow yet, so some functions must still be duplicated per type.

**Desired style**
```xsh
let option_zip = [A, B](a: Option[A], b: Option[B]) -> Option[(A, B)] { ... }
```

**Current workaround**
```xsh
// define per-type variants
let option_zip_int = (a: Option[Int], b: Option[Int]) -> Option[Int] { ... }
```

### 2. Large negative integer literals
- `-2147483648` can fail to parse (`2147483648` exceeds Int range).
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
3. **Type parameters** - `fn[A](x: A) -> A` style
4. **Trait bounds** - `fn[A: Show](x: A) -> String`

### Phase 3: Data structure improvements
5. **Mutable fields** - `enum List { Cons(Int, mut tail: List) }`
6. **Array builtin expansion** - `iter`, `zip`, `flatmap`

## Next Porting Candidates

Candidates that are possible with current language features:
- `string.xsh` - string utility helpers
- `tuple.xsh` - tuple helpers
- `result.xsh` - Result type helpers (already representable with `enum`)
- `math.xsh` - math helpers (Float/Double variants)

Candidates after stronger generics:
- `array.xsh` - typed higher-order array helpers
- `hashmap.xsh` - hash map
- `set.xsh` - set

## Running Tests

```bash
# Run in interpreter
just run test \
  examples/std/bool.xsh \
  examples/std/int.xsh \
  examples/std/float.xsh \
  examples/std/double.xsh \
  examples/std/list.xsh \
  examples/std/option.xsh \
  examples/std/string.xsh \
  examples/std/io.xsh \
  examples/std/wasm/types.xsh \
  examples/std/wasm/opcodes.xsh \
  examples/std/wasm/io_stream.xsh

# Validate WASM compilation (import/export usage)
just run compile --wasm examples/std/test_import.xsh -o /tmp/test.wasm
wasmtime run --invoke run /tmp/test.wasm  # -> 484 (untagged: 121)
```

## Notes

- `examples/std/test_import.xsh` is only for compilation validation (no `test` blocks).
- `examples/std/io.xsh` depends on `string_*` builtins, so it is primarily interpreter-oriented rather than pure Core WASM (`--wasm`) today.
- `examples/std/wasm/io_stream.xsh` is a stream I/O / TUI helper API for Core WASM components.
