# ADR-0084: Effect の分類と `.vibex` entry row の許可規則

Status: proposed

Date: 2026-07-30

Related: #1218, ADR-0071(effectset), ADR-0075(`.vibex` runtime contract),
ADR-0073(checked `Error`), ADR-0068(concurrency)。背景と選択肢は
[effect-taxonomy-review.md](effect-taxonomy-review.md) を参照。

> **Prospective model boundary (#1496):** This proposed ADR and the formal
> `formal/VibeFormal/Effect/Taxonomy*.lean` model describe a future semantic
> admission model. They are not the current compiler registry. Today,
> `core/standard_effect_policy.vibe` stores only standard host-provider and
> entry-execution policy metadata; it does not classify ordinary source effects.

## Context

vibe の effect row は、現在は `Fs`、`Env`、`Error`、`Async`、ユーザー定義
`Logger` を同じ文字列ラベルとして保持している。しかし、これらは host が
解決できるか、プログラム内の handler が解決すべきかという点で異なる。

ADR-0075 は `.vibex` の `main` に closed/exact row を要求する。一方で、host
が解決できない通常の algebraic effect を `main` に残すことを許すと、host
contract は満たせない。反対に `Fs` のような capability を `main` から禁止
すると、実行契約の目的と矛盾する。

## Decision

effect operation を、次の四分類で扱う（`runtime effect` は #1458 の追加）。

| 分類 | 誰が discharge するか | 許諾で揺れるか | メンバー |
|---|---|---|---|
| **capability effect** | host / provider (wasm 境界の外) | 揺れる | Fs, Http, Socket, Env, Console, Stdin, Stdout, Stderr, Process, Profiler, Llm |
| **algebraic effect** | プログラム内の `handle` | 無関係 | Log, State, Ask, ParseRecur, … (表に無い名前はすべてここ) |
| **core ambient effect** | 誰も discharge しない (entry が abortive に処理する) | 無関係 | Exception[E] / Error |
| **runtime effect** | runtime そのもの | 無関係 | Async |

1. **capability effect** は resource kind parameter を持つ effect である。
   host/provider が binding を解決し、residual WIT contract に投影する。例えば
   `Fs[Root]::read_file` と `S3[Posts]::get_object` である。
2. **algebraic effect** は resource kind parameter を持たない通常の effect
   である。これは in-process の handler/DI 用であり、`.vibex` の `main` に
   到達する前に `handle` で discharge しなければならない。
3. **core ambient effect** は言語予約の少数の effect である。ADR-0085 の
   typed `Exception[E]`（`Error` は移行中の alias）が該当する。これは entry
   boundary の runtime handler が diagnosed failure へ変換するため、`main` の
   row に残ることを許可する。
4. **runtime effect** (#1458) は runtime が駆動する effect である。今日の
   唯一のメンバーは `Async` で、ADR-0089 Decision 5 のとおり **backend の
   選択であって権限ではない**。`main` の row に残ることを許可する。

   core ambient と分けたのは分類の正確さのためだけではない。両者は「row を
   素通りする」点では同じだが、**理由が逆**である — core ambient は誰も
   discharge しないから残ってよく、runtime は runtime が discharge するから
   残ってよい。`Async` を core ambient に混ぜていた間、checker と wit_gen の
   両方に「`Error` と `Async` は同じ理由でここに居る」と読めるコメントが
   書かれていた。

   This is prospective admission-model terminology. In the current compiler,
   checker row filtering and WIT import filtering instead use the narrow
   `is_entry_runtime_managed_effect` execution-policy predicate.

`.vibex` の `main` の残余 row は capability effect・core ambient effect・
runtime effect を含めてよい。row に algebraic effect が残るプログラムは、
WIT 生成や host preflight の前に型エラーとする。これは通常の関数の row を
制限しない。

既存 builtin の source compatibility は保つ。Phase 1 では、既存の
`with Fs` と `Fs::read_file(...)` を暗黙 singleton resource
`Fs[Process::Root]` として内部表現に lower する。明示 resource syntax は
Phase 2 以降の追加であり、この ADR では構文を決めない。

## Consequences

- `main` が残す row は host が preflight できる contract になる。host が
  解決できない `Logger` や `State[T]` を残すことはできない。
- user-defined algebraic effect は通常関数・高階関数・handler 内ではこれまで
  どおり利用できる。entry 直前に discharge すればよい。
- `Error` の既存の entry-boundary 処理は維持する。改名を先に行わないため、
  既存ソースの一括変更や bootstrap bump は不要である。
- `Fs` / `Env` / `Process` / `Stdout` / `HttpServer` の resource-kind
  retrofit が完了するまでは、この entry row 検査を有効化しない。現在の
  string-label checker だけでは分類を表現できないためである。

## Non-goals

- resource kind parameter の表面構文・kind bound の構文を決めない。
- `resource` の plan/apply/bind lifecycle、optional capability、WIT ABI を
  実装しない。これらは ADR-0075 の後続 phase である。
- `Error` を `Exception[E]` へ改名しない。改名・typed identity・Wasm EH との
  関係は [ADR-0085](exception-effect.md) が定める。
- `TaskGroup::spawn` の row-polymorphic 化や fork-safe evidence 転送を
  実装しない。これは ADR-0068 / ADR-0075 の個別実装として扱う。

## Implementation sequence

1. `OperationRef` / builtin metadata に resource kind と effect class を導入し、
   builtin を implicit `Process::Root` へ lower する。既存 fixture は無変更で
   通ることを確認する。
2. 明示 resource kind を持つ capability と、resource kind を持たない
   algebraic effect を checker が区別できるようにする。
3. `.vibex` の `main` に残る row を分類し、algebraic effect を残した最小
   fixture を reject、capability/core ambient の fixture を accept する。
4. その残余 row のみを WIT / `Entry.requires` / host preflight に渡す。

## Formal contract

実装に先行する taxonomy-level contract を
[`Effect/Taxonomy.lean`](../formal/VibeFormal/Effect/Taxonomy.lean) に定義し、
[`EffectTaxonomyCorrect.lean`](../formal/VibeFormal/Proofs/EffectTaxonomyCorrect.lean)
で executable checker と命題の一致を証明する。モデルは次を固定する。

- capability / algebraic / typed Exception を disjoint な requirement として扱う。
- entry row は capability/core ambient のみを許し、capability は
  `OperationRef` に exact logical resource marker を保持する。
- host は exact capability identity を provide できるが、algebraic effect を
  解決できない。
- handler は同じ algebraic effect、または exact Exception kind だけを
  discharge し、別カテゴリ・別 kind を保存する。
- spawn child row は parent row の subset で、capability には fork-safe host
  evidence が必要であり、algebraic handler evidence は既定で継承しない。

[`EffectTaxonomyExamples.lean`](../formal/VibeFormal/Proofs/EffectTaxonomyExamples.lean)
は accept/reject 例に加え、capability だけを row から射影する壊れた
preflight が未処理 `Logger` を誤って accept する反例を保持する。

resolved `OperationRef` と declaration metadata から三分類を構築する境界は
[`Effect/TaxonomyClassifier.lean`](../formal/VibeFormal/Effect/TaxonomyClassifier.lean)
で定義する。catalog lookup は同じ `EffectDefId` の metadata が exactly one
の場合だけ成功する。capability は logical resource id をちょうど1個、
algebraic effect は resource argument を0個、core Exception は normalized
type argument をちょうど1個持たなければならない。未知 ID、重複 metadata、
malformed arguments は complete row 全体を reject し、要素を黙って落とさない。

[`TaxonomyClassifierCorrect.lean`](../formal/VibeFormal/Proofs/TaxonomyClassifierCorrect.lean)
は executable classifier と declarative `Classifies` 関係の一致、および
row classification 成功時の well-formedness と input/output length 保存を
証明する。
[`TaxonomyClassifierExamples.lean`](../formal/VibeFormal/Proofs/TaxonomyClassifierExamples.lean)
は argument shape だけで class を推測する壊れた classifier と、失敗要素を
`filterMap` で捨てる壊れた row conversion の反例を保持する。

この分類境界の正負15ケースは
[`effect-taxonomy.tsv`](../formal/oracle/effect-taxonomy.tsv) に機械可読な
Oracle として固定する。catalog metadata、resolved operation row、
accept/reject と正規化後 requirement row を
[`TaxonomyOracleMain.lean`](../formal/TaxonomyOracleMain.lean) が Lean model
から生成し、`formal-check` が stale snapshot を拒否する。現時点では
contract-level Oracle であり、selfhost checker が declaration metadata を
公開した後に同じ corpus を differential fixture として接続する。

taxonomy check 後の ADR-0075 contract への接続は
[`Capability/TaxonomyBridge.lean`](../formal/VibeFormal/Capability/TaxonomyBridge.lean)
で定義し、
[`TaxonomyBridgeCorrect.lean`](../formal/VibeFormal/Proofs/TaxonomyBridgeCorrect.lean)
で一方向 refinement を証明する。exact `CapabilityRef` は semantic
`OperationRef` と `ResourceClaim` に、host provider は authority と
`ResourceBinding` に投影される。完全 row の entry/spawn 判定が通れば、
投影後の既存 ADR-0075 preflight も通る。

この含意の逆向きは成立しない。投影前の taxonomy check を省くと algebraic
effect が capability-only contract から消え、resource claim を省くと同じ
operation/resource identity を持つ別 resource kind を誤受理する。
[`TaxonomyBridgeExamples.lean`](../formal/VibeFormal/Proofs/TaxonomyBridgeExamples.lean)
は両方の負例を固定する。

resource-qualified capability の path scope は ADR-0075 の
[`Capability/PathScope.lean`](../formal/VibeFormal/Capability/PathScope.lean)
で別層として定義する。同一 logical/physical scope domain で交差しうる
glob は同一 authority の場合だけ許可し、異なる authority の重複を
scope-aware preflight が reject する。
[`PathScopeCorrect.lean`](../formal/VibeFormal/Proofs/PathScopeCorrect.lean)
は overlap 判定と共通 path の存在の同値、および同じ path に一致する grant
の authority 一意性を証明する。executable checker は canonical な共通 path
witness を返し、`none` と semantic intersection の空性も同値である。

これは ADR の意味論に対する machine-checked model であり、現行の文字列
checker、builtin metadata、WIT 生成との correspondence proof ではない。
Implementation sequence 1–4 と compiler fixture は引き続き必要である。

## Reconciliation ledger

| 項目 | 根拠 / 観測 | 結論 |
| --- | --- | --- |
| 期待する契約 | ADR-0075 は `main` の closed/exact row と host preflight を要求する | entry row は host が解決可能でなければならない |
| 実装観測 | `loader/loader.vibe` は `.vibex` の形と explicit row を検証するが、exact operation-row equality は後続 phase と明記している | 本 ADR は直ちに checker を変更しない |
| 実装観測 | `checker_effects.vibe` は effect を文字列ラベルで追跡し、`Error` / `Async` を特別扱いしている | effect class/resource kind metadata が先行条件である |
| 回帰ガード候補 | `main with Logger` は reject、`main with Fs` と `main with Exception` は accept | Phase 3 の fixture と compiler gate に固定する |
| 形式モデル | taxonomy-level requirement、entry/host/spawn 判定、handler discharge を Lean で定義した | ADR の意味論は machine-checked。checker 対応は未証明 |
| metadata classifier | exactly-one metadata lookup と argument shape から complete row を分類し、unknown/duplicate/malformed を fail-closed にした | 実装 metadata はこの contract に対応させる |
| Oracle corpus | 正負15ケースを Lean から TSV に生成し、stale snapshot を `formal-check` で拒否する | contract の回帰ガードは自動化済み。selfhost differential は metadata API 待ち |
| contract refinement | exact capability を operation/claim/binding に投影し、taxonomy admission から ADR-0075 preflight への含意を Lean で証明した | taxonomy check は WIT/host projection より前に必須 |
| path-scope policy | restricted glob の overlap と共通 path の存在が同値で、diagnostic witness の健全性と authority 一意性を証明した | logical/physical の二段階で異権限の重複を exact に reject し、共通 path を報告する |

Phase 3 では上記3 fixture を導入し、checker の許可述語と Lean contract の
対応を回帰ガードにする。
