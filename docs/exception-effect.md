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
を消すことであり、下記の解決範囲を広げるほど安全に近づく (local binder と
annotated parameter は follow-up で閉じた。pattern binder と field 射影は
まだ解決不能)。

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

**throw payload の kind 解決範囲**: effect pass は型付けを持たない AST walk
なので、payload の kind は syntax と module 環境から復元する。解決できるのは:

| payload | kind |
| --- | --- |
| `throw("boom")` / `throw(1)` / `throw(1.5)` / `throw(true)` | リテラルの型 |
| `throw(NotFound("cfg"))` | constructor の結果型 |
| `throw(Eof)` | nullary constructor |
| `throw(make_err(x))` | top-level 関数の戻り値型 |
| `throw(Wrapped::{ .. })` | struct literal の型 |
| `let e = NotFound("cfg"); throw(e)` | initializer から (再帰的に) |
| `fn f(e: IoError) { throw(e) }` | parameter annotation の head 名 |
| `match r { Err(e) => throw(e) }` | **解決不能** (pattern binder) |
| `throw(r.cause)` | **解決不能** (field 射影) |

local binder は #1344 の v1 では見えていなかったが、**#1324 の移行が生む形
(`let e = ..; Err(e)` → `let e = ..; throw(e)`) がちょうどそれ**だったため
follow-up で閉じた。実装は `(name, kind)` の scope を perform walk に通す形で、
既に同じように walk に乗っている `ov_names`/`ov_effs` と同じ機構
(`throw_kind_bind*`, checker/checker_effects.vibe)。

kind 不明は「どの exception row でも通る」に倒してあるので、この隙間が
**誤検出を生むことはなく、検出漏れだけを生む**。その性質を保つために、
**解決できない binder も明示的に kind `""` で scope に載せる**: lookup は
名前が scope に無いとき module 表へ落ちるので、載せないと同名の top-level
binding が local の代わりに答えてしまう (それは誤検出になる)。pattern binder、
`for` の要素・index、`loop` param、無注釈 parameter、`let rec`、適用された
local (scope が持つのは値の kind であって結果の kind ではない) がこれに当たる。

同じ理由で、#1340 が残した「row 要素の完全な OperationRef 正規化」も
`Exception[E]` に限って先取りしただけで、他の generic effect
(`State[Int]` 等) は base 名比較の v1 のままである。

### runtime に kind が無い (2026-08-03、PR #1372 review で顕在化)

上の throw-site kind 解決 (#1377) は **compile time** の話である。以下は
runtime 側に残っている、それとは独立な限界。

上の「erased は全 kind と compatible」は **静的規律だけ**である。runtime は
kind を出さず単一 abortive tag のままなので、**erased な
`handle { .. } with Error { Throw(msg) => .. }` は typed な `Exception[E]` の
throw も捕まえ、`msg` に enum 値が入る**。`msg` の静的型は `CtUnknown` なので、
それを `String` として使うコードは型検査を通ってしまう。

#1324 slice 1 で `TaskGroup::run` / `TaskHandle::join` / `Sender::send` が
enum payload を throw するようになり、既存の String 専用 sink 2 箇所で
実際に踏んだ (どちらも計測で確認):

| sink | 症状 |
| --- | --- |
| entry boundary (`lc_wrap_entry_error_boundary`) | payload を packed `(ptr<<32)\|len` として解釈し、**data segment がまるごと stderr に出た** |
| `TaskGroup::spawn` の child runner (`cell.fail_msg = msg`) | `TaskError::Failed(m)` の `String::length(m)` が **2129** (生ポインタ) |

**第一段の緩和 (PR #1375)**: どちらも payload を `__to_string` 経由にした。
ADR-0058 の int/string 判定 (`64 <= ptr && ptr + len <= memory_size`) は
本物の文字列に対しては恒等で、それ以外は有界な10進数を返すので、任意メモリを
読むことはなくなった。ただし**非 String payload は「メッセージに見える裸の
10進数」になり、中身は失われた**。

### kind side channel (#1374、2026-08-03)

**入っている修正**: throw site が payload の静的型名を1スロットの module cell
に記録し、handler 側が `__exn_kind()` で読む。**payload の表現は一切変えない**
ので、既存の handler はすべてそのまま動く — 純粋に additive。

| 層 | 実装 |
| --- | --- |
| 書き込み | `desugar_trait_dicts` が `perform <Exception>::Throw(v)` の直前に `Array::set(__exn_kind_cell, 0, "<Kind>")` を挿入する。kind は codegen 側の `infer_arg_type_name` で解決し、解決できなければ `""` を**必ず**書く (前の throw の kind が残らないように) |
| 読み出し | `__exn_kind() -> String` は checker-only intrinsic (`checker/builtins_misc.vibe` の `lookup_exn_kind`)。desugar が cell 読み出しへ lower するので、どちらの backend にも新しい emission はない |
| cell | `let __exn_kind_cell = ["", ""]` を必要な program にだけ append する (slot 0 = kind、slot 1 = #1392 slice 3 の rendered message)。module-level let の「一度だけ初期化・同一 identity・mutation が見える」性質は `fixtures/module_let_memo_test.vibe` が既に pin している |

**なぜ wasm global や新しい builtin ではないか**: cell を普通の vibe AST にして
おけば、linear / wasm-gc の2つの backend で実装が分岐しない。新しい global の
index 割り当ても memory layout の変更も要らない。

**なぜ1スロットで足りるか**。書き込みから handler の読み出しまでの区間は単一の
abortive unwind であり、その中で他のゲストコードは走らない:

- `Error` は非 resumable (#640) なので、throw site へ戻ることはなく、書き込みの
  後に handler 以外のコードが挟まらない。
- ADR-0076 の task pump が task に再入するのは suspend 点だけで、unwind 途中では
  ない。兄弟 task が書き込みを割り込ませることはできない。
- handler arm の中の入れ子 throw は、内側が先に書き内側の handler が先に読む —
  innermost-wins という正しい順序になる。

payload を保存して**後で** kind を見る handler はこの区間の外なので、`__exn_kind()`
は arm の中で読むこと。2つの sink はどちらもそうしている。

**sink の挙動**:

| kind | 出力 | 理由 |
| --- | --- | --- |
| `String` / `Int` | `__to_string` の結果 (#1374 以前と同一) | ADR-0058 の判定が忠実 |
| `""` (解決不能) | `__to_string` の結果 | String かもしれない。#1375 の保守的な挙動を維持 |
| その他 | rendered message、無ければ `<Kind>` | 下の #1392 slice 3 参照 |

regression lock:

- `fixtures/exn_kind_side_channel_test.vibe` — enum / String / Int / struct /
  解決不能 / 入れ子 / 連続 throw の kind を直接 assert する
- `fixtures/err_entry_boundary_typed_payload.vibe` (`<Boom>`) と
  `fixtures/err_entry_boundary_string_payload.vibe` (verbatim) の対 +
  compiler_gate 44c

### message side channel (#1392 slice 3、2026-08-03)

kind side channel の残りの限界は「非 String payload の**値**が出せない」ことだった。
これには「kind ごとの formatting」が要ると書いていたが、**その dispatch を
handler 側で解くことは原理的にできない**: erased な `with Error { Throw(m) => .. }`
の `m` は静的に `CtUnknown` なので、`T::to_string` も `[T: Show]` の witness も
そこでは解決しようがない。trait dispatch (`Show` をメソッド持ちにする) を入れても
この地点は救われない。

**型が分かっている唯一の場所は throw site**。なので rendering も throw site で
やり、結果の String を kind と同じ cell の slot 1 に載せる。

| 層 | 実装 |
| --- | --- |
| 書き込み | kind の書き込みと同じ場所。payload temp に対して #1392 slice 1/2 の補間 renderer を走らせる (`interp_show_target` → `T::to_string`、無ければ `interp_expand` の `Option`/`Result` 展開) |
| 読み出し | `__exn_message() -> String`。`__exn_kind()` と同じ checker-only intrinsic |

**構造的な renderer が見つかったときだけ書く**。見つからなければ `""` を書いて
slot をクリアする。これが要点で、reader 側は「空でなければ信用する」という単純な
判定しかできない — `__to_string` のポインタ10進数はごく普通の非空文字列なので、
それを書いてしまうと `derive(Show)` の無い enum が `<NoShow>` ではなく `192` に
なる (#1374 より悪化する)。忠実かどうかは throw site の**静的**な性質なので、
判断もそこでやる。

sink の実測:

| payload | #1374 | #1392 slice 3 |
| --- | --- | --- |
| `Failed("io")` (`derive(Show)` enum) | `<AppError>` | `Failed(io)` |
| `"plain message"` | verbatim | verbatim (不変) |
| `Bang(5)` (renderer 無し) | `<NoShow>` | `<NoShow>` (不変) |
| `Some(7)` | `<Option>` | `Some(7)` |
| `TaskGroup` の子の `Failed("child blew up")` | `<TaskError>` | `Failed(Failed(child blew up))` |

最後の行の二重 `Failed` は正しい: 外側が `TaskHandle::join` の wrapper、内側が
子自身の payload。#1374 ではこの内側が丸ごと失われていた。

**呼ぶのは「このパスが生成した renderer」だけ** (#1398 review, Codex P1)。
補間 `"\{v}"` はユーザがその呼び出しを書いているので任意の `T::to_string` を
使ってよいが、throw site の呼び出しは**合成**であり、

- どの handler も message を読まなくても**毎回**走る
- 型検査の後に挿入されるので、その effect は throwing function の checked row に
  一切現れない
- formatter 自身が throw すると、元の例外を差し替えるか formatting 中に再帰する

という性質を持つ。実測: `println` を含む `Boom::to_string` が、payload を無視する
handler しか無い `throw(Bang(1))` で実行された。derive 由来の renderer は構造的・
全域・effect-free なので、eager path をそれだけに絞ればこの危険は消える
(`dtd_derived_renderers`)。

**`""` sentinel が健全な理由** (#1398 review, Codex P2)。ここから到達できる
renderer の出力は構造上必ず非空である: derived struct renderer は型名で始まり
(`P { ..`)、derived enum renderer は変種名そのもの、wrapper 展開は
`Some(..)` / `Ok(..)` / `Err(..)` / `None`。「空文字列を返すのが正しい」
ユーザ定義 formatter は上の P1 の制限により、そもそもここから呼ばれない。

regression lock:

- compiler_gate 87 — `derive(Show)` enum / String / renderer 無し / 手書き
  formatter の4本。3本目が「#1374 より悪化していないこと」、4本目が
  「手書き formatter は補間でだけ走る」の pin
- `@vibex/concurrent` の "a typed child throw is reported by kind" は
  `Failed("<SendError>")` から `Failed("Closed")` へ更新した (caller が switch
  したいのは変種名の方)
- `suspend_test.vibe` の "result_wait propagates a cancelled sibling to the
  awaiter" — suspend lane を `Exception[E]` へ移した #1324 slice 2 が
  この channel に依存している。cancel された sibling の `Cancelled` が
  CPS 分割 callee の throw → erased runner arm → `fail_msg` → `join` の
  再 throw まで variant 名のまま届くことを assert する

## #1324 (Result 削除) との統合順序

#1324 は `Result` を捨てて例外に一本化する提案で、この ADR の完成形の上に
載る。**順序は #1344 → #1324 で確定**。理由:

1. `Result[T, E]` を捨てられるのは、失敗の型 `E` が row 側で表現できる
   ようになった後である。Phase 3 以前の `Error` は payload が実質 String
   だったので、`Result[T, ParseError]` を `with { Error }` に置き換えると
   `E` の情報が消えた。今は `with { Exception[ParseError] }` が同じ情報を
   持つので、置き換えが情報を落とさない。
2. `Result` を返していたコードは失敗値を local binding に持って回してから
   返すことが多く (`let e = ...; Err(e)`)、それを throw に直すと
   `throw(e)` — #1344 の v1 ではちょうどここが kind 不明に落ちていた。
   **移行の主役が検査漏れする形だったため、#1344 の follow-up で local
   binder と annotated parameter を解決可能にした** (上表)。残る解決不能形
   (pattern binder / field 射影) は移行の主役ではないので、gradual のまま
   でよい。
3. Phase 4 (stdlib/compiler を `Exception[E]` へ移行) は #1324 と同じ
   コードに触るので、別々に2回書き換えないよう #1324 と一体で行う。

### 移行の進捗と、bundle 由来の制約 (2026-08-03)

| slice | 対象 | row |
| --- | --- | --- |
| 1 (#1372) | `@vibex/concurrent` の stack-driving 5本 | `Exception[TaskError]` ほか |
| 2 (#1401) | `@vibex/concurrent` の suspend lane 3本 | `Exception[SendError]` / `Exception[TaskError]` |
| 3 | `@vibe/json` (accessor 11 + `parse` + `parse_message` + `RpcMessage::parse`) | **erased `Error`** |

**slice 3 だけ erased `Error` なのは bootstrap の制約による**。`@vibe/json` の
7ファイルは `compiler_sources_manifest.tsv` に載っていて compiler の merged
bundle に同梱される。`scripts/generate_bundle.sh` の
`validate_module_source_compiles` (#979 sticky-failure guard) は候補 module
source を **pin された seed compiler** でコンパイル検査するが、現在の seed
(`vpkg-structured-header-2026-07-27`、source commit `08c4c58`) は ADR-0085 の
`Exception[E]` より古く、**bracketed label を parse できない**:

```
vibe: uncaught error: expected ',' or '}' in effect list
```

`fn` 宣言・closure literal どちらの位置でも再現する (現在の stage2 では
どちらも通る)。これは CLAUDE.md / docs/bootstrap.md が書いている
「新しい syntax を compiler source 自体で使う場合は先に bootstrap bump」
そのもの。

payload が `String` である以上、erased `Error` でも**情報は落ちない** —
ADR-0085 の migration section が `Error` を `Exception[String]` の
compatibility alias と呼んでいるとおりで、ADR-0058 の判定は本物の文字列に
対して恒等なので `handle .. with Error { Throw(msg) => msg }` は実際の
メッセージを受け取る。失われるのは**静的な精度**だけ (binder が
`CtUnknown` になるので、その handler の中で `msg` を String 以外として
使っても検査が止めない)。

**follow-up**: bootstrap bump 後に `@vibe/json` の row を
`Exception[String]` へ締め直す。#1324 の残り (`@vibe/compiler` 本体、
prelude `result.vibe` 削除) も全部 bundle 経由なので、**bump はそれらの
前提でもある**。

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
