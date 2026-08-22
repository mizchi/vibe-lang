# 12 — Writing tests

Previous: [Modules and packages](11_modules_packages.vibe.md)

日本語版: [12_tests.vibe.md](../ja/12_tests.vibe.md)

A test is a `test "name" { ... }` block written in an ordinary source
file. There is no framework to install and nothing to import.

```vibe
fn double(n: Int) -> Int {
  n * 2
}

test "double works" {
  assert_eq(double(21), 42)
  assert(double(0) == 0)
}
```

By convention they live in files ending `_test.vibe`, so that the build
can leave them out of your shipped package.

```bash
vibe test demo_test.vibe             # one file
vibe test a_test.vibe b_test.vibe    # several
vibe test tests/                     # every *_test.vibe underneath
```

A passing file reports each file and a one-line summary:

```console
$ vibe test demo_test.vibe
ok   demo_test.vibe
[vibe-test] 1 passed, 0 failed (1 files, 1 tests)
```

## When one fails

Change the expected value to 43 and the report names the test, shows
both sides, and stops:

```console
$ vibe test demo_test.vibe
FAIL demo_test.vibe
       failing test: double works
       assert_eq failed
         expected: 43
         actual:   42
       trap: RuntimeError: unreachable
[vibe-test] 0 passed, 1 failed (1 files, 1 tests)
```

The trailing `trap:` line is the assert's implementation showing
through, not a second failure (#2202 tracks removing it, along with
giving the report a line number).

`assert_eq(actual, expected)` works for any type that can be compared,
and compares strings by content — so you can assert directly on a
concatenation or on whatever a function returned, without converting
anything first. `assert(cond)` is for a plain `Bool`.

## `inspect` — let the tool write the expectation

Often you know what a value should *look* like but do not want to type
it out, and you especially do not want to retype it every time the
format changes legitimately. `inspect` puts the expected rendering in
the source, and the tool maintains it:

```vibe
fn double(n: Int) -> Int {
  n * 2
}

test "inspect records the value" {
  inspect(double(3), "6")
}
```

Run with `--update` and any stale expectation is rewritten to what the
code actually produced:

```bash
vibe test --update demo_test.vibe
```

Then you read the diff. That is the workflow: the tool proposes, you
review. It is much better than hand-maintaining a string, and much worse
than `assert_eq` if you have not read the diff — a snapshot you accepted
without looking is a test that asserts nothing.

Use `assert_eq` when you know the answer and it matters. Use `inspect`
for the shape of a bigger structure, where writing it out by hand is the
only thing stopping you from testing it at all.

## Testing what you cannot call directly

Tests live inside the package, so they can reach its internals — a test
file may use modules that consumers cannot, which is what lets you test
a helper without exporting it just for the test. This is the reason
tests belong beside the code rather than in a separate tree.

Next: [Collections](13_collections.vibe.md).
