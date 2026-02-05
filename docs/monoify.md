# Monoify Design (Int/Float/Double)

## 目的
- `Int/Float/Double` の算術を **boxing や動的ディスパッチ無し**で実行する。
- `Num` 制約付きのジェネリクスを **実行時表現に落とさず**に特殊化する。
- wasm-gc / wasm-js-string 両ターゲットで **同じ型決定**を使う。

## しないこと
- `&Num` のような **ランタイム共通表現**は導入しない。
  - monoify の目的（分岐・boxing削減）と逆方向。
- 完全な trait システムは作らない（`Num` 限定）。
- 全ジェネリクスの monoify は当面しない（`Num` 対象から開始）。

## スコープ
- 対象型: `Int`, `Float`, `Double`
- 対象演算: `+ - * / == <`（内部では `__add/__sub/__mul/__div/__eq/__lt/__neg`）
- 対象関数: `T: Num` を含む関数（数値プリミティブのみ）

## 型システムの設計
### `Num` 制約（型クラス）
- 型変数に **制約集合**を持たせる。
- `Num` は `{Int, Float, Double}` のみ許可。

#### 例（構文案）
```
fn[T: Num] add(a: T, b: T) -> T { a + b }
```
※ 構文を増やさず内部制約として持つ場合は、`__add` 使用時に型変数へ `Num` 制約を付与する。

### 制約付与ルール
- `__add/__sub/__mul/__div/__eq/__lt/__neg` の型推論時に、
  - 引数が型変数なら `Num` 制約を付与する。
  - 具体型なら `Num` 制約と整合性を検査する。

### 制約検証
- 型変数が具体型に解決された時点で `Num` 制約に含まれるか検証する。
- 不整合なら型エラー。

## Monoify パス
### 位置づけ
`parse -> typecheck -> monoify -> codegen`

### 生成キー
```
MonoKey = (fn_id, [type_arg...])
```
`fn_id` は既存の content-hash を利用し、`type_arg` を付与して一意化。

### 手順
1. 型付け後 AST を走査し、`T: Num` を含む関数呼び出しの **具体型**を収集。
2. `MonoKey` ごとに関数定義を複製し、型変数を具体型に置換。
3. 呼び出しサイトを **特殊化関数**へ差し替え。
4. 本体の `__add` などは型が具体化しているため、コード生成で直接 `i32/f32/f64` 命令へ。

### 生成名（例）
```
add[Int]    -> add_i32
add[Float]  -> add_f32
add[Double] -> add_f64
```
内部的には `fn_id + type_args` で一意性を確保する。

## コード生成方針
- **型を見て命令を選ぶ**だけにする（分岐なし）。
- wasm-gc: `i32/f32/f64` を直接 emit
- wasm-js-string: `Float/Double` は boxing/unboxing を回避できる箇所は直接化

## 例
```
fn[T: Num] add(a: T, b: T) -> T { a + b }

add(1, 2)        -> add_i32(1, 2)
add(1.0f, 2.0f)  -> add_f32(1.0f, 2.0f)
add(1.0, 2.0)    -> add_f64(1.0, 2.0)
```

## 実装の最小ステップ
1. 型変数に制約集合（`Num`）を追加
2. `__add/...` の型推論で制約付与
3. Monoify パス（Num だけ対象）
4. コード生成は既存の型分岐を維持（既に `Int/Float/Double` 対応済み）

## 検証
- 数値演算のテスト（Int/Float/Double）
- monoify 有無での wasm サイズ・ベンチ比較
- 失敗ケース: `T: Num` に `String` が流れる
