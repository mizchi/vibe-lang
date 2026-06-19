# ADR-0012: Async/Await (Stack Switching + WASI P3)

- Date: 2026-02-17
- Status: deferred (エラー制御構文は ADR-0016 に統一。Async/Stream 機能自体は延期)
- Updated: 2026-03-18 (P3 HTTP は ADR-0021 の algebraic effect で実現。Stack Switching は引き続き延期)
- Updated: 2026-06-19 — `for await x in s { ... }` は **pull-only** に確定（#582）。
  iterable は pull closure `() -> Option[T]` を要求し `None` まで駆動する
  (host stream は `stdin_stream(4)` のように host 状態を持つ closure として供給)。
  eager iteration（Array/`Stream[T]`）は plain `for x in arr` を使う。
  selfhost compiler は `await` マーカーで pull-only を強制（parser desugar
  `build_pull_for_in`）。host compiler は現状型ベースの permissive 実装で、
  spec 適合プログラムは両者で同一挙動。詳細は `docs/spec/wasi-p3-async.md` M2c-3。
- Note: `{Async}`, `Future[T]`, `Stream[T]` は廃止ではなく延期。
  WASM Stack Switching の安定化後に ADR-0021 Phase 4 で再検討予定。
  P3 HTTP の async handler は wasmtime の component-model-async が処理するため、
  vibe 側では同期的な effect (perform/resume) として記述可能

## Context

vibe の Effect システム（ADR-0003）は `{Error}` による同期エラーハンドリングを提供しているが、非同期 I/O やストリーム処理をサポートしていない。WebAssembly Stack Switching (Phase 3) と WASI Preview 3 の登場により、WASM 上で効率的な async/await が実現可能になった。

## Decision

Effect システムを `{Async}` エフェクトで拡張し、async/await を導入する。

### 構文

```vibe
// async 関数（{Async} effect を暗黙付与）
async let fetch = (url: String) -> Response { ... }

// 明示的 effect 宣言
let fetch_data = (url: String) -> String with {Async, Error} {
  let response = await http_get(url)
  response.body
}

// ストリーム生成
let numbers = () -> Stream[Int] with {Async} {
  for i in 0..10 { yield i }
}

// ストリーム消費
for await item in stream { process(item) }
```

### 型

- `Future[T]` — 非同期計算結果
- `Stream[T]` — 非同期ストリーム
- `{Async}` — 非同期エフェクト（`await` 使用に必須）

### WASM コンパイル戦略

1. **Phase 1 (現行)**: WASM exceptions で `{Error}` を処理
2. **Phase 2 (将来)**: Stack Switching (`cont.new`/`suspend`/`resume`) で `{Async}` を実現
3. **WASI P3**: `async func`, `future<T>`, `stream<T>` との統合

### Interpreter 実装

CPS 変換または coroutine ベースで `AsyncValue` (Pending/Ready/Error) を評価する。

### 未決事項

- `async let` vs `let async` vs `with {Async}` のみ
- `Stream[T]` を組み込み型にするかライブラリにするか
- 協調的 vs 並列（WASM threads）の並行性モデル
- タスクキャンセルとバックプレッシャーの設計

## Consequences

- 非同期 I/O が Effect システムと統一的に扱え、既存の `try/catch` と組み合わせ可能
- Stack Switching の安定化待ちのため、WASM バックエンドの実装は段階的になる
- `{Async}` の伝播チェックにより、同期関数から非同期関数の誤用を防止できる
- 将来の代数的エフェクトハンドラ（`effect Log { ... }` / `handle`）への拡張パスが開ける
