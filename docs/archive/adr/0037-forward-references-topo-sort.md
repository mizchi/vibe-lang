# ADR-0037: トップレベル前方参照 (topo sort)

- Date: 2026-03-27
- Status: accepted

## Context

vibe 言語ではトップレベルの `let` 束縛が定義順に評価されるため、後方で定義された関数を先に参照できなかった (#8)。相互再帰はもちろん、単純な前方参照も不可能で、ユーザーは手動で定義順を依存関係に合わせる必要があった。

インタプリタ (evaluator) では既に `topo_sort_let_stmts` による並べ替えを実装済みだったが、compiled backend (WASM codegen) には未適用だった。インタプリタ廃止 (#51) に伴い、compiled backend でも同等の機能が必要。

## Decision

### 1. WASM codegen bundle で topo sort を適用

`bundle_for_wasm_impl` でメインモジュールの文を `topo_sort_let_stmts` で並べ替える。

副作用文 (`LetMut`, `Assign`, `IndexAssign`, 最後以外の `Expr`) が存在する場合はソートをスキップするガードを入れるが、**トップレベルにこれらの文は置けない**ため実質的には常にソートが適用される。ガードは防御的措置。

### 2. Checker pre-scan: 戻り値型注釈なし関数の前方宣言

既存の pre-scan は `ret=Some(r)` (戻り値型注釈あり) の関数のみ前方宣言していた。これを拡張し、以下の条件を満たす関数も前方宣言する:

- 全パラメータに型注釈がある
- 関数 body が自身の名前を参照していない (自己再帰でない)

戻り値型は `fresh_type_var` で仮登録し、本パスの型推論で確定する。`forward_annotated_values` に登録することで `effective_rec = true` にならず、自己再帰の `let rec` + 戻り値型注釈要求は維持される。

### 3. トップレベルの設計原則

| 制約 | 理由 |
|------|------|
| パラメータ型注釈は必須 | トップレベルは明示的な API 境界 |
| 自己再帰は `let rec` + 戻り値型注釈 | 再帰関数の型推論は undecidable になりうる |
| 相互再帰はパラメータ型注釈があれば可 | topo sort + pre-scan で解決 |
| 副作用文はトップレベルに不可 | 評価順序の保証が必要な文は関数内に置く |

## Consequences

**良い面:**
- Rust/OCaml/MoonBit と同様、定義順を気にせずトップレベル関数を書ける
- 相互再帰が自然に書ける (`is_even`/`is_odd` パターン)
- インタプリタ廃止後も前方参照が動作する

**悪い面:**
- topo sort のオーバーヘッド (循環検出 + 並べ替え) が毎回発生するが、トップレベル文数は通常少ないため無視できる
- 型注釈なしパラメータの関数は前方宣言できない (bidirectional type checking #39 で将来対応)
