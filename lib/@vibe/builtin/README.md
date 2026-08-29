# vibe Core Library (Self-hosted std)

This directory is the vibe core library, self-hosted by porting selected parts of the MoonBit core library.

## Implemented Modules

| Module | Test Count | Description |
|--------|-----------:|-------------|
| `builtin_traits.vibe` | 8 | Trait-oriented generic API (`Eq`/`Hash`/`Ord`/`Add`/`Signed`, `ord_clamp`, `num_abs`) |
| `iterator.vibe` | 7 | Finite indexed `Iterator[T]` protocol and eager `Iterator::*` operations for Array, String, Map, and user collections |
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

`list.vibe` / `map.vibe` / `set.vibe` moved to `lib/@vibe/core` (#766).
`io.vibe` is gone (#2102): the stdio wrappers duplicated names
`@vibe/console` already published (and `println` / `print` are compiler
builtins), and `ansi_escape` / `tui_*` / `tap` / `tap_some` moved to
`@vibe/console`. Nothing in this package carries an effect row now.

Tests are separated into `*_test.vibe` files (for example, `string_test.vibe` for `string.vibe`).

## Module Boundary (Layered Responsibilities)

`@vibe/builtin` is managed as layered modules. See `docs/adr.md` (ADR-0005) for the canonical table and allowed import matrix.

- `trait-contract`: contracts (`builtin_traits.vibe`)
- `pure-primitive`: pure scalar/string operations (`bool/cmp/char/int/float/double/string`)
- `pure-data`: pure ADT/data operations (`array/option/result/bytes`)
- `effect-boundary`: **empty since #2102** — `io.vibe` moved to
  `@vibe/console`, so this package is pure layers only

Path モジュールは `vibe/path` へ移動済み。
- quick usage: `import /vibe/path { ... }`
- split import:
  - pure model: `import /vibe/path/ref.vibe { ... }`
  - effect bridge: `import /vibe/path/runtime.vibe { ... }`

Boundary enforcement is active in:

- `vibe check`
- `vibe normalize`

## Effect Signature Policy

`@vibe/builtin` は pure 層と effect 境界を意図的に分離し、関数シグネチャで副作用を可視化する。
#2102 以降このパッケージに effect 境界は残っていない（`io.vibe` は
`@vibe/console` へ移動）。以下は境界を再び足す場合の規則。

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

`iterator.vibe` provides the finite collection protocol and its eager transform
surface. Trait-associated operations stay in the trait namespace instead of
adding bare top-level names. Importing the trait is sufficient to make its
exported namespaced operations visible:

```vibe
import @vibe/builtin { trait Iterator }

let arrays = [1, 2]
  |> Iterator::map((x) -> { x + 1 })
  |> Iterator::map((x) -> { x * 2 })
```

Implementing `Iterator` with `iter_length` and `iter_get` makes
`Iterator::map`, `filter`, `fold`, `find`, `any`, `all`, and `flatmap`
available. These eager operations return arrays where applicable. Array calls
devirtualize to the existing `Array::*` intrinsics; Map key iteration uses a
direct storage read and does not allocate `Map::keys` per element. `AsyncIter`
is a separate pull layer with its own `AsyncIter::*` operations (ADR-0099/0110).

`option.vibe` exposes these additional Option-specific helpers:

- `is_some`, `is_none`, `unwrap_or`, `unwrap_or_else`
- `map_opt`, `map_or`, `flatten`, `flatmap`, `filter`, `zip`
- `and`, `or`, `or_else`, `equals`, `zip_sum`
- `option_*` prefixes are no longer exported.
- `map_opt` remains the explicit Option-specific helper. Option does not
  implement the finite indexed `Iterator` protocol.

`result.vibe` was removed in #1324 (see the header comment in `index.vpkg`):
`Result` no longer exists as a language- or library-provided type. A program
wanting `Ok`/`Err` declares the enum itself like any other user enum; failure
is carried by `Exception[E]` effect rows (ADR-0085).

### Canonical Naming / Alias Policy

`@vibe/builtin` では parser 予約語制約を前提に、以下を canonical API 名として扱う。

- Finite collection transform: `Iterator::map` through `Iterator[T]`
- Option-specific: `map_opt`, `flatmap`, `map_or`, `unwrap_or`, `unwrap_or_else`
- Array: `Array::map`, `flatmap`, `filter`, `fold`

互換 alias 運用ルール:

1. 新旧 API が併存する期間でも README では canonical 名のみを一次記載する。
2. alias は最低 2 回の minor リリース相当期間を維持する。
3. 期間後は `*_compat` 相当の互換面へ隔離し、既定 import からは外す。
4. 削除前には `vibe normalize` の自動変換候補へ追加し、移行コストを固定化する。

Recommended usage (collision-safe, pipe-first):

```vibe
import @vibe/builtin/option.vibe { is_some, unwrap_or }
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
- Safe Int range is `-4611686018427387904 .. 4611686018427387903` (63-bit; the tagged runtime representation's width, #1877).
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
# every test in the package
bash scripts/vibe_test.sh lib/@vibe/builtin

# one file
bash scripts/vibe_test.sh lib/@vibe/builtin/string_test.vibe
```

`scripts/vibe_test.sh` takes any number of files or directories. It compiles
with the **committed seed** by default; when you are testing a change to the
compiler itself, pass `VIBE_TEST_CLI_WASM=<stage2.wasm>` or the run answers for
a compiler that does not contain it.

This section previously showed `just run test <13 files>` and
`just run compile --wasm @vibe/builtin/test_import.vibe`. There is no Justfile
— the runner is pkfire — and three of those paths had moved: `test_import.vibe`
is now `test_import_test.vibe`, `io_test.vibe` moved to `@vibe/console`, and
`result_test.vibe` is gone.

## Notes

- `@vibe/builtin/test_import_test.vibe` exists to validate that a module's
  import/export surface compiles.
- `@vibe/console/tui.vibe` (formerly `@vibe/builtin/io.vibe`) depends on runtime
  builtins, so it is exercised through the compiled test path rather than as
  pure Core WASM.
