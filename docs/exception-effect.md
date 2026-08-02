# ADR-0085: `Error` を typed `Exception[E]` core effect へ移行する

Status: accepted (Phase 3 実装済み — #1344)

Date: 2026-07-30 (Phase 3 landed 2026-08-02)

Related: #1218, #1136, #1344, ADR-0016(`handle`/`throw`), ADR-0050(generic effect
handler), ADR-0071(effectset), ADR-0073(checked `Error`), ADR-0084(effect
taxonomy)。

> **実装状況 (2026-08-02, #1344):** typed `Exception[E]` の row は
> **checker に入った**。`throw(v)` は `Exception[typeof(v)]` を要求し、
> `Exception[E1]` は `Exception[E2]` を authorize も discharge もしない。
> `with { Exception[E] }` / `handle .. with Exception[E]` /
> `effectset { Exception[A], Exception[B] }` がすべて通る。
> 何が検査され、何がまだ gradual なのかは
> [実装状況 (Phase 3)](#実装状況-phase-3) を読むこと。
> #1279 の非 generic な `Exception` alias は撤去していない —
> **erased(kind なし)綴りとして残っている**(下記「`Error` の意味」)。

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

### 決定: Option A (closed exhaustiveness) — #1344

#1344 は Option A / Option B の二択を決めることを最初の項目にしていた。
**Option A (閉じた exhaustiveness) を採る。Option B (trait 境界の
escape hatch) は採らない。**

- **Option A**: 例外 family は closed enum。`E` ごとに別の row 要素で、
  handler は exact kind だけを放電する。payload の網羅性は enum の `match`
  がそのまま与える。
- **Option B**: `ExceptionKind` のような trait 境界を置き、`Exception[T]`
  を `T: ExceptionKind` の存在型的な口として開く。open-world で FFI や
  plugin 由来の例外型を後付けできる。

決め手は3つ。

1. **Option B は row の閉世界性と両立しない。** effectset の
   normalization も package contract hash も「row 要素の集合が
   compile time に確定する」ことに依存している (ADR-0071)。trait 境界で
   開くと `Exception[T]` の row 要素が call site の instantiation でしか
   決まらず、`decl_authorizes_effect` が比較すべき対象が実行時まで確定しない。
   これは #1340 が閉じた「generic effect の instantiation が検査を素通り
   する」穴と同じ形をしている。
2. **Option B が要求する機構は既にある機構と重複する。** 「複数の失敗領域を
   一つの row にまとめたい」は effectset union (`effectset ConfigExceptions
   = { Exception[IoError], Exception[ParseError] }`) が既に表現できる。
   trait 境界を足しても新しく書けるようになるのは *未知の* 例外型の受け入れ
   だけで、それは least privilege の反対側にある。
3. **開く決定は後からできるが、閉じる決定は後からできない。** Option A で
   出発して escape hatch が実証的に要ると分かったら別 ADR で足せる。逆に
   Option B で出発すると、既存コードが open-world に依存した後で閉じるのは
   breaking change になる。

したがって `ExceptionKind` trait / open subclass / dynamic downcast は
初期設計に入れない、という上の段落が **決定** であり、両論併記ではない。

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

### 突き合わせ結果 (#1344 で「要検証」を消化)

Phase 3 の実装は **kind を一切 lowering に出さない**。`Error::Throw` /
`Exception::Throw` / `Exception[IoError]::Throw` はすべて
`is_exception_throw_operation` (core/exception_effect.vibe) が同一視し、
既存の1つの abortive Wasm tag へ落ちる。回帰ロックは
fixtures/exception_typed_row.vibe が実際に 42 を返すこと
(compiler_gate.sh 81)。

この「静的には kind 別、動的には単一 tag」が健全である条件を明示しておく。

- `handle .. with Exception[IoError]` は runtime では **すべての** vibe
  exception を捕まえる。これが正しいのは、その handle body の row に
  `Exception[IoError]` 以外の kind が残っていれば checker が拒否するから
  であって、tag が識別しているからではない。つまり **exact-kind の保証は
  完全に checker 側の性質**であり、Wasm EH はそれを支えても否定してもいない。
- 例外は gradual な穴だけである: payload の kind が解決できなかった throw
  (下記 v1 の限界) は kind `""` として *どの* `Exception[K]` にも通る。
  この場合 handler が捕まえるのは checker が許した throw なので、動的挙動は
  やはり宣言と一致する。
- したがって WebAssembly の typed tag / `try_table` を採用するかは
  **source semantics に対して観測不能な最適化**である。採用すれば
  「捕まえない」を tag で表現できるようになるが、それは上の checker 保証を
  runtime にも複製するだけで、新しい保証を与えない。EH を持たない backend が
  現行の effect/evidence lowering のままでよい、という ADR の主張はこの
  実装で具体的に裏づけられた。

per-kind tag が実際に要るのは、checker が kind を解決できない payload を
**動的に** 選り分けたくなったときだけである。それは Option A の閉じた
exhaustiveness では起きない (kind が分からない payload は enum の `match`
でも分けられない) ので、現時点で per-kind tag を追う理由はない。

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

### `Error` の意味 — この ADR の当初記述に対する訂正

上の Phase 2 は `Error = Exception[String]` alias と書いている。**実装は
そうしていない。`Error` は kind を持たない ERASED な exception row である。**

理由は #786 である。既存コードは `throw(KeyInvalid("x"))` のような suberror
値を **plain な `with { Error }` の下で** 投げており、その数は数百に及ぶ。
`Error` を `Exception[String]` と定義すると、この throw はすべて
`missing { Exception[KeyInvalid] }` になる。移行の初手が既存コードベースの
全面書き換えを要求する、という順序は成立しない。

そこで実装上の `Error` は **どの kind とも compatible な最弱の label** とした
(`exception_kinds_compatible`, core/exception_effect.vibe)。両方向に効く:

- 宣言側が erased (`with { Error }`) → どの kind の throw も authorize する。
  これが既存コード無変更の根拠。
- 要求側が erased (payload の kind が解決できない throw) → どの
  `Exception[K]` 宣言でも authorize される。これが gradual 側。

結果として、この機能は **既存コードに対して証明可能に additive** である:
宣言 row は (a) erased な exception label を持つ (= 全 kind と compatible)、
(b) exception label を1つも持たない (= 変更前も同じ診断で reject 済み)、
(c) kinded label を持つ (= コードベースに存在しない綴り) のいずれかで、
新たに失敗しうるのは (c) だけである。

この帰結として **Phase 5 (alias 削除) は単なる改名ではなく本物の breaking
change** になる。`Error` を消すということは「kind 不明の throw を許す」逃げ道
を消すことであり、下記 v1 の限界 (local binding の型が見えない) を先に閉じて
おく必要がある。

## 実装状況 (Phase 3)

#1344 で入ったもの:

- `with { Exception[E] }` の row 検査 (`decl_authorizes_effect`,
  checker/checker_effects.vibe)。`Exception[E]` は #1340 の
  「base 名で比較する instantiation 非依存 v1」から **明示的に除外** されて
  いる (`row_base_membership`) — そうしないと `State[Int] ~ State[String]`
  と同じ規則で `Exception[IoError] ~ Exception[ParseError]` になり、
  typed exception の唯一の保証が消える。
- `handle .. with Exception[E]` (parser: `collect_row_item_targs` を
  `with` 節でも使う)。arm は `Exception[E]::Throw` に qualify され、
  `collect_handle_effects` がそれを discharge label として publish する。
- `effectset { Exception[A], Exception[B] }` — union は既存の展開で通る。
- fn 型の代入互換 (`row_contains_label` / `effect_label_base_name`):
  `Exception[A]` の値を `Exception[B]` の口に渡すのは
  "effect would be dropped"。erased との出入りは両方向とも許す。
- entry boundary: `main` の row が kinded exception を宣言していても
  `lc_row_has_error` が拾い、診断付き process failure へ変換する
  (`lc_wrap_entry_error_boundary`)。

**v1 の限界 (意図的)**: throw payload の kind は effect pass が
**module 環境から** 解決する — 文字列/数値リテラル、constructor 適用
(`throw(NotFound("x"))`)、nullary constructor、top-level 関数の戻り値まで。
**local binding は見えない** (`fn f(e: IoError) { throw(e) }` の `e` は
kind 不明)。effect pass は型付けを持たない AST walk なので、ここを閉じるには
local binder の型を walk に通すか、型検査側で throw site ごとの kind を
記録する必要がある。kind 不明は「どの exception row でも通る」に倒してある
ので、この隙間が **誤検出を生むことはなく、検出漏れだけを生む**。

同じ理由で、#1340 が残した「row 要素の完全な OperationRef 正規化」も
`Exception[E]` に限って先取りしただけで、他の generic effect
(`State[Int]` 等) は base 名比較の v1 のままである。

## #1324 (Result 削除) との統合順序

#1324 は `Result` を捨てて例外に一本化する提案で、この ADR の完成形の上に
載る。**順序は #1344 → #1324 で確定**。理由:

1. `Result[T, E]` を捨てられるのは、失敗の型 `E` が row 側で表現できる
   ようになった後である。Phase 3 以前の `Error` は payload が実質 String
   だったので、`Result[T, ParseError]` を `with { Error }` に置き換えると
   `E` の情報が消えた。今は `with { Exception[ParseError] }` が同じ情報を
   持つので、置き換えが情報を落とさない。
2. ただし **#1324 を始める前に上記 v1 の限界を閉じる必要がある**。
   `Result` を返していたコードは失敗値を local binding に持って回してから
   返すことが多く (`let e = ...; Err(e)`)、それを throw に直すと
   `throw(e)` — つまり kind 不明の形になる。移行の主役がちょうど検査漏れ
   する形なので、先に local binder の型を effect pass へ通すこと。
3. Phase 4 (stdlib/compiler を `Exception[E]` へ移行) は #1324 と同じ
   コードに触るので、別々に2回書き換えないよう #1324 と一体で行う。

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
