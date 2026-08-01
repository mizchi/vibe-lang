# ADR-0085: `Error` を typed `Exception[E]` core effect へ移行する

Status: proposed

Date: 2026-07-30

Related: #1218, #1136, ADR-0016(`handle`/`throw`), ADR-0050(generic effect
handler), ADR-0071(effectset), ADR-0073(checked `Error`), ADR-0084(effect
taxonomy)。

> **#1279 interim implementation:** the compiler currently accepts a
> non-generic, abortive `Exception` spelling as an alias of existing `Error`.
> `Exception::Throw` and `Error::Throw` use one Wasm tag and String-payload
> compatibility behavior. This is deliberately **not** the typed
> `Exception[E]` proposed by this ADR: it has no type argument, no distinct
> normalized effect identity, and no typed-row/exact-kind guarantees.

## Context

ADR-0073 により、現在の `Error::Throw` は非再開・完全 checked の semantic
effect であり、未処理 `Error` は明示 row を持つ entry boundary で診断付き失敗へ
変換される。一方、payload は実質 `String` に固定され、異なる失敗領域を型と row
で区別できない。

`IOException` のような型別例外を subclass hierarchy として追加すると、effectset
の closed-world normalization、handler の exhaustiveness、package contract hash
と別の subtype 機構が必要になる。既存の generic effect identity を使えば、この
追加機構は不要である。

## Decision

言語予約の core ambient effect として、次を導入する。

```vibe skip
effect Exception[E] {
  Throw(E) -> Nothing
}
```

`Nothing` は「正常には return しない」ことを表す便宜的表記である。現在の
checker が `throw` を任意の式位置に置けるようにしている bottom-like な型付けを
維持し、表面の bottom type 名は別途決める。

- `throw(value)` は `perform Exception[E]::Throw(value)` の sugar とし、`E` は
  `value` の静的型から決まる。
- `Exception[IoError]` と `Exception[ParseError]` は別の normalized
  `OperationRef` であり、一方の row/handler は他方を許可・放電しない。
- `Exception[E]` は非再開 effect とする。handler arm 内の `resume` は
  ADR-0073 と同じく reject する。
- 複数の例外型を宣言する場合は subclass ではなく effectset union を使う。

```vibe skip
enum IoError {
  NotFound(String),
  PermissionDenied(String)
}

enum ParseError {
  UnexpectedToken(String, Int),
  Eof
}

effectset ConfigExceptions = {
  Exception[IoError],
  Exception[ParseError]
}
```

通常の例外 family は closed enum とし、payload の `match` で exhaustiveness を
得る。`ExceptionKind` trait、open subclass、dynamic downcast は初期設計に含めない。
将来、FFI adapter などに open-world escape hatch が必要だと実証された場合だけ
別 ADR で追加する。

`.vibex` の `main` は、明示した `Exception[E]` を core ambient effect として
残してよい。runtime entry handler は宣言された typed exception を診断付きの
unsuccessful process outcome に変換し、生の Wasm exception を host へ漏らさない。

## WebAssembly exception handling との関係

WebAssembly の exception handling は、typed tag、payload value、`throw` /
`throw_ref`、matching catch を持つ `try_table` を定義する低レベル制御機構である。
source-level の checked row、effectset union、enum exhaustiveness は定義しない。

したがって Wasm EH は `Exception[E]` の型システム上の根拠ではなく、non-resumable
transfer の lowering 候補である。vibe の linear/gc backend は既に
`Error::Throw` を専用 Wasm tag へ lower しており、この意味論とは整合する。

複数の `E` を ABI 上で「normalized `E` ごとの tag」にするか、「vibe exception
tag + type id + payload」にするかは backend/ABI の選択として後続へ延期する。
どちらを選んでも、checker 上の `Exception[E1] ≠ Exception[E2]` と entry boundary
の診断契約を変えてはならない。

参照:

- [WebAssembly 3.0 control instructions](https://webassembly.github.io/spec/core/syntax/instructions.html#syntax-instr-control)
- [WebAssembly 3.0 exception validation](https://webassembly.github.io/spec/core/valid/instructions.html#valid-throw)
- [旧 exception-handling proposal](https://github.com/WebAssembly/exception-handling/blob/master/proposals/exception-handling/Exceptions.md)

## Compatibility and migration

移行中は `Error` を `Exception[String]` の compatibility alias として扱う。
既存の `throw("message")`、`with { Error }`、`handle ... with Error` の payload
shape と entry diagnostic は維持する。

1. **Phase 0**: typed exception identity と exact-kind handler の Lean model を
   固定する。既存 ADR-0073 のモデルは checked/ambient policy と entry boundary
   の正本として残す。
2. **Phase 1**: ADR-0071 の `NormalizedEffectArguments` を checker row の実表現に
   導入し、generic effect の異なる instantiation を区別する。
3. **Phase 2**: 予約済み `Exception[E]` と `Error = Exception[String]` alias を
   導入する。compiler 内の `"Error::Throw"` 文字列判定を normalized core
   exception predicate に集約する。
4. **Phase 3**: `throw(value)` の payload type を検査し、row に
   `Exception[typeof(value)]` を要求する。exact-kind handler と effectset union の
   accept/reject fixture を先に追加する。
5. **Phase 4**: stdlib/compiler/docs を `Exception[E]` へ移行し、`Error` alias を
   deprecated にする。
6. **Phase 5**: compatibility alias を削除する。これは明示的な breaking change
   として扱う。

Phase 2 までは compiler source 自身に新構文を使わない。Phase 3 以降で
compiler source を移行する前に、seed compiler と stage2/stage3 fixpoint を
更新する。

## Formal contract

typed identity の実行可能な正本:

- `formal/VibeFormal/Effect/ExceptionPolicy.lean`
- `formal/VibeFormal/Proofs/ExceptionPolicyCorrect.lean`

モデルは `ExceptionKind` を normalized `E` の最小代替として使い、次を検証する。

- escaping `Exception[E]` は exact `E` の row requirement を必ず残す。
- `handle Exception[E1]` は `Exception[E2]` (`E1 ≠ E2`) を捕捉しない。
- capability requirement は typed exception handler で消えない。
- kind identity を消す broken checker は、empty row を許可しながら別 kind の
  exception を escape させる反例を持つ。

entry boundary の「宣言された exception は process failure へ変換される」という
保証は、移行中は ADR-0073 の `ErrorPolicy.lean` / `ErrorPolicyCorrect.lean` を
再利用する。typed entry outcome への一般化は Phase 2 の runtime representation
決定後に行う。

## Consequences

- exception family ごとの least privilege と API compatibility diff が可能になる。
- Java 型の open subclass hierarchy は持たず、effectset union と closed enum の
  exhaustiveness を再利用できる。
- 現行 codegen は `Error::Throw` を多数の string comparison で特別扱いしている。
  alias だけを追加して一括 rename すると分岐漏れが起きるため、normalized predicate
  への集約を migration gate とする。
- Wasm EH の対応状況は source semantics を変えない。EH を使えない backend は
  現行の effect/evidence lowering または等価な host boundary loweringを使える。

## Rejected / deferred alternatives

- **`Error` の名前だけを `Exception` へ一括置換**: payload 型と row identity が
  String のままで、#1136 の型別例外を解決しない。
- **subclass hierarchy**: effectset normalization と別の subtype/dispatch 規則を
  追加するため不採用。
- **Wasm tag を source exception 型そのものとみなす**: tag は lowering identity
  であり、source row/exhaustiveness の代替にならない。
- **すべての exception を一つの erased row element にする**: formal model の
  cross-kind witness が、別 kind の handler で requirement が消える不健全性を示す。
