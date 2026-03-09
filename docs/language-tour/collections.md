# Collections

## Array

```vibe
let arr = [1, 2, 3]

// Index access
arr[0]           // => 1
Array::get(arr, 2) // => 3

// Length
Array::length(arr) // => 3

// Iteration (returns collected array)
for x in arr { x * 2 }   // => [2, 4, 6]

// Higher-order functions (prelude) — collection-first, fn-last
Array::map(arr, x -> x * 2)            // => [2, 4, 6]
Array::filter(arr, (x: Int) -> Bool { x > 1 })  // => [2, 3]
Array::fold(arr, 0, _ + _)             // => 6
Array::any(arr, (x: Int) -> Bool { x > 2 })  // => true
Array::all(arr, (x: Int) -> Bool { x > 0 })  // => true
Array::find(arr, (x: Int) -> Bool { x > 1 }) // => Some(2) (None if not found)

// Concat, reverse, sort, slice
Array::concat([1, 2], [3, 4])     // => [1, 2, 3, 4]
Array::reverse([1, 2, 3])         // => [3, 2, 1]
Array::sort([3, 1, 2])            // => [1, 2, 3]
Array::slice([10, 20, 30, 40], 1, 3) // => [20, 30]

// Join (alias for String::join)
Array::join(["a", "b", "c"], ", ")  // => "a, b, c"

// Generic — works with any type, not just numbers
Array::map(["hi", "there"], (s: String) -> String { String::to_upper(s) })
// => ["HI", "THERE"]
```

### Array Builder

```vibe
let result = do {
  let b = ArrayBuilder::new()
  ArrayBuilder::push(b, 1)
  ArrayBuilder::push(b, 2)
  ArrayBuilder::freeze(b)
}
// => [1, 2]
```

## Map

String-keyed dictionary.

```vibe
// Create with map literal
let m = map { a: 1, "b": 2 }

// Access
Map::get(m, "a")     // => 1 (throws if key missing)
Map::get_or(m, "c", 0) // => 0 (safe, returns default)
m["a"]              // => 1 (index syntax)

// Query
Map::has_key(m, "a") // => true
Map::keys(m)         // => ["a", "b"]
Map::values(m)       // => [1, 2]

// HOFs
Map::map(m, (v: Int) -> Int { v * 10 })       // => map { a: 10, b: 20 }
Map::filter(m, (v: Int) -> Bool { v > 1 })    // => map { b: 2 }
```

### Map Builder

```vibe
let m = do {
  let b = MapBuilder::new()
  MapBuilder::set(b, "x", 10)
  MapBuilder::set(b, "y", 20)
  MapBuilder::freeze(b)
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
let data = Json::parse("{\"name\": \"vibe\", \"version\": 1}")

// Query
Json::type_of(data)              // => "object"
Json::get(data, "name")       // => Json
Json::string(Json::get(data, "name"))  // => "vibe"
Json::number(Json::get(data, "version")) // => 1.0

// Array access
let arr = Json::parse("[1, 2, 3]")
Json::index(arr, 0)           // => Json(1)
Json::length(arr)             // => 3

// Type checks
Json::is_null(Json::parse("null"))  // => true

// Object keys
Json::keys(data)              // => ["name", "version"]

// Serialize
Json::stringify(42)                  // => "42"

// JSONL (newline-delimited JSON)
Json::parse_lines("{\"a\":1}\n{\"b\":2}")  // => Array[Json]
```

## String as Collection

```vibe
// Length
String::length("hello")       // => 5

// Char access
String::char_code_at("abc", 0) // => 97

// Split / Join
String::split("a,b,c", ",")   // => ["a", "b", "c"]
String::join(["a", "b", "c"], ",") // => "a,b,c"

// Line operations
Lines::parse("a\nb\nc")        // => ["a", "b", "c"]
Lines::stringify(["a", "b", "c"])    // => "a\nb\nc"
```
