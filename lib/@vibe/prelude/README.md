# vibe Core Library (Self-hosted std)

This directory is the vibe core library, self-hosted by porting selected parts of the MoonBit core library.

## Implemented Modules

| Module | Test Count | Description |
|--------|-----------:|-------------|
| `builtin_traits.vibe` | 8 | Trait-oriented generic API (`Eq`/`Hash`/`Ord`/`Add`/`Signed`, `ord_clamp`, `num_abs`) |
| `option.vibe` | 13 | Generic Option helpers (`is_some`, `unwrap_or`, `map_opt`, `map_or`, `or_else`, `equals`) |
| `cmp.vibe` | 4 | Compare helpers (`int/float/double/string_compare`, `maximum/minimum`, `*_by`, `*_by_key`) |
| `int.vibe` | 14 | Integer helpers (`abs`, `max`, `min`, `clamp`, `pow`, `gcd`, `lcm`, `factorial`, `fibonacci`) |
| `float.vibe` | 7 | Float helpers (`abs`, `signum`, `clamp`, `square`, `lerp`) |
| `double.vibe` | 12 | Double helpers (`abs`, `signum`, `floor`/`ceil`/`round`, `lerp`) |
| `array.vibe` | 4 | Generic array helpers (`length`, `get`, `head`, `last`, `append`, `slice`, `reverse`, `Array::map`, `iter`, `zip`, `flatmap`, `filter`, `fold`, `find`, `any`, `all`) |
| `bool.vibe` | 8 | Boolean helpers (`to_int`, `implies`, `xor`, `nand`, `nor`) |
| `char.vibe` | 3 | ASCII classification/conversion helpers (`is_ascii_*`, `to_ascii_*`, `to_string`, `from_string`) |
| `bytes.vibe` | 5 | Byte array helpers (`is_byte`, `clamp_byte`, `from_ascii`, `to_ascii`, `to_hex`, `from_hex`) |
| `string.vibe` | 19 | String helpers (`equals`, `compare`, `utf8/utf16/unicode length`, `is_blank`, `trim*`, `head`, `tail`, `contains`, `replace*`, `from_char_code`) |
| `io.vibe` | 6 | High-level stdio + ANSI/TUI helpers (`stdout_write`, `stdout_writeln`, `stdin_read`, `stdin_read_line`, `ansi_escape`) |

`list.vibe` / `map.vibe` / `set.vibe` moved to `lib/@vibe/core` (#766).

Tests are separated into `*_test.vibe` files (for example, `string_test.vibe` for `string.vibe`).

## Module Boundary (Layered Responsibilities)

`vibe/prelude` is managed as layered modules. See `docs/adr.md` (ADR-0005) for the canonical table and allowed import matrix.

- `trait-contract`: contracts (`builtin_traits.vibe`)
- `pure-primitive`: pure scalar/string operations (`bool/cmp/char/int/float/double/string`)
- `pure-data`: pure ADT/data operations (`array/option/result/bytes`)
- `effect-boundary`: runtime side-effect bridge (`io`)

Path モジュールは `vibe/path` へ移動済み。
- quick usage: `import /vibe/path { ... }`
- split import:
  - pure model: `import /vibe/path/ref.vibe { ... }`
  - effect bridge: `import /vibe/path/runtime.vibe { ... }`

Boundary enforcement is active in:

- `vibe check`
- `vibe normalize`

## Effect Signature Policy

`vibe/prelude` は pure 層と effect 境界を意図的に分離し、関数シグネチャで副作用を可視化する。

- pure modules (`pure-primitive`, `pure-data`) は `with` row を持たない。
- runtime bridge (`effect-boundary`) は host builtin への薄い委譲に限定し、effect を明示する。
- effect の種類は責務に合わせる:
  - file/path: `with Fs` / `with Env`
  - network: `with Net`
  - stdio: `with Stdin` / `with Stdout`
  - async runtime: `with Async`
- 新規 API を追加する場合、pure 変換ロジックは pure module に置き、effect module には混在させない。
- 実験 API は runtime wrapper 側へ隔離し、必要な unstable flag をドキュメントに明記する。

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

`result.vibe` was removed in #1324 (see the header comment in `index.vpkg`):
`Result` no longer exists as a language- or prelude-provided type. A program
wanting `Ok`/`Err` declares the enum itself like any other user enum; failure
is carried by `Exception[E]` effect rows (ADR-0085).

### Canonical Naming / Alias Policy

`vibe/prelude` では parser 予約語制約を前提に、以下を canonical API 名として扱う。

- Option: `map_opt`, `flatmap`, `map_or`, `unwrap_or`, `unwrap_or_else`
- Array: `Array::map`, `flatmap`, `filter`, `fold`

互換 alias 運用ルール:

1. 新旧 API が併存する期間でも README では canonical 名のみを一次記載する。
2. alias は最低 2 回の minor リリース相当期間を維持する。
3. 期間後は `*_compat` 相当の互換面へ隔離し、既定 import からは外す。
4. 削除前には `vibe normalize` の自動変換候補へ追加し、移行コストを固定化する。

Recommended usage (collision-safe, pipe-first):

```vibe
import /vibe/prelude/option.vibe { is_some, unwrap_or }
let ok = Some(1) |> is_some
let v = None |> unwrap_or(0)
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
6. **Collection iteration expansion** - list/collection への `iter`, `zip`, `flatmap` 展開

## Running Tests

```bash
# Run with the default compiled backend
just run test \
  vibe/prelude/builtin_traits_test.vibe \
  vibe/prelude/bool_test.vibe \
  vibe/prelude/cmp_test.vibe \
  vibe/prelude/char_test.vibe \
  vibe/prelude/bytes_test.vibe \
  vibe/prelude/int_test.vibe \
  vibe/prelude/float_test.vibe \
  vibe/prelude/double_test.vibe \
  vibe/prelude/array_test.vibe \
  vibe/prelude/option_test.vibe \
  vibe/prelude/result_test.vibe \
  vibe/prelude/string_test.vibe \
  vibe/prelude/io_test.vibe

# Validate WASM compilation (import/export usage)
just run compile --wasm vibe/prelude/test_import.vibe -o /tmp/test.wasm
wasmtime run --invoke _start /tmp/test.wasm  # -> 484 (untagged: 121)
```

## Notes

- `vibe/prelude/test_import.vibe` is only for compilation validation (no `test` blocks).
- `vibe/prelude/io.vibe` depends on runtime builtins, so it is exercised via the native/compiled test path rather than pure Core WASM (`--wasm`) today.
