# ADR-0042: トップレベル未処理 effect 禁止と file/shell surface の整理

- Date: 2026-03-31
- Status: proposed

## Context

### 現状

checker は `type_check` / `type_check_with_env` の両エントリで、トップレベル文に対し `effect_scope_all()` を渡している (`typecheck_stmts.mbt:20,90`)。`effect_scope_all()` は `allow_all: true` であり、すべてのエフェクトが許可される。これは、ファイルモジュールのトップレベルで `sh("ls")` や `throw("err")` や `perform Effect::Op(x)` を直接書いてもチェッカーがエラーにしないことを意味する。

一方、`let mut` はトップレベルで明示的に禁止されている (`TopLevelLetMut` エラー, `typecheck_stmts.mbt:708-709`)。これは「トップレベルは pure であるべき」という設計意図の部分的な表れだが、effect についてはこの制約が欠けている。

ADR-0041 で `_start` エントリポイントの戻り値型を `Unit` に制限し、`with { Effects }` 句で capability を明示宣言する方針を決めた。しかし、`_start` の外側（トップレベルの `let` 束縛や式文）に未処理 effect が残り得る状態では、この方針が不完全になる。

### 曖昧な surface 区分

`vibe run`/`vibe check`/`vibe compile` はファイルモジュールを処理するが、`vibe shell`/`vibe shell --tui`/`vibe shell --ai` は対話的にトップレベル式を受け付ける。`vibe test` はテストブロック内で独自の effect scope を持つ。これらの surface ごとに「トップレベルで何が許されるか」の契約が文書化されていない。

## Decision

### 1. ファイルモジュールのトップレベルで未処理 effect を禁止する

ファイルモジュール (`.vibe` ファイル) のトップレベルでは、以下の制約を課す:

**許可**:

```
// Pure な式
let x = 1 + 2

// Pure な関数定義
let greet = (name) -> "hello " + name

// handle で effect を閉じた式 (全体として pure)
let result = handle {
  throw("error")
} {
  Error(msg) => "caught: " + msg
}

// _start エントリポイント (ADR-0041)
export let _start = () -> Unit with { Stdout } {
  Stdout::write_stream("hello\n")
}
```

**拒否**:

```
// トップレベル sh → エラー
let output = sh("ls")

// トップレベル throw → エラー
throw("fail")

// トップレベル perform → エラー
perform Fs::ReadFile("x.txt")

// await → エラー
let data = await fetch("...")

// let mut → 既にエラー (既存)
let mut x = 0
```

**原則**: トップレベル式の最終的な effect scope は pure でなければならない。`handle` ブロックが effect を消去して pure にする場合は許可される。

### 2. Surface ごとの契約

| Surface | コマンド | トップレベル effect | 最終式の値 | effect scope |
|---------|----------|-------------------|-----------|-------------|
| **file module** | `run`, `check`, `compile` | 禁止 (pure 必須) | `_start` 経由 | `effect_scope_none()` |
| **test** | `test` | テストブロック内で許可 | assert 結果 | ブロック内 `effect_scope_all()` |
| **interactive** | `shell`, `shell --tui`, `shell --ai` | 許可 (暗黙全許可) | 最終式の値を表示 | `effect_scope_all()` |

各 surface の詳細:

- **file module** (`run`/`check`/`compile`): ファイルのトップレベルは pure。副作用は `_start` 関数のエフェクト宣言 (`with { ... }`) で明示する。checker は `effect_scope_all()` の代わりに `effect_scope_none()` (新設) をトップレベルに渡す。
- **test**: `test "name" { ... }` ブロックの内部は引き続き `effect_scope_all()` とする。テストコードでは `sh`, `throw`, I/O を自由に使える。トップレベル文 (テストブロック外) は file module と同じ pure 制約。
- **interactive** (`shell`/`shell --tui`/`shell --ai`): 対話セッションでは全 effect を暗黙許可する。`effect_scope_all()` を維持。REPL のフィードバックループでは制約が UX を損なう。

### 3. `effect_scope_none()` の導入

```
fn effect_scope_none() -> EffectScope {
  EffectScope::{ allow_all: false, allowed: {}, rest: None }
}
```

ファイルモジュールのトップレベルに対して渡す新しい scope。この scope では `sh`, `throw`, `perform`, `await` などすべてのエフェクトが `EffectGuardNotSatisfied` エラーになる。ただし `handle` ブロック内部では `effect_scope_extend` によりハンドルされたエフェクトが許可される（既存の仕組みで動作する）。

### 4. checker の変更点

`type_check_with_aliases` と `type_check_with_env` の呼び出しを変更:

```
// Before
type_check_stmts(env, ast.stmts, aliases, effect_scope_all(), false, ...)

// After (file module)
type_check_stmts(env, ast.stmts, aliases, effect_scope_none(), false, ...)
```

interactive / shell 用の entry point は `effect_scope_all()` を維持する。呼び出し元で surface を判別するか、別の entry point (`type_check_interactive`) を用意する。

## Implementation Plan

### Phase 1: effect_scope_none と file module 制約

1. `typecheck_effects_set.mbt` に `effect_scope_none()` を追加
2. `type_check_with_aliases` / `type_check_with_env` で `effect_scope_none()` を使用
3. interactive 用の `type_check_interactive` entry point を新設 (`effect_scope_all()` を維持)
4. shell / REPL のコードパスを `type_check_interactive` に切り替え

### Phase 2: fixture 更新

1. トップレベルで `sh`, `throw`, `perform` を使っている既存 fixture に `handle` を追加するか、テスト期待値を更新
2. 新規 fixture 追加: `toplevel_unhandled_sh.diag`, `toplevel_unhandled_throw.diag`, `toplevel_handled_pure.vibe` (成功ケース)

### Phase 3: ドキュメントと診断メッセージ

1. `EffectGuardNotSatisfied` の診断メッセージにトップレベル文脈用のヒントを追加: "top-level expressions must be pure; use `handle { ... } { ... }` to handle effects"
2. 言語仕様ドキュメントの更新

## Consequences

### Good

- **Pure contract の完成**: `let mut` 禁止と合わせて、ファイルモジュールのトップレベルが完全に pure になる
- **ADR-0041 との整合**: `_start` のエフェクト宣言が唯一の副作用導入点となり、capability が明示される
- **静的解析の強化**: トップレベルが pure であることを前提にした最適化 (pure test cache 等) が安全になる
- **Surface 契約の明文化**: `run`/`check`/`compile`/`test`/`shell` の違いが文書化される

### Bad

- **既存コードの破壊**: トップレベルで `sh` や `throw` を直接使っているファイルが壊れる
- **学習コスト**: `handle` でエフェクトを閉じるパターンの理解が必要
- **Interactive との非対称性**: file module は pure 強制、shell は全許可。同じコードが surface によって通ったり通らなかったりする

### Neutral

- `test` ブロック内部は変更なし（既に独自の scope を持つ）
- `handle` の既存セマンティクスは変更なし（`effect_scope_extend` による scope 拡張は既存の仕組み）
