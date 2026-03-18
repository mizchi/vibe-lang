# Hello from Markdown

This is a vibe program embedded in markdown.

```vibe
let rec fib = (n: Int) -> Int {
  match n {
    0 => 0,
    1 => 1,
    _ => fib(n - 1) + fib(n - 2),
  }
}
```

Tests can be defined in code blocks:

```vibe
test "fib(10) = 55" {
  assert(eq(fib(10), 55))
}
```

This JavaScript block is ignored:

```js
console.log("not vibe")
```
