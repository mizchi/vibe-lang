# ADR-0073: `Error` は checked semantic effect とする

Status: accepted

Date: 2026-07-17

Related: ADR-0003, ADR-0016, ADR-0050, ADR-0071, #626, #939, #944, #955, #1324

Follow-up: ADR-0085 は、この checked/non-resumable/entry-boundary 契約を保った
まま `Error` を typed `Exception[E]` へ移行する案を定める。compatibility alias
の移行が完了するまでは、本 ADR が現行 `Error` semantics の正本である。

## Context

capability effect (`Fs`, `Env`, `Stdin`, `Stdout` など) は、直接の operation と
effectful callee の双方について `with { ... }` へ推移的に伝播する。一方、#626
では selfhost 移行コストを理由に `Error` と `Async` の transitive 非強制を採用した。

この例外規則では、`with { Error }` を持たない関数からも Error が escape する。
そのため関数型、effect polymorphism、package contract に現れる `Error` row が
実際の保証にならず、特に高階関数で「直接 call は許可するが同じ関数値の代入は
どうするか」という不整合が #939 で顕在化した。

互換性より semantic row の一貫性を優先し、#626 の ambient decision を本 ADR で
置き換える。

## Decision

`Error::Throw` は、完全に checked な非再開 semantic effect とする。

- `throw(x)` と `perform Error::Throw(x)` は同じ operation requirement を生成する。
- Error を直接送出する関数は `with { Error }` または
  `with { Error::Throw }` を宣言しなければならない。
- `with { Error }` を持つ callee の requirement は caller へ推移する。caller は
  Error を宣言するか、`handle ... with Error` で放電する。
- 関数値の latent effect に Error を保持する。Error 関数を pure callback として
  渡すことはできない。pure 関数は Error を許す callback slot に渡せる。
- 明示 `with { Error }` は高階関数型、subtyping、package contract、contract hash、
  effect surface diff で意味のある row element とする。
- 公開関数への Error 追加は effect surface の拡大であり、破壊的変更として扱う。
- ~~通常の失敗表現には `Result[T, E]` を推奨し、`throw` は adapter / CLI / FFI / test
  などの boundary mechanism と位置づける。~~ **この項は #1324 で撤回された。**
  `Result` は言語からも prelude からも削除されたので、通常の失敗表現は
  **effect row 自体** (`fn f(..) -> T with { Exception[E] }`) になり、`throw` は
  境界専用の逃げ道ではなく失敗の第一級の表現手段になった。`handle` を置く位置が
  「回復したい境界」を表す。本 ADR の他の項 (checked / 非再開 / 推移伝播 /
  entry boundary) はいずれもこの変更の影響を受けない。

`Async` の非強制理由と structured concurrency 上の扱いは ADR-0068 に委ね、本 ADR
では変更しない。

## Entry boundary

`fn main with { Error } { ... }` を許可する。未処理 Error が entry まで到達した場合、
runtime が最外周 Error handler となり、診断付きの unsuccessful process outcome へ
変換する。生の `WebAssembly.Exception` を公開 entry boundary の外へ漏らさない。

`fn main` が Error を宣言しない場合は、通常の関数と同じく Error を送出する処理を
直接・推移的に含められない。`handle` または `Result` によって局所化する。

## Formal contract

実行可能な正本は以下に置く。

- `formal/VibeFormal/Effect/ErrorPolicy.lean`
- `formal/VibeFormal/Proofs/ErrorPolicyCorrect.lean`
- `formal/VibeFormal/Proofs/ErrorPolicyExamples.lean`

最小モデルは、正常 return、Error 送出、capability perform、transitive call、逐次実行、
Error handler、runtime entry boundary を区別する。主要な保証は次のとおり。

```text
Allowed checked [] term
  => run term = returned

Allowed checked [Error] main
  => runEntry main = succeeded or runEntry main = failedWithError
```

第1の定理は、empty row から unhandled Error と undeclared capability operation が
escape しないことを表す。第2の定理は entry boundary A を表し、宣言された Error を
runtime failure に変換する。実言語では divergence、panic、Wasm trap、OOM が別にあり、
empty row から totality や正常終了までは導かない。

比較用の ambient policy は、empty row の transitive caller から raised outcome を許す
不採用 witness として残す。さらに capability requirement まで落とす壊れた checker が、
empty row から `Fs` operation を許す negative witness を置く。

## Consequences

- 「pure by default」に Error 非脱出の意味が戻る。ただし totality は意味しない。
- compiler 自身を含む既存コードへ Error annotation が推移的に伝播する。
- `map` / `apply` 等の高階 API は latent effect の検査と effect row polymorphism が
  必須になる。
- legacy 診断は row checker へ統合済み (#944 follow-up):
  row なし `throw` は `EEEffectRowMismatch` の `missing { Error }` として報告される
  (`EEThrowOutsideEffect` は構築箇所ゼロのまま退役)。`EEEffectfulCallOutsideEffect`
  は Async-scoped pass (`check_async_effects_*`) の正式診断として存続。
  旧 `check_effects_expr` walk (in_effect: Bool の全 effect 一律規律) は
  live-pipeline 呼び出しゼロのため削除。
- current checker の Error exemption は #944 stage A-C (デフォルト on 化 + entry
  boundary) で解消済み。残: builtin-call carve-out の sub-decision と
  `VIBE_CHECK_ERROR_ROW=0` opt-out の退役。

## Epistemic status

Lean は上記の抽象 term、checked policy、entry boundary に関する定理を証明する。
checker がすべての構文・import・高階関数経路でこの judgment と一致すること、
Wasm exception unwind、診断文字列、finalizer exactly-once はまだ証明していない。
checker との対応は #944 の regression fixture と後続 differential oracle で固定する。
