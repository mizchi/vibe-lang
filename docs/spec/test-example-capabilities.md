# Test, bench and example rows

**Status:** implemented (#1508, ADR-0088)
**Related:** #819 (merged doctest compile), #1508 (test/bench effect row),
ADR-0088 (`allows`, the entry grant)

## The rule

A `test`, `bench` or `example` block is an entry point: nothing calls it, so
the row written after its name is a **grant** and the keyword is `allows`,
exactly as on `fn main allows ..`.

```vibe skip
// doctest-skip: form catalogue, not a compilable program
test "pure" {
  assert_eq(1, 1)
}

test "reads a fixture" allows Fs::read_file {
  let _ = Fs::read_file("fixtures/input.txt")
  assert(true)
}

bench "http_get" allows Http {
  let h = Http::request("GET", "http://127.0.0.1:18281/hello", "", "")
  Http::close(h)
}

example "add returns the sum" allows Console {
  println("\{add(1, 2)}")
}
```

## The row widens the ambient default

Test execution supplies an ambient row -- the standard host providers plus
`Exception` -- so that `assert` (which reports through `Exception`) and
ordinary scaffolding need no declaration. The row a block declares **widens**
that default; it does not replace it. `allows Http` therefore adds the one
capability the default deliberately leaves out (network) and keeps
everything else. The default is `test_bench_default_effects` in
`lib/@vibe/compiler/core/standard_effect_policy.vibe`:

```text
Fs, Env, Stdin, Stdout, Stderr, Console, Process, Profiler, Error, Exception
```

A declared row may name an effect, an operation (`Http::request`), or an
`effectset` the program declares; the effectset is expanded before the block
is checked. An anonymous `test { .. }` / `bench { .. }` cannot carry a row,
because the row is keyed on the block's name.

`Http` (and `Socket`) are absent from the default on purpose: a test that
reaches the network says so at its head. `bench/http_bench.vibe` is the
worked example (it needs `python3 tests/http_echo_server.py 18281`).

## `example`

`example "name" { .. }` (#819) is a documentation example: compiled and RUN
like a test, so a sample that stopped compiling is caught by `vibe test`.
The parser lowers it to a test, so it takes the same `allows` row and the
same ambient default. An unused binding inside an example is not reported --
sample code is read, not only executed.

## Legacy spelling

`test "n" with ..` still parses. The committed seed compiles `lib/**` tests
that carry it, so the rejection lands with the bootstrap bump that migrates
those sources; until then `vibe check` reports the head with the `allows`
edit as a non-fatal warning.

## Not implemented

- Binding an example to an API symbol (`example "n" for Array::get`) and a
  docs generator that lifts examples into API documentation.
- A stricter explicit-row mode (`allows ()` replacing the ambient default
  rather than widening it) and a named development bundle such as `DevEnv`.
  Both are open design questions; neither has an issue yet because nothing
  in the tree needs them.
