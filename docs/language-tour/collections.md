# Collections

## Array

```vibe
let arr = [1, 2, 3]

// Index access
arr[0]           // => 1
array_get(arr, 2) // => 3

// Length
array_length(arr) // => 3

// Iteration (returns collected array)
for x in arr { x * 2 }   // => [2, 4, 6]

// Higher-order functions (prelude) — collection-first, fn-last
array_map(arr, x -> x * 2)            // => [2, 4, 6]
array_filter(arr, (x: Int) -> Bool { x > 1 })  // => [2, 3]
array_fold(arr, 0, _ + _)             // => 6
array_any(arr, (x: Int) -> Bool { x > 2 })  // => true
array_all(arr, (x: Int) -> Bool { x > 0 })  // => true
array_find(arr, (x: Int) -> Bool { x > 1 }) // => Some(2) (None if not found)

// Concat, reverse, sort, slice
array_concat([1, 2], [3, 4])     // => [1, 2, 3, 4]
array_reverse([1, 2, 3])         // => [3, 2, 1]
array_sort([3, 1, 2])            // => [1, 2, 3]
array_slice([10, 20, 30, 40], 1, 3) // => [20, 30]

// Join (alias for string_join)
array_join(["a", "b", "c"], ", ")  // => "a, b, c"

// Generic — works with any type, not just numbers
array_map(["hi", "there"], (s: String) -> String { string_to_upper(s) })
// => ["HI", "THERE"]
```

### Array Builder

```vibe
let result = do {
  let b = array_builder()
  array_builder_push(b, 1)
  array_builder_push(b, 2)
  array_builder_freeze(b)
}
// => [1, 2]
```

## Map

String-keyed dictionary.

```vibe
// Create with map literal
let m = map { a: 1, "b": 2 }

// Access
map_get(m, "a")     // => 1 (throws if key missing)
map_get_or(m, "c", 0) // => 0 (safe, returns default)
m["a"]              // => 1 (index syntax)

// Query
map_has_key(m, "a") // => true
map_keys(m)         // => ["a", "b"]
map_values(m)       // => [1, 2]

// HOFs
map_map(m, (v: Int) -> Int { v * 10 })       // => map { a: 10, b: 20 }
map_filter(m, (v: Int) -> Bool { v > 1 })    // => map { b: 2 }
```

### Map Builder

```vibe
let m = do {
  let b = map_builder()
  map_builder_set(b, "x", 10)
  map_builder_set(b, "y", 20)
  map_builder_freeze(b)
}
```

## Record

Dynamic key-value object (string keys, mixed values).

```vibe
// Create
let r = record { x: 3, y: 4 }

// Shorthand (variable names as keys)
let x = 1
let y = 2
let r2 = record { x, y }

// Destructure
let record { x, y } = r
// x => 3, y => 4

// Destructure with rename
let record { x: a, y: b } = r
// a => 3, b => 4

// Match
match r {
  record { x: v } => v,
  _ => 0
}
```

## Tuple

```vibe
let pair = (1, "two")
pair.0   // => 1
pair.1   // => "two"

// Destructure
let (a, b) = pair

// Match
match pair {
  (a, b) => a,
  _ => 0
}
```

## JSON

Parse, query, and serialize JSON data.

```vibe
// Parse
let data = from_json("{\"name\": \"vibe\", \"version\": 1}")

// Query
json_type(data)              // => "object"
json_get(data, "name")       // => Json
json_string(json_get(data, "name"))  // => "vibe"
json_number(json_get(data, "version")) // => 1.0

// Array access
let arr = from_json("[1, 2, 3]")
json_index(arr, 0)           // => Json(1)
json_length(arr)             // => 3

// Type checks
json_is_null(from_json("null"))  // => true

// Object keys
json_keys(data)              // => ["name", "version"]

// Serialize
to_json(42)                  // => "42"

// JSONL (newline-delimited JSON)
from_jsonl("{\"a\":1}\n{\"b\":2}")  // => Array[Json]
```

## String as Collection

```vibe
// Length
string_length("hello")       // => 5

// Char access
string_char_code_at("abc", 0) // => 97

// Split / Join
string_split("a,b,c", ",")   // => ["a", "b", "c"]
string_join(["a", "b", "c"], ",") // => "a,b,c"

// Line operations
from_lines("a\nb\nc")        // => ["a", "b", "c"]
to_lines(["a", "b", "c"])    // => "a\nb\nc"
```
