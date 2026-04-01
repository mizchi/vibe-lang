# ADR-0023: `is` パターンマッチ式

- Date: 2026-03-11
- Status: accepted
- Related: ADR-0016 (handle 統一構文)

## Context

variant の型判定とバインディング導入を簡潔に書きたいケースが頻出する。
現在は `match` で記述するが、単一パターンの判定には冗長:

```
// 現在: match で 2 分岐を書く必要がある
let msg = match result {
  Some(x) => use(x),
  _ => default_value
}

// ガード的な使い方でも同様に冗長
match v {
  Some(x) => { body },
  _ => ()
}
```

MoonBit は `v is Pattern` 中置式を提供しており、これを vibe にも導入する。

## Decision

### 構文

`expr is pattern` を中置式として導入する。

```
// Bool を返す型判定
v is Some(_)         // true if v matches Some(_)
v is None            // true if v matches None
v is Cons(_, _)      // true if v matches Cons(_, _)

// if 条件でのバインディング導入
if v is Some(x) {
  use(x)             // x はここで有効
}

// else 分岐との組み合わせ
if v is Some(x) {
  use(x)
} else {
  handle_none()
}
```

### desugar

内部的に `EMatch` に変換する。新しい AST ノードは不要。

```
// Bool-only（if 外）
v is Some(_)
→ EMatch(v, [(PCtor("Some", [PWild]), EBool(true)),
              (PWild, EBool(false))])

// if 条件でのバインディング
if v is Some(x) { body } else { alt }
→ EMatch(v, [(PCtor("Some", [PBind("x")]), body),
              (PWild, alt)])

// else なし
if v is Some(x) { body }
→ EMatch(v, [(PCtor("Some", [PBind("x")]), body),
              (PWild, EUnit)])
```

### バインディングのスコープ規則

1. `if v is Pat { body }` — パターン内のバインド変数は `body` のみで有効
2. `if v is Pat { body } else { alt }` — バインド変数は `body` のみ。`alt` では無効
3. `let b = v is Pat` — `b: Bool` が返る。パターン内のバインド変数は**導入されない**
4. `&&` / `||` との結合は Phase 1 では禁止

```
// OK
if v is Some(x) { use(x) }

// OK: Bool として使う（バインディングなし）
let is_some = v is Some(_)

// ERROR (Phase 1): && との結合は未サポート
if v is Some(x) && x > 0 { ... }
```

### パーサー実装

`if` の条件式をパースする際に `expr is pattern` を検出する:

1. `if` の後に式をパース
2. 次のトークンが `is` (識別子) なら、右辺をパターンとしてパース
3. `if` + `is` の組み合わせを `EMatch` に desugar
4. `if` 外で `is` が使われた場合は Bool を返す `EMatch` に desugar

`is` はソフトキーワード（識別子としても使用可能）とする。
中置位置で `expr is` が出現したときのみキーワードとして認識される。

### 対応パターン

Phase 1 では既存の `Pat` をそのまま利用:

| パターン | 例 | 意味 |
|---|---|---|
| コンストラクタ | `v is Some(x)` | variant マッチ + バインド |
| ワイルドカード付き | `v is Some(_)` | variant マッチのみ |
| 引数なし | `v is None` | 0-ary コンストラクタ |
| タプル | `v is (x, _)` | タプル分解 |
| リテラル | `v is 42` | 値比較 |
| ネスト | `v is Some(Cons(x, _))` | ネストしたパターン |

## Consequences

良い面:
- 単一パターンの型判定が簡潔に書ける（`match` の 2 分岐が不要）
- `if let` (Rust) や smart cast (Kotlin) 相当の機能を統一構文で提供
- 実装コストが低い（パーサーで検出 → `EMatch` に desugar。新 AST ノード不要）
- 既存の `Pat` と `EMatch` をそのまま再利用

悪い面/トレードオフ:
- `is` がソフトキーワードになるため、変数名 `is` が中置位置で使えなくなる
- `&&` との結合が Phase 1 で未サポートのため、複合条件で `match` に戻る必要がある
- バインディングの有効スコープが `if` の then-branch に限定されるという暗黙の規則がある
