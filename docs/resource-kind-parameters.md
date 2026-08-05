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
   `with Frobnicate` は素通りする (module-local な `TDEffect` しか見えず、
   import された user effect と builtin を区別できないため、素朴な
   「既知ラベル検査」は false positive を生む)。
6. **`wit_gen` の分類は反転しており、かつ checker とは独立している**。
   `wit_collect_effect_defs` は **AST の `SEffectDef` 文だけ**を走査する
   (entry file + export 対象)。checker の `TDEffect` レジストリも
   `effect_is_declared` も参照しない。規則は「`effect X {...}` 宣言が見つかれば
   interface を生成、無ければ host capability のコメント」であり、ADR-0084 の
   分類 (宣言された algebraic effect こそ境界に出てはいけない) と逆。これが
   #1143 の「ねじれ」の実体で、**checker 側の表現を変えても自動的には直らない**
   (wit_gen 自身の規則を差し替える必要がある)。
7. **ADR-0075 Phase 2 (`resource X : Kind = ...` 宣言) は未実装**。
   parser / AST / `TypeDef` のいずれにも resource 宣言は無い
   (`@vibex/wasm_wit_parser` の `TDResource` は WIT IDL 用の別物)。
   したがって `Process::Root` には現状いかなる表現も無い。

## Decision

### 0. 粒度には**2つの独立した軸**がある (provider 軸 / consumer 軸)

以降の決定はすべてこの分離を前提にする。混同すると、片方の都合でもう片方の
表現を壊すことになる。

| 軸 | 単位 | 誰のための粒度か | 具体物 |
|---|---|---|---|
| **provider 軸** | effect 名 (`Fs` / `Http` / `Socket`) | **実装契約**。どの WASI/host provider が実装するか | host import 束、WIT interface、binding、resource kind |
| **consumer 軸** | operation (`Http::request`) | **最小権限**。呼ぶ側が `with` に何を宣言するか | `with ...` row、`effectset`、ADR-0088 の `allows` |

- provider 軸を consumer の都合で割ってはならない。`Http` を
  `HttpServer`/`HttpClient`/`HttpIncoming` という**別 effect** に分割すると、
  1つの host HTTP provider に対する実装契約が3つに断片化する
  (raw import 層は `Http` のまま残るので、層ごとにラベルが食い違う —
  実際 `builtins_net.vibe` が現にその状態にある)。
- consumer 軸の細粒度は **ADR-0071 が既に定めた operation-level row** で表す。
  `with Http::request` (egress) と `with Http::listen` (serve) は
  別々に書ける。束ねた名前が欲しければ
  `effectset Http::Client = { Http::request, Http::response_status, ... }` —
  effectset は透明な compile-time alias で runtime identity を持たないので、
  provider 契約を汚さない。
- resource kind パラメータ (本 ADR の主題) は**第3の軸**であり、provider 軸の
  「どのインスタンスか」を指す (`Fs[SrcTree]` の `SrcTree`)。operation 軸とは
  直交する。ADR-0071 が `NormalizedEffectArguments` を型引数 / region 引数 /
  logical resource 引数の**別 kind**として保持すると決めているのはこのため。

> **実装状況 (#1343)**: consumer 軸は `perform Eff::Op` の経路でしか効いて
> いなかった。builtin 呼び出しの経路は `builtin_call_effect` が裸の effect
> ラベルを返し `decl_authorizes_effect(declared, "Fs")` で照合していたため、
> `with Fs::read_file` は `missing { Fs }` で reject され、**host
> capability には effect 全体以外の粒度が存在しなかった**。`with Http`
> のような粗い row が強制されていたのはこれが原因。builtin 経路を
> operation ラベルでも認可するよう修正した (裸の effect も従来どおり通るので
> 純粋な緩和)。

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
TDEffect(name, ops, params, param_kinds)
                    ^^^^^^  ^^^^^^^^^^^ Array[String]、params と同じ長さの
                    |                   parallel 配列。"" = 通常の型パラメータ、
                    |                   それ以外 = resource kind の path
                    既存の Array[String] (#1340) のまま。宣言順を保持する
```

- **宣言順を保持するため、resource パラメータを別配列に分離しない**。
  採用した構文は両者を1つの位置リストに書くので、`effect E[R: K, T]` と
  `effect E[T, R: K]` を分離配列で表すと区別できなくなり、後続の明示
  instantiation `E[X, Y]` でどちらが resource 引数か決まらない。既存の
  `params: Array[String]` を**全パラメータの順序付きリストのまま**にし、
  同じ添字で引く `param_kinds` を並置する (`""` が通常の型パラメータ)。
  これにより #1340 の `tparams` 消費側 (`effect_tparams` /
  `effect_fresh_targs` / `subst_type_params`) の**シグネチャは変わらない**が、
  **意味は変わる — 消費側は `param_kinds` を見て分岐する必要がある**
  (Codex review on PR #1356)。`effect_fresh_targs` は現在すべての要素に対して
  無制約な `CtVar` を作る (`checker.vibe`) が、resource パラメータは推論変数
  ではなく**論理リソースの同一性** (`Fs[SrcTree]` の `SrcTree`) なので、
  fresh var を割り当ててはならない。resource 引数は宣言された resource へ
  解決し、その kind が宣言の kind と一致するかを検査する別経路にする。
  この分岐を入れずに resource パラメータを `params` に載せると、kind 検査が
  効かないまま `Fs[SrcTree]` と `Fs[AnythingElse]` が単一化してしまう。
  したがって実装順 3 は「スロット追加 + registration」だけでは閉じず、
  **消費側3関数の kind 分岐までを1単位**とする。
- 追加は**末尾**とする (`TDStruct` の #829、`TDEffect` の #1340 と同じ規約 —
  既存の positional match を壊さない)。
- 宣言順に制約は課さない (「resource パラメータは先頭にまとめる」等の規則は
  採らない) — 順序が表現に保存されるので不要。
- **`CtFn` の `Option[String]` は広げない**。row を構造化データにする変更は
  コンパイラ全域の `CtFn` パターンマッチ数百箇所に波及し、ADR-0071 の
  OperationRef 正規化と一体で行うべき別作業である。resource 引数は
  generic instantiation と同じく**ラベル本文**に載せる (`"Fs[SrcTree]"`)。
  `row_label_base` が既にこの形を扱える。

### 3. builtin は registry のメタデータ列で分類する (`TDEffect` を作らない)

builtin effect に `TDEffect` を合成する案は**採らない**。理由は
**checker 側の副作用**である — `effect_is_declared` が builtin に対して
`true` を返すようになると、#813/#828 の handler arm 検証と perform 検証が
host effect にも一斉に効き始める: `handle body with Fs { ... }` の arm 名 /
payload arity / **網羅性**が検査対象になり、部分的な `with Fs` handler は
`non-exhaustive handler` で reject される。しかし ADR-0088 が記録したとおり
**builtin operation は host import 直呼びに lower され、その handler arm は
そもそも実行されない** (vacuous-handle elimination)。実行されないコードを
新たに型検査して既存プログラムを弾くことになるため、これは retrofit の
Phase 1 (「表面無変更・既存プログラム無破壊」) と両立しない。

> **訂正 (Codex review on PR #1355)**: 初稿はここで「合成すると `wit_gen` が
> 全 host effect に WIT interface を生成し始める」と書いていたが、これは
> 誤りだった。`wit_gen` は `SEffectDef` (AST) だけを見ており `TDEffect` も
> `effect_is_declared` も参照しない (上記「現状の実測 6」)。両者は結合して
> いないので、`TDEffect` を合成しても `wit_gen` の挙動は変わらない。逆に
> **#1143 のねじれは wit_gen 自身の規則を差し替えないと直らない** (実装順 4)。

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

`perform Fs::read_file(...)` / `with Fs` は無変更。resource 引数省略時は
既定 singleton (`Fs[Process::Root]`) へ展開する sugar として扱う
(effect-taxonomy-review.md の Phase 1)。これにより compiler 自身のソースを
含む既存コードは無風で、bootstrap bump も不要。

## 実装順 (#1343 のチェックボックスへの対応)

Phase 0 の前提である ADR-0075 Phase 2 (`resource` 宣言) が**未着手**なので、
`Fs::Root` のような kind 名を書けるようになるのは先である。したがって
**最初に実装できるのは構文ではなく分類 metadata** である。

0. **(着地済み、#1343)** builtin 呼び出し経路に consumer 軸を通す —
   `with Fs::read_file` / `with Http::request` が builtin を認可する。
   これで `Http` が広すぎる問題は provider 軸を割らずに解ける。後続として
   `builtins_net.vibe` の `HttpServer`/`HttpClient`/`HttpIncoming` は
   **provider ラベルではなく `Http::*` operation 上の effectset** へ寄せる
   (provider 軸は `Http` に統一)。
1. **(着地済み、#1343)** 分類 metadata + `effect_class` の導入。
   `lib/@vibe/compiler/core/effect_taxonomy.vibe` が
   `(effect 名, class, 既定 resource kind, test/bench ambient か, entry
   キャッシュ安全か)` の表を持ち、そこから
   `effect_class` / `is_core_ambient_effect` / `is_capability_effect` /
   `effect_default_resource_kind` と、二つの派生リストを提供する。

   **Decision 3 の「`registry_typed_rows` に列を足す」からは実装時に外れた** —
   registry の行は **operation 単位** (`Fs::read_file` / `Fs::write_file` /
   ...) なので、class 列を足すと同じ `Fs` の分類が 19 行に複製され、行ごとに
   食い違う。分類は effect の属性なので effect 名で引ける独立した表にし、
   registry 側のラベルが全部その表に載っていることを
   `verify_effect_taxonomy_coverage` (builtin_registry.vibe、
   `verify_lane_builtins` と同じ形の drift guard) で照合する構成にした。
   置き場所が `core/` なのは、consumer の checker と `wit_gen` が両方とも
   `@vibe/compiler/core` を既に import しているから (checker →
   codegen/common_base の向きに依存を増やさない)。

   吸収したリテラル列: `test_bench_ambient_effects` (8 要素)、
   `file_entry_cacheable` の `cache_safe_row` (4 要素)、および
   `is_exception_effect_name(x) || x == "Async"` という core ambient の
   二項判定 (checker の `builtin_call_effect` と `wit_gen` に重複していた)。
   派生リストは**要素順まで**吸収前と同一で、表面挙動は不変
   (`tests/effect_taxonomy_test.vibe` が pin)。`wit_gen` の反転はこの段では
   **直していない** (挙動変更を分離するため)。

   **drift guard の範囲**: registry の行だけ。host effect ラベルは
   `checker/builtins_*.vibe` の if-chain にも散在しており (上記「現状の実測
   1」)、そちらは配列として列挙できないので照合できない — 現に `Llm` は
   `builtins_system.vibe` にしか存在せず guard が触れない。registry へ
   寄せる作業 (#415 B-2 の続き) が進むほどカバー率が上がる。
2. ADR-0075 Phase 2: `resource X : Kind = <literal>` 宣言と `Process::Root`
   singleton kind。
3. parser: `parse_type_params_list` に bound と `_` を追加。`TDEffect` の
   `param_kinds` スロット追加と registration。**同一単位で消費側3関数
   (`effect_tparams` / `effect_fresh_targs` / `subst_type_params`) を
   kind 分岐させる** — resource パラメータに fresh `CtVar` を割り当てず、
   宣言された resource へ解決して kind 一致を検査する。分岐を欠くと
   `Fs[SrcTree]` と `Fs[AnythingElse]` が単一化して kind 検査が無効化される
   (Codex review on PR #1356)。
4. `wit_gen` を `effect_class` 起点に切り替える (#1143 のねじれ解消)。
5. main の closed row 検査 (ADR-0084 Phase 3、warning から)。ADR-0088
   Decision 5 の段階ゲートに接続。
6. Phase 5 enforce + `Entry.requires ⊆ ComposedHost.provides` の preflight。

## Consequences

- resource kind を**型引数として既存の型に足すことは禁止**する。上記「現状の
  実測 3」の5箇所が `Array::length(targs) == N` で黙って分岐から漏れるため、
  やる場合は同一コミットで lockstep 修正すること (#1181 の再発防止)。
- row containment は当面 instantiation-insensitive のままなので、
  `with Fs` は `Fs[Anything]` を authorize する。resource 単位の最小権限が
  実効化するのは ADR-0071 の OperationRef 正規化が入ってからで、本 ADR は
  その表現を先に確定させるだけである。
- 表面構文を変えないため、compiler 自身のソースは Phase 1〜3 で無変更。

## References

- [effect-taxonomy-entry-policy.md](effect-taxonomy-entry-policy.md) (ADR-0084)
- [effect-taxonomy-review.md](effect-taxonomy-review.md) (移行計画 Phase 0〜5)
- [capability-authorization-surface.md](capability-authorization-surface.md) (ADR-0088)
- [effectset.md](effectset.md) (ADR-0071)、[vibex-runtime-contract.md](vibex-runtime-contract.md) (ADR-0075)
