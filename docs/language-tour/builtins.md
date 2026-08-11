# Built-in Functions

## Arithmetic (operators)

These are used via operators, not direct calls.

| Operator | Desugars to | Types |
|----------|-------------|-------|
| `a + b` | `__add(a, b)` | Int, Float, Double |
| `a - b` | `__sub(a, b)` | Int, Float, Double |
| `a * b` | `__mul(a, b)` | Int, Float, Double |
| `a / b` | `__div(a, b)` | Int, Float, Double |
| `a % b` | `__mod(a, b)` | Int, Float, Double |
| `-a` | `__neg(a)` | Int, Float, Double |
| `a == b` | `__eq(a, b)` | Eq types |
| `a < b` | `__lt(a, b)` | Ord types |
| `a & b` | `__bit_and(a, b)` | Int |
| `a \| b` | `__bit_or(a, b)` | Int |
| `a ^ b` | `__bit_xor(a, b)` | Int |
| `a << b` | `__lshift(a, b)` | Int |
| `a >> b` | `__rshift(a, b)` | Int (arithmetic) |
| `a[i]` | `__index(a, i)` | Array, Map |

Prelude wrappers: `add(a, b)`, `sub(a, b)`, `mul(a, b)`, `div(a, b)`, `eq(a, b)`, `lt(a, b)`, `not(b)`, `and(a, b)`, `or(a, b)`.

## String

| Function | Signature | Description |
|----------|-----------|-------------|
| `String::length` | `(String) -> Int` | Length |
| `String::concat` | `(String, String) -> String` | Concatenate |
| `String::substring` | `(String, Int, Int) -> String` | Substring (start, end) |
| `String::char_code_at` | `(String, Int) -> Int` | Char code at index |
| `String::from_char_code` | `(Int) -> String` | String from char code |
| `String::from_char_codes` | `(Array[Int]) -> String` | String from char codes |
| `String::equals` | `(String, String) -> Bool` | Equality |
| `String::split` | `(String, String) -> Array[String]` | Split by separator |
| `String::join` | `(Array[String], String) -> String` | Join with separator |
| `String::contains` | `(String, String) -> Bool` | Contains substring |
| `String::index_of` | `(String, String) -> Int` | Index of substring |
| `String::last_index_of` | `(String, String) -> Int` | Last index of substring |
| `String::starts_with` | `(String, String) -> Bool` | Starts with prefix |
| `String::ends_with` | `(String, String) -> Bool` | Ends with suffix |
| `String::trim` | `(String) -> String` | Trim whitespace |
| `String::trim_start` | `(String) -> String` | Trim leading whitespace |
| `String::trim_end` | `(String) -> String` | Trim trailing whitespace |
| `String::replace` | `(String, String, String) -> String` | Replace first |
| `String::replace_all` | `(String, String, String) -> String` | Replace all |
| `String::to_upper` | `(String) -> String` | Uppercase |
| `String::to_lower` | `(String) -> String` | Lowercase |
| `String::count` | `(String, String) -> Int` | Count occurrences |

## Array (builtins)

| Function | Signature | Description |
|----------|-----------|-------------|
| `Array::length` | `(Array[T]) -> Int` | Length |
| `Array::get` | `(Array[T], Int) -> T` | Get element |
| `Array::slice` | `(Array[T], Int, Int) -> Array[T]` | Slice (start, end) |
| `Array::concat` | `(Array[T], Array[T]) -> Array[T]` | Concatenate |
| `Array::reverse` | `(Array[T]) -> Array[T]` | Reverse |

## Array (prelude)

| Function | Signature | Description |
|----------|-----------|-------------|
| `Array::map` | `(Array[T], (T) -> U) -> Array[U]` | Map function over array |
| `Array::filter` | `(Array[T], (T) -> Bool) -> Array[T]` | Filter by predicate |
| `Array::fold` | `(Array[T], U, (U, T) -> U) -> U` | Fold/reduce |
| `Array::foreach` | `(Array[T], (T) -> Unit) -> Unit` | Iterate with side effects |
| `Array::any` | `(Array[T], (T) -> Bool) -> Bool` | Any element matches |
| `Array::all` | `(Array[T], (T) -> Bool) -> Bool` | All elements match |
| `Array::find` | `(Array[T], (T) -> Bool) -> Option[T]` | Find first match (Some/None) |
| `where` | `(Array[T], (T) -> Bool) -> Array[T]` | Filter (alias) |

## Array Builder

| Function | Signature | Description |
|----------|-----------|-------------|
| `ArrayBuilder::new` | `() -> ArrayBuilder[T]` | Create builder |
| `ArrayBuilder::push` | `(ArrayBuilder[T], T) -> Unit` | Add element |
| `ArrayBuilder::freeze` | `(ArrayBuilder[T]) -> Array[T]` | Convert to array |

`for-in` comprehensions desugar to builder operations internally. `do` is
reserved and is not part of the current surface syntax.

## Map

| Function | Signature | Description |
|----------|-----------|-------------|
| `Map::get` | `(Map[K, V], K) -> V` | Get value by key (throws if missing) |
| `Map::set` | `(Map[K, V], K, V) -> Map[K, V]` | Set key-value (returns new map) |
| `Map::get_or` | `(Map[K, V], K, V) -> V` | Get value or default |
| `Map::has_key` | `(Map[K, V], K) -> Bool` | Check key existence |
| `Map::keys` | `(Map[K, V]) -> Array[K]` | All keys |
| `Map::values` | `(Map[K, V]) -> Array[V]` | All values |

## Map Builder

| Function | Signature | Description |
|----------|-----------|-------------|
| `MapBuilder::new` | `() -> MapBuilder[K, V]` | Create builder |
| `MapBuilder::set` | `(MapBuilder[K, V], K, V) -> Unit` | Set key-value |
| `MapBuilder::freeze` | `(MapBuilder[K, V]) -> Map[K, V]` | Convert to map |

## Record

| Function | Signature | Description |
|----------|-----------|-------------|
| `record_set` | `(Record, String, V) -> Record` | Set field value |

## Math

| Function | Signature | Description |
|----------|-----------|-------------|
| `Int::abs` | `(Int) -> Int` | Absolute value |
| `Int::max` | `(Int, Int) -> Int` | Maximum |
| `Int::min` | `(Int, Int) -> Int` | Minimum |
| `Int::clamp` | `(Int, Int, Int) -> Int` | Clamp to range |
| `Int::signum` | `(Int) -> Int` | Sign (-1, 0, 1) |
| `Int::is_even` | `(Int) -> Bool` | Even check |
| `Int::is_odd` | `(Int) -> Bool` | Odd check |
| `Double::abs` | `(Double) -> Double` | Absolute value |
| `Double::max` | `(Double, Double) -> Double` | Maximum |
| `Double::min` | `(Double, Double) -> Double` | Minimum |
| `Double::floor` | `(Double) -> Double` | Floor |
| `Double::ceil` | `(Double) -> Double` | Ceiling |

## Type Conversion

| Function | Signature |
|----------|-----------|
| `Int::to_float` | `(Int) -> Float` |
| `Int::to_double` | `(Int) -> Double` |
| `Float::to_int` | `(Float) -> Int` |
| `Float::to_double` | `(Float) -> Double` |
| `Double::to_int` | `(Double) -> Int` |
| `Double::to_float` | `(Double) -> Float` |
| `to_string` | `(Any) -> String` |

## IO

| Function | Signature | Effect | Description |
|----------|-----------|--------|-------------|
| `sh` | `(String) -> Unit` | `{Stdout}` | Execute command |
| `sh_lines` | `(String) -> Array[String]` | `{Stdout}` | Execute, return lines |
| `Stdout::write_stream` | `(String) -> Unit` | `{Stdout}` | Write to stdout |
| `Stdout::write_char` | `(Int) -> Unit` | `{Stdout}` | Write char to stdout |
| `Stdin::read_stream` | `(Int) -> String` | `{Stdin}` | Read from stdin |
| `Stdin::read_char` | `() -> Int` | `{Stdin}` | Read char from stdin |
| `Stdin::read_via_stream` | `() -> StdinStream` | `{Stdin}` | Acquire an opaque p3 stdin provider stream |
| `StdinStream::next` | `(StdinStream) -> Int` | `{Async}` | Read one byte, or `-1` after settled EOF |
| `StdinStream::close` | `(StdinStream) -> Unit` | `{Async}` | Settle an early close (idempotent after success) |
| `StdinStream::chunks` | `(StdinStream, Int) -> (() -> Option[String] with Async)` | `-` (pull: `{Async}`) | Pure factory for exact-size binary chunks; caller retains and closes the stream on early stop |

## JSON

| Function | Signature | Description |
|----------|-----------|-------------|
| `Json::stringify` | `(Any) -> String` | Serialize to JSON |
| `Json::parse` | `(String) -> Json` | Parse JSON string |
| `Json::type_of` | `(Json) -> String` | Type name |
| `Json::get` | `(Json, String) -> Json` | Object property |
| `Json::index` | `(Json, Int) -> Json` | Array element |
| `Json::string` | `(Json) -> String` | Extract string |
| `Json::number` | `(Json) -> Double` | Extract number |
| `Json::bool` | `(Json) -> Bool` | Extract bool |
| `Json::is_null` | `(Json) -> Bool` | Null check |
| `Json::length` | `(Json) -> Int` | Length |
| `Json::keys` | `(Json) -> Array[String]` | Object keys |
| `Json::stringify_lines` | `(Array[Json]) -> String` | Array to JSONL |
| `Json::parse_lines` | `(String) -> Array[Json]` | Parse JSONL |

## Line Operations

| Function | Signature | Description |
|----------|-----------|-------------|
| `Lines::parse` | `(String) -> Array[String]` | Split by newlines |
| `Lines::stringify` | `(Array[String]) -> String` | Join with newlines |

## Assertion

| Function | Signature | Description |
|----------|-----------|-------------|
| `assert` | `(Bool) -> Unit` | Assert true |
| `eq` | `(Eq, Eq) -> Bool` | Equality check |
| `assert_eq` | `(Eq, Eq) -> Unit` | Assert equal |

## Path

| Function | Signature | Description |
|----------|-----------|-------------|
| `path` | `(String) -> Path` | Create path object |
