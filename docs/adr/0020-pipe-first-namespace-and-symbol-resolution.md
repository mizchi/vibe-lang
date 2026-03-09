# ADR-0020: Pipe-first 呼び出し規約と名前空間シンボル解決

- Date: 2026-02-25
- Status: accepted

## Context

既存仕様では `recv.method(...)` / `recv.prop` のようなメソッド風糖衣と、
`Type::method` 形式の型名 namespace シンボルが併存している。

一方、`vibe` は object-lane の `|>` を持ち、`normalize` 後の内部表現は
完全修飾シンボルへ決定的に解決される前提が強い。AI 生成・機械変換・レビューの観点では、
「呼び出しは `|>` ファースト」「`.` はデータアクセス専用」に寄せた方が曖昧性が小さい。

また、エラー経路を pipeline 上で可視化するため、Result 合成を第一選択にした
railway-oriented な記述規約を固定したい。

## Decision

### 1. Pipe-first 呼び出し規約

1. `x |> f` は `x |> f()` の省略形とする。
2. `x |> f(a, b)` は `f(x, a, b)` へ desugar する。
3. 複数段の pipe は左結合で評価する。

### 2. `|>` の曖昧性ポリシー

`|>` と他の二項演算子が同一式で混在し、括弧なしで解釈が複数あり得る場合は
パースエラーにする。

- `1 + 1 |> double` はパースエラー
- `(1 + 1) |> double` は許可

### 3. `.` の責務を限定

1. `.` は struct/record のメンバーアクセス専用とする。
2. `recv.method(...)` 形式のメソッド呼び出し糖衣は採用しない。
3. 関数値フィールドの呼び出しは `(obj.method)(...)` と書く。

### 4. 名前空間シンボルの正規形

1. 人間向けの名前空間記法は `Type::symbol` とする。
2. 完全修飾シンボルは `/pkg@version/module/Type::symbol` 形式とする。
3. 名前解決は lexical scope 優先で行う。
   `local > lexical > explicit import > prelude`
4. 内部アドレス参照は `<canonical-symbol>#<addr-hash>` 形式とする。

例:
- `/vibe/builtin@0.0.1/result/Result::and_then`
- `/vibe/builtin@0.0.1/result/Result::and_then#9b1f...`

### 5. 定義スタイル

1. 名前空間関数は `let Type::symbol = ...`（または同等の関数宣言）で定義する。
2. `impl` は trait 実装（`impl Trait for Type`）に限定する。
3. `impl Type::symbol` のような「メソッド機構としての別系統」は導入しない。

### 5.1 型所有 API の rename パターン

型に意味的に属する操作は、free function / builtin 名から `Type::verb` 形式へ
寄せていく。これは「メソッド糖衣」ではなく、型名 namespace による通常の
シンボル定義として扱う。

基本ルール:

1. 旧 API が `domain_verb(x, ...)` 形式でも、実体が特定の型操作なら
   `Type::verb(x, ...)` を正規形にする。
2. pipe-first では `x |> Type::verb(...)` を第一表記とする。
3. 移行期間中は旧名を alias として残してよいが、normalize / docs / examples は
   正規形へ寄せる。

例:

- `map_set(m, key, value)` → `Map::set(m, key, value)`
- pipe-first では `m |> Map::set(key, value)`

このパターンは、collection / string / bytes など「型の所有操作」として読める API に
適用する。逆に endpoint 横断の衝突回避 alias（`process_run`, `json_parse` など）は
別 ADR の canonical naming に従う。

### 6. Result 合成とエラー境界（Railway）

1. アプリケーション pipeline は Result 合成を第一選択にする。
2. 例外化・中断（`unwrap`/`handle`/`throw`）の境界は pipeline 上で明示する。
3. normalize 後の内部表現でも、どこでエラー境界を跨ぐか追跡可能にする。

### 7. 互換性

この移行で旧メソッド糖衣の互換レイヤは提供しない。非互換で進める。

## Consequences

- 良い影響:
  - 呼び出し規則が単純化し、`normalize` の決定性が上がる
  - AI 生成時に import 補完前提のメソッド記法へ依存しにくくなる
  - エラー処理境界を pipeline として読める
- トレードオフ:
  - 括弧必須の箇所が増え、短期的に記述量が増える
  - 旧 `recv.method(...)` スタイルのコードは rewrite が必要

## Follow-up

- parser: `|>` 混在曖昧性の専用エラーコードと修正ヒント（括弧提案）を追加する
- normalize/edit: 完全修飾シンボルから人間向け import へ再展開する規則を固定する
- normalize/edit: 旧 free function 名から `Type::symbol` 正規形への rewrite 候補
  （例: `map_set` -> `Map::set`）を段階的に追加する
- semver: 関数レベル semver とパッケージ semver の関係は別 ADR で定義する
