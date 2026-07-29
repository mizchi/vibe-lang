# ADR-0084: Effect の分類と `.vibex` entry row の許可規則

Status: proposed

Date: 2026-07-30

Related: #1218, ADR-0071(effectset), ADR-0075(`.vibex` runtime contract),
ADR-0073(checked `Error`), ADR-0068(concurrency)。背景と選択肢は
[effect-taxonomy-review.md](effect-taxonomy-review.md) を参照。

## Context

vibe の effect row は、現在は `Fs`、`Env`、`Error`、`Async`、ユーザー定義
`Logger` を同じ文字列ラベルとして保持している。しかし、これらは host が
解決できるか、プログラム内の handler が解決すべきかという点で異なる。

ADR-0075 は `.vibex` の `main` に closed/exact row を要求する。一方で、host
が解決できない通常の algebraic effect を `main` に残すことを許すと、host
contract は満たせない。反対に `Fs` のような capability を `main` から禁止
すると、実行契約の目的と矛盾する。

## Decision

effect operation を、次の三分類で扱う。

1. **capability effect** は resource kind parameter を持つ effect である。
   host/provider が binding を解決し、residual WIT contract に投影する。例えば
   `Fs[Root]::read_file` と `S3[Posts]::get_object` である。
2. **algebraic effect** は resource kind parameter を持たない通常の effect
   である。これは in-process の handler/DI 用であり、`.vibex` の `main` に
   到達する前に `handle` で discharge しなければならない。
3. **core ambient effect** は言語予約の少数の effect である。ADR-0085 の
   typed `Exception[E]`（移行中は checked `Error`）が該当する。これは entry
   boundary の runtime handler が diagnosed failure へ変換するため、`main` の
   row に残ることを許可する。

`.vibex` の `main` の残余 row は capability effect と core ambient effect
だけを含めてよい。row に algebraic effect が残るプログラムは、WIT 生成や
host preflight の前に型エラーとする。これは通常の関数の row を制限しない。

既存 builtin の source compatibility は保つ。Phase 1 では、既存の
`with { Fs }` と `Fs::read_file(...)` を暗黙 singleton resource
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
  string-label checker だけでは三分類を表現できないためである。

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

## Reconciliation ledger

| 項目 | 根拠 / 観測 | 結論 |
| --- | --- | --- |
| 期待する契約 | ADR-0075 は `main` の closed/exact row と host preflight を要求する | entry row は host が解決可能でなければならない |
| 実装観測 | `loader/loader.vibe` は `.vibex` の形と explicit row を検証するが、exact operation-row equality は後続 phase と明記している | 本 ADR は直ちに checker を変更しない |
| 実装観測 | `checker_effects.vibe` は effect を文字列ラベルで追跡し、`Error` / `Async` を特別扱いしている | effect class/resource kind metadata が先行条件である |
| 回帰ガード候補 | `main with { Logger }` は reject、`main with { Fs }` と `main with { Error }` は accept | Phase 3 の fixture と compiler gate に固定する |

この段階では、machine-checked な判定対象がまだ metadata を持たないため、新しい
proof/model は追加しない。Phase 3 で上記3 fixture を導入し、checker の許可述語
を回帰ガードにする。
