# Effect → WIT mapping (#537)

`vibe compile --wit <file.vibe>` (and `VIBE_EMIT_WIT=1` on the compiler wasm)
renders a vibe file's **effect surface** as a WIT world. `vibe serve` writes
the same WIT next to the handler component it builds. Implementation:
`lib/@vibe/compiler/wit_gen.vibe` (`wit_from_program`); pinned by
`fixtures/wit_gen_http.golden.wit` (gate 40i), `fixtures/wit_gen_effectset.golden.wit`
(gate 40t) and `fixtures/wit_gen_result.golden.wit` (gate 90), and unit-tested
by `lib/@vibe/compiler/tests/wit_gen_test.vibe`.

This is the generator for an **export surface**: the world is read off the
entry file's exported signatures. It is not ADR-0075's executable contract for
a `.vibex` `main`, which starts from the entry's normalized row, keeps
resource-qualified operations, composes providers and emits WIT for the
residual host row; that work is not implemented, and until it is, the
host-capability comment and the exception-as-trap rule below are
implementation behavior rather than the target contract. ADR-0113
([component-build-convention.md](component-build-convention.md)) is the
direction for this generator: WIT derived from the export surface together with
a vibe-facing contract, host capabilities as inline interfaces from the
`vibe:host` catalog ([host-contract-artifact-lazy-cli.md](host-contract-artifact-lazy-cli.md)),
`Exception[E]` projected to `result<T, E>` on a component export, and a vibe
component imported by another vibe program with an ordinary `import`. None of
that has landed; what follows is the implemented behavior.

## The contract

The world surface is defined by the **entry file's exported functions**:

| vibe | WIT |
|---|---|
| `export let f: (A) -> B [with E + ..] = ...` (or a fully annotated `export fn`) | `export <kebab f>: func(...)` |
| effect `E` named in an exported signature's row and declared in the file (`effect E { Op(Args) -> Ret ... }`) | `import <kebab E>: interface { <kebab Op>: func(...) -> ...; }` |
| a row item that names one operation (`E::Op`) or an effectset | resolved to its effect(s) first, then mapped as above (ADR-0071) |
| a standard host provider in the row (`Fs`, `Env`, `Console`, ...; an operation the provider owns, such as `Console::write_stream`) | comment marker `// host capability effect 'E' (provided by the vibe runtime; no WIT mapping yet)` |
| `Exception` / `Exception[E]` | never surfaces. An escaping throw is a component trap, not a capability |
| `Async` in an exported signature's row, directly or through an effectset | the export becomes `async func(...)`; `Async` never surfaces as an import (ADR-0089 Decision 5: it is the suspension effect, realized by the async lift) |

Notes:

- **Only exported signatures define the surface.** An effect that is declared
  but only used internally — discharged with `handle` inside the file, or used
  by non-exported functions — does not become an import. The component's
  capability boundary is exactly what its exported signatures admit.
- **Entry file only.** Exports and effect declarations are read from the entry
  file; imports are not resolved and nothing is type checked. An effect
  declared only in an imported module therefore renders as the
  host-capability comment.
- **Provider admission is by operation identity** (#1961). A user effect that
  happens to be named `Console` is a user effect: `with Console::Get` imports
  the declared interface, and an operation the host provider does not own is
  not admitted as that provider.
- Exports need a full type annotation, either `let f: (A) -> B = ...` or fully
  annotated lambda parameters and return type. An unannotated export is
  skipped; nothing is guessed at the boundary.
- Operation parameters are positional (`arg0`, `arg1`, ...): operation
  declarations do not carry parameter names.

## Name mapping

vibe identifiers (strict CamelCase / snake_case) map to WIT kebab-case:
`HttpReq` → `http-req`, `now_us` → `now-us`, `Fs` → `fs`. Consecutive
uppercase letters split per letter (`URL` → `u-r-l`), so keep to CamelCase.

## Type mapping

| vibe | WIT |
|---|---|
| `Int` | `s64` |
| `Double` | `f64` |
| `Bool` | `bool` |
| `String` | `string` |
| `Char` | `char` |
| `Unit` (return only) | no result |
| `Bytes` | `list<u8>` |
| `Array[T]` | `list<T>` |
| `Option[T]` | `option<T>` |
| `Result[T, E]` | `result<T, E>` — matched by the type's head name; the language has no built-in `Result` (#1324), so import the canonical one from `@vibe/wit_runtime` |
| `Map[String, V]` | `list<tuple<string, V>>` (a non-`String` key has no mapping, #2276) |
| `StringMap[V]` | `list<tuple<string, V>>`, unless the file declares or imports its own `StringMap` |
| `(A, B, ...)` | `tuple<A, B, ...>` |
| `Future[T]` | `future<T'>` (ADR-0089 Decision 5) |
| `ByteStream`, `HostStream` | `stream<u8>` — the nominal byte streams whose producer end the host owns (`HostStream` arrives as a parameter, which is how `vibe serve` hands a handler its request body) |

Anything else — a named user type, a function type, the eager `Stream[T]` — is
**refused with an error**, so the generated WIT never mis-declares a boundary
type. User `enum` / `struct` to WIT `variant` / `record` is not implemented. A
general `stream<T'>` stays limited to nominal host-owned handles (ADR-0089
Decisions 4 and 5): a stream produced inside the guest cannot enter the
component instance.

### Fallible exports: `@vibe/wit_runtime`

**An `Exception[E]` row does not project to `result<T, E>`.** The idiomatic
fallible signature is `fn f(..) -> T with Exception[E]` (#1324), but the WIT
signature is built from the return type alone and exception labels never
surface, so a row-carrying export renders as plain `T` and an escaping throw
is a component trap rather than a declared failure channel.

A fallible boundary therefore converts once, in the export's body, into the
canonical `Result` from `@vibe/wit_runtime`:

```vibe
import @vibe/wit_runtime { Result }

fn parse_port(s: String) -> Int with Exception[String] {
  if String::length(s) == 0 {
    throw("empty port")
  }
  8080
}

export let port_of: (String) -> Result[Int, String] = (s) -> {
  handle {
    Ok(parse_port(s))
  } with {
    Exception[String]::Throw(e) => Err(e)
  }
}
```

renders as `export port-of: func(s: string) -> result<s64, string>;`
(`fixtures/wit_gen_result.vibe`, compiled and diffed against its golden by
gate 90).

The `handle` goes in the export body, not in a shared generic `catching(f)`
helper: a helper that takes a thunk does not discharge the row at its call
site, because the caller's closure literal carries its own latent row (#1361),
so the caller still reports `missing { Exception[String] }`. That is why
`@vibe/wit_runtime` ships only the type.

## Example

Abridged from `fixtures/wit_gen_http.vibe` (bodies elided):

```text
effect HttpReq {
  Method -> String
  Url -> String
  Header(String) -> String
}

export let route: (String) -> String with HttpReq + Exception = (prefix) -> { ... }

export let handler = (method: String, url: String, headers: String, body: String) -> String { ... }

export let stats: (Int, Bool) -> Array[Int] with Fs = (n, flag) -> { ... }
```

renders as (`fixtures/wit_gen_http.golden.wit`)

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

## `vibe serve` and the wasi-http P3 adapter

`vibe serve handler.vibe` builds a component from a fixed handler contract
(`validate_serve_handler` in `lib/@vibe/compiler/wit_gen.vibe`), writes its
WIT next to it, and the launcher plugs it into the Rust wasi-http P3 adapter
(`scripts/build_wasi_http_p3_full_adapter.sh`) with `wac plug` and runs
`wasmtime serve`. The entry file must export `handler` with three `String`
parameters, a fourth for the body, and a `String` result in the form
`"STATUS\n<Header: value lines>\n\n<body>"`. The handler may use algebraic
effects internally as long as it discharges them; its row may carry nothing
but `Exception` and, with a stream body, `Async`. The signature selects the
lane (`serve_handler_takes_body_stream`):

| handler | component |
|---|---|
| `(method: String, url: String, headers: String, body: String) -> String` | sync lift; the body is collected into a `String` first (`comp_emit_component_wasm_string_handler`). Gate: `scripts/test_wasi_http_p3_full_gate.sh` |
| `(.., body: HostStream) -> String with Async` | async lift; the component exports `handler` with the body as a `stream<u8>`, which the handler reads as it arrives with `host_stream_next` (#1540, `comp_emit_component_wasm_stream_handler`). The stream-body adapter's `handler` import takes that shape |
| the same, and the handler also awaits outbound responses (a `from_wit` client binding returning `Future[HostResponse]`) | the `wasi:http/service` shape (#2066): one component that exports `handler` and imports the client interface; a provider built by `scripts/build_http_client_provider.sh` implements that interface over `wasi:http/client` (`comp_emit_component_wasm_service_handler`, chosen when the core awaits a host future) |

`Async` and a `HostStream` body go together in both directions: `with Async`
without a stream body has nothing to await, and a stream body without `Async`
could never be read, so `vibe serve` refuses either half on its own with that
reason. The stream lanes need the stream-body adapter
(`VIBE_HTTP_ADAPTER_BODY_STREAM=1 scripts/build_wasi_http_p3_full_adapter.sh`);
the launcher picks it by reading the WIT sidecar. Gates:
`scripts/test_serve_async_lift_gate.sh` (an async-lifted `String` handler,
built directly), `scripts/test_serve_body_stream_gate.sh` (the `HostStream`
lane byte for byte, and the service world through
`fixtures/serve_service_world/handler.vibe`). The command-line surface is in
[cli-commands.md](../../user/reference/cli-commands.md#serve-537).

The algebraic-effect style of server
(`lib/@vibe/wasi/p3/_example_effect_server_v2.vibe`, an explicitly compiled
demo) composes with this: it discharges its `effect HttpReq` inside `handler`,
so the component boundary stays the handler contract while the WIT world
documents the effect surface of anything else the file exports.
