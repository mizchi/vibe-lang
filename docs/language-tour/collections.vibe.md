# Collections

## Array

```vibe
let arr = [1, 2, 3]

test "array basics" {
  // Index access
  assert(eq(arr[0], 1))
  assert(eq(Array::get(arr, 2), 3))
  assert(eq(Array::length(arr), 3))

  // Higher-order functions — collection-first, fn-last
  let doubled = Array::map(arr, (x) -> { x * 2 })       // [2, 4, 6]
  let filtered = Array::filter(arr, (x) -> { x > 1 })   // [2, 3]
  let sum = Array::fold(arr, 0, (acc, x) -> { acc + x })  // 6
  assert(eq(sum, 6))

  assert(Array::any(arr, (x) -> { x > 2 }))   // true
  assert(Array::all(arr, (x) -> { x > 0 }))   // true

  // find returns Option[T]
  let found = Array::find(arr, (x) -> { x > 1 })  // Some(2)

  // Concat, reverse, sort, slice
  let merged = Array::concat([1, 2], [3, 4])         // [1, 2, 3, 4]
  let rev = Array::reverse([1, 2, 3])                // [3, 2, 1]
  let sliced = Array::slice([10, 20, 30, 40], 1, 3)  // [20, 30]
}
```

### Array Builder

`do` is reserved and is not part of the current surface syntax. Prefer
`for-in` for collected array expressions:

```vibe
let result = for x in [1, 2] { x }
```

## Map

String-keyed dictionary.

```vibe
// Richer Map API (get_or etc.) lives in lib/@vibe/core (#766)
import ./lib/@vibe/core { get_or }

// Create with the Map:: API (#960: the map literal was removed)
let m = Map::from_pairs([("a", 1), ("b", 2)])

test "map operations" {
  // Access
  assert(eq(Map::get(m, "a"), 1))       // throws if key missing
  assert(eq(get_or(m, "c", 0), 0))      // safe, returns default
  assert(eq(m["a"], 1))                 // index syntax

  // Query
  assert(Map::has_key(m, "a"))
  let keys = Map::keys(m)     // ["a", "b"]
  let vals = Map::values(m)   // [1, 2]
}
```

### Map Builder

Builder internals are intentionally not part of the standard syntax path.
Use map literals for ordinary source code.

## Record

Dynamic key-value object (string keys, mixed values).

```vibe
// Create
let r = record { x: 3, y: 4 }

// Shorthand (variable names as keys)
let x = 1
let y = 2
let r2 = record { x, y }

// Destructure — inside a fn/test body (top-level record destructure is
// currently a parse error, #830)
test "record destructure" {
  let record { x, y } = r
  // x => 3, y => 4
  assert(eq(x + y, 7))

  // Destructure with rename
  let record { x: a, y: b } = r
  // a => 3, b => 4
  assert(eq(a + b, 7))
}

// Match
let mx = match r {
  record { x: v } => v,
  _ => 0
}
```

## Tuple

```vibe
let pair = (1, "two")
let p0 = pair.0   // => 1
let p1 = pair.1   // => "two"

// Destructure
let (a, b) = pair

// Match
let first = match pair {
  (a2, b2) => a2,
  _ => 0
}
```

## JSON

Parse, query, and serialize JSON data.

```vibe
// Convenience surface (throwing accessors), alongside the Result-based
// primitives (`parse`, `Json::get`, `json_as_*`) — all declared in the
// @vibe/json package contract (index.vpkg, #897).
import ./lib/@vibe/json {
  Json::parse, Json::type_of, Json::string, Json::field,
  Json::length, Json::is_null, Json::keys
}

test "json" {
  let data = Json::parse("{\"name\": \"vibe\", \"version\": 1}")

  // Query
  assert(String::equals(Json::type_of(data), "object"))
  // object field accessor is Json::field (Json::get is the Result-based one)
  assert(String::equals(Json::string(Json::field(data, "name")), "vibe"))

  // Array access
  let arr = Json::parse("[1, 2, 3]")
  assert(eq(Json::length(arr), 3))

  // Type checks
  assert(Json::is_null(Json::parse("null")))

  // Object keys
  let keys = Json::keys(data)   // ["name", "version"]

  // Serialize
  // Json::stringify(42)         => "42"
}
```

## String as Collection

```vibe
import @vibe/prelude { Lines::parse, Lines::stringify }

test "string as collection" {
  assert(eq(String::length("hello"), 5))
  assert(eq(String::char_code_at("abc", 0), 97))

  let parts = String::split("a,b,c", ",")   // ["a", "b", "c"]
  let joined = String::join(parts, ",")      // "a,b,c"

  let lines = Lines::parse("a\nb\nc")        // ["a", "b", "c"]
  let text = Lines::stringify(lines)         // "a\nb\nc"
}
```
