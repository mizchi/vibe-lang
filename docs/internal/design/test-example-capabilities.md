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

## The row is admitted like `main`'s

A block has no caller, so what its row names must be something the run can
bring in: a host capability (`Http`, `Fs::read_file`, optionally graded
`Fs::read_file?`), `Exception`, `Async`, or an effectset of those. The same
admission that `fn main allows ..` goes through (ADR-0088) runs on the block's
row, and refuses:

- a user-declared effect or operation (`test "x" allows Ask::Get`) — nobody
  outside the program provides it, so granting it would authorize a `perform`
  that no handler catches and the test would trap at run time. The edit is
  `handle`, which is also what a block body performing a user effect without
  a handler is told:

  ```text
  entry point test "x" cannot discharge { Ask::Get }: no host provider or
  runtime handler owns this effect
  hint: wrap the operation in `handle ... with Ask { ... }` before it reaches
  the entry boundary
  ```

- a row variable (`allows e`) — there is no caller to instantiate it;
- an operation a standard provider does not own (`allows Console::Get`).

## `perform?` in a block

A test artifact runs with full authority: every optional grant it carries is
resolved to `Granted` before code generation, so a `perform?` written
directly in a block would advertise a `NotGranted` arm that can never run.
It is refused, with the two edits — call the operation plainly, or move the
`perform?` into a function that requires the optional grade:

```vibe skip
// doctest-skip: the refused shape and the honest one, side by side
test "asks optionally" allows Fs::read_file? {
  let _ = perform? Fs::read_file("x")   // refused: `NotGranted` can never happen here
}

fn read_missing() -> Attempt[String, String] with Fs::read_file? {
  perform? Fs::read_file("x")           // honest: the helper's own requirement
}

test "a host failure is Errored" allows Fs::read_file? {
  match read_missing() {
    Errored(_) => assert(true),
    _ => assert(false)
  }
}
```

The same rule refuses `perform?` under any row that also grants the
operation or its provider as required (`allows Fs + Fs::read_file?`):
Required is the join of the grade lattice and absorbs the optional grade.

`Http` (and `Socket`) are absent from the default on purpose: a test that
reaches the network says so at its head. `bench/http_bench.vibe` is the
worked example (it needs `python3 tests/http_echo_server.py 18281`).

## `example`

`example "name" { .. }` (#819) is a documentation example: compiled and RUN
like a test, so a sample that stopped compiling is caught by `vibe test`.
The parser lowers it to a test, so it takes the same `allows` row and the
same ambient default. An unused binding inside an example is not reported --
sample code is read, not only executed.

## `with` on a block

`test "n" with ..` is a parse error. A block is an entry point and grants
its row, so the parser refuses the requirement keyword and names the edit
with the row it read: ``write `test "n" allows Http` ``. `bench` and
`example` are refused the same way.

## Not implemented

- Binding an example to an API symbol (`example "n" for Array::get`) and a
  docs generator that lifts examples into API documentation.
- A stricter explicit-row mode (`allows ()` replacing the ambient default
  rather than widening it) and a named development bundle such as `DevEnv`.
  Both are open design questions; neither has an issue yet because nothing
  in the tree needs them.
