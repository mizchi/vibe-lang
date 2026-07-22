# ADR-0076: effect handler を evidence passing 化する (suspend 点 IR で WasmFX/WASI 0.3 前方互換)

Status: proposed

Date: 2026-07-22

Related: ADR-0003, ADR-0021, ADR-0050, ADR-0060, ADR-0071, ADR-0073, #626, #806, #817

## Context

現行の `handle ... with Effect { ... }` は **replay** で実装されている
(`lib/@vibe/compiler/codegen/expr/compile_expr_tail6.vibe`)。handle body を
wasm `loop` で包み、`perform` は effect ごとに確保した固定 128KB のメモリ
領域 (`lib/@vibe/compiler/codegen/wasi/linked_compile.vibe` の `eff_reserve`)
へ「これまでに解決済みの resume 値」を記録しながら handler へ unwind する。
`resume(v)` は memo 配列に `v` を追記して **loop の先頭へ戻り、body を
最初から丸ごと再実行する**。実行順に解決済みの perform だけ memo 値を
返してスキップし、未解決の perform に到達したところで再度 unwind — という
形で「毎回 1 個ずつ多く解決される」まで body を繰り返す。

この実装は 2 つの実害を持つ。

1. **観測可能な副作用の重複実行**。memo されるのは perform の *戻り値* だけで、
   body 内の `print`/`let mut` 更新などの副作用は resume のたびに丸ごと
   再実行される。実測 (`eval/lang-review/findings/2026-07-12-r2.md` M2):
   2 回 perform する body で `[body-start]` が 3 回出力され、`let mut` の
   累積カウントは期待値 11 に対し実測 23、最終戻り値は期待 17 に対し
   実測 29 と**値そのものが壊れる**。cheatsheet に「handle body は最後の
   perform まで pure に保つこと」という運用回避を明記して凌いでいるが
   (`docs/cheatsheet.md:617-623`)、これは headline feature の欠陥であり
   test で pin されてもいない (`fixtures/` に該当する回帰なし)。
2. **`perform` 回数の実用上限**。128KB / 8 byte = 16382 エントリを超える
   perform は memo 領域を溢れる。過去に領域サイズを詰めすぎてヒープを
   実際に破壊した事故がある (`linked_compile.vibe:522-524` のコメント参照)。
   この bound は `linked_compile.vibe` / `compile_call.vibe` / `compile_expr_tail6.vibe`
   の 3 箇所に定数として重複している。

**issue #817 の記述に対する訂正**: 「ADR-0021 の tail-resumptive Mut
zero-cost 実装を一般化する」という issue の前提は、現行 selfhost
コンパイラには**当てはまらない**。ADR-0021 の tail-resumptive inline pass
(`src/frontend/rewrite_effect_handle.mbt`) は #594 で退役した旧 MoonBit
host にのみ存在し、`lib/@vibe/compiler/` (selfhost 実装) には
tail-resumptive 検出・高速化パスが一切ない — 現在は **すべての**
perform (built-in `Mut` 相当のものを含む) が上記の replay 経路を通る。
つまり本 ADR は「既存の高速パスを一般化する」のではなく、「replay しか
無いところに evidence passing を新規導入する」。

wasm-gc backend (`lib/@vibe/compiler/codegen/gc/backend_expr.vibe:1285`)
は代数的 effect handler を一切実装しておらず、`with Error { Throw(..) => .. }`
専用のスタブのみ (それ以外の effect は compile error)。replay 機構は
linear backend 限定。

## Decision

replay を全廃し、**Koka 流 generalized evidence passing** (Xie & Leijen,
ICFP 2021) を採用する。perform/resume を IR 上で明示的な **suspend 点**
にし、lowering 戦略を差し替え可能にする — 今日は evidence passing、
将来は WasmFX の `cont.new`/`suspend`/`resume` や WASI 0.3 の
component-model future/stream + JSPI (ADR-0012 の async の写像先) へ
差し替える。

### Evidence vector は既存の trait-dictionary passing の応用

vibe は method-bearing trait の generic 呼び出しに、既に「静的に決まらない
実装を witness struct (dict) として暗黙引数に通す」機構を持つ
(`lib/@vibe/compiler/codegen/common_base/desugar_trait_dict.vibe`)。
generic `f = [T: Tr](.. x: T ..) -> Ret { .. T::m(args) .. }` は隠し
パラメータ `__dict_Tr_T: TrDict[T]` を受け取り、`T::m(args)` を
`(__dict_Tr_T.m)(args)` へ書き換える。呼び出し側は具体型 `C` から
witness `TrDict::{ m: C::m, ... }` を合成して渡す。

evidence vector をこの**同じ機構の応用**として設計する。

```text
EffectDict[Effect] = struct {
  <opA>: (ArgsA) -> ResumeStrategy(ResultA),
  <opB>: (ArgsB) -> ResumeStrategy(ResultB),
  ...
}
```

`ResumeStrategy(R)` は operation ごとに 2 通りの具体形を持つ (下記参照)。
これにより evidence-passing の新規実装は「effect 版の dict-passing」に
帰着し、RC (Perceus) の扱い・witness 合成のコード生成パターン・
`checker`/`codegen` 双方の実装経路を trait dict のものと共有できる —
新しいパラメータ渡し規約をゼロから作らない。

### Suspend 点を IR に明示する: `EPerform` / `EHandle`

現状 `perform`/`resume` は専用 AST ノードではなく、`compile_call.vibe`
内で `fname == "perform"` 等をリテラル文字列比較する builtin 呼び出しの
一種として扱われている。これを `Expr` に昇格する。

```text
EPerform(EffectRef, OperationId, Array[Expr])
EResume(Expr)               // 継続時の位置は handler arm 内に限定 (既存の scoping 規則を維持)
EHandle(Expr, Array[(Pat, Expr)])   // 既存ノード、lowering 先を戦略で差し替え
```

`OperationId` は ADR-0071 (`(EffectDefId, OperationIndex)`) の正規化形を
第一の入力とする。ADR-0071 が未着地の間は、現行の `effect_op_index`/
`effect_op_keys` (`lib/@vibe/compiler/codegen/common_base/common_base.vibe`)
が実質的に同じ情報を codegen 時点で計算済みなので、それを型検査後・
codegen 前の正規化パスへ前倒しして代用する (ADR-0071 が着地したら
差し替えるだけで済むよう、`OperationId` の**外部インターフェースだけ**
先に固定する)。

lowering 戦略は `EPerform`/`EHandle` を消費する差し替え可能な pass として
実装する:

- **今日**: `lower_perform_evidence.vibe` (新規) — 本 ADR の evidence
  passing + yield bubbling
- **将来 (b)**: I/O 系 effect 用に component-model future/stream + JSPI
  lowering (ADR-0012 の async 経路と合流)
- **将来 (c)**: WasmFX 対応エンジンでの `cont.new`/`suspend`/`resume` 直接
  lowering

いずれの戦略も `EPerform`/`EHandle` という同じ入力 IR を消費するため、
将来の戦略追加は新しい lowering pass の追加であって、`EPerform`/`EHandle`
を生成する checker/normalize 側の変更を要求しない。

### 静的解決 (evidence 不要) と動的解決 (evidence を実引数で渡す)

vibe の effect row は静的に宣言され、handler は lexical scope で決まる
(#817 の主張どおり、これ自体は正しい)。`perform Effect::Op(args)` の
呼び出し経路 (perform から handle まで) 上のすべての関数が、その
operation を**具体的な row として**(row variable 越しではなく) 宣言して
いる場合、handler は**コンパイル時に一意に決まる**。この場合 evidence は
実行時の値として存在する必要すらなく、`perform` はコンパイル時に選ばれた
handler 実装への**直接呼び出し**へ完全に消える (dict そのものを持ち回ら
ない — trait dict でいう「単相化された呼び出しは dict 引数なしで直接
呼べる」場合と同じ)。

経路上のいずれかの関数が row variable (現行の「単一小文字ラベル」escape
hatch、または ADR-0071 の `RowVariable`) 越しにその operation を要求して
いる場合のみ、その関数は evidence dict を暗黙引数として受け取るよう
コンパイルし、呼び出し側は具体 handler から dict を合成して渡す。
「evidence を静的に消せるか、実引数として渡す必要があるか」は
generic 関数が trait dict を静的に消せるか (単相化) 実引数で渡す必要が
あるか (真に polymorphic) と同型の判定であり、同じ解析基盤
(`desugar_trait_dict.vibe` の instantiation 判定) を拡張して求める。

### tail-resumptive 高速パス (ゼロコスト直接呼び出し)

handler arm `Op(args) => body` が **tail-resumptive** とは、`body` の
すべての実行経路において `resume(e)` が唯一の効果であり、かつ tail
位置にあること (`resume` の戻り値に対して何もせず、その値をそのまま
arm の結果として返す) と定義する。この判定は #tco の self-tail-call
解析 (`lib/@vibe/compiler/codegen/common_base/self_tail_call.vibe`) と
同じ「tail 位置だけを辿る構造的再帰」で書ける — `EIf`/`EMatch`/`ELet`
等の継続位置を辿り、葉が `EResume(e)` かどうかを見る。

tail-resumptive な operation は、対応する evidence エントリを
**単純な関数** `(Args) -> Result` としてコンパイルする。
`perform Effect::Op(args)` はこの関数への直接呼び出しに等しくなり、
unwind も loop も発生しない — ADR-0021 が Mut について目指していた
「ゼロコスト」を、判定を型検査後の handler 宣言に対して行うことで
**任意の effect の任意の operation**に一般化する。

### 非 tail-resumptive: yield bubbling (選択的 CPS)

handler arm が resume を tail 位置以外で使う (resume の戻り値に対して
後処理をする)、複数回 resume する (multi-shot)、resume しない、という
場合は真の継続キャプチャが要る。wasm はネイティブな stack switching を
持たない (WasmFX は stage 2 で未着地) ため、Koka の yield bubbling を
採る: `EPerform` を含みうる関数は、戻り値型を

```text
Outcome[R] = Done(R) | Yield(OperationId, Args, Cont[R])
```

に変換する (`Cont[R]` は「resume 値を受け取ってこの関数の残りを実行する」
closure)。`Done`/`Yield` の判別と `Yield` の再送出 (自分の残りの計算を
`Cont` に閉じ込めて呼び出し元へ伝播) は、**その関数がこの operation を
処理しうる経路上にある場合にのみ**挿入する — 「pure-by-default + 静的
effect row」があるため、変換対象になる関数の集合は型検査結果から
コンパイル時に確定できる (wasm_of_ocaml の選択的 CPS と同じ発想。
`docs/pl-survey-2026-07.md` 該当箇所参照)。空 row の関数、あるいは
非 tail-resumptive 経路に乗らない関数は一切変換されず、既存の直接
呼び出しコード生成のまま — オーバーヘッドは「実際に非 tail-resumptive
な perform を経由しうる呼び出し経路」だけに局所化される。

`handle` 側は `Yield` を受け取ったら対応する evidence の非 tail-resumptive
アームを実行し、そのアームが `resume(v)` を呼ぶたびに `Cont[R]` を `v`
で呼び直す (multi-shot は `Cont` を複数回呼べば良いだけで、追加の機構は
要らない — closure なので当然に再利用可能)。アームが resume を呼ばずに
終われば、その `Yield` はそのまま `Done` として handle 全体の結果になる。

`Cont[R]` の実体はコンパイラが機械合成する `EFn` クロージャであり、
capture する自由変数は「perform 時点で生きていたローカル」— 通常の
クロージャ capture と同じ RC (Perceus) の扱いで済む。新しい RC ルールは
導入しない。

### メモリレイアウトと perform 上限の撤廃

evidence passing には replay loop も per-effect 固定メモリ領域も存在
しない。`linked_compile.vibe` の `eff_reserve` 計算、`compile_call.vibe`
の memo 配列アドレッシング、`compile_expr_tail6.vibe` の replay loop
codegen をまるごと削除する。perform 回数の上限は (multi-shot の場合を
除き) 単に無くなる — tail-resumptive は直接呼び出し、非 tail-resumptive
は `Cont` クロージャの通常のヒープ割り当てのみで、いずれも固定サイズの
予約領域を必要としない。

### wasm-gc backend

wasm-gc は元々クロージャを `struct`/`ref` として first-class に持つため、
`Cont[R]` クロージャの表現は evidence passing とむしろ相性が良い —
現行の replay 機構 (`with Error` スタブのみ) より実装コストが低いと
見込む。ロールアウトは linear backend 優先 (既存の effect fixture
カバレッジが linear 限定のため、退行検知の土台がある) だが、wasm-gc は
「Error のみ」の暫定スタブから「evidence passing による完全な代数的
effect」への昇格を同じ設計で行う。

## Rejected alternatives

- **replay の memo 領域を単純に拡張する**: `~16K` bound と副作用重複
  実行 (M2) のうち後者を一切解決しない。対症療法。
- **CPS 変換をすべての effectful 関数に一律適用する**: tail-resumptive
  な場合 (issue の想定では多数派) までクロージャ割り当てのオーバー
  ヘッドを払う。「静的 row から CPS 対象をゼロコスト判定できる」という
  vibe の強みを使わない。
- **WasmFX が来るまで待つ**: stage 2、Wasmtime 限定。node/ブラウザで
  今日使えない。suspend 点 IR を用意しておけば WasmFX 到達後の
  lowering 追加は非破壊的にできるため、待つ理由がない。
- **evidence を常に実引数で渡す (静的解決を省略)**: 呼び出し経路の
  大半が具体 handler に静的に解決できるという vibe の実態
  (issue の主張、本 ADR も支持) を活かさず、trait dict の単相化と
  対称性が壊れる。

## 段階導入計画 (bootstrap bump は各段階の境界)

Large cost の機能なので、ADR-0061/0064/0072 と同じ「新構文/新経路は
まずユーザプログラム対象、compiler 自身のソースでの使用は seed bump
後」の規律に従う。

- **Phase 0 (本 ADR)**: 設計のみ。コード変更なし。
- **Phase 1**: M2 (replay の副作用重複実行・値破壊) を `fixtures/` に
  回帰として pin する。evidence passing の実装有無に関わらず価値があり、
  Phase 2 以降の「直した」ことを機械的に証明する基準点になる。
  (このタスクとは独立に、issue #817 のスコープ最小の着手点として先に
  やっておいてよい。)
- **Phase 2**: `EPerform`/`EResume`/`OperationId` を IR に導入し、
  checker が tail-resumptive 判定を行う。linear backend は
  tail-resumptive operation だけ evidence 直接呼び出しへ、非
  tail-resumptive operation は**引き続き既存の replay** へ振り分ける
  (hybrid — 高価値・低リスクな部分から先に落とす)。tail-resumptive な
  アームしか持たない handler は、この時点で M2 から解放される。
- **Phase 3**: yield bubbling (選択的 CPS) を実装し、非 tail-resumptive
  経路も evidence passing へ移行。replay loop・`eff_reserve`・memo
  アドレッシングを削除。`~16K` bound と M2 が全域で解消する。
  selfhost bootstrap bump が必要 (compiler 自身の effect 呼び出しが
  新経路でコンパイルされる)。
- **Phase 4**: wasm-gc backend に同じ evidence 設計で完全な代数的
  effect handler を実装 (`with Error` スタブからの昇格)。
- **Phase 5**: suspend 点 IR に WasmFX / WASI 0.3 async (JSPI) 向けの
  代替 lowering を追加。この ADR が定義する `EPerform`/`EHandle` を
  変更しない、新規 lowering pass の追加のみ。

各 Phase は 75 本の `fixtures/effect_*.vibe` と `compiler_gate.sh` の
gate 26/27 (effect-call discipline / handle effect discharge) を
壊さないことを前提条件とする。

## Implementation and regression locks

実装は次の順で TDD する。

1. `fixtures/` に M2 の再現ケース (2 perform で `[body-start]` 3 回出力、
   `let mut` 二重加算) を pin する (Phase 1)。
2. checker: tail-resumptive 判定 (`resume` が唯一の効果かつ tail 位置か)
   を handler arm 単位で計算し、診断ではなく内部フラグとして保持する。
3. IR: `EPerform`/`EResume` ノードを導入し、既存の文字列名ディスパッチ
   (`compile_call.vibe` の `fname == "perform"` 等) をこのノードの
   構築に置き換える (codegen 側の消費はまだ変更しない — 既存の
   replay codegen が `EPerform`/`EResume` を見て今までと同じコードを
   出す薄いブリッジを一時的に挟む)。
4. linear backend: tail-resumptive operation の evidence 直接呼び出し
   経路を実装。非 tail-resumptive operation は既存 replay codegen へ
   フォールバック。
5. linear backend: yield bubbling (選択的 CPS 変換 + `Outcome[R]`) を
   実装し、replay codegen を削除。
6. wasm-gc backend: 同じ evidence 設計で `EHandle` を実装 (Error 専用
   スタブを一般化)。
7. suspend 点 IR に WasmFX/JSPI 向け代替 lowering の骨組みを追加
   (実装は本 ADR のスコープ外、swap 可能な形だけ用意する)。

最低限、次を回帰として固定する。

- M2 の再現ケースが Phase 3 完了後に正しい値・正しい副作用回数を返す
- tail-resumptive のみの handler は Phase 2 完了時点で値・副作用回数が
  正しくなる (replay 由来の重複実行が起きない)
- multi-shot resume (`fixtures/effect_multishot.vibe` — 現状「未対応」を
  記録しているだけの fixture) が Phase 3 完了後に複数回 resume できる
  ことを検証する形へ更新される
- `~16K` perform を超えるケース (tail-resumptive の場合) が Phase 2
  以降オーバーフローしない
- 既存 75 本の `fixtures/effect_*.vibe` と gate 26/27 が全 Phase を通じて
  壊れない
- 新 IR ノード (`EPerform`/`EResume`) の使用は fixtures/docs から開始し、
  compiler 自身のソースでの使用は Phase 3 の bootstrap bump 後

## Open questions

- tail-resumptive 判定を **handler 宣言時**に固定するか、**perform 呼び出し
  ごと**(同じ handler でも呼び出し経路によって tail 位置かどうかが変わる
  高階 handler のケース) に行うかは要検討。本 ADR は前者 (arm 単位) を
  既定にしているが、`fixtures/effect_higher_order_*.vibe` 群で後者が
  必要になる可能性がある。
- 動的 evidence 解決 (row variable 越し) のコストが trait dict 版の
  method 呼び出しと同等かどうかは実装後にベンチマークで確認する。
- ADR-0060 の `Write[r]` region モデルが `let mut` を effect として
  統一する場合、evidence passing はそのモデル上の `Write` operation にも
  同じ tail-resumptive 判定を適用できるはずだが、`Write[r]` 自体が
  proposed のまま未実装なので、順序 (evidence passing が先か
  `Write[r]` が先か) は別途決める。
- WASI 0.3 の component-model future/stream + JSPI lowering (Phase 5 (b))
  は ADR-0012 の async 設計との統合方法が未確定 — 別 ADR に切り出す
  可能性がある。

## References

- N. Xie, D. Leijen, [Generalized Evidence Passing for Effect
  Handlers](https://www.microsoft.com/en-us/research/publication/generalized-evidence-passing-for-effect-handlers/)
  (ICFP 2021) — 本 ADR の中核アルゴリズム。tail-resumptive の直接呼び出し
  化と非 tail-resumptive の yield bubbling。
- D. Leijen, [The Koka Programming Language: Effect
  Typing](https://koka-lang.github.io/koka/doc/book.html#sec-effect-types)
  — evidence vector と row-based effect の実装例。
- Effekt, one-shot 定数時間 resume (ICFP 2025 該当セッション、
  `docs/pl-survey-2026-07.md` 参照) — 本 ADR の tail-resumptive 判定は
  one-shot 前提の高速化と同じ動機を持つが、multi-shot を排除しない
  (yield bubbling 側で multi-shot をサポートし続ける) 点で異なる。
- wasm_of_ocaml, 選択的 CPS — 「pure-by-default + 静的 effect row から
  CPS 対象をゼロコストで判定する」という本 ADR の yield bubbling 適用
  範囲の絞り込み方針の直接の参考。
- `docs/archive/adr/0021-mut-effect-handler.md` — tail-resumptive
  ゼロコスト化の元祖の提案 (旧 MoonBit host 限定で実装され、#594 で
  当該実装は退役。本 ADR が selfhost 上での再実装にあたる)。
- `docs/effectset.md` (ADR-0071) — operation-level 正規化 row。本 ADR の
  `OperationId` はこの ADR の正規化形を第一の入力とする。
- `docs/pl-survey-2026-07.md` — 本 ADR の元になったサーベイ項目。
- `eval/lang-review/findings/2026-07-12-r2.md` M2 — replay の実測バグ。
