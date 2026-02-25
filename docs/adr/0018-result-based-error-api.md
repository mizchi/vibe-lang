# ADR-0018: ライブラリ API のエラー報告を Result ベースへ移行する

- Date: 2026-02-22
- Status: accepted

## Context

`vibe/json/json.vibe`, `vibe/json/jsonrpc.vibe` 等のライブラリ関数は
エラー報告に文字列 `throw` を使っている（例: `throw("key not found: ...")`）。

問題点:

1. **型安全性の欠如**: 呼び出し側は `handle { ... } { Error(_) => ... }` で全エラーを
   一括捕捉するしかなく、エラー種別による分岐ができない
2. **合成不能**: `throw` は制御フローを中断するため、`bind` / `map_ok` 等の
   関数合成パターンが使えない
3. **暗黙の effect 伝播**: `with { Error }` が呼び出し元に伝播し、
   pure 関数として扱えない

一方、`vibe/builtin/result.vibe` には成熟した `Result[T, E]` 型と
`map_ok` / `bind` / `unwrap_or` 等の API が既に存在する。

## Decision

ライブラリ API のエラー報告は以下の方針で `Result` ベースへ段階的に移行する。

### 1. 戻り値型の変更

```
// Before: throw で中断
let json_get = (obj: Json, key: String) -> Json with { Error } { ... }

// After: Result を返す
let json_get = (obj: Json, key: String) -> Result[Json, String] { ... }
```

### 2. エラー型の選定基準

| ケース | エラー型 | 例 |
|--------|----------|-----|
| 単純な失敗理由 | `String` | `Err("key not found: name")` |
| 構造化が必要 | `suberror` enum | `Err(ParseError::UnexpectedToken(...))` |
| 位置情報あり | `{ message: String, line: Int, col: Int }` | パーサー系 |

初期移行では `Result[T, String]` を基本とし、需要に応じて構造化エラーへ昇格する。

### 3. 移行対象と優先度

| 優先度 | モジュール | 現状 | 移行先 |
|--------|-----------|------|--------|
| High | `vibe/json/json.vibe` | `throw(String)` × 15+ 箇所 | `Result[Json, String]` |
| High | `vibe/json/jsonrpc.vibe` | `throw(String)` × 8 箇所 | `Result[Json, String]` |
| Medium | `vibe/shell/from_csv.vibe` | サイレント失敗 | `Result[Json, String]` |
| Medium | `vibe/shell/from_yaml.vibe` | サイレント失敗 | `Result[Json, String]` |

### 4. 互換性ルール

- 旧 API（`throw` 版）は移行期間中 alias として残す
- alias には `// deprecated: use xxx instead` コメントを付与
- alias lifecycle は `vibe/builtin/README.md` の規定に従う

### 5. テストパターン

```vibe
// Result を直接 match
match json_parse(input) {
  Ok(data) => json_get(data, "key"),
  Err(e) => Err(e),
}

// bind でチェイン
json_parse(input) |> bind((data: Json) -> Result[Json, String] {
  json_get(data, "key")
})

// unwrap_or でフォールバック
unwrap_or(json_get(data, "name"), Null)
```

## Consequences

- 良い影響:
  - エラーハンドリングが型レベルで強制され、未処理エラーがコンパイル時に検出される
  - `bind` / `map_ok` による関数合成が可能になる
  - `with { Error }` effect の伝播が不要になり、pure 関数として扱える
- トレードオフ:
  - 既存コードの `handle` パターンを `match` / `bind` に書き換える必要がある
  - 移行期間中は `throw` 版と `Result` 版が併存する
