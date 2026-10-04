# HTTP Server Builtins Contract

The raw-handle HTTP surface that `@vibe/http` publishes
(`lib/@vibe/http/index.vpkg`). Each operation is exported under the
collision-safe `Http::` name and, inside the package, under its bare name.

## Type contract

Server:

- `Http::listen(port: Int) -> Int with Http`
- `Http::accept(server_fd: Int) -> Int with Http`
- `Http::respond(req_fd: Int, status: Int, headers: String, body: String) -> Unit with Http`

Incoming request, on a handle `accept` returned:

- `Http::request_method(fd: Int) -> String with Http`
- `Http::request_url(fd: Int) -> String with Http`
- `Http::request_header(fd: Int, name: String) -> String with Http`
- `Http::request_body(fd: Int) -> String with Http`

Client:

- `Http::request(method: String, url: String, headers: String, body: String) -> Int with Http`
- `Http::response_status(fd: Int) -> Int with Http`
- `Http::response_header(fd: Int, name: String) -> String with Http`
- `Http::response_body(fd: Int) -> String with Http`
- `Http::close(fd: Int) -> Unit with Http` — closes a response handle
  `request` returned. It is not a server operation.

Notes:

- **The server operations are not usable yet.** `listen`, `accept`,
  `respond` and the `request_*` readers `perform` the matching `Http::`
  operation (`Http::Listen`, `Http::Accept`, ...). No runner implements
  those operations, so an unhandled call throws, and a program cannot handle
  them either: `Http` is a builtin effect with no operation list, so the
  lowering cannot build a handler for it (`evidence_poison_expr.vibe`).
  `lib/@vibe/http/http_effect_test.vibe` exercises the same shape through a
  user-declared `HttpServer` effect, not through these functions. The client
  operations call the runner's `vibe.http_*` imports directly and reach the
  network with no handler. To serve HTTP today, use `vibe serve` (a wasi-http
  component; see [cli-commands.md](cli-commands.md)).
- Every `Int` handle is **opaque**; its value is not part of the contract.
- `headers` is the wire-format string (`"name: value\nname2: value2"`).
  `headers_to_wire` builds it from a `Map[String, String]`, and the typed
  helpers in the same package (`make_request`, `make_response`,
  `request_with`, `respond_with`, `status_*`, `headers_*`) are thin wrappers
  over the operations above.

## Authority

`Http` is a host capability carried in the effect row. A function that calls
these operations declares `with Http`, and the entry point that runs it grants
`allows Http`, or only the operations it uses (`allows Http::request +
Http::close`). Authorization is settled before `main` runs and does not change
during the run (ADR-0088); a program whose row does not grant `Http` does not
build. See the cheatsheet's capability sections for the grant ladder.

## Coverage

- `lib/@vibe/http/index_import_test.vibe` imports every `Http::` operation
  through the package contract.
- `lib/@vibe/compiler/builtins/declarations.vibe` declares the checker's
  builtin signatures (for example `Http::respond` returning `Unit`).
