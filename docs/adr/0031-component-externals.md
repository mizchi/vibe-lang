# ADR-0031: Component Externals via Effect Handlers

- Date: 2026-03-19
- Status: proposed
- Related: ADR-0030 (runtime capability), ADR-0027 (capability DCE), ADR-0021 (effect + #import)

## Context

JavaScript bundler では `external` で「バンドルしないで実行時に提供を期待する」依存を宣言する:

```js
// webpack.config.js
externals: { react: 'React', fs: 'node:fs' }
```

vibe の Component Model ビルドで同等のことをしたい:
- ライブラリを component としてビルド
- 一部の capability は parent に提供を期待（external）
- 一部は自前で handler を提供（bundled）

## Decision

**effect の handler 有無が external/bundled を決定する。**

### 基本原則

```
perform Effect::Op  +  handler なし  =  WASM import (external)
perform Effect::Op  +  handler あり  =  inline 化 (bundled)
```

### 例: ライブラリの component ビルド

```vibe
// lib.vibe — ライブラリ
effect Db { Query(String) -> String }
effect Cache { Get(String) -> String; Set(String, String) -> Unit }

// Db は external (handler なし → import として残る)
// Cache は bundled (handler で in-memory 実装を提供)

export let get_user = (id: Int) -> String with { Db } {
  let key = __to_string(id)
  let cached = handle {
    perform Cache::Get(key)
  } {
    // Cache は自前実装 (bundled)
    Cache::Get(_k) => resume(""),
    Cache::Set(_k, _v) => resume(0)
  }
  if String::length(cached) > 0 { cached }
  else {
    let data = perform Db::Query(key)  // Db は external
    data
  }
}
```

コンパイル結果:
```wat
(component
  ;; Db は import (external) — parent が提供
  (import "Db" (instance
    (export "Query" (func (param "sql" string) (result string)))
  ))
  ;; Cache は import なし (bundled) — inline 化済み

  ;; get_user を export
  (export "get_user" (func ...))
)
```

### bundler external との対応

| bundler | vibe effect | Component Model |
|---------|-----------|----------------|
| `external: ['fs']` | `perform Fs::ReadFile` (handler なし) | `(import "Fs" ...)` |
| `import('./utils')` (bundled) | `handle { perform Cache::Get } { ... }` | inline 化 |
| `external: ['react']` | `perform UI::Render` (handler なし) | `(import "UI" ...)` |
| `require('lodash')` (bundled) | 直接関数呼び出し | inline 化 |

### 明示的な external 宣言

```vibe
// lib.vibe
#import("my-org:database/query@1.0.0")
effect Db { Query(String) -> String }

// ↑ #import ディレクティブで Component Model の import 名を指定
// handler がなければ自動的に external

// ↓ handler があれば bundled (in-memory cache)
effect Cache { Get(String) -> String }
let cache_handler = handle { ... } { Cache::Get(k) => resume("") }
```

### Compose 時の plug

```bash
# lib.wasm は Db を import として公開
vibe compile --component lib.vibe -o lib.component.wasm

# parent が Db 実装を plug
wasm-tools compose \
  --plug lib.component.wasm \
  --adapt db-postgres.component.wasm \
  -o app.component.wasm

# db-postgres が Db.Query を export → lib の import を満たす
```

### テスト時の差し替え

```vibe
// test.vibe — Db を mock で plug
import ./lib.vibe { get_user }

test "get_user with mock db" {
  let result = handle {
    get_user(1)
  } {
    Db::Query(_sql) => resume("{\"name\": \"Alice\"}")
  }
  assert(String::contains(result, "Alice"))
}
```

テスト時は handle で mock を注入 → Db は external から bundled に切り替わる。

### ビルドモードによる external の制御

```bash
# Development: 全て bundled (mock handler 付き)
vibe compile --mock-all lib.vibe -o lib.dev.wasm

# Production: Db は external, Cache は bundled
vibe compile --component lib.vibe -o lib.component.wasm

# Standalone: handler が全 effect を処理
vibe compile --standalone lib.vibe -o lib.standalone.wasm
# → すべての effect に default handler を注入
# → import なし (fully self-contained)
```

### DCE との連携 (ADR-0027)

```bash
# Edge profile: Fs は不使用 → DCE で除去
vibe compile --profile edge --component lib.vibe -o lib.edge.wasm
# → Fs import が消える (使用コードも DCE)
# → Db import のみ残る
```

## 型安全性

bundler の external は文字列ベースで型がない:
```js
externals: { fs: 'node:fs' }  // fs の型は不明
```

vibe の effect external は型安全:
```vibe
effect Db { Query(String) -> String }
// ↑ import の型が effect 定義で確定
// parent が間違った型の実装を plug → Component Model リンクエラー
```

## Open Questions

1. **granularity**: effect 単位で external/bundled を切り替え可能か、operation 単位か
   → effect 単位が自然。operation 単位は分離しすぎ

2. **default handler**: standalone ビルドで handler がない effect をどうするか
   → `--standalone` で stub handler を自動注入 (Unit/empty string を返す)
   → or コンパイルエラー

3. **transitive externals**: ライブラリ A が B を使い、B が Db を external にする場合
   → A は B の Db external を知る必要があるか
   → Component Model の import は自動的に transitive

## Consequences

良い面:
- bundler external が型安全に: effect 定義 = import contract
- テスト容易性: handle で mock ↔ production で real impl を plug
- Component Model と自然に統合: import/export = external/bundled
- DCE: 不使用の external は自動除去
- Deno, webpack, rollup ユーザーに馴染みのあるメンタルモデル

悪い面:
- Effect handler の有無でビルド結果が変わる（暗黙的）
- 明示的な `external` 宣言がないとユーザーが意図を読みにくい
- #import ディレクティブの設計が必要 (ADR-0021)
