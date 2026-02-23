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
| `string_length` | `(String) -> Int` | Length |
| `string_concat` | `(String, String) -> String` | Concatenate |
| `string_substring` | `(String, Int, Int) -> String` | Substring (start, end) |
| `string_char_code_at` | `(String, Int) -> Int` | Char code at index |
| `string_from_char_code` | `(Int) -> String` | String from char code |
| `string_equals` | `(String, String) -> Bool` | Equality |
| `string_split` | `(String, String) -> Array[String]` | Split by separator |
| `string_join` | `(Array[String], String) -> String` | Join with separator |
| `string_contains` | `(String, String) -> Bool` | Contains substring |
| `string_index_of` | `(String, String) -> Int` | Index of substring |
| `string_last_index_of` | `(String, String) -> Int` | Last index of substring |
| `string_starts_with` | `(String, String) -> Bool` | Starts with prefix |
| `string_ends_with` | `(String, String) -> Bool` | Ends with suffix |
| `string_trim` | `(String) -> String` | Trim whitespace |
| `string_trim_start` | `(String) -> String` | Trim leading whitespace |
| `string_trim_end` | `(String) -> String` | Trim trailing whitespace |
| `string_replace` | `(String, String, String) -> String` | Replace first |
| `string_replace_all` | `(String, String, String) -> String` | Replace all |
| `string_to_upper` | `(String) -> String` | Uppercase |
| `string_to_lower` | `(String) -> String` | Lowercase |
| `string_count` | `(String, String) -> Int` | Count occurrences |

## Array (builtins)

| Function | Signature | Description |
|----------|-----------|-------------|
| `array_length` | `(Array[T]) -> Int` | Length |
| `array_get` | `(Array[T], Int) -> T` | Get element |
| `array_slice` | `(Array[T], Int, Int) -> Array[T]` | Slice (start, end) |
| `array_concat` | `(Array[T], Array[T]) -> Array[T]` | Concatenate |
| `array_reverse` | `(Array[T]) -> Array[T]` | Reverse |

## Array (prelude)

| Function | Signature | Description |
|----------|-----------|-------------|
| `array_map` | `(Array[T], (T) -> U) -> Array[U]` | Map function over array |
| `array_filter` | `(Array[T], (T) -> Bool) -> Array[T]` | Filter by predicate |
| `array_fold` | `(Array[T], U, (U, T) -> U) -> U` | Fold/reduce |
| `array_foreach` | `(Array[T], (T) -> Unit) -> Unit` | Iterate with side effects |
| `array_any` | `(Array[T], (T) -> Bool) -> Bool` | Any element matches |
| `array_all` | `(Array[T], (T) -> Bool) -> Bool` | All elements match |
| `array_find` | `(Array[T], (T) -> Bool) -> Option[T]` | Find first match (Some/None) |
| `where` | `(Array[T], (T) -> Bool) -> Array[T]` | Filter (alias) |

## Array Builder

| Function | Signature | Description |
|----------|-----------|-------------|
| `array_builder` | `() -> ArrayBuilder[T]` | Create builder |
| `array_builder_push` | `(ArrayBuilder[T], T) -> Unit` | Add element |
| `array_builder_freeze` | `(ArrayBuilder[T]) -> Array[T]` | Convert to array |

Builders require `do { ... }` or `for-in` context.

## Map

| Function | Signature | Description |
|----------|-----------|-------------|
| `map_get` | `(Map[T], String) -> T` | Get value by key (throws if missing) |
| `map_get_or` | `(Map[T], String, T) -> T` | Get value or default |
| `map_has_key` | `(Map[T], String) -> Bool` | Check key existence |
| `map_keys` | `(Map[T]) -> Array[String]` | All keys |
| `map_values` | `(Map[T]) -> Array[T]` | All values |

## Map Builder

| Function | Signature | Description |
|----------|-----------|-------------|
| `map_builder` | `() -> MapBuilder[T]` | Create builder |
| `map_builder_set` | `(MapBuilder[T], String, T) -> Unit` | Set key-value |
| `map_builder_freeze` | `(MapBuilder[T]) -> Map[T]` | Convert to map |

## Record

| Function | Signature | Description |
|----------|-----------|-------------|
| `record_set` | `(Record, String, V) -> Record` | Set field value |

## Math

| Function | Signature | Description |
|----------|-----------|-------------|
| `int_abs` | `(Int) -> Int` | Absolute value |
| `int_max` | `(Int, Int) -> Int` | Maximum |
| `int_min` | `(Int, Int) -> Int` | Minimum |
| `int_clamp` | `(Int, Int, Int) -> Int` | Clamp to range |
| `int_signum` | `(Int) -> Int` | Sign (-1, 0, 1) |
| `int_is_even` | `(Int) -> Bool` | Even check |
| `int_is_odd` | `(Int) -> Bool` | Odd check |
| `double_abs` | `(Double) -> Double` | Absolute value |
| `double_max` | `(Double, Double) -> Double` | Maximum |
| `double_min` | `(Double, Double) -> Double` | Minimum |
| `double_floor` | `(Double) -> Double` | Floor |
| `double_ceil` | `(Double) -> Double` | Ceiling |

## Type Conversion

| Function | Signature |
|----------|-----------|
| `int_to_float` | `(Int) -> Float` |
| `int_to_double` | `(Int) -> Double` |
| `float_to_int` | `(Float) -> Int` |
| `float_to_double` | `(Float) -> Double` |
| `double_to_int` | `(Double) -> Int` |
| `double_to_float` | `(Double) -> Float` |
| `to_string` | `(Any) -> String` |

## IO

| Function | Signature | Effect | Description |
|----------|-----------|--------|-------------|
| `sh` | `(String) -> Unit` | `{Stdout}` | Execute command |
| `sh_lines` | `(String) -> Array[String]` | `{Stdout}` | Execute, return lines |
| `stdout_write_stream` | `(String) -> Unit` | `{Stdout}` | Write to stdout |
| `stdout_write_char` | `(Int) -> Unit` | `{Stdout}` | Write char to stdout |
| `stdin_read_stream` | `(Int) -> String` | `{Stdin}` | Read from stdin |
| `stdin_read_char` | `() -> Int` | `{Stdin}` | Read char from stdin |

## JSON

| Function | Signature | Description |
|----------|-----------|-------------|
| `to_json` | `(Any) -> String` | Serialize to JSON |
| `from_json` | `(String) -> Json` | Parse JSON string |
| `json_type` | `(Json) -> String` | Type name |
| `json_get` | `(Json, String) -> Json` | Object property |
| `json_index` | `(Json, Int) -> Json` | Array element |
| `json_string` | `(Json) -> String` | Extract string |
| `json_number` | `(Json) -> Double` | Extract number |
| `json_bool` | `(Json) -> Bool` | Extract bool |
| `json_is_null` | `(Json) -> Bool` | Null check |
| `json_length` | `(Json) -> Int` | Length |
| `json_keys` | `(Json) -> Array[String]` | Object keys |
| `to_jsonl` | `(Array[Json]) -> String` | Array to JSONL |
| `from_jsonl` | `(String) -> Array[Json]` | Parse JSONL |

## Line Operations

| Function | Signature | Description |
|----------|-----------|-------------|
| `from_lines` | `(String) -> Array[String]` | Split by newlines |
| `to_lines` | `(Array[String]) -> String` | Join with newlines |

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
