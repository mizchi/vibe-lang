# Adding and repairing a module — a maintenance guide

The rules for boundaries, visibility and pins are normative in the "current
model" section of [module-system-oracle.md](../design/module-system-oracle.md)
(ADR-0063/0064/0070). This guide is the procedure that applies them.

In this repository, a library is alive only while a `*_test.vibe` of its own is
running in the battery. Untested code is never compiled by the compiler at all,
and rot from the host era accumulates in it — the rot #742 dug out of json /
base64 / fmt is what that looks like. **Always add a module together with its
tests.** Registering the test takes no step of its own: `discover()` picks it up
(see step 3 of §2).

## 1. Where to put it

| Location | Purpose | Examples |
| --- | --- | --- |
| `lib/@vibe/<pkg>/` | Contract package. `index.vpkg` is both the boundary and the public API (the legacy `index.vibei` is not a boundary, ADR-0070). **Boundary enforcement (#729)**: a file inside a directory that has an `index.vpkg` cannot be imported directly by an outside owner — only through the contract (a directory import). The compiler itself consumes these with `import ../../../lib/@vibe/<pkg> { ... }` (#741, #766) | `lib/@vibe/core` (sha1 / leb128 / list / set / maps / sorted_index, #766/#1353), `lib/@vibe/ast` (transparent AST types), `lib/@vibe/parser` (lexer/parser/printer, #753), `lib/@vibe/concurrent` / `semver` / `blake3` / `scan` (promoted in #1353) |
| `lib/@vibe/<domain>/` | Standard-library layer. A directory import (`import ../json { ... }`) goes through the `index.vpkg` contract | `lib/@vibe/json`, `lib/@vibe/module`, `lib/@vibe/cache` (portable fingerprint / envelope / path) |
| `lib/@vibex/<pkg>/` | Experimental / extension layer (ADR-0065: @vibex is a virtual experimental user scope). Promote to `lib/@vibe/` once stable | `lib/@vibex/fmt`, `lib/@vibex/regexp` (`url` stays experimental until its regexp/scan dependency is cut) |
| `lib/@<user>/<pkg>/` | A real user-scope package unrelated to the compiler (only scopes the repo owner controls may live in-repo) | `lib/@mizchi/markdown` |
| `lib/@vibe/compiler/` | The compiler itself, and nothing else. Do not put libraries here — factor anything shared out to `lib/@vibe/` and import it through its contract. The compiler-only incremental DB and import DAG live in `compiler/incremental` and `compiler/module_graph`, the header codec in `compiler/cache` (#1353) | — |

For a new reusable data structure or algorithm, **`lib/@vibe/core` is the first
choice** (moonbitlang/core-style per-domain files plus an `index.vpkg`
contract).

Resolution order for a `@scope/name` import (ADR-0065, #751): `.vibe/store/`
(pin-verified) → the workspace `lib/` → each root in **`VIBE_LIB`** (a
`:`-separated list; when unset, `$VIBE_HOME/lib`, and failing that
`~/.vibe/lib`). The lib/ and VIBE_LIB paths are a dev-mode convenience: when a
pin exists the hash is checked wherever the package was found. Under
**`VIBE_REQUIRE_PINS=1`** (the freeze switch for release/publish; a future
`vibe run --freeze` maps onto it) an unpinned lib resolution is an error.

## 2. The procedure

1. **Implement**: write `<pkg>/foo.vibe`. Mark the public API `export`.
   - String indexing `s[i]` yields an Int (a byte value, ADR-0098). Compare
     bytes with `String::byte_at` plus a char literal (`'x'`) — the lesson of
     the base64/fmt rot in #742. `String::char_code_at` is a deprecated alias
     that `vibe check` warns about.
   - An `r#` raw identifier is re-escaped by the printer (#741), but binding a
     keyword name is best avoided anyway.
2. **Contract (for `lib/@vibe`)**: add `import ./foo.vibe {}` at the top of
   `index.vpkg` and list the public functions as bodyless declarations. The
   checker verifies conformance (#729).
3. **Test**: write `<pkg>/foo_test.vibe`. Note that `vibe test` compiles at the
   production default (RC), so the RC-specific float and ownership paths are
   exercised too — that is how #745 was found. `scripts/unit_test_runner.sh`
   runs the battery over every `*_test.vibe` under `examples/`, `lib/` and
   `fixtures/` that `discover()` finds, unconditionally. There is no allowlist
   file, so no registration step is needed. Only files the
   generic harness cannot run — fixtures needing dedicated gate settings or a GC backend
   — go in `EXCLUDE_PATTERNS` in `scripts/unit_test_runner.sh`, with a reason.
   **A file with a `test` block placed under `fixtures/` must be named
   `*_test.vibe`** — that naming is the only condition for reaching
   `discover()`, and a file that misses it is run by no lane at all.
   `scripts/check_fixture_execution.sh` checks this at the top of the gate so it
   cannot pass silently ([docs/internal/operations/operation-gate.md](../operations/operation-gate.md), "Do not
   enumerate fixtures").
4. **Only when the compiler consumes it**: add a row under the `vibe_core` group
   of `lib/@vibe/compiler/compiler_sources_manifest.tsv`, pointing at
   `../../../lib/@vibe/<pkg>/...`. Inlining into the generated bundles and the
   knock-on effect on the codegen fingerprint follow from that row:
   `bash scripts/ensure_generated.sh` regenerates them (#741, #766).

### Reaching a sibling file inside the same package

A package's files do **not** share a scope. Reaching a function defined in a
sibling file of the same package needs all three of the following, and leaving
any one out fails with a *different* message — so trying two of the three gives
an error that does not name the missing one:

1. `export fn f` in the defining file
2. a bodyless `fn f(..) -> T` declaration in `index.vpkg`
3. `import ./defining_file.vibe { f }` in the consuming file

Measured, all five cases (`scripts/check_package_sibling_scope.sh`,
`pkf run check-package-sibling-scope`):

| the sibling declares | consumer does | result |
|---|---|---|
| `fn f` (private) | calls `f` | `unknown name: f` |
| `export fn f` | calls `f` | `contract violation: exported 'f' is not declared in the contract` |
| `export fn f` + contract entry | calls `f` | `unknown name: f` |
| `fn f` (private) + contract entry | `import ./helper.vibe { f }` | `contract violation: contract declaration 'f' is implemented but not exported by its implementation file` |
| `export fn f` + contract entry | `import ./helper.vibe { f }` | ok |

The fourth row is the one that shows `export` is required **on its own**: it
supplies the other two prerequisites and fails anyway. Without it the first
three rows each fail for their own missing piece, and none of them would notice
if a private function present in the contract started being accepted.

`checker.vibe`'s `import ./checker_resolve.vibe { ... }` is this pattern.

**Price this in before splitting a file.** Every helper shared across sibling
files becomes a declared contract entry — public surface. Extracting N private
helpers into a sibling module publishes N names. When the helpers are a
self-contained sub-language rather than a handful of utilities, a **nested
package** (`<pkg>/<sub>/index.vpkg`) is the better boundary: the internals stay
private and only the entry points are declared.

## 3. Verification (always, before committing)

```bash
# A single test, by hand (compile + run)
env VIBE_PREOPEN_DIR="$PWD" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  <stage2.wasm> path/to/foo_test.vibe /tmp/t.wasm __no_entry__
env VIBE_PREOPEN_DIR="$PWD" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start /tmp/t.wasm

# Everything (plus bundle regen + fixpoint if you touched the compiler)
bash scripts/compiler_gate.sh
bash scripts/unit_test_runner.sh

# Formatting (the same as CI's vibe-fmt-check job: lib/**/*.vibe + lib/**/*.vpkg)
bash scripts/check_vibe_fmt.sh
```

A new `index.vpkg` header does not have to be written neatly by hand —
`bash scripts/vibe_fmt.sh <path/to/index.vpkg>` normalizes key order,
whitespace, the indentation of `#|` and dep lines, and sorts `deps`.  (#1435)
But the loader matches a directive's spelling exactly, so writing `name  =`
means the formatter does not recognize it as a directive and **leaves the file
alone** (it declines rather than corrupting). If a file will not format, suspect
the header spelling first.

If you touched the compiler itself (`lib/@vibe/compiler/`, or the parts of
`lib/@vibe/` it consumes), also rebuild it and check the fixpoint:

```bash
bash scripts/ensure_generated.sh      # regenerate the generated compiler files if stale
bash scripts/generations.sh build --stage3 --out-dir _build/gen
cmp _build/gen/stage2.wasm _build/gen/stage3.wasm   # fixpoint
```

`vibe test` compiles with the committed seed unless told otherwise, so a test
of a compiler change has to name the new compiler:
`VIBE_TEST_CLI_WASM=_build/gen/stage2.wasm bash scripts/vibe_test.sh <file>`
(AGENTS.md, "Which compiler answered?").

## 4. Language and checker traps people hit

- **Failure rides the effect row, not the return value** (#1324): write
  `-> T with Exception[E]` rather than `-> Result[T, E]`, raise with `throw(e)`,
  and receive with `handle { .. } with { Exception[E]::Throw(e) => .. }`.
  **`Result` is in neither the language nor the prelude** — a bare `Ok`/`Err` is
  `unknown name: Err`. The only place a two-track return value is really needed
  is the **WIT boundary**, and there `import @vibe/wit_runtime { Result }` is the
  one spelling that projects to WIT's `result<T,E>`
  ([effect-wit-mapping.md](../design/effect-wit-mapping.md)). Declaring your own
  `enum Result[T, E] { Ok(T); Err(E) }` for anything else is allowed, but it is
  an ordinary user enum with no special treatment whatsoever.
- **Qualified constructor patterns** such as `Result::Ok(v) =>` work, including
  against an enum you declared yourself, as above.
- Importing the owner declaration activates its namespace: for example,
  `import @vibe/core { struct MutMap }` makes exported `MutMap::*` members
  available. Name `Type::method` explicitly only when importing a narrower
  surface or assigning the member an alias.

The language reference's own list of measured traps is the "落とし穴" section of
[cheatsheet.md](../../user/reference/cheatsheet.md); add a new trap there, with
the measurement, rather than here.
