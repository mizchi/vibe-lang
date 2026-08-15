# #1540 probe: what does a guest have to do to READ the body?

`../http_body_stream` established that a `wasi:http` request body can reach the
guest as a `stream<u8>` **parameter**, and its README closes by naming what it
does not answer: its guest ignores the stream and returns a constant, so
"reading it needs `stream.read` plus an async lift" stayed open.

This probe closes that. `guest.wat` drains the body stream one `stream.read` at
a time and returns what it read, and `scripts/test_http_body_read_probe_gate.sh`
POSTs a per-process token over real HTTP and asserts that token comes back. A
constant cannot pass it.

## Result 1: the adapter's import must be spelled `async func`

Not a style choice — a requirement that falls out of reading the body.

Reading blocks, so the handler has to be async-lifted; `canon lift ... async`
validates only against an async functype (`../async_string_lift`); and the
functype in question is the one the **adapter** declares for its import. With
the sibling probe's spelling:

```wit
import handler: func(method: string, url: string, headers: string, body: stream<u8>) -> string;
```

the import's functype is `async_: false`, and no async-lifted guest can plug
into it. With `async func`:

```wit
import handler: async func(method: string, url: string, headers: string, body: stream<u8>) -> string;
```

it is `async_: true`. Measured on wit-bindgen 0.54: the spelling is accepted,
and the generated import is awaitable with **owned** string params (`String`,
not `&str`).

So the eventual serve adapter has to declare the handler import async, and that
is decided by whether the handler can suspend — which, for anything that reads
a body, it can.

## Result 2: the stream parameter is one i32 handle, and the result leaves through `task.return`

The core function the async lift wraps takes 7 i32 — three `(ptr, len)` pairs
for the strings, then the stream handle — and returns **nothing**:

```wat
(func (export "handler")
  (param i32 i32 i32 i32 i32 i32 i32)   ;; method, url, headers, body handle
  ...)
```

Compare the sibling probe's sync lift, whose core function returns an i32
pointer to the result's `(ptr, len)` pair. Under an async lift the string comes
back through `task.return` instead.

## What this probe reuses rather than re-measures

- `../host_stream_value` — `stream.read`'s status encoding (`BLOCKED` =
  `0xffffffff`, completion packs `(amount << 4) | code`), both end-of-stream
  shapes, and the unjoin-before-drop rule.
- `../async_string_lift` — the canonopt set for a string-result async lift, and
  why memory and realloc must live outside the guest instance.
- `../http_body_stream` — the acyclic adapter/guest composition, and why the
  two-edge shape in #1540's scope bullets is not expressible.

What is new is that they hold **together** on one export.

## Limits

The guest reads at most 64 bytes and answers `ERR-OVERRUN` past that. It is a
probe: the point is that the bytes arrive through `stream.read`, not that this
guest is a general reader. Diagnostics come back as recognisable strings
(`ERR-EVENT`, `ERR-STATUS`, `ERR-OVERRUN`) so a failing gate names the broken
assumption instead of only reporting a missing token.

## Still open for #1540 scope 3/4

The guest here is hand-written WAT. Emitting it from vibe source needs a way to
**spell** a `HostStream`-typed handler parameter (#1341 made `host_stream_named`
return the nominal `HostStream` rather than `Stream[Int]`), and
`validate_serve_handler` currently requires exactly four `String` params and
rejects every non-`Exception` effect.
