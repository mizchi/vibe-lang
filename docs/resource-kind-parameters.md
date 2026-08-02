# ADR-0094: resource kind パラメータの宣言側構文と内部表現

Status: proposed

Date: 2026-08-02

Related: ADR-0071 (effectset / operation-level row), ADR-0075 (vibex runtime
contract), ADR-0084 (effect taxonomy), ADR-0088 (capability authorization
surface), #1343, #1218, #1143

## Context

[ADR-0084](effect-taxonomy-entry-policy.md) は capability effect と algebraic
effect を **resource kind パラメータの有無**で型レベルに区別する、と決めた。
[effect-taxonomy-review.md](effect-taxonomy-review.md) の「未解決のまま残る
論点」に残っていた唯一の項目が、その**宣言側の構文**である
(`effect Fs[R: Fs::Root]` は本文中の便宜表記であって決定ではない)。#1343 の
最初のチェックボックスがこれにあたる。

本 ADR はその構文と、対応する内部表現を決める。決定は実装調査に基づく —
以下は現状の実測であり、構文の選択肢を強く制約する。

### 現状の実測 (2026-08-02)

1. **builtin effect には `TDEffect` が無い**。host effect の内部表現は
   builtin 関数シグネチャ (`CtFn`) の第3スロット `Option[String]` **ただ1つ**
   である。`Fs` という effect の宣言はどこにも存在せず、
   `("Fs::read_file", CtFn(..., Some("Fs")), ...)`
   (`codegen/common_base/builtin_registry.vibe`) と `builtins_*.vibe` の
   `if name == ...` チェーンに散らばった `Some("Fs")` リテラルがすべて。
2. **`effect Fs[R: Fs::Root]` は現状パースできない**。
   `parse_type_params_list` (`parser/parser_base.vibe`) は**裸の識別子のみ**を
   受理し、それ以外は `expected type parameter name or ']'` で throw する。
   bound 構文も `_` も未対応。
3. **`TaskGroup` 系の escape 検査は型引数の個数をハードコード照合している** —
   `is_region_tagged_ty` / `sp_spawnable_ok` / spawn call-site 検出 /
   `TaskGroup::run` の region generativity / codegen の計5箇所が
   `Array::length(targs) == 2` 等で分岐する (#1181 の実測記録、
   `checker.vibe` の該当コメント参照)。
4. **row label は文字列**であり、generic instantiation は既に**ラベル本文**に
   載っている (`"State[Int]"`、ADR-0071/#1340)。`row_label_base` が `[` で
   base 名を切り出す。containment は現状 instantiation-insensitive。
5. **row のラベルが実在の effect を指すかは検査されていない**。
   `with { Frobnicate }` は素通りする (module-local な `TDEffect` しか見えず、
   import された user effect と builtin を区別できないため、素朴な
   「既知ラベル検査」は false positive を生む)。
6. **`wit_gen` の分類は反転している**。「entry file 内に `effect X {...}` 宣言が
   あれば interface を生成、無ければ host capability のコメント」という規則で、
   ADR-0084 の分類 (宣言された algebraic effect こそ境界に出てはいけない) と
   逆になっている。これが #1143 の「ねじれ」の実体。
7. **ADR-0075 Phase 2 (`resource X : Kind = ...` 宣言) は未実装**。
   parser / AST / `TypeDef` のいずれにも resource 宣言は無い
   (`@vibex/wasm_wit_parser` の `TDResource` は WIT IDL 用の別物)。
   したがって `Process::Root` には現状いかなる表現も無い。

## Decision

### 1. 宣言側構文: 型パラメータリスト内の **bound 付きパラメータ**

```vibe skip
effect Fs[R: Fs::Root] {
  read_file(String) -> Bytes
}

// singleton resource kind は `_` で受ける (束縛名が不要な場合)
effect Stdout[_: Process::Root] {
  write_stream(String) -> Unit
}
```

- 新しい括弧グループも新しい sigil も**導入しない**。ADR-0071/#1340 が既に
  `effect State[S]` の型パラメータリストを持っているので、そこに bound を
  書けるようにするだけの拡張とする。
- **resource kind パラメータか通常の型パラメータかは、bound の有無ではなく
  bound が指す名前の kind で判別する**。`R: Fs::Root` の `Fs::Root` が
  resource kind として宣言されていれば resource パラメータ、trait であれば
  通常の型パラメータ境界 (将来の拡張余地)。判別は registration 時に行い、
  構文では区別しない。
- `_` をパラメータ名として受理する (束縛しない resource パラメータ)。
- **却下した代替**: 別括弧 (`effect Fs[T] for Fs::Root`) は row 構文にも
  波及して表面が二重化する。sigil (`[%R]`) は既存の型パラメータと視覚的に
  分裂し、ADR-0071 が「row の文法は1つ」と決めた方針に反する。

### 2. 内部表現: `TDEffect` に**第4スロットを追加**、`CtFn` は不変

```
TDEffect(name, ops, tparams, rparams)
                              ^^^^^^^ Array[(String, String)] = (param name, kind path)
```

- 追加は**末尾**とする (`TDStruct` の #829、`TDEffect` の #1340 と同じ規約 —
  既存の positional match を壊さない)。
- **`CtFn` の `Option[String]` は広げない**。row を構造化データにする変更は
  コンパイラ全域の `CtFn` パターンマッチ数百箇所に波及し、ADR-0071 の
  OperationRef 正規化と一体で行うべき別作業である。resource 引数は
  generic instantiation と同じく**ラベル本文**に載せる (`"Fs[SrcTree]"`)。
  `row_label_base` が既にこの形を扱える。

### 3. builtin は registry のメタデータ列で分類する (`TDEffect` を作らない)

builtin effect に `TDEffect` を合成する案は**採らない**。合成すると
`effect_is_declared` が builtin に対して `true` を返すようになり、
`wit_gen` が全 host effect に対して WIT interface を生成し始める
(上記「現状の実測 6」の反転が、意図せぬ形で一気に発火する)。

代わりに `registry_typed_rows` に **effect class + 既定 resource kind** の列を
足し、`builtins_*.vibe` の if-chain 側は既存の `Some("Fs")` のままとする
(ラベルは変えない)。分類はラベル名から metadata を引く一段の参照にする。

### 4. 三分類の判定は metadata 由来にする (「宣言されているか」では判定しない)

```
effect_class(name) -> Capability | Algebraic | CoreAmbient
```

- `CoreAmbient`: `Error` / `Exception[E]` (既存 `is_exception_effect_name`)、
  および `Async` (ADR-0089 で backend 選択であって権限ではないと整理済み)。
- `Capability`: registry metadata が capability と宣言しているもの、または
  resource パラメータを持つ user effect。
- `Algebraic`: resource パラメータを持たない user effect。
- **module-local に `TDEffect` があるか否かで分類してはならない** — import
  された user effect が builtin と区別できず、`wit_gen` の反転を再生産する。

### 5. resource 引数は Phase 1 では**暗黙**とし、表面構文を変えない

`perform Fs::read_file(...)` / `with { Fs }` は無変更。resource 引数省略時は
既定 singleton (`Fs[Process::Root]`) へ展開する sugar として扱う
(effect-taxonomy-review.md の Phase 1)。これにより compiler 自身のソースを
含む既存コードは無風で、bootstrap bump も不要。

## 実装順 (#1343 のチェックボックスへの対応)

Phase 0 の前提である ADR-0075 Phase 2 (`resource` 宣言) が**未着手**なので、
`Fs::Root` のような kind 名を書けるようになるのは先である。したがって
**最初に実装できるのは構文ではなく分類 metadata** である。

1. **(構文不要・最小)** registry のメタデータ列 + `effect_class` の導入。
   散在する host-effect リテラル列
   (`test_bench_ambient_effects`、`cache_safe_row`、`wit_gen` の暗黙規則) を
   この単一の source of truth に寄せる。表面挙動は不変、`wit_gen` の反転は
   この段では**直さない** (挙動変更を分離するため)。
2. ADR-0075 Phase 2: `resource X : Kind = <literal>` 宣言と `Process::Root`
   singleton kind。
3. parser: `parse_type_params_list` に bound と `_` を追加。`TDEffect` の
   `rparams` スロット追加と registration。
4. `wit_gen` を `effect_class` 起点に切り替える (#1143 のねじれ解消)。
5. main の closed row 検査 (ADR-0084 Phase 3、warning から)。ADR-0088
   Decision 5 の段階ゲートに接続。
6. Phase 5 enforce + `Entry.requires ⊆ ComposedHost.provides` の preflight。

## Consequences

- resource kind を**型引数として既存の型に足すことは禁止**する。上記「現状の
  実測 3」の5箇所が `Array::length(targs) == N` で黙って分岐から漏れるため、
  やる場合は同一コミットで lockstep 修正すること (#1181 の再発防止)。
- row containment は当面 instantiation-insensitive のままなので、
  `with { Fs }` は `Fs[Anything]` を authorize する。resource 単位の最小権限が
  実効化するのは ADR-0071 の OperationRef 正規化が入ってからで、本 ADR は
  その表現を先に確定させるだけである。
- 表面構文を変えないため、compiler 自身のソースは Phase 1〜3 で無変更。

## References

- [effect-taxonomy-entry-policy.md](effect-taxonomy-entry-policy.md) (ADR-0084)
- [effect-taxonomy-review.md](effect-taxonomy-review.md) (移行計画 Phase 0〜5)
- [capability-authorization-surface.md](capability-authorization-surface.md) (ADR-0088)
- [effectset.md](effectset.md) (ADR-0071)、[vibex-runtime-contract.md](vibex-runtime-contract.md) (ADR-0075)
