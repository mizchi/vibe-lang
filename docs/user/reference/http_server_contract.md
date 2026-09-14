# HTTP Server Builtins Contract (Phase 2-1)

`Http::listen` / `Http::accept` / `Http::respond` の API 契約をここで固定する。

## Type Contract

- `Http::listen(port: Int) -> Int with Net`
- `Http::accept(server_handle: Int) -> Int with Net`
- `Http::respond(request_handle: Int, status: Int, headers: String, body: String) -> Unit with Net`

補足:

- `Int` は **opaque handle** として扱う（値の中身は公開契約に含めない）。
- `headers` は wire format 文字列（`"name: value\nname2: value2"`）を受け取る。

## Runtime Error Contract

compiled runtime / wasm host runner では、観測面は内部例外型ではなく thrown `Error` の文字列で固定する。

- capability deny:
  - `PermissionDenied: net_connect:<host>:<port>`
  - `PermissionDenied: net_response_status` / `net_response_header` / `net_response_body` / `net_close`
  - `PermissionDenied: net_listen:<port>`
  - `PermissionDenied: net_accept`
  - `PermissionDenied: net_request_method` / `net_request_url` / `net_request_header` / `net_request_body` / `net_respond`
- capability 判定前の URL 解析失敗:
  - `invalid URL for network capability check: ...`
- invalid handle や socket/listen 失敗などの backend 実行失敗:
  - backend 依存の `Error` 文字列

## Capability Contract

compiled runtime / wasm host runner では `NetListen` capability をサーバー API に適用する。

- `Http::listen(port)`:
  - `caps.can_listen(port)` が `false` の場合、`PermissionDenied: net_listen:<port>`
- `Http::accept(server_handle)`:
  - `caps.can_listen_any()` が `false` の場合、`PermissionDenied: net_accept`
- `Http::respond(request_handle, ...)`:
  - `caps.can_listen_any()` が `false` の場合、`PermissionDenied: net_respond`

加えてクライアント API では `NetConnect` capability を適用する。

- `Http::request(method, url, headers, body)`:
  - URL が `http://` / `https://` で host/port 抽出できない場合:
    - `invalid URL for network capability check: ...`
  - `caps.can_connect(host, port)` が `false` の場合:
    - `PermissionDenied: net_connect:<host>:<port>`
- `Http::response_status(handle)` / `Http::response_header(handle, name)` / `Http::response_body(handle)` / `Http::close(handle)`:
  - `caps.can_connect_any()` が `false` の場合:
    - `PermissionDenied: net_response_status` / `net_response_header` / `net_response_body` / `net_close`

サーバー request handle API では `NetListen` capability を適用する。

- `Http::request_method(handle)` / `Http::request_url(handle)` / `Http::request_header(handle, name)` / `Http::request_body(handle)`:
  - `caps.can_listen_any()` が `false` の場合:
    - `PermissionDenied: net_request_method` / `net_request_url` / `net_request_header` / `net_request_body`

## Locked By Tests

- checker 契約:
  - `src/checker/typecheck_call_builtin_wbtest.mbt`
- runtime 契約:
  - `src/runtime_compile/builtin_contract_wbtest.mbt`
- wasm host-import 契約（capability parity + request/response/listen/accept/respond e2e）:
  - `scripts/test_http_wasm_host_imports.sh`
  - deny ケース:
    - `PermissionDenied: net_connect:<host>:<port>`
    - `PermissionDenied: net_response_status`
    - `PermissionDenied: net_listen:<port>`
    - `PermissionDenied: net_accept`
  - allow ケース:
    - call order に `Http::request_method` / `Http::request_url` / `Http::request_header` / `Http::request_body` を含み、`request handle` API が host-import 経路で往復すること
    - host 側が `vibe_http_host_string_new` export を使って文字列オブジェクトを guest ヒープに確保し、`http_request_*` の戻り値として返せること
- compiled 実行系 host runner 契約:
  - `scripts/test_compiled_backend_http_policy.sh`
  - `VIBE_HTTP_ALLOW_CONNECT` / `VIBE_HTTP_ALLOW_LISTEN` で deny/allow を切り替え、`PermissionDenied: net_*` を検証
