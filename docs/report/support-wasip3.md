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

### Adapter バージョン

| adapter | WIT import | handler 返り値 | vibe 制御範囲 |
|---------|-----------|--------------|-------------|
| v1 (`build_wasi_http_p3_adapter.sh`) | `func(string, string) -> s64` | Int (tagged) | status code のみ |
| v2 (`build_wasi_http_p3_adapter_v2.sh`) | `func(string, string) -> string` | String | status + headers + body |

### v2 Wire Protocol

```
STATUS_CODE\n
Header-Name: Header-Value\n
...\n
\n
BODY
```

例:
```
200
content-type: application/json

{"status":"ok"}
```

## 既知の問題

### 1. WASM Exceptions の string throw/catch 破損

`throw("NotFound")` → `handle { ... } { Error(err) => ... }` で `err` の値が破損する。
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

## 今後の作業

### Phase 1: WASM Exceptions 修正 + suberror 対応

- [ ] WASM exceptions での string tagged value 伝搬を修正
- [ ] suberror → Error 型の自動変換を compiled backend で実装
- [ ] `harness()` が throw/catch で正しく動作することを検証

### Phase 2: Algebraic Effect `Http` の設計

- [ ] `effect Http { request_method: () -> String; ... }` の代数的エフェクト設計
- [ ] P3 handler を effect handler として自然に書ける syntax
- [ ] effect → WIT import/export の自動マッピング

### Phase 3: Adapter WIT 拡張

- [ ] request body の伝搬: `handler(method, url, body) -> string`
- [ ] request headers の伝搬: serialized headers or 個別 import
- [ ] streaming response body (wit_stream)

### Phase 4: CI / Tooling

- [ ] CI で wasmtime v44 を使って P3 serve テストを有効化
- [ ] `just test-wasi-p3-e2e-v44` を CI に追加（submodule build 必要）
- [ ] `vibe serve` コマンド（compile → compose → wasmtime serve の一括実行）

### Phase 5: Production Ready

- [ ] adapter を vibe/wasm で書き直す（Rust 依存排除）
- [ ] CORS headers サポート
- [ ] Request routing DSL
- [ ] Middleware chain パターン
- [ ] Static file serving
