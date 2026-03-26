# Builtin Single Source of Truth (SSoT) Design

## 問題

ビルトイン関数の型シグネチャが以下の場所に散在・重複している:

| 場所 | 役割 | 形式 |
|------|------|------|
| `src/checker/typecheck_call_builtin_handler_*.mbt` | Host checker | MoonBit match arm |
| `src/checker/prelude.mbt` | Host prelude source | vibe source 文字列 |
| `src/checker/builtin_modules.mbt` | Host module builtins | vibe source 文字列 |
| `src/codegen/wasm_codegen_call_builtin_pre_user.mbt` | Host codegen | WASM emit |
| `vibe/compiler/checker/builtins_*.vibe` | Selfhost checker | vibe 関数 |
| `vibe/compiler/codegen/*/builtin_bodies*.vibe` | Selfhost codegen | vibe 関数 |

host と selfhost で同じシグネチャを別々に管理しており、不一致が頻発。

## 設計: .vibe をSSoTにする

### Step 1: ビルトイン宣言ファイル (`vibe/builtins/declarations.vibe`)

```vibe
// vibe/builtins/declarations.vibe
// SSoT: 全ビルトイン関数の型シグネチャ宣言

//# Array
declare Array::new() -> Array[T]
declare Array::length(Array[T]) -> Int
declare Array::get(Array[T], Int) -> T
declare Array::push(Array[T], T) -> Array[T]
declare Array::set(Array[T], Int, T) -> Array[T]
declare Array::map(Array[T], (T) -> U) -> Array[U]
declare Array::filter(Array[T], (T) -> Bool) -> Array[T]
declare Array::find_index(Array[T], (T) -> Bool) -> Option[Int]
declare Array::sort_by(Array[T], (T, T) -> Int) -> Array[T]
declare Array::contains(Array[T], T) -> Bool

//# String
declare String::length(String) -> Int
declare String::substring(String, Int, Int) -> String
declare String::split(String, String) -> Array[String]
declare String::join(Array[String], String) -> String
declare String::to_upper(String) -> String
declare String::to_lower(String) -> String
declare String::concat(String, String) -> String
declare String::equals(String, String) -> Bool

//# Int
declare Int::parse(String) -> Option[Int]

//# Double
declare Double::parse(String) -> Option[Double]

//# Set
declare Set::new() -> Set[T]
declare Set::add(Set[T], T) -> Set[T]
declare Set::contains(Set[T], T) -> Bool
declare Set::remove(Set[T], T) -> Set[T]
declare Set::size(Set[T]) -> Int
declare Set::to_array(Set[T]) -> Array[T]
declare Set::from_array(Array[T]) -> Set[T]

//# Option
declare Option::map(Option[T], (T) -> U) -> Option[U]
declare Option::and_then(Option[T], (T) -> Option[U]) -> Option[U]
declare Option::unwrap_or(Option[T], T) -> T
declare Option::is_some(Option[T]) -> Bool
declare Option::is_none(Option[T]) -> Bool

//# Map
declare Map::new() -> Map[K, V]
declare Map::set(Map[K, V], K, V) -> Map[K, V]
declare Map::get(Map[K, V], K) -> Option[V]
declare Map::has_key(Map[K, V], K) -> Bool
declare Map::remove(Map[K, V], K) -> Map[K, V]
declare Map::size(Map[K, V]) -> Int
declare Map::keys(Map[K, V]) -> Array[K]
declare Map::values(Map[K, V]) -> Array[V]

//# IO
declare println(String) -> Unit
declare print(String) -> Unit
declare assert(Bool) -> Unit
declare assert_eq(T, T) -> Unit
```

### Step 2: コンパイル時にパースして中間表現に変換

```
declarations.vibe → parse → Array[BuiltinDecl]
```

```
struct BuiltinDecl {
  name: String       // "Array::get"
  params: Array[Type] // [Array[T], Int]
  ret: Type          // T
  effects: Array[String] // []
}
```

### Step 3: host と selfhost の両方がこの中間表現を消費

**Host compiler**:
- `src/checker/` が `declarations.vibe` をパースして型チェック情報を生成
- `src/codegen/` は name → codegen handler のマッピングのみ保持 (シグネチャは宣言から導出)

**Selfhost compiler**:
- `vibe/compiler/checker/` が同じ `declarations.vibe` をパースして lookup テーブルを構築
- 現在の `builtins_array.vibe` 等の手動 match arm は自動生成に置換

### Step 4: 段階的移行

| Phase | 内容 |
|-------|------|
| Phase 0 | `declarations.vibe` を定義、パーサーを実装 |
| Phase 1 | Host checker が declarations.vibe から型情報を読み込み |
| Phase 2 | Selfhost checker も同じファイルから読み込み |
| Phase 3 | `builtin_modules.mbt` の vibe source 埋め込みを declarations.vibe に統合 |
| Phase 4 | codegen handler のシグネチャ検証を declarations から自動化 |

## メリット

1. **SSoT**: シグネチャの定義が1箇所
2. **契約**: host と selfhost が同じ宣言を共有
3. **検証可能**: declarations と codegen の不一致を自動検出
4. **拡張容易**: 新ビルトイン追加は declarations に1行追加するだけ
5. **ドキュメント**: declarations.vibe がそのまま API リファレンス

## `declare` 構文

```
declare <Name>::<method>(<params>) -> <return> [with { <effects> }]
```

- `declare` は新しいキーワード (既存の `let`/`export let` とは異なる)
- body なし (型宣言のみ)
- 実装は codegen が提供 (host) または builtin_bodies が提供 (selfhost)
