# Effect → WIT mapping (#537)

> **Scope:** this document describes the current export-signature-based
> implementation. ADR-0075's target `.vibex` contract uses `main`'s normalized
> semantic row as its source boundary, retains resource-qualified operations,
> composes providers, and generates WIT from the residual host row. Until that
> migration lands, host-capability comments and Error-as-trap below are known
> implementation/spec correspondence debt, not the target executable contract.
>
> **Async / future / stream (2026-08-01, implemented):** the
> [ADR-0089](wasip3-effect-alignment.md) Decision 5 mapping is now the
> implementation: `Future[T]` → `future<T'>`, an export `with { Async }` →
> `async func` (with `Async` never surfacing as an import — it is the
> suspension effect, realized by the async lift the step-4 composition
> emits), and `stream<u8>` only for the nominal host-owned boundary-stream
> handle `ByteStream` — a guest-produced eager `Stream[T]`/AsyncIter in a
> component signature stays a hard error (spec §3.3: the producer end
> cannot enter the component instance).

`vibe compile --wit` (launcher) / `VIBE_EMIT_WIT=1` (compiler wasm) render a
vibe file's **effect surface** as a WIT world. `vibe serve` writes the same
WIT next to the handler component. Implementation:
`lib/@vibe/compiler/wit_gen.vibe`; pinned by `fixtures/wit_gen_http.golden.wit`
(gate step 40i) and unit-tested by `lib/@vibe/compiler/wit_gen_test.vibe`.

## The contract

The world surface is defined by the **entry file's exported functions**:

| vibe | WIT |
|---|---|
| `export let f: (A) -> B [with { E, .. }] = ...` | `export <kebab f>: func(...)` |
| effect `E` named in an exported signature's `with` row, declared via `effect E { Op(Args) -> Ret; ... }` | `import <kebab E>: interface { <kebab Op>: func(...) -> ...; }` |
| effect named in a `with` row **without** a declaration (host capability: `Fs`, `Env`, ...) | comment marker `// host capability effect 'E' (provided by the vibe runtime; no WIT mapping yet)` |
| `Error` | never surfaces (vibe-internal control flow; an escaping throw is a component trap, not a capability) |
| `Async` in an exported signature's row (declared or not) | the export becomes `async func(...)`; `Async` never surfaces as an import (ADR-0089 Decision 5 — it is the builtin suspension effect, realized by the async lift) |

Notes:

- **Only exported signatures define the surface.** Effects that are declared
  but only used internally (discharged with `handle` inside the file, or used
  by non-exported functions) do not become imports. The capability boundary of
  the component is exactly what its exported signatures admit.
- **Entry-file-only scan (v1).** Exports and effect declarations are read from
  the entry file itself; an effect declared only in an imported module renders
  as a host-capability comment. (The linked-import scan is a follow-up.)
- Exports need a full type annotation (either a `let f: (A) -> B = ...`
  annotation or fully annotated lambda params + return). Unannotated exports
  are skipped — nothing is guessed at the boundary.
- Operation parameters are positional (`arg0`, `arg1`, ...): vibe effect
  operation declarations do not carry parameter names.

## Name mapping

vibe identifiers (strict CamelCase / snake_case) map to WIT kebab-case:
`HttpReq` → `http-req`, `now_us` → `now-us`, `Fs` → `fs`. Consecutive
uppercase letters split per letter (`URL` → `u-r-l`) — keep to CamelCase.

## Type mapping

| vibe | WIT |
|---|---|
| `Int` | `s64` |
| `Double` | `f64` |
| `Bool` | `bool` |
| `String` | `string` |
| `Char` | `char` |
| `Unit` (return) | no result |
| `Bytes` | `list<u8>` |
| `Array[T]` | `list<T>` |
| `Option[T]` | `option<T>` |
| `Result[T, E]` | `result<T, E>` |
| `Map[K, V]` | `list<tuple<K, V>>` |
| `(A, B, ...)` | `tuple<A, B, ...>` |
| `Future[T]` | `future<T'>` (ADR-0089 Decision 5; backed by the step-4 lowering, spec §3.13/§3.14) |
| `ByteStream` | `stream<u8>` (nominal host-owned boundary stream only) |

Anything else (named user types, function types, the eager `Stream[T]`
builtin) is **rejected with an error** — the generated WIT never silently
mis-declares a boundary type. User enum/struct → WIT `variant`/`record` is
a follow-up; general `stream<T'>` stays restricted to nominal host-owned
handles by ADR-0089 Decision 4/5 (a guest-side producer cannot enter the
component instance, spec §3.3).

## Example

```vibe
effect HttpReq {
  Method -> String;
  Url -> String;
  Header(String) -> String
}

export let route: (String) -> String with { HttpReq, Error } = (prefix) -> { ... }

export let handler = (method: String, url: String, headers: String, body: String) -> String { ... }

export let stats: (Int, Bool) -> Array[Int] with { Fs } = (n, flag) -> { ... }
```

renders as

```wit
package vibe:app;

world wit-gen-http {
  import http-req: interface {
    method: func() -> string;
    url: func() -> string;
    header: func(arg0: string) -> string;
  }
  // host capability effect 'Fs' (provided by the vibe runtime; no WIT mapping yet)
  export route: func(prefix: string) -> string;
  export handler: func(method: string, url: string, headers: string, body: string) -> string;
  export stats: func(n: s64, flag: bool) -> list<s64>;
}
```

## `vibe serve` and the P3 adapter

`vibe serve handler.vibe` uses the same machinery with a fixed contract: the
entry file must export

```vibe
export let handler = (method: String, url: String, headers: String, body: String) -> String
```

returning `"STATUS\n<Header: value lines>\n\n<body>"`, and must not require
undischarged capability effects. The compiler emits a component exporting
`handler: func(method, url, headers, body: string) -> string` (packed-string
trampoline, `comp_emit_component_wasm_string_handler`); the runner layer
(`runtime/vibe serve`) plugs it into the Rust wasi-http P3 adapter
(`scripts/build_wasi_http_p3_full_adapter.sh`) with `wac plug` and launches
`wasmtime serve`. E2E gate: `scripts/test_wasi_http_p3_full_gate.sh`.

The algebraic-effect style HTTP server (`effect HttpReq` + `perform`, see
`lib/@vibe/wasi/p3/_example_effect_server_v2.vibe`; `_`-prefixed since #897 —
explicitly compilable demo, not a package member) composes with this: discharge the
effects inside `handler` with `handle`, keeping the component boundary at the
4-string contract while the WIT world documents the internal effect surface
of anything you choose to export.
