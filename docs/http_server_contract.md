# HTTP Server Builtins Contract (Phase 2-1)

`http_listen` / `http_accept` / `http_respond` の API 契約をここで固定する。

## Type Contract

- `http_listen(port: Int) -> Int with { Net }`
- `http_accept(server_handle: Int) -> Int with { Net }`
- `http_respond(request_handle: Int, status: Int, headers: String, body: String) -> Unit with { Net }`

補足:

- `Int` は **opaque handle** として扱う（値の中身は公開契約に含めない）。
- `headers` は wire format 文字列（`"name: value\nname2: value2"`）を受け取る。

## Runtime Error Contract

ランタイムは次の 2 系統に正規化する。

- 引数個数/型不一致:
  - `EvalError::BadCall(BuiltinDetail(fn_name=<builtin>, detail=\"bad call\"))`
- バックエンド実行失敗:
  - `EvalError::BadCall(Io(op=<builtin>, detail=<backend error>))`

`<builtin>` はそれぞれ `http_listen` / `http_accept` / `http_respond`。

`detail` の値は backend 依存:

- native: 例 `invalid server handle: -1`, socket/listen 系 OS エラー
- js/wasm: `not supported on <target> target`

## Capability Contract (Interpreter)

interpreter runtime では `NetListen` capability をサーバー API に適用する。

- `http_listen(port)`:
  - `caps.can_listen(port)` が `false` の場合、`EvalError::PermissionDenied("net_listen:<port>")`
- `http_accept(server_handle)`:
  - `caps.can_listen_any()` が `false` の場合、`EvalError::PermissionDenied("net_accept")`
- `http_respond(request_handle, ...)`:
  - `caps.can_listen_any()` が `false` の場合、`EvalError::PermissionDenied("net_respond")`

加えてクライアント API では `NetConnect` capability を適用する。

- `http_request(method, url, headers, body)`:
  - URL が `http://` / `https://` で host/port 抽出できない場合:
    - `EvalError::BadCall(Io(op="http_request", detail="invalid URL for network capability check: ..."))`
  - `caps.can_connect(host, port)` が `false` の場合:
    - `EvalError::PermissionDenied("net_connect:<host>:<port>")`
- `http_response_status(handle)` / `http_response_header(handle, name)` / `http_response_body(handle)` / `http_close(handle)`:
  - `caps.can_connect_any()` が `false` の場合:
    - `EvalError::PermissionDenied("net_response_status" | "net_response_header" | "net_response_body" | "net_close")`

サーバー request handle API では `NetListen` capability を適用する。

- `http_request_method(handle)` / `http_request_url(handle)` / `http_request_header(handle, name)` / `http_request_body(handle)`:
  - `caps.can_listen_any()` が `false` の場合:
    - `EvalError::PermissionDenied("net_request_method" | "net_request_url" | "net_request_header" | "net_request_body")`

## Locked By Tests

- checker 契約:
  - `src/checker/typecheck_call_builtin_wbtest.mbt`
- runtime 契約:
  - `src/runtime/eval_builtins_wbtest.mbt`
