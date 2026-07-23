# ADR-0076: effect handler を evidence passing 化する (suspend 点 IR で WasmFX/WASI 0.3 前方互換)

Status: proposed (実装 Phase 1/2/2b は着地済み。Phase 3 は「CPS 新規実装」ではなく「evidence_dict_pass の静的カバレッジ拡大」に帰着することが判明 (追記 2/16) -- 2026-07-23 のセッションで multi-effect row・nested handle・pure helper 呼び出し・EDot・closure literal・effectset alias (whole-effect/qualified operation 双方)・row-variable tail・capture-free local closure invocation まで対象を拡大、加えて関連する closure+effect codegen バグ #1069 (capturing local closure の invocation) を修正、#1070 (by-value に渡された capturing closure) を新規発見・報告。「段階導入計画」の実装ノート・追記 9-16 参照)

Date: 2026-07-22

Related: ADR-0003, ADR-0012, ADR-0021, ADR-0050, ADR-0060, ADR-0068, ADR-0071,
ADR-0073, #626, #806, #817, #818

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

### evidence dict のスコープと解決 (**訂正版** — 2026-07-22 実装作業中に判明)

初稿ではここを「呼び出し経路上に row variable が無ければ handler はコンパイル
時に一意に決まり、evidence は完全に消える」と書いたが、これは誤りだった。
`fixtures/effect_higher_order_swap.vibe` を精査すると反例になる: `compute`
(effect row は `with { Env }` — row variable を一切含まない具体的な row) は
`with_ten(compute)` と `with_hundred(compute)` の**両方**から呼ばれ、
呼び出し先ごとに**異なる**handler がインストールされる。つまり「row variable
が無いこと」は handler の一意性を全く保証しない — 一意性は「その関数の
*特定の呼び出し* が、コンパイル時に判別可能な唯一の handler インストール
経路の下にあるか」という、呼び出しグラフの reachability の問題であって、
宣言された row の形からは決まらない。

正しいモデルは、**trait dict-passing とまったく同じ**「dict はデフォルトで
常に (暗黙引数として) 持ち回り、静的消去は monomorphization 相当の最適化」
という形にする。

- `handle { EXPR } with Effect { Op(args) => body }` の **EXPR 自身の直下**
  (関数呼び出しを挟まない位置) にある `perform Effect::Op(args)` は、
  handle 式が evidence を合成するその場で直接わかるので、コンパイル時に
  handler 実装への直接呼び出しへ解決できる — dict は要らない。これは
  trait dict でいう「具体型が呼び出し位置で分かっている単相呼び出し」と
  同じ状況である。
- `perform` が **関数呼び出しを 1 段以上挟んだ先** (`EXPR` が `f()` を呼び、
  `f` の本体が perform する、というよくある形 — 実際
  `fixtures/effect_higher_order_*.vibe` は**すべて**この形) にある場合、
  `f` は evidence dict を暗黙引数として受け取るようコンパイルし、
  `handle` 側が dict を合成して渡す。これは trait dict でいう「型引数が
  外側から渡ってくる generic 関数」と同じ状況であり、`f` の effect row に
  row variable があるかどうかとは無関係に発生する (`compute` の例のとおり)。
- 「dict を静的に消せる」ケースを**呼び出しグラフ全体に一般化する** (`f`
  が provably 単一の handle 経路の下でしか呼ばれないと証明して dict 引数
  ごと消す) のは、trait dict の monomorphization/inlining と同じ**独立した
  最適化**として後続に位置づける。Phase 2/3 の正しさはこれに依存しない
  — dict は常に正しく機能する既定経路であり、消去は追加のボーナスに
  すぎない。

row variable (現行の「単一小文字ラベル」escape hatch、または ADR-0071 の
`RowVariable`) は「dict を持ち回るかどうか」の判断基準ではなく、
「**dict のどの operation フィールドが必要になるか、コンパイル時に列挙
できるか**」の問題として引き続き関係する — ADR-0071 の構造化 row が
Phase 3 (replay 全廃) の前提になる、という既存の結論 (下記「検討済みの
論点」参照) はこの訂正後も変わらない。

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

### 並行モデル (ADR-0068) との整合

`docs/concurrency.md` (ADR-0068) は本 ADR に先んじて evidence の語彙と
制約の一部を既に規定しており、本 ADR はそれと矛盾しないよう設計する。

- ADR-0068 の実装順は「1. 本仕様と fixture を固定 → **2. #817:
  replay handler を evidence passing + yield bubbling へ置換し、共通の
  `Suspend` IR と finalizer unwind を作る** → 3. mutable global を
  `TaskContext` へ集約 → …」であり、**本 ADR (#817) は並行 runtime が
  「準拠」を名乗るための前提条件**として先に位置づけられている
  (`docs/concurrency.md` の「cancel と non-local exit は stack を
  unwind し…replay handler を generalized evidence passing + 明示
  suspend IR へ置き換える #817…は、並行 runtime を compliant と呼ぶ
  前提である」)。本 ADR の `EPerform`/`EHandle`/suspend 点 IR は、
  ADR-0068 が指す「共通の `Suspend` IR」と同一のものとして設計する
  (別の IR を用意しない)。
- `Cont[R]` (yield bubbling の継続クロージャ) は ADR-0068 の
  「continuation は task-affine、同じ task で一度だけ resume でき、
  channel message / spawn capture / global state に保存できない」と
  いう制約をそのまま満たす — 本 ADR は `Cont[R]` を通常のクロージャ
  として実装するので `Send` 判定は ADR-0068 の allowlist
  (`docs/concurrency.md` の `Send`/`Spawnable[r]` checker) が自動的に
  除外する。本 ADR 側で追加の cross-task 制約を実装する必要はない。
- evidence dict も同じ理由で既定では `Send`/fork-safe ではない。
  ADR-0068 は「v0.4.0 では `Async`/`Spawn` runtime evidence と
  package contract で fork-safe と定めた built-in host capability
  だけを fork できる。user-defined handler は既定で task-local」と
  定めており、本 ADR が生成する evidence (ユーザー定義 `effect` の
  handler dict) はこの既定 (fork 不可) にそのまま従う。fork-safe な
  ユーザー定義 handler を宣言する surface は ADR-0068 が「後続 ADR」に
  委ねており、本 ADR のスコープにも含めない。
- 本 ADR が replay 機構 (`eff_reserve` 固定領域、perform counter、resume
  memo 配列というグローバル可変状態) を丸ごと削除することは、ADR-0068
  が「`TaskContext` へ集約するか spawn 前に freeze する必要がある」と
  名指ししていたグローバル可変状態の一つを**削除によって解消する** —
  ADR-0068 の Phase 3 (mutable global の `TaskContext` 集約) の対象から
  この分だけ縮小される。evidence dict/`Cont[R]` 自体は (通常のクロージャ
  なので) 元々スタック/ヒープ上の値であり、集約すべきグローバル可変状態
  ではない。

### finalizer と dynamic-wind

ADR-0068 は「cancel と non-local exit は stack を unwind し、登録済み
finalizer をちょうど一度実行しなければならない」ことを並行 runtime の
必須要件にしている。本 ADR の yield bubbling は `Outcome[R] = Done(R) |
Yield(...)` という通常の値を関数間で返すだけなので、cancel/non-local
exit 自体は既存の `Error`/`throw` の unwind 経路 (ADR-0073) と同じ
機構で表現できる — 新しい unwind プリミティブを追加しない。ただし
「finalizer をちょうど一度実行する」という**保証**は本 ADR の設計だけ
からは自動的に出ない: `Cont[R]` を呼ばずに `Yield` を破棄する (=
perform した computation を resume しないまま終了する) ケースで、
`Cont[R]` が capture していたローカルの finalizer 相当 (Perceus の
drop、あるいはユーザー定義の `handle ... with Error` によるクリーン
アップ) が正しく実行されるかは、`Cont[R]` クロージャの RC drop 経路が
「capture した値を最後まで正しく drop する」という既存の Perceus 保証
に委ねられる。これは本 ADR のスコープでは**据え置きとする**: Effekt の
dynamic-wind 相当の明示的な finalizer スタック機構 (`docs/pl-survey-2026-07.md`
参照) を独自に導入するかどうかは、ADR-0068 の Phase 3 以降
(`TaskContext` の finalizer stack 実装、`docs/concurrency.md` の
`TaskContext` 構成要素に「finalizer stack」が既に列挙されている) で
決める。本 ADR は「`Cont[R]` を破棄すれば通常の RC drop で capture 済み
資源が解放される」という Perceus ベースの最小保証だけを約束し、
明示的な finalizer 登録 API の要否は ADR-0068 側の判断に委ねる。

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
- **row variable の有無だけで static/dynamic を判定する** (初稿の誤り):
  `fixtures/effect_higher_order_swap.vibe` が反例 — row variable を含まない
  具体的な effect row の関数 (`compute`) でも、呼び出しグラフ上で複数の
  異なる handler インストール経路の下に置かれうる。dict の要否は宣言された
  row の形ではなく呼び出しグラフの reachability で決まる (上記「evidence
  dict のスコープと解決」参照)。

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
- **Phase 3**: 当初は「yield bubbling (選択的 CPS) を実装し、非
  tail-resumptive 経路も evidence passing へ移行」と計画されていたが、
  「追記 2」「追記 16」の調査で **CPS 自体は現在コンパイル可能などの
  vibe プログラムにも必要とされない可能性が高い** ことが分かった
  (`#942`/`#814` が non-tail・multi-shot な resume をチェッカーレベルで
  一律 reject するため、Xie & Leijen の定義上そもそも handler は既に
  tail-resumptive)。従って Phase 3 の実態は「CPS ランタイムの新規実装」
  ではなく、**`evidence_dict_pass` の静的カバレッジを、あらゆる
  tail-resumptive な perform を direct call へ書き換えられる状態まで
  漸進的に拡大し続けること** に帰着する -- 2026-07-23 のセッションで
  実際にこの方向で拡張した範囲 (multi-effect row・nested handle・pure
  helper 呼び出し・EDot・closure literal・effectset alias・qualified
  operation・row-variable tail・capture-free local closure invocation)
  はその一部。カバレッジが「コンパイル可能な全プログラム」に到達した
  時点で replay codegen (`eff_reserve`・memo アドレッシング・loop) は
  到達不能になり、削除できる -- `~16K` bound と M2 はそこで全域解消する。
  唯一の未検証項目は ADR-0068 の `Cont`/finalizer まわりとの整合
  (「追記 2」(c)) で、ADR-0068 側の TaskContext/finalizer stack 実装が
  着地するまで本 ADR 単独では確認できない。selfhost bootstrap bump は
  依然必要 (compiler 自身の effect 呼び出しが新経路でコンパイルされる
  段階で)。**前提**: 現行の「単一小文字ラベルは全 operation を
  authorize する」row-polymorphism hack には evidence dict を組み立てる
  ための operation 集合情報がなく、replay 経路を完全に削除するには
  この hack を使う関数にも evidence を割り当てられる必要がある —
  ADR-0071 の構造化 row (少なくとも row variable 部分) が Phase 3 完了
  までに着地していることを前提とする (詳細は下記「検討済みの論点」
  参照)。着地していない場合は、hack を使う関数だけ replay 経路を残す
  長期 hybrid に切り替える。
- **Phase 4**: wasm-gc backend に同じ evidence 設計で完全な代数的
  effect handler を実装 (`with Error` スタブからの昇格)。
- **Phase 5**: suspend 点 IR に WasmFX / WASI 0.3 async (JSPI) 向けの
  代替 lowering を追加。この ADR が定義する `EPerform`/`EHandle` を
  変更しない、新規 lowering pass の追加のみ。

各 Phase は 75 本の `fixtures/effect_*.vibe` と `compiler_gate.sh` の
gate 26/27 (effect-call discipline / handle effect discharge) を
壊さないことを前提条件とする。

**実装ノート (2026-07-22, Phase 1/2/2b 着地)**: 実際に着地した Phase 2
は上記の当初計画 (`EPerform`/`EResume` IR ノード導入 + 既存 replay
codegen への薄いブリッジ) より単純な経路をとった —
`lib/@vibe/compiler/codegen/common_base/inline_direct_perform.vibe` の
`inline_direct_performs` は AST 変換パスとして実装され、新しい IR
ノードを一切導入しない。#942 (`check_arm_resume_tail`) が既に
「有効な handler arm は全て tail-resumptive」を保証している事実を使い、
handle の BODY に `EFn`/`nested EHandle`/`perform` 以外への call が
一切無いことを保証できた場合 (Phase 2b で純粋 builtin 呼び出しは
この「call」判定から除外し適用範囲を拡大)、その handle 内の対応する
`perform` を全て呼び出し元の arm body へ直接展開し、`EHandle` 自体を
削除する — codegen (replay 経路含む) はこの handle を最初から見ない。
条件を満たさない handle は今まで通り無変更で既存 replay codegen へ
流れる (hybrid という結果は当初計画と同じだが、フォールバック機構が
「新 IR ノード上のディスパッチ分岐」ではなく「変換パスの conservative
bail-out」である点が異なる)。Phase 1 (M2 を fixture として pin) は
計画通り着地。Phase 3 (yield bubbling) に着手する際は、この AST 変換
アプローチを土台にするか、当初計画の IR ノード導入に切り替えるかを
再検討すること — 少なくとも #942 ベースの tail-resumptive 判定は
Phase 3 でも再利用できる。

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

## 検討済みの論点 (Open questions からの解消)

設計確定にあたり、次の 4 点は「未決」ではなく本 ADR の決定として確定する。

1. **tail-resumptive 判定の粒度は handler arm 単位に固定する**。
   `fixtures/effect_higher_order_{basic,compose,swap,test_double}.vibe`
   を精査した結果、これらの「高階」性は「effect を使う関数値を、handler
   を設置する別関数へ引数として渡す」ことだけを指し、`handle ... with
   Effect { Op(args) => body }` の **`body` 自体は常に固定されたソース
   テキスト**である (呼び出し元がどんな `f` を渡すかに関わらず、その
   handle 式の arm の形は変わらない)。vibe に「同じ arm が呼び出し経路
   によって tail 位置かどうか変わる」ケースは存在しない — handler は
   実行時に組み替わる値ではなく、lexical に固定された arm の集合だから
   である。したがって「呼び出し経路ごとの判定」を検討する必要はなく、
   arm 単位の静的判定 (本 ADR の既定) で十分かつ正確である。
2. **動的 evidence 解決のコストは個別にベンチマークしない**。evidence
   dict は method-bearing trait dict-passing と**同じ codegen 経路**を
   再利用する設計 (上記) なので、コスト特性は trait dict 呼び出しの
   それと構造的に同一になる。trait dict の呼び出しコストは既に実装済み・
   受け入れ済みなので、evidence dict だけを対象にした追加のベンチマーク
   を実装完了の前提条件にしない。実装後のスモークテストで生成コードの
   形が trait dict のものと同型であることだけ確認すれば十分とする。
3. **ADR-0060 (`Write[r]` region モデル) との順序依存はない**。evidence
   passing は「今日 handle されている任意の effect」の実行戦略であり、
   `let mut` を effect として統一するかどうかという型システム側の設計
   (ADR-0060、proposed のまま未実装) とは独立である。`Write[r]` が
   将来実装されても、それは evidence passing が既に扱える「もう一つの
   handled effect」になるだけで、本 ADR 側の変更を要求しない。ADR-0060
   実装の先後を待つ理由はない。
4. **WASI 0.3 async / JSPI lowering は独立した後続 ADR に切り出す**。
   `docs/concurrency.md` (ADR-0068) 自身の実装順が「1. 本仕様の fixture
   固定 → 2. #817 (本 ADR) → 3. `TaskContext` 集約 → … → 7. JSPI/Worker
   と WASI Component Model lowering」と定めており、JSPI 統合は本 ADR
   より後の、複数ステップを経た段階の仕事として既に順序付けられている。
   本 ADR は「後で追加できる形」(suspend 点 IR を差し替え可能にする)
   だけを約束し、統合方法そのものの決定は ADR-0068 の該当フェーズに
   到達した時点の別 ADR に委ねる。

一方で、この確認作業で新たに顕在化した依存が 1 つある。

- **Phase 3 (yield bubbling による replay 全廃) は ADR-0071 の正規化
  row (少なくとも row variable の構造化表現) の着地を前提とする**。
  現行の「単一小文字ラベルは全 operation を authorize する」という
  row-polymorphism hack (`checker_effects.vibe` の
  `label_is_effect_var`) には、evidence dict を組み立てるために必要な
  「この関数が要求しうる operation の集合」という情報がそもそも存在
  しない — dict の field を列挙できない。**Phase 1/2 (静的解決 +
  tail-resumptive 高速パス) はこの制約を受けない**: 対象になる perform
  はほぼ全て具体的effect使用であり (issue 自身の「解決率が極めて高い」
  という主張どおり)、row-variable 越しの perform は Phase 2 の間
  対象外のまま既存 replay 経路に残しておける。**Phase 3 で replay 経路
  を完全に削除する時点で**、row-variable 越しの perform にも evidence
  passing を適用できる必要があり、そのためには ADR-0071 の構造化
  row 表現が必要になる。ADR-0071 が Phase 3 着手までに着地していない
  場合は、(a) ADR-0071 を先に着地させるか、(b) 現行の hack を使う関数
  だけ replay 経路を暫定的に残す長期 hybrid のいずれかを選ぶ — 本 ADR
  は (a) を既定の想定とする (ADR-0071 の方が影響範囲が狭く、着地が
  早いと見込む)。

**追記 (2026-07-22, ADR-0071 step 6 着手時の調査で判明)**: 上記の
「ADR-0071 の構造化 row が必要」という依存を、実装可能な単位まで
具体化する調査を行った結果、2 つの新しい事実が判明した。

1. **row-polymorphism hack はチェッカーの健全性としては現状のままで
   問題ない**。`decl_authorizes_effect` (checker_effects.vibe:719-732)
   が row 変数ラベルを見た時点で無条件に authorize するのは、宣言時
   点の型 (「この関数はどんな row `e` を渡されても動く」という
   parametricity の主張そのもの) としては正しい。型検査を壊さずに
   直せる/直すべき「バグ」ではない。実際に足りないのは、Phase 3 の
   **codegen 側**が「この row 変数の実体化先の evidence をどう組み立て
   渡すか」を決める情報であり、チェッカーの許可判定ロジックではない。
   ADR-0071 の `OperationId`/`OperationRef` 正規化そのものを先に
   チェッカー全体へ導入する必要はなく、Phase 3 の dict 構築ロジックが
   要求する最小限の情報 (下記) だけを用意すればよい。
2. **trait dict-passing の直接転用は shape の理由で成立しない**。
   `desugar_trait_dict.vibe` の dict-passing (`thread_dict_params`
   `:3036-3054`, `synth_dicts` `:1706-1738`, `find_dict_for_trait`
   `:1590-1603`) が成立するのは、`TrDict[T]` が **T に依存せず常に固定
   の field 集合**(trait 自身のメソッド一覧、`make_dict_struct_stmt`
   `:919-931`) を持つからで、呼び出し側は「どの具体型か」だけを
   `infer_arg_type_name` で静的に決めれば、あとは固定レイアウトの
   struct を合成できる。一方 effect row 変数 `e` は、呼び出し箇所ごとに
   **異なる、時には複数 effect の集合**(`with { e }` の実体化先が
   `Ask` のときも `Ask, Fs` のときもある) に束縛されうるため、
   「row 変数用の固定レイアウト struct」という型自体が存在しない —
   trait dict の struct 版パターンをそのまま流用できない。
   単一関数を実体化ごとに monomorphize すれば固定レイアウトを回復
   できるが、effectful な HOF は compiler 自身のソースにも多数出現する
   ため (#705 の RC 二値化 bundle size 予算を参照)、コード膨張が懸念
   される。
3. **暫定の解決方針 (実装は Phase 3 の一部として行う。ここでは方針だけ
   決定する)**: 固定レイアウト struct ではなく、**(OperationId,
   closure) のペアを並べた可変長ベクタ**を evidence 値の runtime 表現
   とする — vtable ではなく Koka の evidence vector そのものの素直な
   表現。row 変数の実体化先が単一 effect でも複数 effect でも同じ
   ベクタ表現に載るため monomorphize が不要になり、trait dict の
   `find_dict_for_trait` に相当する「呼び出し元が既に持っている
   evidence をそのまま/フィルタして転送する」というスレッディングの
   形だけを流用する (中身は固定 struct field アクセスではなくベクタの
   線形探索または該当 operation だけの部分ベクタになる)。
   `OperationId` はこのベクタのキーとしてだけ必要になる —
   ADR-0071 の正規化 row をチェッカー全域に波及させる代わりに、
   「各 effect operation に安定した数値/文字列キーを 1 つ割り当てる」
   という最小のメタデータ生成だけで十分。よって **ADR-0071 step 6 は
   「Phase 3 着手前の独立した準備ステップ」ではなく、Phase 3 の
   dict/evidence-vector 構築ロジック実装 (段階導入計画のステップ 4/5)
   に統合して行う** — 消費者が存在しない状態でキー割り当てだけを
   先行実装すると、Phase 2 の当初計画 (`EPerform`/`EResume` IR ノード)
   と同様に「実装したが実際の経路では使われない scaffolding」になる
   リスクがあるため。ADR-0071 (docs/effectset.md) の step 6 の記述は
   この結論に合わせて更新する。

**追記 2 (2026-07-22, replay 機構の実装精査から得た簡略化仮説 — 未検証、
要 fixture 実証)**: 現行 replay 実装 (`compile_expr_tail6.vibe`) と
`#942` (`check_arm_resume_tail`, checker.vibe:2617-2637) を実装レベルで
精査した結果、**Phase 3 は当初想定した Outcome[R]/CPS 変換
("yield bubbling") を必要としない可能性がある**、という仮説が得られた。
確定した設計変更ではなく、実装着手前に fixture で検証すべき仮説として
記録する。

根拠: `#942` は「resume(...) は arm の tail 位置以外では compile error」
という制約を、resume を呼ぶ場合に**強制**する (multi-shot・non-tail
resume は現在の vibe ソース言語で構文的に構築不可能)。Xie & Leijen の
generalized evidence passing 理論において、この「1 arm につき resume
高々 1 回・必ず tail 位置」という性質はまさに "tail-resumptive" の定義
そのものであり、tail-resumptive な handler は **CPS 変換なしの直接
呼び出し** (perform → 対応する operation の evidence closure を
ordinary call で呼び、closure 内の tail `resume(v)` はその closure の
ordinary return として v を返すだけ) に還元できる、というのが
Xie & Leijen 論文自身の核心的主張である。もしこれが vibe の全 handler
に当てはまるなら (`#942` が resume を伴う全 arm に対してこれを機械的に
強制しているため)、**「evidence dict を通常引数として呼び出しチェーンに
沿って中継する (trait dict-passing の `find_dict_for_trait` と同型の
スレッディング) だけで、replay loop・`eff_reserve`・memo アドレッシング
を全廃できる」**ことになり、Outcome[R] 型も CPS 変換も新規に導入する
必要がなくなる。Phase 2 (`inline_direct_performs`) が対応できていない
のは「perform が静的に (AST 上で) 発見できない」ケース (closure 引数
越し・nested handle・非純粋呼び出し越し) だけであり、これは
「静的インライン展開」を「動的 evidence 直接呼び出し (dict 経由)」に
置き換えるだけで解決する、CPS を要さない問題である可能性が高い。

resume を一度も呼ばない arm (`Error` arm は `handler_arm_pat_is_error`
で本チェックの対象外、それ以外の通常 effect の arm がノーリターン/
abort 的に「resume せず arm 自身の値を handle 式全体の値にする」ことを
意図的に書けるのかは本調査では未確定) は依然として非局所脱出
(non-local exit) が必要になるが、これは replay の throw/`try_table`
機構が今日すでに提供している経路をそのまま流用でき (abort は
1 度しか実行されない性質上、replay 特有の「体を再実行する」問題を
そもそも引き起こさない)、新規機構は不要と見込まれる。

**この仮説が崩れる可能性のある具体的な検証対象** (Phase 3 着手時に
`fixtures/effect_*.vibe` 75 本 + 新規 fixture で必ず確認すること):
(a) **[検証済み・懸念解消]** resume を一度も呼ばない非 `Error` effect の
arm を実際に試したところ (`handle { let x = perform Ask::Get; x + 100 }
with Ask { Get => 42 }`、gen_adr71k の stage2 でコンパイル・実行)、結果は
`142` (= 42 + 100) だった — つまり resume を書かない arm は「abort して
handle 式全体の値を arm の値にする」という別意味論ではなく、**arm の
tail 値がそのまま暗黙の `resume(値)` として扱われている**。ユーザ定義
effect の arm に真の abort/non-local-exit 意味論は存在せず (それは
`Error` 専用の別経路)、全ての通常 effect arm は結局 tail-resumptive に
帰着する。このリスクは解消したと見てよい — CPS/Outcome[R] を要さない
という仮説をむしろ補強する結果。(b) **[検証済み・懸念解消]** 同じ
effect に対する入れ子の `handle` (shadowing) で、どちらの evidence が
呼ばれるべきかを実際に試したところ (`handle { handle { perform
Ask::Get } with Ask { Get => resume(1) } } with Ask { Get => resume(2) }`、
同じく gen_adr71k の stage2 でコンパイル・実行)、結果は `1` — 内側
(lexically innermost = 動的に最も最近インストールされた) handler が
勝つ、という通常の (dynamic scoping の) 期待どおりの意味論だった。
これは evidence-dict スレッディングモデルでも変更なしに自然に成立する
— 内側の `handle` の evidence は、trait dict の `dict_binds` が
lexical scope でネストした generic 呼び出しを自然にシャドーする
のと全く同じ理屈で、呼び出しチェーンに沿って外側の evidence を
シャドーするだけでよい (新しい解決ロジックは不要)。このリスクも
解消したと見てよい。(c) ADR-0068 (`docs/concurrency.md`) の
async/`Spawn` 文脈で `Cont[R]` を経由した継続の保存が必要になる場面
(本 ADR の「cancel と non-local exit」節で「据え置き」とされている
finalizer 保証の話) と、この直接呼び出しモデルとの整合性 — 3 点のうち
唯一まだ未検証。(a)(b) が解消したことで、この仮説はかなり有望になった
と見てよい: Phase 3 の実装コストは当初想定より大幅に小さくなる可能性が
高い (新規 IR ノード・新規 runtime 型が不要になり、Phase 2 の
`inline_direct_performs` を「静的に発見できる場合」の特殊高速路として
残したまま、「動的 evidence 直接呼び出し」を fallback 経路として追加する
だけで済む)。(c) は ADR-0068 側の TaskContext/finalizer stack 実装が
まだ存在しない (据え置き扱いのまま) ため、本 ADR の範囲だけでは検証
できない — ADR-0068 の該当フェーズに到達してから改めて確認する。
(a)(b) の解消と (c) の未検証状態を踏まえてもなお、まだ「確定した設計」
ではなく「有望な作業仮説」の位置づけとする — Phase 3 実装着手時に
75 本の fixture 回帰を通しながら最終確認すること。

**実装ノート (2026-07-22, Phase 3 第一スライス着地)**: 上記の仮説に
沿って、Phase 3 の最小スライスを実装・着地させた。対象は Phase 2
(`inline_direct_performs`) が「named 関数呼び出し」を理由に bail-out
する最狭のケース — handle の BODY が、宣言 row が **その 1 effect
ちょうど**である top-level 関数を呼び、その関数自身が該当 effect を
perform する形。このケースは実際に M2 と同型の replay 破損を再現する
本物のバグだった (fixtures/effect_handle_call_evidence.vibe、修正前は
6016、fixtures/effect_handle_replay_corruption.vibe と全く同じ壊れ方)。

実装は `evidence_dict_pass` (`codegen/common_base/inline_direct_perform.vibe`
に追記 -- 新規ファイルにすると「新規クロスファイル export + 同一コミットでの
初回 import」で bootstrap の flatten 工程がその関数を黙って merge 結果から
落とす、という新種の bootstrap gotcha を実際に踏んだため、既存の
cross-file-registered ファイルへ追記する形に変更した。詳細は
docs/effectset.md の「Bootstrap gotcha」注記、および本ノート末尾の
デバッグ記録参照): 宣言 row が「ちょうど 1 effect」の関数を
`desugar_trait_dict.vibe` の `TrDict[T]` と同型の struct
(`__EvDict_<Effect>`、field はその effect の operation 名) を暗黙の
先頭引数として受け取るよう書き換え、関数内の直接 `perform Effect::Op`
をその引数の field 呼び出しへ置換する。対応する `handle` 側は
arms から dict literal を合成し、対象関数への呼び出しにその場で渡した
上で `EHandle` ラッパー自体を削除する (Phase 2 と同じく、対象になった
handle は replay codegen を一切生成しない)。健全性は「関数は宣言 row が
実際にその effect を含む場合にのみ対象になる」という既存チェッカーの
保証に完全に依拠しており (本文書の「検討中の簡略化案」参照)、対象範囲外
(row-variable 越し、複数 effect が同じ row に同居、closure/nested handle
越し) は今まで通り無条件で replay に残る -- all-or-nothing で
中途半端な適用はしない。fixtures/effect_handle_call_evidence.vibe
(修正後 3013、M2 と同じ計算) + compiler_gate.sh 40u で回帰を固定。

デバッグ記録 (今後同じ罠を踏まないための注記): 実装完了後の最初の
selfhost ビルド+実行では、新規追加した処理が一見何も効果を及ぼしていない
ように見えた (fixture が直り切らない/変化がない) が、これは実装のロジック
自体のバグではなく、検証手順側の環境問題だった。原因は二重: (1)
`generations.sh build` が内部で独自に `generate_bundle.sh` を呼ぶ際、
呼び出し元シェルで export した `VIBE_REGEN_MODULE_SOURCE=1` を継承させる
だけでは不十分で、`generations.sh` 自身がその内部呼び出しに
`VIBE_ADAPTER_MODULE_SOURCE_OUT` を明示的に (一時ディレクトリ配下へ)
渡すため、`VIBE_REGEN_MODULE_SOURCE` を渡さない限りそちらは常に「stale な
committed `_cli_adapter_module_source.vibe` を再利用する」経路に落ちる
-- 手元での `generate_bundle.sh` 単体実行が成功していても、続けて呼ぶ
`generations.sh build` は依然として古いソースからビルドしてしまう。(2)
`_cli_adapter_module_source.vibe` (committed ファイル) 自体の書き戻しは
`VIBE_ADAPTER_MODULE_SOURCE_OUT` を明示的にその実パスへ設定した場合のみ
発生し、`VIBE_REGEN_MODULE_SOURCE=1` だけでは書き戻されない
(regenerate はするが、書き戻し先未指定なら一時ファイルへ捨てられる)。
両方を正しく設定して初めて `compiler_gate.sh` gate 1 (bundle sync) も
通った。「関数内に一時的な debug marker (main の本体を既知の定数へ
上書きする) を仕込んで、実行結果から内部状態を直接読み出す」という
手法が、effect 未宣言の `print` を使わずに済む安全なデバッグ手段として
機能した -- 今後 selfhost パイプラインの挙動を疑うときの再利用手順として
記録しておく。

**追記 3 (2026-07-22, 着地直後に発見・修正した実 バグ)**: 上記の第一
スライス着地後、カバレッジを広げる目的で「needing 関数呼び出しが
handle body の `if`/`match` 分岐の中にある」ケースを追加で直接テストした
ところ、生成される wasm が実際に**invalid** (`WebAssembly.instantiate():
... not enough arguments on the stack for call`) になり実行時に
クラッシュする、という本物のバグを発見した (AST 書き換え自体は構造的に
正しい呼び出しを生成しているにも関わらず、下流の何らかの codegen パスが
分岐内の呼び出し先 arity について食い違った判断をしていた -- 根本原因は
特定しきれていない)。この時点で `edp_has_unsafe_construct` は
`EIf`/`EMatch`/`EWhile`/`EForIn`/`ELoop` の中まで再帰して needing 呼び出し
を許可していたため、実際にこの形の handle body を書けば誰でも踏める
状態だった。安全側に倒し、分岐構文を `EFn`/`EHandle`/`EDot` と同じく
**常に unsafe** 扱いにする修正を即座に行った (このパスの対象は
straight-line なコードのみに縮小する) -- fixtures/effect_handle_call_
evidence_branch_fallback.vibe + compiler_gate.sh 40v で、分岐ケースが
クラッシュせず安全に (未着地時と同じ) replay へフォールバックすることを
回帰として固定した。教訓: 「AST 書き換えが構造的に正しく見える」ことと
「生成される wasm が実際に valid である」ことは別の主張であり、新しい
形の入力 (今回は「分岐の中」) を広げるたびに、レビューだけでなく実際に
コンパイル・実行して確かめる必要がある。

**追記 4 (2026-07-22, 上記バグの根本原因調査 -- 未確定、次にここから
着手すること)**: 「分岐の中を安全に再許可する」ための根本原因調査を
行った。以下は静的読解だけで得られた所見であり、ランタイム計装による
確認はまだ行っていない (確認せずに fix を当てるのはリスクが高いと判断し、
今回は見送った)。

除外できた仮説: 「`evidence_dict_pass` の書き換え前に構築された stale な
arity テーブルを下流が参照している」という仮説は誤り。
`linked_compile.vibe` の `fn_names_list`/`fn_param_counts` を含む全ての
arity/signature テーブルは `evidence_dict_pass(stmts)` 呼び出し (line 189)
より**後**に、書き換え済みの `stmts` から構築されている。

除外できたもう 1 つの仮説: `edp_rewrite_needing_fn`
(inline_direct_perform.vibe) は関数の `EFn` の `params` に dict 引数を
先頭追加する一方、同じ `SLet` の `ty` (トップレベルの型注釈) はそのまま
素通しする -- 一見「書き換え後の関数は実際の `EFn` params と自身の宣言
`ty` の引数数が 1 だけ食い違う」ように見えたが、確認したところ
`desugar_trait_dict.vibe` の `rewrite_stmt` (line 3075) も
`SLet(exp, isrec, fname, ann, EFn(tparams, bounds, new_params, ret, eff,
new_body))` と全く同じパターン (`ann`/`ty` は素通し、`params` だけ書き換え)
を使っており、これは trait dict-passing が本番で長期間問題なく使って
いる確立されたパターンだった。クラッシュの原因ではない。

最有力の手がかり: `codegen/expr/compile_call.vibe` の `compile_call` は
呼び出し名ごとに `fn_idx_in_list` (トップレベル関数テーブルでの位置) と
`local_idx_hint` (現在スコープのローカル変数名リスト `local_names` 内での
一致) の両方を調べ、`prefer_bound_call = fn_idx_in_list >= 0 ||
local_idx_hint >= 0` で分岐する。直接呼び出し (dict 引数を含む正しい
arity で `emit_call`) が選ばれるのは `fn_idx_in_list >= 0 &&
local_idx_hint < 0` のときだけで、`local_idx_hint >= 0` (呼び出し名が
`local_names` の中にも見つかる) だとクロージャ/ローカルシャドー呼び出し
経路 (`resolve_local` + `emit_closure_call_tail`) に流れ、そちらは
書き換え後の新しい arity とは無関係な別の呼び出し規約を使う。`EIf` の
codegen (`codegen/expr/compile_expr.vibe`、`#678` 注記のあるブロック) は
分岐ごとに `local_names` を `Array::truncate(local_names, names_len_before)`
で復元する処理を持っており、これが `EIf` の中か外かで唯一
「名前付き関数呼び出しに対する arity 判定ロジックが実際に変わりうる」
場所である。`ask_helper` という名前が `EIf` の分岐の中でだけ誤って
`local_names` に一致してしまう (=ローカル扱いされてしまう) 経路がある
かどうかが本命の疑い所だが、`local_idx_hint`/`fn_idx_in_list`/
`prefer_bound_call` を実際にログ計装して確認するところまでは今回
到達できていない。次にこのバグへ取り組む際は、まずここ (compile_call.vibe
の `local_idx_hint` 算出と、`EIf` 分岐前後の `local_names` の実際の中身)
を計装して確認するところから始めること。

**追記 5 (2026-07-23, もう 1 つ発見・修正した実バグ)**: 上記の根本原因
調査中、`#639` の残課題 (別件) を検討する過程で、`Error` が row 宣言
不要 (#640 Stage 2) であることに着目し、直接テストしたところ、もう
1 つの実バグを発見した -- 宣言 row がちょうど 1 effect (`Ask`) の
needing 関数が、その本文で **`perform Error::Throw` も併せて行う**
(row 宣言不要なので合法) と、実行時ではなく**コンパイル時エラー**
(`unknown struct field: Error::Throw`) になっていた。原因は
`edp_rewrite_perform_via_dict` が、本文中のどの `perform` も対象effect
を区別せず無条件に evidence dict 経由の呼び出しへ書き換えていたため
-- `Ask` 用の dict struct には `Get` field しか無いので、`Error::Throw`
をその dict 経由で呼ぼうとして存在しない field 参照になっていた。
`perform` の qualified 名の effect prefix が今回移行対象の `ename` と
一致する場合のみ書き換え、それ以外 (理論上 `Error` しか起こりえない --
他の effect が混在していれば checker の健全性により row がちょうど
1 effect のままにはならない) はそのまま素通しするよう修正
(`edp_qname_is_for_effect`)。fixtures/effect_handle_call_evidence_
error_mix.vibe + compiler_gate.sh 40w で回帰を固定 -- この fixture は
「`Error::Throw` だけを perform する needing 関数を宣言だけして一度も
呼ばない」形にしてあり、evidence_dict_pass が handle から到達可能かに
関わらず row が一致する関数を機械的に全て移行対象にすることを利用して、
実行時に踏まなくてもコンパイル時点でバグを再現できるようにしてある。

**追記 6 (2026-07-23, 「追記 4」の根本原因を特定・修正)**: 「追記 4」で
未確定のまま残していた分岐内呼び出しクラッシュの根本原因を、
`compile_call.vibe` に一時的な debug throw (`with { Error }` を既に
宣言している既存関数なので `print`/`Stdout` を新たに要求せず安全に
埋め込めた) を仕込んで実際に計装し、特定した。

結果、「追記 4」で本命視していた `local_idx_hint`/`fn_idx_in_list` の
分岐判定は **無関係だった** (計装値: `fn_idx_in_list=0`,
`local_idx_hint=-1` — 直接呼び出し経路が正しく選ばれていた)。真因は
`args_len=0` (AST 側の書き換えが、呼び出しサイトに対して**全く適用
されていなかった**) だった。

原因は evidence_dict_pass 側の設計そのものにあった: handle サイトの
書き換えは、まず `edp_collect_handle_sites` で対象 `EHandle` を
「収集」し、後で `edp_replace_handle_in_stmts` が同じ `stmts` を
もう一度歩いて **手製の構造的等価性チェック** (`edp_expr_eq`) で
「収集したのと同じ handle」を再発見し、そこだけ差し替える、という
2 段階の設計になっていた。ところが `edp_expr_eq` は
`EIdent`/`ECall`/`ESeq`/`ELet`/`EBinOp`/`EAssign`/`EInt` の 7 種類しか
扱っておらず、handle body に **それ以外の Expr** (今回踏んだ `EIf` を
含む) が含まれると、body を自分自身と比較しても `false` を返し、
「再発見」に静かに失敗していた。再発見に失敗した handle は
**元の (書き換え前の) 呼び出しのまま** 放置される一方、needing 関数
自身の署名は `edp_rewrite_needing_fn` という別の (名前ベースで
`fn_defs` を引く、この等価性チェックに一切依存しない) 経路で
**確実に書き換わっていた** ため、「呼び出し先は dict 引数込みの
新しい arity を要求するのに、呼び出しサイトは古い arity のまま」
という食い違った状態が生まれ、それが wasm レベルの arity mismatch
として表出していた。EIf はこの不具合を最初に踏んだ具体例に過ぎず、
`edp_expr_eq` が扱わない Expr 形なら (`ETuple`、`ELetMut`、`EMatch` 等
何であれ) 同じクラスのバグを引き起こしうる、branch 固有ではない、
より広いバグだったと判明した。

修正: 「収集してから等価性で再発見する」2 段階設計を廃止し、
`edp_find_rewrite_handles` という単一の走査関数に統合した --
対象 effect にマッチする `EHandle` を**見つけたその場で直接書き換える**
ため、そもそも「後で再発見する」フェーズが存在せず、このバグの
クラス全体が構造的に発生しえなくなった。これに伴い、
`edp_has_unsafe_construct` の `EIf`/`EMatch`/`EWhile`/`EForIn`/`ELoop`
を再び「安全なら再帰して判定」する元の (broader な) 挙動へ戻した --
このクラスのバグ自体が無くなったので、保守的な「分岐は常に unsafe」
制限を維持する理由が無くなったため。fixtures/effect_handle_call_
evidence_branch.vibe (旧 `..._branch_fallback.vibe` から改名・
再テスト) は、分岐ケースが「クラッシュしないだけ」ではなく
「evidence dict 経由で正しく (replay の重複実行なしに) 実行される」
ことを固定するよう更新した (期待値: replay フォールバック時の `3008`
ではなく、evidence dict 直接呼び出し時の正しい値 `2007`)。
compiler_gate.sh 40v で回帰を固定。

**追記 7 (2026-07-23, multi-effect row 拡張を試みて即座に revert)**:
「追記 6」の修正 (単一走査での書き換え) を踏まえ、`needing` の判定
(`edp_row_is_exactly`、宣言 row がちょうど 1 effect であることを要求)
を「row が複数 effect の comma-join でも、対象 effect が labels の
1 つに含まれていればよい」という containment 判定へ緩和することを
試みた。設計上の推論 (各 effect の migration は `evidence_dict_pass`
の `ei` ループで独立した pass として走り、それぞれが自分の
eligibility を独立に判定する。`perform` の書き換えは「追記 5」の
Error 混在修正 (`edp_qname_is_for_effect`) で既に対象 effect ごとに
選択的になっている。複数 pass にまたがる prepend は常に「現在の
stmts の状態に対して先頭へ追加する」という対称な操作なので、
signature 側と call-site 側の引数順序は自動的に揃うはず) では健全に
見えたが、実際に「1 つの関数が `{ Ask, Fs }` 両方を要求し、2 つの
**独立した** (nest していない) handle サイトでそれぞれ discharge
される」形の具体的な fixture を書いて直接テストしたところ、
コンパイルは通るが**実行時に uncaught exception でクラッシュする**、
という実バグが見つかった。抽象的な推論だけでは見抜けなかった
相互作用がある (おそらく: ある effect だけ evidence dict 化され、
もう一方の effect の perform は旧来の replay 経路に残ったままになる
「部分的に移行された」状態が、replay 自身の throw/catch の
前提を壊す) ため、この緩和は**即座に revert** した。根本原因は
未特定のまま、`edp_row_is_exactly` (exact match のみ) に戻し、
「試して reverted した」こと自体を doc comment に記録した上で、
このクラッシュを再現する具体的な fixture
(fixtures/effect_handle_multi_effect_row_fallback.vibe) を
「multi-effect row は evidence_dict_pass に一切触られず、既存の
replay 経路へ安全にフォールバックし続ける」ことを固定する回帰テストと
して追加した (compiler_gate.sh 40x)。multi-effect row 対応は
このセッションでは着手しない — 次に着手する際は、まずこの具体的な
クラッシュの根本原因を (今回の分岐バグと同じように) 実際に計装して
特定するところから始めること。

**追記 8 (2026-07-23, 「追記 7」のクラッシュの構造的原因を特定)**:
「追記 7」を revert した直後、`edp_row_is_exactly` を一時的に
containment 判定へ戻して同じ fixture を再テストしたところ (compile は
通り実行時 uncaught exception でクラッシュする、という同じ症状を
再現)、手作業でのトレースにより **構造的な原因** (実行時計装は行って
いないが、コードの読解だけで再現性のある論理的欠陥として特定できた)
を突き止めた。

`edp_has_unsafe_construct` は `EDot(_, _, _, _) => true` として
**あらゆる `EDot` を無条件に unsafe** 扱いする。ところが Ask の
migration 自身が、`both_helper` の body の `perform Ask::Get` を
`EDot(EIdent("__ev_Ask"), "Get", -1, -1)()` という**まさに `EDot`
ノード**へ書き換える (`edp_rewrite_perform_via_dict`)。Ask の
migration が (`ei` ループで) 先に走り、`both_helper` の body を
`stmts` 上で直接書き換えた**後**で、Fs の migration が (`edp_all_
sites_eligible` の needing-function-body チェック経由で)
`edp_find_fn_body(stmts, fn_defs, "both_helper")` を使って
`both_helper` の body を**現在の (Ask 書き換え後の) 状態**で
再取得し、`edp_has_unsafe_construct` に通す。この body には Ask が
直前に埋め込んだ `EDot` が含まれているため、Fs 自身の migration の
eligibility 判定はこの「自分より前の migration が生成した artifact」
を理由に**必ず unsafe と判定して abort**する。

これは 2 effect 目に限った偶然の不具合ではなく、**設計そのものの
構造的欠陥**である: `evidence_dict_pass` の 각 effect ごとの
eligibility 判定 (`edp_all_sites_eligible`) は毎回「その時点の
`stmts` の現在の状態」を re-scan する設計になっているため、ある
effect の migration が (`EDot` を導入するなどして) 対象コードを
書き換えた**後**に、同じ関数が**別の** effect の needing 対象として
再度チェックされると、前段の書き換え自体が新しい unsafe 要因として
検出され、後段の migration を必ず妨げる。これは containment 緩和を
やめて `edp_row_is_exactly` に戻している限り (ある関数が 2 つ以上の
migration の対象に重複してなることがないので) 顕在化しないが、
multi-effect row 対応に本格的に着手する際は、この「後段の
eligibility 判定が前段の書き換え artifact を誤検出する」問題を
先に解消する必要がある — 具体的には、全 effect の eligibility 判定を
**どの migration もまだ書き換えていない、元の (unmutated) `stmts`**
に対して**先に一括で** (現在のような `ei` ループ内での都度判定ではなく)
行い、判定結果を確定させてから初めて実際の書き換えを開始する設計に
改める必要があると見込まれる。ランタイム計装によるクラッシュの直接
確認はまだ行っていないが、この構造的欠陥はコード読解だけで再現性
高く説明がつくため、今後の着手時はまずこの仮説の妥当性を計装で
検証するところから始めるとよい。

**追記 9 (2026-07-23, 「追記 8」の仮説を実装したが同じクラッシュが再現
-- 別の構造的原因を発見)**: 「追記 8」で見立てた「全 effect の
eligibility 判定を書き換え開始前に一括で確定させる」設計を実際に
`edp_plan_migrations` として実装した (`evidence_dict_pass` を
「まず全 effect の migration plan を決定する」フェーズと「決定済みの
plan を順に適用する」フェーズへ分離)。この 2-phase 化自体は
単一 effect のケースでは挙動を一切変えない、副作用のない改善であり、
実際に全ての既存 fixture (effect_handle_call_evidence, ..._branch,
..._error_mix, multi_effect_row_fallback, replay_corruption) が
以前と全く同じ値を返すことを確認した上でこのセッションでは維持する。

しかし、この修正を適用した状態で「追記 7」と**全く同じ** multi-effect
fixture を containment 判定へ戻して再テストしたところ、**バイト単位で
同一のクラッシュ**が再現した。これは「追記 8」の見立て (EDot artifact
問題) が**この特定のクラッシュの原因ではなかった**ことを意味する
(EDot artifact 問題自体は実在する構造的欠陥として 2-phase 化で解消
されたが、それとは別に、そもそも `ask_only_wrapper` (`Fs` needing) の
body が**直接** `handle { ... } with Ask { ... }` そのものであり
(`EHandle` ノードが body の最上位に元々存在する、書き換えとは無関係な
事実)、`edp_has_unsafe_construct` の `EHandle(_, _) => true` が
(EDot とは独立に、正しく) これを unsafe と判定して `Fs` の migration
を最初から (2-phase 化の有無に関わらず) abort させていた。`Ask` の
migration は (`both_helper` 側にはこの問題が無いため) 成功する一方
`Fs` は abort する、という「一部の effect だけ evidence dict 化され、
もう一方は旧来の replay に残る」混在状態は、interleaved 設計でも
2-phase 設計でも**結果として同一**になり、それがクラッシュの真因で
ある可能性が高い (この「混在状態そのものが replay の前提を壊す」と
いう「追記 7」時点の当初の推測に実質的に回帰したことになる)。

containment 判定は `edp_row_is_exactly` (exact match のみ) へ再度
revert 済み。2-phase 化 (`edp_plan_migrations`) は独立した改善として
維持する。次に multi-effect row へ着手する際は、「EDot artifact」
「body が直接別 effect の handle」の 2 つの既知の eligibility 上の
障害を回避できる (あるいは正しく扱える) ように eligibility/rewrite の
設計を見直した上で、なお残る「一部の effect だけ migrate され、
残りが旧来の replay に残る」混在状態が replay 側の前提とどう
衝突するのかを、ランタイム計装 (「追記 6」の分岐バグ根本原因調査で
使った手法) で直接確認するところから始めること — 抽象的な推論や
コード読解だけでの見立ては、このセッションで 2 回とも実際のクラッシュ
との対応が外れており、十分な確信が得られていない。

### 追記 10 (2026-07-23): ランタイム計装で multi-effect クラッシュの真因を
特定 -- ただし multi-effect とは無関係の、既にシップ済みの健全性バグだった

「追記 9」の結論通り、抽象推論だけでの見立てを 2 回とも外したため、
今度は実際にランタイム計装で確認した。`edp_row_is_exactly` を
containment へ一時的に relax し (実験用、revert 済み)、さらに
`linked_compile.vibe` の export section を一時的にパッチして
全ての per-effect wasm exception tag を名前付きで export するようにした
上で (これも実験用、revert 済み) `effect_handle_multi_effect_row_fallback.vibe`
を実行したところ、`wasm_vibe_host_runner.js` の tag 判定
(`err.getArg(tag, 0)` が例外を投げずに成功する tag を探す) が
**`Fs` ではなく `Ask` タグ**を uncaught exception として特定した。
「追記 9」の手による見立て (`Fs` の migration が abort し、`Ask` は
成功する) が正しいとすれば、uncaught になるのは `Fs` のはずで、
`Ask` が uncaught になるのは矛盾する -- つまり「追記 9」の推測もまだ
不完全だった。

この矛盾を手がかりに `evidence_dict_pass` のコード自体を再点検した
結果、**multi-effect や containment relax とは全く無関係の、独立した
実装バグ**を発見した: `edp_rewrite_needing_body` (needing 関数自身の
body を書き換えるトラバーサル) の `ELet`/`ELetMut`/`ELetRec`/`EAssign`/
`EAssignOp` の各ケースが、値/RHS 位置 (`v`) を全く再帰していなかった
(body/継続位置の `b`/`c` だけを再帰) -- 一方、eligibility を決める
`edp_has_unsafe_construct` の同じ構文ケースは `v` も正しく再帰していた。
つまり `let a = perform Ask::Get` のように **`let` で束縛された
perform** は eligibility 判定 (「安全」) を正しく通過するにも関わらず、
書き換え本体では一度も visit されず生の `perform` のまま残っていた
-- そしてそのハンドラ側 (`EHandle`) は migration 成立の一部として
既に除去されているため、この生の `perform` が投げる例外を
キャッチする者が誰もいなくなり、uncaught exception でクラッシュする。

再現に multi-effect も containment も不要であることを、exact-match
のみの単一 effect + `let a = perform Ask::Get; a + 1` という最小
フィクスチャ (`fixtures/effect_handle_call_evidence_let_bound.vibe`)
で確認した -- containment を一切 relax していない、現在コミット
済みの exact-match 版のコードだけで同じ uncaught tag=Ask クラッシュが
再現した。**これは multi-effect 実験がたまたま踏んだだけの、
既にシップされていた本物のソウンドネスギャップ**であり、直接の
関連はない。

同型の不整合は `edp_rewrite_handle_body` (ハンドルサイト側の
書き換え) にも存在した (`EWhile`/`EForIn`/`ELoop`/`EUnaryOp`/
`ELabeledArg`/`EBreak`/`EContinue`/`ETuple`/`EArray`/`ERecord`/
`EMap`/`ESpread` を全く visit せず `_ => expr` にフォールスルー)。
両トラバーサルを `edp_has_unsafe_construct` の構造と完全に一致する
よう作り直し (全く同じ construct を全く同じ位置で再帰する)、
新規 regression fixture (`effect_handle_call_evidence_let_bound.vibe`、
期待値 6) と `compiler_gate.sh` gate 40y として固定した。

multi-effect row 自体の containment relax は今回も試みていない --
これは独立した別バグで、`edp_row_is_exactly` は exact match のまま
据え置いている。次に multi-effect へ再挑戦する際は、この
`edp_rewrite_needing_body`/`edp_rewrite_handle_body` の網羅性バグは
もう解消済みという前提から始められる。

### 追記 11 (2026-07-23): multi-effect row containment を実際に有効化 --
「追記 10」で見つけた網羅性バグが本当の原因だった

「追記 10」の予告通り、網羅性バグ解消済みの状態から multi-effect
row の containment relax に再度挑戦した (今回で 3 回目)。今回は
まず `evidence_dict_pass` に一時的な計装 (`main` の body を
`EInt(...)` で上書きし、どの effect が実際に migration plan を
獲得したかをプログラム自身の戻り値として直接読み出す) を入れ、
「本当に migration が発生しているのに偶然同じ値になっているだけ」
という可能性を排除してから判断する方針を取った (このセッションで
2 回、抽象推論だけの見立てが外れた反省を踏まえた)。

結果: `effect_handle_multi_effect_row_fallback.vibe` に対して
`edp_row_is_exactly` を containment に relax した状態で計装ビルドを
実行すると、`Ask` の migration plan が**実際に生成・適用されている**
ことを確認した (`Fs` は「追記 9」で特定した通り `ask_only_wrapper`
の body が直接 `handle {...} with Ask {...}` である、という独立の
理由で正しく除外される)。かつクラッシュせず、既存の fallback 値
(3018) と**完全に同じ**値で安定して実行できた。両効果の値が
一致するのは偶然ではなく、`Ask` の handler がこの fixture では
純粋に tail-resumptive でリプレイに対して冪等な副作用しか持たない
ため、evidence dict 経由でもリプレイ経由でも同じ答えになるという
自然な帰結である (# 別効果の side effect が repeat 実行に敏感な
ケースでの検証は今回未実施、今後の課題として残す)。

これにより、「追記 9」「追記 10」で追っていた multi-effect row の
クラッシュは、multi-effect 固有の問題では一切なく、`edp_rewrite_
needing_body` の網羅性バグ (「追記 10」参照) が原因のすべてだった
ことが最終的に確定した。計装を revert し、`edp_row_is_exactly` を
containment 判定へ本採用 (実コードとしてコミット) した。

安全性の根拠:
- 各 effect は独立した per-tag メモリ領域 (`eff_off`) を使うため、
  ある effect が evidence dict 化されて別の effect がまだ replay の
  ままでも、互いの領域は衝突しない。
- `edp_qname_is_for_effect` により、`edp_rewrite_needing_body` は
  migration 対象の effect の perform だけを書き換え、他の effect の
  perform (未対応の Error や、まだ migrate されていない他の effect)
  はそのまま残す。
- 1 つの needing 関数が複数の effect について「一部は evidence dict
  化され、残りは replay に残る」状態は、上記 2 点により意味的に
  安全 (readme の「追記 10」の分析通り)。

既知の残存スコープ境界 (今回は対応しない、バグではない):
同じ handle body が `handle ... with A { ... handle ... with B { ... }
... }` のように**直接ネスト**している場合、外側の handle site 自身の
body が `EHandle` ノードそのものになるため、`edp_has_unsafe_
construct` が無条件に unsafe と判定し、外側の effect は migrate
できない (ネストの一番内側の effect だけが migrate 可能)。中間
wrapper 関数を経由するパターン (本 fixture の `ask_only_wrapper`)
はこの制約に当たらないため両方 (少なくとも一方) が独立に migrate
できる。

`fixtures/effect_handle_multi_effect_row_fallback.vibe` と
`compiler_gate.sh` gate 40x のコメントを新しい理解に合わせて更新
(期待値 3018 自体は変わらず、「除外の正しさ」ではなく「per-effect
migration の安定性」を pin する gate として説明を書き換えた)。
`edp_row_is_exactly` のコメントも今回の経緯 (3 ラウンド目でようやく
根本原因に到達) を記録した。

### 追記 12 (2026-07-23、同日): 「追記 11」で残した directly-nested handle
制約も同日中に解消 -- `edp_has_unsafe_construct` に nested handle
relaxation を追加

「追記 11」の末尾で「既知の残存スコープ境界」として明記した制約
(`handle ... with A { handle ... with B { ... } ... }` のように直接
ネストしている場合、外側 effect の handle site 自身の body が
`EHandle` ノードそのものになるため `edp_has_unsafe_construct` が
無条件 unsafe 判定し、ネストの一番内側の effect だけが migrate
できる) を、同じセッション内でさらに解消した。

`edp_has_unsafe_construct` に `ename` (現在 migration 判定中の
effect 名) を引数として追加し、`EHandle(body, arms)` を見つけた際に
`edp_handle_matches_effect(arms, ename)` で判定: 同じ effect が
ネストしている場合のみ従来通り無条件 unsafe のまま維持、**別の**
effect の handle であれば body と arms の両方へ再帰する (arms は
handler の本体であり `resume(...)` 呼び出しを含むのが通常だが、
`resume` は今回から明示的に安全な呼び出しとして認識するよう追加した
-- これは既存のどの呼び出し文脈でも無害な追加である、`resume` は
handler arm の中でしか正当な構文として現れないため)。
`edp_rewrite_needing_body`/`edp_rewrite_handle_body` にも同型の
`EHandle` ケースを追加し、eligibility が許可する構造を rewrite 側も
必ず辿れるようにした (「追記 10」で確立した「2 つのトラバーサルは
常に一致していなければならない」という教訓を踏襲)。

検証は今回も抽象推論だけに頼らず、`main` の body を migration plan
情報でエンコードした `EInt` に置き換える計装ビルドで直接確認した:
wrapper 関数を経由しない最小の直接ネスト fixture
(`fixtures/effect_handle_multi_effect_nested_handles.vibe`、期待値
7 == 3 + 4) で `A`・`B` 両方の migration plan が実際に生成・適用
されていることを確認済み。

さらに、`fixtures/effect_handle_multi_effect_row_fallback.vibe`
(`ask_only_wrapper` 経由の wrapper-function パターン) を再テストした
ところ、これも `Ask` に加えて `Fs` まで migrate するようになり、
期待値が **3018 (replay で `count` が余分にインクリメントされていた
劣化値) から 2017 (両方 evidence dict 化された場合の意味的に正しい
値) へ変化した**。この値の変化自体が、今回の拡張が単なる「クラッシュ
しなくなった」以上の、本物の正しさの改善であることを裏付けている。
ファイル名も実態に合わせて `effect_handle_multi_effect_row_nested.vibe`
へ変更し、doc comment と `compiler_gate.sh` gate 40x を全面的に
書き換え、新規 gate 40z (`effect_handle_multi_effect_nested_handles.vibe`
用) を追加した。

これにより、「追記 11」で「今回は対応しない」としていたスコープ境界は
実質的に解消され、ADR-0076 Phase 3 の evidence-dict passing は
multi-effect row と directly-nested handle の両方の組み合わせを
サポートするに至った。残るスコープ (row-variable 多相・
effectset-expanded row・間接呼び出しチェーンの拡張) は
`edp_has_unsafe_construct` の module doc に引き続き明記している。

### 追記 13 (2026-07-23、同日): pure helper 呼び出しと EDot (struct field
読み取り) の 2 つを追加で解禁

同日中にさらに 2 つの eligibility 拡張を実施した。

**Pure helper 呼び出し**: `edp_has_unsafe_construct` の `ECall` ケースは
callee が `perform`/`resume`、手動で列挙した `edp_pure_builtin_names`
のいずれか、または `needing` のメンバーでない限り無条件 unsafe だった
-- ユーザー定義の普通の純粋関数 (`with` 節を持たない、つまりチェッカー
が既に「何も perform しない」と証明済みの関数) を呼ぶだけで migration
全体が disqualify されていた。`edp_pure_fn_names` (fn_defs から row=="" の
関数名を集める) を追加し、そのメンバーへの呼び出しも安全と認識する
ように拡張した -- #942 が保証する row 文字列そのものに基づく判定なので、
呼び出し先の body を再帰チェックする必要すらない (row=="" は「一切
perform できない」ことをチェッカー自身が既に証明済みだから)。

開発中に一時的な migration-plan probe 自体にバグを作り込んでしまい
(本物の機能ではなく、使い捨てデバッグ計装コードの方に)、一見「main()
の戻り値が期待値の 2 倍になる」という不可解な結果に遭遇したが、probe
コードを単純化・以前確立済みの安全なパターン (`main` 単体を上書き) に
差し替えたところ即座に解消した。これもこのセッション終始一貫している
教訓 (計装自体もバグを持ちうる、コード変更前後の A/B 比較で切り分ける)
を再確認する出来事だった。

**EDot (struct field 読み取り)**: `edp_has_unsafe_construct` の
`EDot(_, _, _, _) => true` は元々無条件 unsafe だった (このパスには
型情報が無いため、フィールドアクセスの先が何なのか判別できないという
保守的な理由)。しかし `.field` の**単純な読み取り**は、それを**呼び出す**
場合 (`obj.method(...)`、`ECall` の `EDot` callee は依然として `_ =>
true` で拒否される) とは違い、型情報が無くても健全に安全と判定できる
-- object 式自身が何を隠しているかだけが問題であり、既存の再帰
トラバーサルがそれを型に関係なく正しく答える。`EDot(o, _, _, _) =>
edp_has_unsafe_construct(o, ...)` へ緩和し、
`edp_rewrite_needing_body`/`edp_rewrite_handle_body` にも対応する
`EDot` ケース (object 式のみ再帰、フィールド名はそのまま) を追加した。

検証は今回も migration-plan probe で実施し、`Ask` が実際に migrate
していることを確認した (`fixtures/effect_handle_call_evidence_struct_
field.vibe`、期待値 6)。開発中、`Type { field: value }` sugar 構文が
`let` 初期化子の位置でパーサーのブロック式との曖昧性により失敗する
ことに気づいた (これは今回の変更とは無関係の既存の挙動 -- 同じ
既にコミット済みのビルドでも再現することを確認済み) が、`Type::{
field: value }` (`::` 付き、非糖衣形式) を使うことで回避した。

`fixtures/effect_handle_call_evidence_pure_helper.vibe` (gate 40aa) と
`fixtures/effect_handle_call_evidence_struct_field.vibe` (gate 40ab) を
regression fixture として追加。両方とも `edp_has_unsafe_construct` の
module doc comment (「Not attempted here」段落) を更新して反映した。

### 追記 14 (2026-07-23、同日): closure literal (`EFn`) の定義を解禁 --
ただし呼び出し側の制約は未解決のまま残す

`edp_has_unsafe_construct` の `EFn(_, _, _, _, _, _) => true` は
「needing 関数の body 内のどこであれ closure を定義したら即
migration 全体を disqualify する」という無条件の制約だった。他の
拡張と同じ構造で緩和: closure の body を同じ関数で再帰チェックし、
中身が既知の安全な構文だけなら定義そのものは安全と判定する。
`edp_rewrite_needing_body`/`edp_rewrite_handle_body` にも対応する
`EFn` ケースを追加し (body のみ再帰、params/type params/戻り値型/
宣言 row はそのまま)、closure body 内の `perform ename::Op` は
enclosing scope から**レキシカルにキャプチャした** `dict_pname` を
通して正しく書き換えられる (これは通常の closure capture 意味論
そのものであり、evidence dict 固有の特別扱いは不要)。

**重要な残存スコープの発見**: この緩和は closure の**定義**を
安全にするだけで、ローカル変数経由での closure **呼び出し**
(`f()`、`f` がローカル変数でトップレベル関数名でない場合) は
別の独立した制約のままである。`ECall` ケースの `else => true`
フォールバックは「ローカル変数の callee」と「未知のトップレベル
名の callee」を区別しないため、`f()` は closure の定義が安全に
なった後も依然 unsafe 判定される。ローカル callee を安全に認識
するには本物のスコープ追跡が必要 (このパスは AST レベルのみで
持っていない) で、素朴に名前だけで判定すると `pure_fns`/`needing`
の name-matching と同種の shadowing false-safety リスクを負う。

結果として、この緩和の実用上の効果は見た目より狭い: needing 関数は
自由に closure を「定義」できるようになった (未使用のまま、
opaque データとして受け渡す、など) が、ローカル束縛経由で
「呼び出す」ケースは依然 replay にフォールバックする。

`fixtures/effect_handle_call_evidence_closure_literal.vibe`
(gate 40ac、期待値 6) は、この境界を明示的に固定する: 定義した
closure (`never_called`、body は `perform Ask::Get` を含む) を
意図的に一度も呼び出さない構成にし、「定義が安全になったこと」と
「呼び出しは別問題として未解決のまま残ること」の両方を同じ
fixture で pin している。検証は今回も migration-plan probe で
実施し、`Ask` が実際に migrate することを確認した。

### 追記 15 (2026-07-23、同日): effectset alias で宣言された row が
一度も migrate されていなかった (「追記 6」以来のバグと同型の見落とし)

module doc comment の「Not attempted here」節に残っていた
「effectset-expanded rows」を検証目的で試したところ、単純な
whole-effect alias (`effectset AskAll = { Ask }`、`with { AskAll }`)
ですら **一度も migrate されていなかった** ことが判明した
(temporary migration-plan probe で `plans` が空であることをまず確認、
その後に理由を追跡 -- 「推測ではなく先に空であることを直接確認してから
原因を追う」という、このセッションを通じて確立した手順)。

原因は checker 側の既存の意図的な設計にあった:
`checker_stmt.vibe::check_program` の
`es_expand_stmts_effect_rows` (ADR-0071 step 3) は `stmts` の
**non-mutating コピー** に対して effectset 名の展開を行い、
それを型チェック専用に使う。そのコメントには明示的にこう書かれている:
「codegen never reads the row's text content」-- つまり codegen が
渡される実際の `EFn` の `eff` 文字列は展開されない生の
`"AskAll"` のままで良い、という前提。この前提は
`evidence_dict_pass` が row 文字列を直接読むようになった時点で
既に成り立たなくなっていたが、誰も気づいていなかった。

`edp_needing_names`/`edp_row_is_exactly` の comma-split + trim による
文字列比較は、当然ながら生の `"AskAll"` を `"Ask"` と一致させられず、
effectset で宣言されたどんな row (単純な whole-effect alias でさえ)
も `needing` に一切含まれないまま静かに replay へフォールバックして
いた -- コンパイルエラーにもならず、実行結果も (replay 自体は元々
正しいので) 一見正しく見えるため、誰にも気づかれずに残っていた
類のバグ。

修正は `wit_gen.vibe`/`contract.vibe`/`checker_stmt.vibe` が
それぞれ同じ問題を自分の消費者向けに解決している方法と全く同じ
パターンを踏襲した: 新しい cross-file export を作らず (`docs/
effectset.md` の bootstrap gotcha 参照)、`inline_direct_perform.vibe`
自身に effectset テーブル収集・展開ロジックの小さなローカルコピー
(`edp_es_collect_into`/`edp_es_expand_into`/`edp_effect_name_of`/
`edp_resolve_effect_names_into`) を追加し、`stmts` を
evidence_dict_pass が実際に受け取る形のまま (checker のコピーとは
独立に) 自前で再展開する。`edp_row_is_exactly`/`edp_needing_names`
はこのテーブルを引数に取るよう拡張し、comma-split した各 row item を
effect 名の集合へ解決してから `ename` の有無を判定するようになった。

effect 名の粒度までしか解決しない (operation 単位までは解決しない)
設計は意図的: `edp_make_dict_struct_stmt` が作る dict struct は
そもそも常に effect の全 operation 分のフィールドを持ち、handle site
の arms も常に全 operation 分の closure を用意するため、
operation-level effectset (`effectset Env::Read = { Env::get, ... }`)
であっても「この row が effect X を要求するか」という
evidence_dict_pass にとって唯一必要な問いには、effect 名まで
解決すれば十分に答えられる -- 呼び出し側が宣言した operation
の部分集合が全体のどのサブセットかを追跡する必要はない。

`fixtures/effect_handle_call_evidence_effectset_alias.vibe`
(gate 40ad、期待値 2007) は gate 40u と同じ `count` による
replay-vs-evidence-dict の判別構造を使い、「compile が通って妥当な
値を返す」ではなく「実際に migrate された」ことを直接 pin している
(replay へ fallback していれば `count` が余分にインクリメントされ、
異なる値になっていたはず)。検証は temporary migration-plan probe と
両方の replay-check fixture (functional value のみの版、count 判別版)
の両方で実施した。

### 追記 16 (2026-07-23、同日): 「追記 2」の仮説を独立に再検証 -- Phase 3
本体 (yield bubbling/CPS) は「現在コンパイル可能などの vibe プログラムに
とっても不要」の可能性が高いことを確認、段階導入計画の記述を訂正

「段階導入計画」節 (Phase 3) は当初「yield bubbling (選択的 CPS) を
実装し、非 tail-resumptive 経路も evidence passing へ移行」と書かれて
いるが、これは「追記 2」(2026-07-22) で既に「有望な作業仮説」として
疑問視されていた: `#942` (`check_arm_resume_tail`) が「resume は arm の
tail 位置以外では compile error」を機械的に強制するため、non-tail・
multi-shot な resume はそもそも**現行の vibe ソース言語で構文的に
構築不可能**であり、Xie & Leijen の定義上これは handler が既に
tail-resumptive であることそのものを意味する -- つまり CPS 変換
(yield bubbling) を要するプログラムが最初から存在しない可能性がある、
という仮説。

このセッション (2026-07-23) で本 ADR の実装拡張作業 (追記 9-15、
evidence_dict_pass の適用範囲を multi-effect row・nested handle・
pure helper・EDot・closure literal・effectset alias・qualified
operation・row-variable tail・capture-free local closure invocation へ
順次拡大) を進める過程で、この仮説を独立した調査で再検証した。結果:

1. `#942`/`check_arm_resume_tail` (`checker.vibe:2637-2785`) は
   syntactic な tail-position チェックであり、「resume の呼び出しが
   arm の最終式でない」ケースだけでなく、「同じ arm 内で resume を
   2 回呼ぶ」(2 回目は 1 回目の tail 位置には決してなり得ない ため
   機械的に reject される) や「resume を値として保存・後で呼ぶ」も
   まとめて reject する -- non-tail と multi-shot が別々の抜け道に
   なっている訳ではなく、1 つのチェックで両方とも塞がれている。
2. 旧 `Op(v, k) => v + k(0)` k-convention 構文 (非 tail 継続を明示的に
   束縛する構文) は別途 `#814` (`checker.vibe:4508-4529`) が
   「non-tail continuation binder (k-convention) is not supported by
   the build path」として reject する。この構文を使う既存 fixture
   (`effect_cps_mut_adr021.vibe`,
   `effect_cps_accumulate.vibe`,
   `effect_cps_product.vibe`,
   `effect_cps_collect_array.vibe`,
   `effect_generic_writer.vibe`) は**いずれも現行ビルドパスでは
   コンパイルできない** -- historical/MoonBit-host 専用の遺物。
3. `effect_multishot.vibe` は名前とは裏腹に、実際の multi-shot resume
   を検証する fixture ではなく、「現行実装では multi-shot は不可能」
   という制約を 2 つの独立した `handle` 呼び出しで回避する例を
   ドキュメントしているだけ -- Phase 3 の CPS 実装が着地した**場合の**
   将来の回帰対象として段階導入計画に予約されているプレースホルダで
   あり、現時点で何かを検証しているわけではない。

つまり「追記 2」(a)(b) で既に検証済みだった 2 点 (no-resume arm は暗黙
tail resume として扱われる; nested handle の shadowing は evidence
チェーンでそのまま成立する) に加えて、「そもそも現行チェッカーが
non-tail/multi-shot な resume を一切通さない」という事実を独立に
再確認したことで、「追記 2」の仮説はさらに補強された:
**「Phase 3 本体 (yield bubbling/CPS) は、現在コンパイル可能などの
vibe プログラムにも必要とされない」** -- CPS が必要になるのは、
`#942`/`#814` のチェッカー制約を将来意図的に緩和して
multi-shot/non-tail resume を新機能として解禁する場合に限られる。
唯一の未検証項目 (「追記 2」(c): ADR-0068 の `Cont`/finalizer
まわりとの整合) は ADR-0068 側の TaskContext/finalizer stack 実装が
まだ存在しないため、本 ADR 単独では今回も検証できないまま据え置き。

**実務上の帰結**: 「段階導入計画」の Phase 3 の文言 (「yield bubbling
を実装し...」) は、それ自体が実装対象というより「一度実装が必要か
どうか確認すべき仮説」であったと訂正して読むべきである。この仮説が
(ADR-0068 の 1 点を除き) 成り立つ以上、**replay 機構
(`eff_reserve`・memo アドレッシング・`~16K` perform 上限) を完全に
削除できるかどうかは、CPS の新規実装ではなく、単に
`evidence_dict_pass` の**静的カバレッジを広げ続けること** (このセッション
で一貫して行ってきた作業そのもの: multi-effect row, nested handle,
pure helper 呼び出し, EDot, closure literal, effectset alias, 
qualified operation, row-variable tail, capture-free local closure
invocation, ...) **にかかっている**。すべての `perform` を静的に
evidence 直接呼び出しへ書き換えられる状態に到達すれば、replay
codegen 自体は到達不能な死んだコードになり、削除できる -- これが
「Phase 3 を完了させる」ことの実態であり、当初想定されていた
「CPS ランタイムを新規実装する」大規模タスクとは性質が異なる、
本質的にはこのセッションの延長線上にある漸進的なカバレッジ拡大作業
である。段階導入計画の Phase 3 の記述は、この理解を反映するよう
将来更新すべき (本追記はその根拠を記録するのみで、計画本文自体は
まだ書き換えていない -- 次に本 ADR に着手する際に、この追記を踏まえて
Phase 3 の文言を書き直すこと)。

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
  `OperationId` はこの ADR の正規化形を第一の入力とし、Phase 3 (yield
  bubbling による replay 全廃) はこの ADR の row variable 構造化が
  着地していることを前提とする。
- `docs/concurrency.md` (ADR-0068) — 並行モデルの source of truth。
  本 ADR (#817) をその実装順の 2 番目に置き、evidence/continuation の
  task-affine 制約と `Suspend` IR という呼称を既に規定している。本 ADR
  はその制約下で設計している (「並行モデル (ADR-0068) との整合」節参照)。
- `docs/pl-survey-2026-07.md` — 本 ADR の元になったサーベイ項目。
- `eval/lang-review/findings/2026-07-12-r2.md` M2 — replay の実測バグ。
