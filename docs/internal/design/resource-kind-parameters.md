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
   (`core/builtin_registry.vibe`) と `builtins_*.vibe` の
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
7. **ADR-0075 Phase 2 (`resource` 宣言) は未実装**。
   parser / AST / `TypeDef` のいずれにも resource 宣言は無い
   (`@vibex/wasm_wit_parser` の `TDResource` は WIT IDL 用の別物)。
   したがって `Process::Root` には現状いかなる表現も無い。
   → **実装順 2 で着地 (#1343)**。下記「実装順 2」参照。

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

### 3. builtin は標準 provider policy を使う (`TDEffect` を作らない)

builtin effect に `TDEffect` を合成する案は**採らない**。理由は
**checker 側の副作用**である — `effect_is_declared` が builtin に対して
`true` を返すようになると、#813/#828 の handler arm 検証と perform 検証が
host effect にも一斉に効き始める: `handle body with Fs { ... }` の arm 名 /
payload arity / **網羅性**が検査対象になり、部分的な `with Fs` handler は
`non-exhaustive handler` で reject される。しかし builtin operation は host
import 直呼びに lower され、その handler arm はそもそも実行されない
(vacuous-handle elimination)。実行されないコードを新たに型検査して既存
プログラムを弾くことになるため、これは retrofit の Phase 1 と両立しない。

> **訂正 (Codex review on PR #1355)**: `TDEffect` の合成は `wit_gen` の
> 挙動を変えない。`wit_gen` は `SEffectDef` (AST) だけを見ており、#1143 の
> ねじれは wit_gen 自身の規則を差し替えないと直らない。

現在の compiler は `registry_typed_rows` に列を足さず、effect 名で引ける
`core/standard_effect_policy.vibe` の標準 provider / entry-execution policy を
使う。registry は operation 単位なので、provider metadata を列として複製
しない。これは current execution policy であり、ordinary user effect の
semantic class を決めるものではない。

### 4. 将来の admission model は current policy と分離する

ADR-0084 の capability/algebraic/core-ambient admission model と
`formal/VibeFormal/Effect/Taxonomy*.lean` は prospective であり、現在の
string-label registry と対応付けない。現在の policy lookup は次だけを
提供する:

- standard host provider の有無と既定 resource kind
- `Error` / `Exception[E]` の entry-boundary exception handling
- `Async` の runtime scheduling
- test/bench default と entry cache-safe の既存リスト

module-local に `TDEffect` があるかどうかは、standard policy を決める根拠に
してはならない。

### 5. resource 引数は Phase 1 では**暗黙**とし、表面構文を変えない

`perform Fs::read_file(...)` / `with Fs` は無変更。resource 引数省略時は
既定 singleton (`Fs[Process::Root]`) へ展開する sugar として扱う
(effect-taxonomy-review.md の Phase 1)。これにより compiler 自身のソースを
含む既存コードは無風で、bootstrap bump も不要。

## 実装順 (#1343 のチェックボックスへの対応)

Phase 0 の前提である ADR-0075 Phase 2 (`resource` 宣言) が当初**未着手**
だったので、`Fs::Root` のような kind 名を書けるようになるのは先だった。
したがって**最初に実装できたのは構文ではなく分類 metadata** である
(実装順 1)。実装順 2 で `resource` 宣言が入り、この前提は解けている。

0. **(着地済み、#1343)** builtin 呼び出し経路に consumer 軸を通す —
   `with Fs::read_file` / `with Http::request` が builtin を認可する。
   これで `Http` が広すぎる問題は provider 軸を割らずに解ける。後続として
   `builtins_net.vibe` の `HttpServer`/`HttpClient`/`HttpIncoming` は
   **provider ラベルではなく `Http::*` operation 上の effectset** へ寄せる
   (provider 軸は `Http` に統一)。
1. **(着地済み、#1496)** standard provider / entry-execution policy。
   `lib/@vibe/compiler/core/standard_effect_policy.vibe` has independent
   private owners for `(label, provider default resource kind)`, ordered
   test/bench defaults, and ordered entry-cache-safe labels, plus narrow
   predicates for `Exception` and `Async` entry/runtime behavior. They retain
   the existing output/order and entry/runtime filtering without assigning
   ordinary effects a string class.

   Registry rows are **operation** keyed, so provider policy remains in this
   label-keyed table rather than being copied to every operation. The
   `verify_standard_effect_policy_coverage` guard verifies that every registry
   effect label has policy metadata. Its scope remains registry rows only;
   checker if-chains are not enumerable. WIT's declaration/provider inversion
   is intentionally unchanged in this slice.

2. **(着地済み、#1343)** ADR-0075 Phase 2: `resource Name : Owner::Kind`
   宣言と `Process::Root` singleton kind。

   AST に `SResource(name, kind)` を追加し (`lib/@vibe/ast/index.vpkg`)、
   parser・printer・checker を通した。`Process::Root` は
   `core/standard_effect_policy.vibe` の `predeclared_resources` /
   `is_singleton_resource_kind` として在り、既に同ファイルの
   provider default resource kind 列が指していた名前に**初めて実体**が付いた。

   **`= <literal>` は実装しなかった** — 本 ADR 初稿のこの行は ADR-0075 の
   surface を略記したものだが、ADR-0075 の決定本文は
   `resource Posts : S3::Bucket` であり、かつ「physical name / credential を
   guest に渡さない」を明示している。`= <literal>` は physical name を guest
   ソースに書く形にしかならないので、ADR-0075 の surface をそのまま採った。

   採った検査は**同一性の 2 規則だけ**:
   - 名前は一度だけ宣言できる (predeclared を含む)
   - **singleton kind (`Process::Root`) の resource は宣言できない** —
     住人は `Process::Root` 自身ただ一つなので、`resource Home :
     Process::Root` は process に二つ目の名前を与える alias になる
     (ADR-0075 の alias 検査が bind 時に捕まえる対象を、宣言時に前倒しで
     弾く)

   kind 名そのものは registry と照合**しない** — resource kind の宣言構文が
   まだ無いので、ADR-0075 自身の例である `S3::Bucket` を宣言できる場所が
   無い。parser の「kind は `Owner::Kind` の修飾パスであること」だけが今の
   well-formedness 規則である。

   `resource` は**文脈キーワード**で、`effect`/`effectset` と違い無条件に
   その語を取らない (`resource` は変数名としてずっとありそうなので)。宣言と
   認めるのは直後が識別子のときだけ — 文の位置で識別子が 2 つ並ぶ式は無い
   ので、この 1 トークン先読みは heuristic ではなく厳密である。

   綴りは `resource Posts: S3::Bucket` (コロン前に空白なし) を canonical と
   する。CST formatter (`fmt/format.vibe`) は他の注釈と同じ規則をここにも
   適用するので、printer が ` : ` を出すと `vibe normalize` と `vibe fmt` が
   綴りを取り合う (#1429 で実際に起きた形)。

   **`.vibex` root 限定は未強制** — checker は自分が entry file を見ている
   のかライブラリモジュールを見ているのかを知らない。`export resource` は
   拒否する (ライブラリが resource 名を公開する道は塞いだ) が、非 entry
   モジュールの private な `resource` 宣言は今のところ通る。
3. parser: `parse_type_params_list` に bound と `_` を追加。`TDEffect` の
   `param_kinds` スロット追加と registration。**同一単位で消費側3関数
   (`effect_tparams` / `effect_fresh_targs` / `subst_type_params`) を
   kind 分岐させる** — resource パラメータに fresh `CtVar` を割り当てず、
   宣言された resource へ解決して kind 一致を検査する。分岐を欠くと
   `Fs[SrcTree]` と `Fs[AnythingElse]` が単一化して kind 検査が無効化される
   (Codex review on PR #1356)。
4. `wit_gen` の entry/runtime-managed filtering は
   `is_entry_runtime_managed_effect` に切り替え済み。ただしこれは既存判断の
   名前を policy として明確化しただけで、`def_idx < 0` による
   declaration/provider 判定の反転 (#1143) は未解決。#1496 の explicit
   provider binding inventory 後に別スライスで修正する。
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
