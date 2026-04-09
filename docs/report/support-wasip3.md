# WASI P3 サポート状況レポート

## 現在の状態 (2026-03-18)

### 動作確認済み

- **wasmtime v44.0.0** (deps/wasmtime submodule) で P3 HTTP serve 完全動作
- wasmtime v42.0.1 (system install) では `fields` resource 未リンクで serve 不可
- フラグ: `-Sp3 -Shttp -Wcomponent-model-async=y -Wcomponent-model-async-builtins=y -Wexceptions=y`

### パイプライン

```
handler.vibe
    ↓ vibe compile --compose-p3 --adapter adapter.wasm
.p3.component.wasm
    ↓ wasmtime serve -Sp3 -Shttp -Wcomponent-model-async=y ...
HTTP server (localhost:8080)
```

### ディレクトリ構造

```
vibe/wasi/
├── index.vibe                  # ルートモジュール
├── p2/
│   ├── index.vibe              # P2 re-export (vibe/http + vibe/socket)
│   └── import_test.vibe        # 4/4 pass
└── p3/
    ├── index.vibe              # P3 エントリ
    ├── handler.vibe            # Request/Response/Handler 基本型
    ├── handler_test.vibe       # 7/7 pass
    ├── http_effect.vibe        # HttpEffect 型 + serialize + harness
    ├── http_effect_test.vibe   # 16/16 pass
    ├── example_hello.vibe      # v1: status code only
    ├── example_server.vibe     # v1: routing + status
    ├── example_server_v2.vibe  # v2: body + headers
    └── example_effect_server.vibe  # v2 + HttpEffect 型
```

### Active Adapter Scripts

| adapter | WIT import | handler 返り値 | 用途 |
|---------|-----------|--------------|------|
| `build_wasi_http_p3_adapter.sh` | `func(string, string) -> s64` | Int (tagged) | 最小の P3 adapter。`compile --compose-p3 --adapter ...` の基準 |
| `build_wasi_http_p3_combined_adapter.sh` | `func(string, string) -> s64` + `wasi:http/client` | Int (tagged) | `compose_http_p3_handler.sh` / `vibe_serve.sh` の serve 向け adapter |

## 既知の問題

### 1. WASM Exceptions の string throw/catch 破損

`throw("NotFound")` → `handle { ... } with Error { Throw(err) => ... }` で `err` の値が破損する。
WASM exceptions proposal 経由の tagged string の伝搬に問題あり。

**影響**: `harness()` の自動エラーハンドリングが compiled backend で動かない
**回避策**: handler 内で直接 `HttpResponse` を返す（throw しない）

### 2. suberror の compiled backend 未サポート

`suberror HttpError { NotFound; BadRequest(String) }` + `throw(NotFound)` が compiled backend で型エラー。
suberror → Error 型への自動変換が WASM codegen で未実装。

**影響**: `HttpError` suberror を throw できない
**回避策**: `throw("NotFound")` で文字列 throw するか、直接 Response を返す

### 3. harness の closure export 不可

`export let handler = harness(my_handler)` — closure 返り値を export すると、
`component-string-lift` が「no exported function with string params found」エラー。

**影響**: harness パターンが compile 時に使えない
**回避策**: export handler を直接関数として書き、内部で handle { } を展開

### 4. request body の未伝搬

現在の adapter WIT は `handler(method, url) -> string` で request body を渡さない。
POST/PUT のリクエストボディを処理するには adapter の WIT 拡張が必要。

### 5. wasmtime バージョン依存

P3 serve は wasmtime v44+ が必要。CI (system install) は v42 で serve テスト skip。

## 設計決定: Model 1 (Full Algebraic Effect)

Request/Response ともに effect として扱う。データ受け渡しではなく capability ベース。

### 設計理由

- **最小権限**: `with { HttpRequest }` だけ渡せば read-only middleware が書ける
- **テスト容易性**: 全 operation を handler で mock 可能
- **合成可能性**: effect は独立にハンドル・合成できる
- **streaming**: Response を effect にすることで streaming response が自然に書ける
- **WIT 対応**: effect = WIT interface に 1:1 マッピング

### Effect 定義

```vibe
// Incoming request を読む capability
effect HttpRequest {
  Method -> String;
  Url -> String;
  Header(String) -> Option[String];
  Body -> String
}

// Response を書く capability
effect HttpResponse {
  Status(Int) -> Unit;
  Header(String, String) -> Unit;
  Write(String) -> Unit
}

// Outbound HTTP client capability
effect HttpClient {
  Fetch(String, String, String) -> (Int, String)  // method, url, body -> status, body
}
```

### Handler の書き方

```vibe
// handler は使う capability を宣言
let handler = () -> Unit with { HttpRequest, HttpResponse } {
  let method = perform HttpRequest::Method
  let url = perform HttpRequest::Url

  if String::equals(url, "/health") {
    perform HttpResponse::Status(200)
    perform HttpResponse::Header("content-type", "application/json")
    perform HttpResponse::Write("{\"status\":\"ok\"}")
  } else {
    perform HttpResponse::Status(404)
    perform HttpResponse::Write("Not Found")
  }
}
```

### Middleware パターン

```vibe
// Auth middleware: HttpRequest のみ要求 (最小権限)
let auth = [A](inner: () -> A with { HttpRequest, HttpResponse })
  -> A with { HttpRequest, HttpResponse, Error } {
  let token = perform HttpRequest::Header("authorization")
  match token {
    None => {
      perform HttpResponse::Status(401)
      perform HttpResponse::Write("Unauthorized")
      throw("Unauthorized")
    }
    Some(_) => inner()
  }
}

// Logger middleware: HttpRequest のみ read
let logger = [A](inner: () -> A with { HttpRequest, HttpResponse })
  -> A with { HttpRequest, HttpResponse, Log } {
  let url = perform HttpRequest::Url
  perform Log::Info(url)
  inner()
}
```

### テスト (effect handler で mock)

```vibe
// handler の単体テスト: HttpRequest を mock, HttpResponse を collect
let (status, body) = handle {
  handle {
    handler()
    (0, "")  // unreachable if Write is called
  } with HttpRequest {
    Method => resume("GET");
    Url => resume("/health");
    Header(_) => resume(None);
    Body => resume("")
  }
} with HttpResponse {
  Status(code) => (code, "");     // capture
  Write(text) => (200, text)      // capture
}
assert(status == 200)
```

### WIT マッピング

```
effect HttpRequest  →  WIT interface http-request { method: func() -> string; ... }
effect HttpResponse →  WIT interface http-response { set-status: func(code: u16); ... }
effect HttpClient   →  WIT interface http-client { fetch: func(...) -> ...; }
```

P3 adapter は handler for these effects:
- `HttpRequest` operations → adapter が `wasi:http/types.request` から値を取得して resume
- `HttpResponse` operations → adapter が `wasi:http/types.response` を構築
- `HttpClient` operations → adapter が `wasi:http/client` を呼び出して resume

### Proxy パターン (複数 capability の合成)

```vibe
let proxy = () -> Unit with { HttpRequest, HttpResponse, HttpClient } {
  let method = perform HttpRequest::Method
  let url = perform HttpRequest::Url
  let (status, body) = perform HttpClient::Fetch(method, url, "")
  perform HttpResponse::Status(status)
  perform HttpResponse::Write(body)
}
```

## 今後の作業

### Phase 1: WASM Exceptions 修正 + suberror 対応

前提: effect handler (resume) を WASM で実現するには exceptions / stack-switching が必要。

- [ ] WASM exceptions での string tagged value 伝搬を修正
- [ ] suberror → Error 型の自動変換を compiled backend で実装
- [ ] `handle { ... } with Error { Throw(x) => ... }` での x の値が正しく伝搬されることを検証

### Phase 2: `effect` 宣言 + `perform` + effect handler

言語に代数的エフェクトの基盤を追加。

- [ ] `effect Name { Op1(Args) -> Ret; Op2 -> Ret }` 宣言の AST / parser / checker
- [ ] `perform Effect::Op(args)` 式の AST / parser / checker / codegen
- [ ] `handle { body } with Effect { Op(args) => resume(value) }` handler 構文
- [ ] `resume(value)` — 中断した計算を値で再開する continuation
- [ ] `with { Effect }` annotation — 既存の `with { Error }` を一般化
- [ ] effect と suberror の関係整理 (`Error` は特殊な effect、suberror は Error の variant)

### Phase 3: Http effect 実装 + P3 adapter 統合

- [ ] `effect HttpRequest`, `effect HttpResponse`, `effect HttpClient` 定義
- [ ] P3 adapter を effect handler として生成する codegen パス
- [ ] `vibe serve handler.vibe` — 一括 compile → compose → serve コマンド
- [ ] streaming response: `HttpResponse::Write` を複数回呼べる

### Phase 4: CI / Tooling

- [ ] CI で wasmtime v44 を使って P3 serve テストを有効化
- [ ] `just test-wasi-p3-e2e-v44` を CI に追加（submodule build 必要）
- [ ] effect handler の型推論テスト

### Phase 5: Production Ready

- [ ] adapter を vibe/wasm で書き直す（Rust 依存排除）
- [ ] Middleware chain パターンの標準ライブラリ
- [ ] CORS / static file / routing の標準 middleware
- [ ] request body streaming (HttpRequest::ReadChunk)
- [ ] WebSocket effect (`effect WebSocket { ... }`)
