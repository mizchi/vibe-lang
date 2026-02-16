# ADR-0007: HTTP バックエンドを純粋 MoonBit 実装に置換

- Date: 2026-02-16
- Status: accepted

## Context

当初の HTTP 実装は C FFI (libcurl 等) 経由だったが、以下の問題があった:
- WASM バックエンドでは C FFI が使えない
- ビルド環境にネイティブツールチェインが必要
- ポータビリティが制限される

## Decision

C FFI HTTP バックエンドを廃止し、`vibe/socket` (WASI P2 POSIX ソケット) 上に純粋 MoonBit で HTTP プロトコルを実装する。

- `vibe/socket` — TCP ソケットの抽象化（WASI P2 サポート）
- `vibe/http` — HTTP/1.1 クライアント・サーバー（チャンク転送対応）
- エフェクト `{Net}` でネットワーク操作をマーク

API:
```vibe
// クライアント
let resp = do { request("GET", "http://example.com", headers, "") }
let status = response_status(resp)
let body = response_body(resp)

// サーバー
let srv = do { listen("0.0.0.0", 8080) }
```

## Consequences

- C ツールチェイン不要でビルド可能
- WASM Component Model でも HTTP が利用可能
- HTTP/1.1 のみ対応（HTTP/2, TLS は将来課題）
- チャンク転送エンコーディングを自前実装する必要があった
