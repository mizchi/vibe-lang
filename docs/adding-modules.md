# Adding and repairing a module — a maintenance guide

> Status: written up 2026-07-04 from the practice established by #741/#742/#745
> (boundary spelling updated to `index.vpkg` 2026-08-01, #1269).
> The rules for boundaries, visibility and pins are normative in
> [module-system-oracle.md's "current model" section](module-system-oracle.md#現行モデル-canonical--ここが唯一の現行記述).
> The design history is [module-system-v2.md](module-system-v2.md) (ADR-0063/0064).
> Assumes selfhost-only ([archive/moonbit-retirement.md](archive/moonbit-retirement.md)).

In this repository, a library is alive only while a `*_test.vibe` of its own is
running in the battery. Untested code is never compiled by the compiler at all,
and rot from the host era accumulates in it — the rot #742 dug out of json /
base64 / fmt is what that looks like. **Always add a module together with its
tests.** Registering the test takes no step of its own: `discover()` picks it up
(the old allowlist was removed in #1231; see step 3 of §2).

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
   - String indexing `s[i]` yields an Int (a byte value). Compare characters
     with `String::char_code_at` plus a char literal (`'x'`) — the lesson of the
     base64/fmt rot in #742.
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
   file (removed in #1231), so no registration step is needed. Only files the
   generic harness cannot run — gate-only `__DATA__` fixtures, gc-only fixtures
   — go in `EXCLUDE_PATTERNS` in `scripts/unit_test_runner.sh`, with a reason.
   **A file with a `test` block placed under `fixtures/` must be named
   `*_test.vibe`** — that naming is the only condition for reaching
   `discover()`, and a file that misses it is run by no lane at all.
   `scripts/check_fixture_execution.sh` checks this at the top of the gate so it
   cannot pass silently ([docs/operation-gate.md](operation-gate.md), "Do not
   enumerate fixtures").
4. **Only when the compiler consumes it**: add a row under the `vibe_core` group
   of `lib/@vibe/compiler/compiler_sources_manifest.tsv`, pointing at
   `../../../lib/@vibe/<pkg>/...`. Inlining into the bundle and the knock-on
   effect on the codegen fingerprint are handled by `generate_bundle.sh`
   (#741, #766).

### Reaching a sibling file inside the same package

A package's files do **not** share a scope. Reaching a function defined in a
sibling file of the same package needs all three of the following, and leaving
any one out fails with a *different* message — so trying two of the three gives
an error that does not name the missing one:

1. `export fn f` in the defining file
2. a bodyless `fn f(..) -> T` declaration in `index.vpkg`
3. `import ./defining_file.vibe { f }` in the consuming file

Measured, all four cases (`scripts/check_package_sibling_scope.sh`,
`pkf run check-package-sibling-scope`):

| the sibling declares | consumer does | result |
|---|---|---|
| `fn f` (private) | calls `f` | `unknown name: f` |
| `export fn f` | calls `f` | `contract violation: exported 'f' is not declared in the contract` |
| `export fn f` + contract entry | calls `f` | `unknown name: f` |
| `export fn f` + contract entry | `import ./helper.vibe { f }` | ok |

`checker.vibe`'s `import ./checker_resolve.vibe { ... }` is this pattern.

**Price this in before splitting a file.** Every helper shared across sibling
files becomes a declared contract entry — public surface. Extracting N private
helpers into a sibling module publishes N names. When the helpers are a
self-contained sub-language rather than a handful of utilities, a **nested
package** (`<pkg>/<sub>/index.vpkg`) is the better boundary: the internals stay
private and only the entry points are declared. See #1849 and #2001.

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
`lib/@vibe/` it consumes), always:

```bash
VIBE_REGEN_MODULE_SOURCE=1 \
  VIBE_ADAPTER_MODULE_SOURCE_OUT=lib/@vibe/compiler/_cli_adapter_module_source.vibe \
  bash scripts/generate_bundle.sh
bash scripts/generations.sh build --stage3 --out-dir _build/gen
cmp _build/gen/stage2.wasm _build/gen/stage3.wasm   # fixpoint
```

## 4. Language and checker traps people hit (as of 2026-07)

- **Failure rides the effect row, not the return value** (#1324): write
  `-> T with Exception[E]` rather than `-> Result[T, E]`, raise with `throw(e)`,
  and receive with `handle { .. } with Exception[E] { Throw(e) => .. }`.
  **`Result` is in neither the language nor the prelude** — a bare `Ok`/`Err` is
  `unknown name: Err`. The only place a two-track return value is really needed
  is the **WIT boundary**, and there `import @vibe/wit_runtime { Result }` is the
  one spelling that projects to WIT's `result<T,E>`
  ([effect-wit-mapping.md](effect-wit-mapping.md)). Declaring your own
  `enum Result[T, E] { Ok(T); Err(E) }` for anything else is allowed, but it is
  an ordinary user enum with no special treatment whatsoever.
- **Qualified constructor patterns** such as `Result::Ok(v) =>` have worked since
  #742 (including against an enum you declared yourself, as above).
- **Name `Type::method` explicitly in the import list** (`Json::get` and the
  like) — there is no implicit companion import as there was in the host era.
- **Stringifying a Double**: `"\{x}"` is only correct where the value is
  statically known to be floatish — a literal, a float-tracked local, float
  arithmetic, or an annotated parameter (#744). Route the result of a plain user
  function call through an annotated parameter, or multiply by `* 1.0` first.
- **No bare export in a facade**: never place a bare `export { A }` next to an
  `export ./file { A }` — the FS merge produces a garbage facade (#726/#742).
- **A deeply recursive perform across an effect handler** is unresolved (#737);
  libraries should call the builtins directly (`Fs::read_file` and friends).

## 5. Known remaining gaps (tracked as issues)

- #737: perform inside deep recursion destroys the outer handler's resume
- #739: a contract's bodyless type declaration does not preserve type arity
- #740: the seed's cold-cache whole-tree FS-compile goes out of bounds (worked
  around in the module_source lane)
- #534: factoring vibe/types and vibe/parser out of the compiler (layout)
- #415: a shared builtin registry across the two backends (so adding a builtin
  is one place)
