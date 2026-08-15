# #1540 probe: how does a request body reach the guest?

`wasi:http` hands the adapter the request body as a `stream<u8>`. The full
adapter today `collect()`s it into a `String` before calling the guest
(`scripts/build_wasi_http_p3_full_adapter.sh`), so a vibe handler can never see
a body larger than memory, and never sees the first byte before the last one
has arrived.

#1540 proposed fixing that by having the adapter **export** `body: func() ->
stream<u8>` and the guest **import** it, composed as a second `wac plug` edge.
This probe exists because that shape does not work, and because the shape that
does needed measuring before any emitter line was written.

## Result 1: the issue's shape is a composition CYCLE and is not expressible

Under the proposal each component is an instantiation argument to the other:

- adapter imports `handler` from the guest
- guest imports `body` from the adapter

Measured with two minimal components (`u32` signatures -- the question is
instantiation topology, not types):

```
$ wac plug --plug guest.wasm adapter.wasm -o out.wasm     # exit 0
$ wasm-tools component wit out.wasm
world root {
  import body: func() -> u32;      # still unsatisfied
  export body: func() -> u32;
}
```

**`wac plug` does not report an error.** It wires the one edge it can and
promotes the other component's unsatisfied import to the composed component's
imports, where it fails at instantiation rather than at compose time. `wac
compose`'s WAC language cannot express the cycle at all:

```
let a = new adapter:comp { handler: g["handler"], ... };
let g = new guest:comp { body: a["body"], ... };
```
```
error: failed to resolve document
  × undefined name `g`
```

Instantiation is a DAG resolved in lexical order.

## Result 2: body-as-a-parameter works, end to end

The acyclic shape keeps one edge and moves the body onto it:

```wit
import handler: func(method: string, url: string, headers: string, body: stream<u8>) -> string;
```

Measured, all four steps:

1. **`wit-bindgen` 0.54 accepts a `stream<u8>` parameter on an imported func**,
   and the adapter can hand `Request::consume_body`'s reader straight through
   without collecting:
   ```rust
   let (req_body_rx, _trailers_rx) = Request::consume_body(request, result_rx);
   let raw = handler("GET", &url, "", req_body_rx);   // no .collect().await
   ```
2. the adapter componentizes and validates, declaring exactly that import;
3. `wac plug` composes it with `guest.wat` here, and the composed component
   has **no unsatisfied import** -- only `wasi:http/types@0.3.0`, which the
   host provides;
4. `wasmtime serve` runs it and a POST with a body gets a response.

`bash scripts/test_http_body_stream_probe_gate.sh` reproduces all of it.

## What this probe does NOT answer

`guest.wat` **ignores** the stream and returns a constant. It answers the
composition question only.

Both follow-ups it named have since been measured, and this probe stays as the
composition ratchet underneath them:

- `../async_string_lift` established the `memory` / `realloc` /
  `string-encoding` option set for a string-bearing async handler, byte for
  byte. `emit_canon_lift_async_section` / `emit_canon_task_return` were
  generalized against it, and `comp_emit_async_string_component` now emits that
  whole component.
- `../http_body_read` answers the reading question: a guest that drains the body
  with `stream.read` and returns what it read. It also found the constraint this
  probe could not see — the adapter's import has to be spelled **`async func`**,
  since a guest that suspends must be async-lifted and `canon lift ... async`
  validates only against an async functype.

## Consequence for #1540's scope

Scope 3 ("compose becomes two edges") cannot be implemented as written. Scope 1
("the adapter exports `body: func() -> stream<u8>`") does not survive either --
`body()` would be a second export on the same instance, and `wasmtime serve`
handles concurrent requests on one instance, so a per-request slot has no
request identity to key on. `Request::consume_body` also takes `this: request`
**by value** (`lib/@vibe/wasi/wit/p3/deps/http.wit`), so the reader must live on
the `handle` future's own stack and be handed over within that call -- which is
what shape (a) does.

Shape (a) does add a requirement none of the three scope bullets mention: the
guest needs a way to SPELL a `HostStream`-typed parameter, since #1341 made
`host_stream_named` return the nominal `HostStream` rather than `Stream[Int]`.

## Gate integration and process isolation

The probe runs from the required-tools `wasi-p3-gate` through
`scripts/test_wasi_p3_guarantee_gate.sh`. Missing tools are a local-development
skip by default and a failure under `VIBE_P3_GATE_REQUIRE_TOOLS=1`, matching the
other P3 probes.

Each invocation chooses a process-specific port and embeds a fixed-width token
in its guest response. It checks that the spawned `wasmtime` remains alive and
that curl receives that token, then cleans up only the recorded child PID. A
different server already listening cannot satisfy the assertion or be killed
by cleanup.
