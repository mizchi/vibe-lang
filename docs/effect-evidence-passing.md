# ADR-0076: effect handler を evidence passing 化する (suspend 点 IR で WasmFX/WASI 0.3 前方互換)

Status: proposed (実装 Phase 1/2/2b は着地済み。Phase 3 は「CPS 新規実装」ではなく「evidence_dict_pass の静的カバレッジ拡大」に帰着することが判明 (追記 2/16) -- 2026-07-23 のセッションで multi-effect row・nested handle・pure helper 呼び出し・EDot・closure literal・effectset alias (whole-effect/qualified operation 双方)・row-variable tail・capture-free local closure invocation まで対象を拡大、加えて関連する closure+effect codegen バグ #1069 (capturing local closure の invocation) を修正、#1070 (by-value に渡された capturing closure) を新規発見・報告。「段階導入計画」step 6 (wasm-gc backend への evidence-dict 配線) も着地済み (追記17)。「段階導入計画」の実装ノート・追記 9-17 参照)

Date: 2026-07-22

> **綴りの注記 (#1461):** 以下の作業ログは当時の綴りのまま `with Error`
> を引用している (コンパイラが実際に出していたエラー文字列を含む)。
> effect row 上の `Error` は #1461 で退役したので、現在の綴りは
> `with Exception`。記録としての正確さのためログ本文は当時のまま残す。

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
(`lib/@vibe/compiler/normalize/desugar_trait_dict.vibe`)。
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
(effect row は `with Env` — row variable を一切含まない具体的な row) は
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
   スタブを一般化)。**着地済み (2026-07-23, 追記17)** -- ただし
   evidence_dict_pass が到達できる部分集合 (直接呼び出しのみ・tail-
   resumptive) に限る。row-polymorphic helper や replay 経路にしか
   落とせないケースは引き続き Error-only エラーにフォールバックする
   (linear backend の replay 機構自体は gc に移植していない)。
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
   **異なる、時には複数 effect の集合**(`with e` の実体化先が
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
`compile_call.vibe` に一時的な debug throw (`with Error` を既に
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
whole-effect alias (`effectset AskAll = { Ask }`、`with AskAll`)
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

**「追記 2」(c) / ADR-0068 Cont/finalizer 整合の未検証状態について
(2026-07-23、同日、精査)**: 本 ADR 側で繰り返し「唯一の未検証項目」
として据え置いてきたこの項目を、`docs/concurrency.md` 側の記述を直接
確認することで、その未検証の性質をより正確に特定した。同ドキュメント
の Lean lifecycle oracle 節 (`docs/concurrency.md:234-237`) は、
「この oracle は heap、thread、host waitable、channel queue、message
linearization、fairness、無限 trace、**finalizer stack をまだ
モデル化しない**。特に terminal state の一回性は証明済みだが、**具体的な
unwind が各 finalizer をちょうど一度実行することは未証明であり、#817 の
lowering と別の refinement proof / differential test が必要である**」
と明記している。

つまりこの項目は「本 ADR の実装を進めれば自然に解消する」類の未検証
ではない -- ADR-0068 側の Lean 形式モデル
(`formal/VibeFormal/Async/*.lean`) 自体が finalizer stack を
まだ全く扱っておらず、それを追加した上で本 ADR (#817) の実際の
lowering 実装との refinement proof (もしくは differential test) を
別途書く、という **形式検証 (Lean での定理証明) の独立した作業**を
要する。本セッションが一貫して行ってきた作業 (AST 変換パスの
カバレッジ拡大、コード生成バグの発見・修正) とは全く異なる技能・
ツールセットが必要であり、ADR-0076 側のコード変更だけでは原理的に
解消できない -- ADR-0068 の該当フェーズ (Lean モデルの拡張) が
独立して着手・完了されるまで、この一点はどう転んでも「未検証」の
ままである。「追記 2」(c) を再度「未検証」と記録するだけでなく、
なぜ・どのように未検証なのか (どの成果物が今存在しないのか) を
具体的な参照箇所付きで確定させたことが本追記の内容である。

### 追記 17 (2026-07-23、同日): 「段階導入計画」step 6 -- wasm-gc backend
への evidence-dict 配線を実装・着地

`codegen/gc/backend_expr.vibe` の `EHandle` codegen はこれまで
`with Error { Throw(..) => .. }` 以外のハンドラ arm パターンを
ハードエラー (`"GC codegen: only `with Error { Throw(..) => .. }`
handlers are supported"`) にしていた。同様に `codegen/gc/backend_call.vibe`
の `perform` lowering も `Error::Throw` か既知の host-capability
builtin (`Fs::ReadFile` 等) 以外は `"GC codegen: unsupported perform
(no builtin mapping)"` で拒否していた -- ユーザー定義の algebraic
effect は gc backend では一切コンパイルできなかった。

`evidence_dict_pass`/`inline_direct_performs`
(`codegen/common_base/inline_direct_perform.vibe`) は EHandle/perform
を通常の `ERecord`/`EFn`/`EDot`/`ECall` ノードへ書き換えるだけの
purely-AST-to-AST な変換で、linear memory のポインタ/オフセットには
一切依存しない -- backend 非依存であることを確認した (research agent
による調査、`inline_direct_perform.vibe:1817,1863-1875`
`edp_rewrite_perform_via_dict`/`edp_build_dict_literal` 参照)。
これまで linear backend の `codegen/wasi/linked_compile.vibe:177,189`
からしか呼ばれておらず、gc backend の driver
(`codegen/gc/backend_body.vibe`) には配線されていなかった -- gc
backend 側の EHandle/perform が「常にサポート対象外」だった直接の
原因はここにあった (evidence-dict 設計自体の欠陥ではなく、単に
呼び出されていなかっただけ)。

`backend_body.vibe`'s `compile_wasi_module_gc` に
`inline_direct_performs(stmts)` / `evidence_dict_pass(stmts)` を
`rewrite_self_tail_calls(stmts)` の直後 (linear backend と同じ
相対位置) に追加した。evidence-dict 適格な handle/perform はこの時点で
既に木から消えているため、gc codegen 側に新規の effect 固有 lowering
コードは一切不要だった (既存の汎用 `ERecord`/`EFn`/`EDot` codegen が
そのまま処理する)。適格と判定できない handle (row-polymorphic helper,
non-tail-resumptive arm など) は従来どおり Error-only エラーへ
フォールバックする -- linear backend の replay 機構
(`eff_reserve`・memo アドレッシング) 自体は gc へ移植していないため、
この一点は本変更のスコープ外のまま残る。

クリーンなベースラインビルドに対する直接の A/B テストで、変更前は
`fixtures/gc_backend_effect_evidence_dict.vibe` (needing helper が
別の needing 関数を呼び、かつ multi-operation handler を持つ) が
`VIBE_BACKEND=gc` 下で `"GC codegen: unsupported perform (no builtin
mapping): Ask::Get"` に失敗すること、変更後は同じ fixture が
コンパイル・実行でき正しい値 (17) を返すことを確認した。
`compiler_gate.sh` gate 40h2 で固定。既存の gate 40h
(`gc_backend_smoke_test.vibe` の `with Error` ケースを含む) と、
linear backend 側の #1069/#1070/effectset alias 系 fixture 一式は
影響を受けないことを個別に再確認済み。

### 追記 18 (2026-07-23、同日): 到達不能な needing 関数を eligibility から除外

追記17 の gc backend 配線を踏まえてカバレッジ実測 (107 本の
`effect_*`/`handle_*` fixture を `VIBE_BACKEND=gc` 下でコンパイルする
sweep) を行ったところ、`fixtures/effect_local_closure_by_value_wrapper.vibe`
(#1070 の narrow-slice fixture、`fixtures/effect_local_closure_wrapper_referenced_as_value.vibe`
も同様) が gc backend では依然 `"GC codegen: only `with Error { Throw(..)
=> .. }` handlers are supported"` で失敗することが判明した。

原因は `evidence_dict_pass` 自身の eligibility 判定にあった:
`dtpw_inline_trivial_wrappers` (`desugar_trait_dict.vibe`) が
`apply(inner)` を `inner()` へ書き換えた後も、trivial wrapper `apply`
自身のトップレベル定義は残ったままで、その本体 `f()` (未知のクロージャ
引数 `f` への呼び出し) は `edp_has_unsafe_construct` が安全と証明できない
構造として扱う (#1070 の一般ケースが安全化できない理由そのもの)。
`apply` はこの書き換え後にもう一切呼ばれない到達不能コードなのに、
`needing` (このパスが effect 対象と見なす関数の集合) に残り続け、その
「証明できない」本体が effect 全体の migration を丸ごとブロックしていた
-- `apply` 以外の (安全と証明できる) needing 関数まで巻き添えになる。

`evidence_dict_pass` に実際の `entry_name` を渡すよう変更し、
`core/dce.vibe` の `dce_keep_flags` (既に `dce_stmts` が本番コードパスで
使っている、同じ到達可能性エンジン) で計算した reachability を使って
`needing` から到達不能な関数を eligibility スキャン前に除外するように
した (`edp_drop_unreachable_needing`)。到達不能な関数は実行時に
evidence dict を一切必要としないため、これを除外しても観測可能な挙動は
変わらない -- reachability 判定が万一不正確でも (到達可能なものを誤って
「到達不能」と扱ってしまっても)、除外された関数の未書き換えの
`perform` は、このパスが migrate を諦めた場合と全く同じフォールバック
(linear backend の replay codegen、または gc backend の既存の
"unsupported perform" エラー) に落ちるだけで、サイレントな誤コンパイル
にはならない (dce_stmts 自体は呼んでおらず `stmts` から何も削除しない
-- eligibility 判定のみへの入力として使うだけ)。

A/B テストで確認: `effect_local_closure_by_value_wrapper.vibe`
(書き換え後に `apply` が真に到達不能になるケース) は変更後
`VIBE_BACKEND=gc` でコンパイル・実行でき正しい値 (105) を返す。一方
`effect_local_closure_wrapper_referenced_as_value.vibe` (`let stored =
apply; stored(inner2)` で `apply` が真に到達可能であり続けるケース) は
変更後も同じ理由で ineligible のままであることを確認 -- この変更が
「本当に死んでいるコードだけ」を除外し、依然生きているコードは
従来どおり正しく安全側に倒すことを個別に検証した。`compiler_gate.sh`
gate 40h3 で固定。

### 追記 19 (2026-07-23、同日): 「自己 discharge」する needing 関数を除外

追記18 と同じカバレッジ sweep で、`fixtures/effect_effectset_expansion.vibe`
(および `effect_effectset_param_expansion.vibe`,
`effect_row_operation_item.vibe`) が gc backend では依然
`"only `with Error { Throw(..) => .. }`..."` で失敗することが判明した
-- effectset-aware な row 解決自体は既に実装済みだったにもかかわらず。

原因は別種: `main` の row `{Ask, Ask::Get}` は、
`effect_effectset_expansion.vibe` 自身のコメントが説明するとおり、
「`handle ... with Effect` 式を囲む宣言 row は effect 全体を authorize
しなければならない」という別のチェッカー要件を満たすためだけに存在し、
`main` の本体は文字通り `handle {..} with Ask {..}` そのもの -- 自分自身の
中で完結して discharge しており、`ename` を dict として受け取る必要は
一切ない。`edp_needing_names` は row 文字列しか見ないため区別できず、
`main` は常に `needing` に含まれてしまう。`edp_has_unsafe_construct` は
(一般ケースとしては正しく) 同じ effect の nested `EHandle` を unsafe と
判定する ("nested handling of the SAME effect inside itself is not a
shape this pass targets") -- が、ここでの「nested」は実際には
関数の本体そのものであり、`edp_collect_handle_sites` によって既に
独立に発見・migrate 対象になっている handle である。

`edp_drop_self_discharging_needing` を追加し、needing 関数の本体が
「ラップなしの、同じ effect に対する bare `EHandle`」に厳密に一致する
場合のみ (ESeq 前置や ELet でのラップなどは対象外、意図的に狭いスコープ)
`needing` から除外するようにした。A/B テストで確認: 上記 3 fixture は
いずれも変更後 `VIBE_BACKEND=gc` でコンパイル・実行でき正しい値 (42) を
返す。`compiler_gate.sh` gate 40h4 で固定。

### 追記 20 (2026-07-23、同日): 未注釈のホイスト済みクロージャの row 補完

同じカバレッジ sweep で `fixtures/effect_handle_call_evidence_closure_literal.vibe`
(このフィクスチャ自身の履歴が「migrate されるはず」と明記しているにも
関わらず) が `VIBE_BACKEND=gc` で依然失敗することが判明した。

原因: `let never_called = () -> Int { perform Ask::Get }` は明示的な
`with ...` 注釈を持たない -- AST 上 `eff` フィールドは空のまま
(チェッカーは内部で row を推論するが、node には書き戻さない)。
`dlh_hoist_expr` (`desugar_trait_dict.vibe`、#786 の capture-free
lambda-lifting) はこのクロージャをトップレベルへ昇格する際、空の
`eff` をそのまま保存していた。`evidence_dict_pass` はトップレベル関数の
「needing」判定を row 文字列だけで行う (`edp_collect_fn_defs`) ため、
ホイストされた関数は一切 Ask を needs すると認識されず、その中の
`perform` は migrate されないまま残る -- linear backend では
un-rewritten な perform は replay codegen に fallback するだけで正しく
動くため無害だが、fallback を持たない gc backend では
`"unsupported perform"` のハードエラーになる。

2 段階で修正した:
1. `dlh_hoist_expr` が、ホイスト前に closure の本体が実際に perform
   している効果名を `dlh_collect_performed_effect_names`
   (`dlh_has_perform` と全く同じ traversal 形状) で収集し、空の row を
   補完するようにした。
2. これだけでは不十分だった (直接テストで確認): `edp_plan_migrations`
   が「まず到達不能な needing 関数を落としてから eligibility を見る」
   順序のままだと、修正1で正しく "Ask" と分類されるようになった
   `never_called` (この fixture では意図的に一度も呼ばれない) が
   `edp_drop_unreachable_needing` によって即座に除外され、結局同じ
   gc エラーに戻ってしまう。`edp_plan_migrations` を
   「まず (self-discharge のみ除外した) FULL な needing セットで
   eligibility を試し、それが失敗した場合にのみ到達不能関数を落として
   再試行する」順序に再構成した (`edp_try_plan_for_effect` を抽出) --
   独立して安全な (本体が unsafe construct を含まない) 到達不能関数は
   dead code を落とす必要が最初からなく、正しく migrate されるべきだった。

直接テストで確認: `VIBE_BACKEND=gc` / linear 双方でコンパイル・実行でき
正しい値 (6) を返す。既存の #1070 系・追記18・追記19 の fixture 群への
影響がないことも個別に再確認した。`compiler_gate.sh` gate 40h5 で固定。

### 追記 21 (2026-07-23、同日): `__index`/length 系 builtin を pure allowlist に追加

追記17 のカバレッジ実測 (VIBE_BACKEND=gc 下の 107 fixture sweep) を再度
行ったところ (18/107 → 23/107 まで改善)、`fixtures/effect_advanced_test.vibe`
の最初のテスト (`while i < Array::length(items) { perform
Logger::Log(items[i]); i += 1 }`) が依然 migrate されないことが判明した。

原因: `obj[i]` は `__index(obj, i)` へ desugar される
(`desugar_trait_dict.vibe`) が、`__index` も `Array::length` も
`idp_pure_builtin_names`/`edp_pure_builtin_names` の hand-audited
allowlist に載っていなかった。`edp_has_unsafe_construct` は allowlist
外の呼び出しを (perform/resume/needing 関数呼び出しでない限り)
無条件に unsafe とみなすため、`log_all` のループ本体は perform
そのものとは無関係に、`__index`/`Array::length` 呼び出しの存在だけで
ineligible に沈んでいた。linear backend では無害 (replay codegen に
fallback するだけで正しく動く) だが、fallback を持たない gc backend
では `"unsupported perform"` のハードエラーになる。

`__index`, `Array::get`, `Map::get`, `Bytes::get`,
`Array::length`, `Map::size`, `Bytes::length` の 7 個を両 allowlist に
追加した -- いずれも checker で個別に pure (`None` effect、関数型
引数なし) と確認済み (`checker/builtins_misc.vibe`,
`builtins_array.vibe`, `builtins_map.vibe`, `builtins_bytes.vibe`) で、
`__index`/`*::get` 系はコンパイラの他の場所 (`perceus.vibe`,
`common_analysis.vibe`) でも既に同じ「borrow のみの読み取り」同値類として
扱われている。

直接テストで確認: `VIBE_BACKEND=gc` でコンパイル・実行でき正しい値 (3) を
返す。`compiler_gate.sh` gate 40h6 で `fixtures/gc_backend_effect_pure_builtin_index.vibe`
を通じて固定。なお `effect_advanced_test.vibe` 全体は同じファイル内の
別の (無関係な) `suberror NotFound` 由来の `"unknown constructor"` エラーで
依然コンパイルできない -- gc codegen の suberror コンストラクタ登録という、
本 ADR のスコープ外の別問題である。

### 追記 22 (2026-07-23、同日): (本 ADR のスコープ外) gc backend の suberror コンストラクタ未登録を別途修正

追記21 で「スコープ外」と記録した `effect_advanced_test.vibe` の
`"unknown constructor: NotFound"` を、evidence_dict_pass とは無関係の
別問題として個別に調査・修正した (本項目は evidence-dict 設計そのものとは
無関係だが、Error も effect の一種であり、同じカバレッジ調査の一環で
見つかったため記録しておく)。

原因: `codegen/gc/backend_body.vibe` の ctor 登録ループ (`SEnum`/`SStruct`
から `CtorTable` を組み立てる) に `SSuberror` のケースが一度も存在
しなかった -- linear backend 側の同等ループ
(`codegen/wasi/linked_compile.vibe`) は最初から `SSuberror` を enum の
variant と同じ扱いで登録していたが、gc 側だけこのケースが単純に
抜けていた。`throw(KeyInvalid("x"))` は gc codegen が constructor を
解決しようとした瞬間に `"unknown constructor or function"` のハード
エラーになっていた。

`linked_compile.vibe` の `SSuberror` 処理を (type_index/tag のエンコード
まで含めて) そのまま移植する形で欠けていたケースを追加した。直接
テストで確認: suberror を construct・throw・catch する (`Throw(_) =>
...` で payload を見ない、実際の fixture が使うのと同じパターン) と
`VIBE_BACKEND=gc` で linear backend と同じ結果になる。enum/struct/
suberror の constructor が type_index の番号を共有しても正しく共存する
ことも確認済み。`compiler_gate.sh` gate 40h7 で
`fixtures/gc_backend_suberror_ctor.vibe` を通じて固定。

なお、catch した suberror の payload に対する `__to_string` の結果が
backend 間で異なる、より深い別の gap が残っている (実 fixture では
一度も exercise されておらず、この修正のスコープ外、未調査のまま)。

### 追記23 (2026-07-23): `__to_string`/Show gap の調査結果、および行多相 (`{ Log, e }`) の正確なスコープ

上の「未調査のまま」だった `__to_string` gap を実際にコードを読んで調査した。
`codegen/gc/backend_builtins_numeric.vibe` の `gc_gen_to_string_body` は
生の wasm バイト列を直接組み立てるヒューリスティック dispatcher で、
「(linear-memory 由来の) 文字列ポインタらしい tagged i64 か」「そうでな
ければ 10 進整数として描画する」の 2 択しか持たない。struct/enum/
suberror のような GC-native な tagged 値を渡すと、どちらのケースにも
一致せず不正な数字列になる (`KeyInvalid("...")` を渡すと `"2"` のような
値になるのを確認)。これは「小さな抜け漏れ」ではなく、GC backend の
`__to_string`/Show 経路がそもそもユーザー定義型への一般的な dispatch
機構を持たない、という設計上の制約 (`bc_expr_is_floatish`/
`bc_expr_is_boolish` のような compile-time 形状判定や `to_string`
wrapper 特殊化 (#1015) を積み重ねて Int/String/Bool/Float だけ個別対応
している状態)。修正は「バグ修正」ではなく「新しい dispatch 機構の設計」
であり、このセッションのスコープには含めない。

`fixtures/effect_row_open.vibe` (`{ Log | e }` という pipe 記法) がずっと
「未実装の行多相構文」として挙げられてきたが、実際に調べると 2 段階の
異なる話が混ざっていたことが分かった:

1. `{ Log | e }` という pipe 記法そのものはパーサが理解できない
   (`expected ',' or '}' in effect list`)。しかしこのコードベースの
   実際の記法は `docs/cheatsheet.md` の "Effect polymorphism" 節が示す
   とおり pipe ではなく **カンマ区切り** (`{ Ask, e }`) であり、
   `fixtures/effect_handle_call_evidence_row_variable_tail.vibe` は
   まさにこの記法で「効果行変数を含む row」がすでに動くことを pin して
   いる。つまり pipe 記法自体は単なる誤記法で、真の未実装機能ではない。
2. カンマ記法 `{ Log, e }` に書き直して直接検証したところ (probe、
   commit 化はしていない)、`docs/cheatsheet.md` が示す **完全多相**
   (`{ e }` のみ、関数本体がその効果行に一切触れず素通しするだけ) は
   既に動くのに対し、`effect_row_open.vibe` が必要とする **混合行**
   (`{ Log, e }` -- 具体的な効果 `Log` はその場でローカルに `handle`
   しつつ、残りの `e` だけ呼び出し元に開いたまま伝播する) は
   `checker.vibe:555` の `effect_row_dropped` (#939 のドロップ検出
   セーフティネット) が `argument type mismatch ... (the { Db } effect
   would be dropped — no handler could ever run)` として拒否すること
   を直接確認した。原因は `effect_row_dropped` の
   `!effect_label_is_exempt(lbl) && !row_contains_label(eeff, lbl)`
   という判定 (`checker.vibe:565` 付近) が、ACTUAL 側の各ラベルを
   EXPECTED 側の行に「そのラベル自体が文字通り含まれているか」だけで
   照合しており、EXPECTED 側に開いた行変数 (`e` のような単一小文字
   トークン) が存在する場合にそれが「まだ具体化されていない残りの
   効果を吸収できる」ことを一切考慮していない、という一点に絞り込めた。

したがって `{ Log, e }` のような混合行多相を実装するには、少なくとも
(a) `effect_row_dropped` のこの判定を「EXPECTED 側に開いた行変数が
あればアクチュアル側の未一致ラベルは吸収可能とみなす」よう緩和する
だけでなく、(b) その手前の主たる型チェック/unification 経路
(`effect_row_dropped` は `structural` retry の中でのみ呼ばれる
フォールバックのエラー内容説明役であり、そもそもの合否判定はそれより
前で行われている) で `e` を真の unification 変数として `{ Db }` に
インスタンス化できるようにする必要があり、さらに (c) `evidence_dict_pass`
をはじめとする codegen 側の row 解決ロジック (このセッション全体で
拡張してきた `edp_resolve_effect_names_into` 等) が「呼び出しサイトご
とに異なる具体化を持つ多相な行」を正しく扱えることを確認する必要が
ある。(a) 単体のパッチでは checker のエラーメッセージを消せたとしても
(b)(c) が未対応なら別の場所で誤ったコード生成につながりかねないため、
3 つセットで設計・実装すべき一つの型システム機能であり、今回のセッ
ションで着手する範囲には含めない。

### 追記24 (2026-07-23): 追記23 の調査中に見つけた実バグを修正 (`ELet` 非経由の inline `EFn` literal)

追記23 の row-polymorphism 調査中、row 多相とは無関係の、より基礎的な
実バグを発見・修正した (commit `1c4aa64`)。let 束縛を一切経由しない
inline なラムダリテラル (`(() -> Int with Log { perform ...; 42 })()`
のような即時呼び出し (IIFE)、あるいは `with_log(() -> Int with Log
{ perform ...; 42 })` のように「呼び出しサイトの ARGUMENT 位置」に直接
書かれたラムダリテラル) が effect を perform すると、コンパイル時に
不正な wasm (`invalid signature index`) を生成するか、実行時に
`null function or function signature mismatch` で落ちていた。

原因: `desugar_trait_dict.vibe` の `dlh_hoist_expr` にあるフック/
closure-conversion ロジック (#786 の capture-free hoist、#1069 の
capturing closure 変換) は例外なく `ELet(name, EFn(...), body)` という
「let で名前に束縛されたクロージャ」の形にしかパターンマッチしない。
名前を一切経由しない inline literal はこれらのどの規則にも一致せず、
#786 以前からある壊れたローカルクロージャ+effect コンビネータの経路に
素通しされていた。

修正は 2 段階、どちらも「名前のない literal を、既存の (十分に検証
済みの) `ELet`+`EFn` 処理に還元する」という同じ戦略:

1. IIFE (`ECall(callee, args, off)` で `callee` 自身が直接 `EFn` の
   場合): `ELet(fresh, callee, ECall(fresh, args, off), off)` に脱糖
   してから再帰的に `dlh_hoist_expr` に戻す。
2. 呼び出し ARGUMENT 位置に直接書かれた `EFn` literal: 呼び出しの
   直前で fresh な名前に let 束縛してから (`dlh_letbind_literal_args`、
   評価順は元の inline 位置と同じ左から右のまま保存)、同じく
   `dlh_hoist_expr` に戻す。

どちらも新しい closure-conversion コードは一切追加していない --
既存の `ELet`/`EFn` 経路をそのまま再利用するだけ。

スコープ: capture-free な literal のみ (直接検証済み)。capture する
literal を HOF の引数として渡す形は、この修正によって合成された
let 束縛が `dlh_marker_only_called_directly` から見て「値として渡され
ていて直接呼び出しされていない」と正しく判定されるため、#1069 の
closure-conversion が安全側に倒れて変換を諦め、#1070 の既知の未解決
一般ケース (「値として渡された capturing closure」) にそのまま
フォールバックする -- この修正の範囲外であり、意図した挙動。

`fixtures/effect_inline_lambda_literal_hof_arg.vibe` (gate 40al) で
IIFE・HOF 引数の両形状 (capture-free) を固定。seed compiler でのクリー
ンな A/B テスト (修正前は同一クラッシュを再現) と、修正適用後の
stage2==stage3 self-host fixpoint ビルドの両方で検証済み。

### 追記25 (2026-07-24): #1070 一般ケースの精密な repro と原因の特定 —
「自前の handle 内で不透明なクロージャ型パラメータを呼ぶ」形が未カバー

selfhost `vibe lsp` (#1077) のドッグフーディングで、`lsp_run_with_handler`
の元設計 (`body: () -> Json with Lsp` を受け取り
`handle { body() } with Lsp {...}` する関数) が実 wasmtime 下でのみ
`indirect call type mismatch` で trap する事象が見つかった (Node
dev-runner では通ってしまっていた)。#1077 では `lsp_run_with_handler` を
`Int` タグ経由の dispatch に再構成して回避したが、根本原因は未修正の
まま残っていた。#1070 を reopen し (誤って #1075 のマージ時に
close されていた)、以下で最小 repro を切り出して原因を特定した。

```vibe
effect Ask {
  Get -> Int
}

let run_with_handler = (f: () -> Int with Ask) -> Int {
  handle {
    f()
  } with Ask {
    Get => resume(42)
  }
}

export let main = () -> Int {
  let base = 100
  let a = () -> Int with Ask { perform Ask::Get + base }
  let b = () -> Int with Ask { perform Ask::Get + base + 1 }
  run_with_handler(a) + run_with_handler(b)
}
// want: 285
```

**この repro は #1075 で pin 済みの `effect_local_closure_by_value_hof_general.vibe`
(`apply_twice`) 系とは別モノ**: `apply_twice` は自分自身が `with Ask`
という row を持つ「needing 関数」で、`edp_own_closure_params`
(#1075、`inline_direct_perform.vibe`) がその closure 型パラメータへの
呼び出しを、他の needing 関数への呼び出しと同様に dict 転送対象として
扱える。一方 `run_with_handler` は `with Ask` を一切持たない —
自分の中で `handle ... with Ask` を確立し、そこで **完結して discharge
する** 関数であり、`edp_needing_names` の判定基準 (row 文字列に対象
effect を含むか) では最初から「needing」に分類されない。したがって
`edp_own_closure_params` の対象外であり、既存のどの eligibility 経路も
この形を migrate しない。

`dtpw_inline_trivial_wrappers` (#1074、narrow slice) も適用されない:
対象は「本体が丸ごと `f(...)` という同 arity の直接呼び出しだけ」の
関数に限定されるが、`run_with_handler` の本体は `f()` を `handle {...}
with Ask {...}` で包んだものであり、`f()` 単体の直接呼び出しではない。

A/B で確認した重要な事実: **`a` (と `b`) を個別に何度参照させても
(1 回だけ / 2 回) 挙動は変わらず、常に `run_with_handler` の呼び出し
箇所で crash する** — つまり trap の原因は closure 引数自体の
「single-use 証明可能性」ではなく、`run_with_handler` という
「自前 handle + 不透明クロージャパラメータ呼び出し」という**関数の形**
そのものが、evidence-dict パス全体から見て未分類のまま古い (#786 由来の)
combinator フォールバックに落ちることにある。

もう一点: この repro は Node dev-runner (`scripts/wasm_vibe_host_runner.js`)
と実 wasmtime (`runtime/viberun`) の **両方**で同一に `null function or
function signature mismatch` / `indirect call type mismatch` として
crash する (元の `lsp_run_with_handler` 実例は wasmtime でのみ trap し
Node では偶然通っていた — dev-runner 側の call_indirect 実装が
実 wasm 仕様より緩い可能性を示唆するが、未調査)。この repro は
どちらのランナーでも検出できるため、回帰ゲートとして dev-runner だけで
十分カバーできる。

**次のステップ (実装は本セッションでは未着手)**: `evidence_dict_pass`
(または新設のパス) に、「`handle` サイトの本体が、囲む関数自身の
closure 型パラメータへの呼び出し (`f()` 直接、または `f()` を含む式)
である」ケースの eligibility を追加する必要がある。既存の
`edp_own_closure_params` と概念上は同じ (呼び出しグラフ全体で個々の
実引数 closure literal が個別に migrate 可能かを証明し、evidence dict
を forwarding する) だが、トリガー条件を「囲む関数が needing である」
ではなく「囲む関数がこの effect を discharge する handle を確立して
いる」に一般化する必要がある。より広くは、closure 値そのものに
evidence を持たせる真の closure-conversion-to-value ABI
(#786 が示した「本質的な」修正方向) の方が、この種の未分類ケースを
将来にわたって個別に列挙しなくて済む可能性がある — が、そちらは
`emit_lambda_closure_gc`/`emit_closure_resolve`/`emit_closure_call_tail`
(gc backend, `common_analysis.vibe`/`backend_lambda_emit.vibe`/
`backend_call.vibe`) と `linked_compile.vibe` の arity ベース型登録
全体に渡る、より大きな ABI 変更になる。

未 pin (このケースはまだ修正されていないため、`fixtures/` には
「成功する」__DATA__ 付きでは追加していない — 上記コードそのものが
repro)。#1070 のコメントにも同じ repro と分析を記録済み。

### 追記26 (2026-07-24): 追記25 のケースを実装 — `edp_handle_owner_cps`
(self-discharging owner の closure param)

追記25 で提案した「小さい方」の修正方向を実装した。
`edp_handle_owner_cps` (`inline_direct_perform.vibe`) が、needing でない
関数 F について「F の closure 型パラメータ p (row がちょうど ename) が、
F 自身の確立する ename-handle の body の中でのみ直接呼び出されている」
形を検出し、#1075 の `edp_own_closure_params` と同一の全プログラム
call-site 証明 (`edp_closure_param_universally_safe`: 全 call site が
single-use かつ個別 migrate 可能な closure literal を渡す) に加えて、
row を持たないことに起因する 2 つの追加ガードを課す:

1. **owner が値として一切参照されないこと** (`edp_fn_used_as_value`:
   EIdent 出現数 == 直接呼び出し数)。needing owner は自分の row によって
   「エイリアス経由の呼び出しも必ず ename-authorized な文脈に置かれ、
   そこの eligibility スキャンが unknown-name call として弾く」ことが
   型システムから保証されるが、self-discharging owner は row を持たない
   ため純粋コードから `let alias = owner; alias(other)` で呼べてしまい、
   `other` は migrate されないのに handle body は dict を渡す — という
   arity 不一致を静的に排除する唯一の健全な方法が値参照ゼロの要求。

2. **パラメータの全使用が、owner 自身の ename-handle body 内の直接
   呼び出しであること** (`edp_param_uses_confined_to_handle_calls`)。
   needing owner は本体全体が書き換え対象なので任意の位置の呼び出しに
   dict が転送されるが、こちらは handle body しか書き換えないため、
   handle 外の使用 (先行呼び出し・handler arm 内参照・別関数への
   受け渡し) が残ると migrate 済み closure に対して旧 arity の呼び出しが
   残ってしまう。

eligibility (`edp_all_sites_eligible`) の handle-site 検査は、フラットな
handle_sites リストから「トップレベル文ごとに owner 帰属で検査」する
形に再構成した — owner の証明済み param 名はその文の site にだけ
safe-call 集合として加わる (#1074 review の shadowing 教訓どおり、
名前だけのマッチをプログラム全域に広げない)。apply
(`edp_apply_migration`) 側は phase 1 (全文を読み取りのみで解析、
eligibility が見たのと同じ未変更ビュー) → phase 2 (literal migrate) →
handle 書き換え時に per-stmt 拡張 needing、の順で mirror する。

fixture: `fixtures/effect_local_closure_handle_owner_param.vibe`
(want 285)、gate 40ar。seed A/B: 修正前 stage2 では同 fixture が
"null function or function signature mismatch" で crash することを確認。
なお owner がエイリアスされるケース (`let alias = run_with_handler`) は
ガード (1) により ineligible → 従来どおり #786 経路へフォールバック
する — そのフォールバック自体が壊れているのが #1070 の残り
(closure-value ABI、追記25 の「大きい方」) であり、本追記のスコープ外。

### 追記27 (2026-07-25): Phase 3a 設計 — `resume` の第一級化と
depth-0 suspend CPS (ADR-0068 実装順 step 2 の入口、#817/#1081)

**前提実測 (2026-07-25、stage2 = #1094 相当)**: 現行 surface は
「tail-resumptive か no-resume か」を既に完全に静的強制している:

- 非 tail の `resume(...)` 呼び出し → checker が reject
  (`resume(...) must be the last expression of the handler arm` — #942)
- `resume` の値参照 (`let k = resume`) → `unknown name: resume`
  (call 構文としてのみ存在)

したがって suspend (第三のクラス: **arm が resume を呼ばずに保存し、
後で別の dynamic extent から一度だけ呼ぶ** — ADR-0068 の
`Async::suspend` が要求) は、壊れた既存挙動の migration なしに
「新しい許可」として追加できる。replay の M2 系の心配も無い (その形は
そもそもコンパイルされない)。

**Surface (3a)**: handler arm 内で `resume` を第一級値として束縛する。

- checker: arm scope に `resume : (ResumeArg) -> HandleResult` を束縛
  (op の宣言戻り型 → ResumeArg、handle 式の型 → HandleResult)。
  直接呼び出し形 `resume(v)` の #942 tail 制約は**維持**
  (tail-resumptive 高速経路の適格性シグナルを保つ)。値参照した場合のみ
  新 lowering へ。post-processing (`let r = k(1)  r + 1000`) は値経由で
  自然に許可される (driver 上では arm はただのコード)。
- one-shot: 動的 flag で二重呼び出しを trap (静的 affine 検査は後続)。

**Lowering (3a、depth-0)**: codegen-time の AST-to-AST pass
(`evidence_dict_pass` と同じ位置に配線)。trigger は「arm が resume を
値参照する handle site」。3a の適用条件: 対象 effect の perform が
handle body の**直下** (関数呼び出しを跨がない) にのみ現れること。

per-site 合成 (すべて既存 AST ノード + 既存 closure 機構):

```text
enum __Step_N {                        // handle site N ごとに inject
  __Done_N(R);                         // body 正常完了 (R = body の型)
  __Y_N_op(P..., (Q) -> __Step_N)      // op ごとに variant:
}                                      //   payload + 継続 closure

body を perform 境界で nested closure に分割:
  { s1  let x = perform E::Op(a)  rest }
  → () -> { s1  __Y_N_op(a, (x) -> { rest を再帰変換 }) }

driver を合成:
  let rec __drive_N : (__Step_N) -> R' = (st) -> match st {
    __Done_N(v) => v への body-value 側変換,
    __Y_N_op(p.., k) => ARM[ resume := (rv) -> __drive_N(k(rv)) ]
  }
  handle 式全体 → __drive_N((body thunk)())
```

- 継続 closure の capture は既存 closure conversion がそのまま扱う
  (#1085 の RC 修正で「closure を helper へ渡して store」系の地雷は
  除去済み。`Cont` の解放は ADR-0076 本文の「RC drop で解放」保証)。
- arm が resume を保存して呼ばず返れば handle は arm の値で返る。
  保存された `(rv) -> __drive_N(k(rv))` を後で呼べば、残り body が
  次の suspend まで走り、そこで**同じ driver が再帰的に arm を評価**
  する — scheduler が新しい継続を再び受け取る。ADR-0068 の
  `TaskCell` に継続 slot を足すだけで cooperative scheduler の内部を
  差し替えられる。

**3b (bubbling) への拡張線**: CPS 対象 effect を row に持つ関数の戻りを
`__Step` 系へ持ち上げ、call site を `match step { Done → 継続,
Yielded → 再 wrap して上へ }` に書き換える (wasm_of_ocaml の選択的
CPS)。変換対象は静的 row から機械列挙できる。depth-0 で driver /
one-shot / RC 経路を固めてから深さを解禁する。

**検証計画**: scheduler 形 fixture (arm が resume を配列に保存 → handle
は Suspended を返す → 外側が継続を呼ぶ → 残り body が走る → 順序と
one-shot trap を pin)、非 tail 直呼びが引き続き #942 で reject される
ことの pin、tail-resumptive / no-resume の既存 fixture 群の非退行、
gc backend は当面 ineligible (linear 先行)。

### 追記28 (2026-07-25): Phase 3a 実装着地 — 追記27 の設計どおり、初回で

**実装 (2 箇所 + gate)**:

1. **checker** (`checker/checker.vibe` EHandle の declared-effect arm 検査):
   arm body の check_expr にだけ `resume : CtFn([op戻り型], handle結果型,
   None)` を束縛した `henv_arm` を渡す。`check_resume_values` は束縛前の
   `henv` のまま (resume_shadowed 検出と直呼び引数検査を不変に保つ)。
   payload binder が literal に `resume` という名前ならユーザの束縛が勝つ
   (追加束縛しない)。#942 の tail 制約 (`check_arm_resume_tail`) は
   call site だけを見る別 walk なので値参照では発火しない — 直呼び形の
   制約は完全に不変。
2. **codegen** (`codegen/common_base/inline_direct_perform.vibe` 末尾に
   `suspend_cps_pass` を追記 — 新規ファイルにしなかったのは
   evidence_dict_pass と同じ bootstrap flatten 回避)。
   `compile_wasi_module_linked_impl` の `lc_wrap_entry_error_boundary` 直後
   / `inline_direct_performs` 直前に配線 (Phase 2 / evidence pass は
   本 pass が残した site しか見ない)。trigger = arm が `resume` を裸の値と
   して参照する handle site (shadow 追跡は #942 と同じ規則)。
   ineligible な triggered site は error list 経由で `throw` する hard
   compile error (replay に silent fallback しない — 値参照 arm は replay
   では compile できないため)。
3. **eligibility (depth-0)**: (a) 対象 op の perform が body の
   let/seq/tail/branch-tail spine 上に直接現れる (loop / let mut spine /
   ネスト式位置は 3b)、(b) body 内の call は perform か
   `idp_pure_builtin_names` のみ (それ以外は動的 perform を隠しうる)、
   (c) nested handle / target-perform 入り closure なし、(d) Error:: arm
   との混在なし。arm body 側は無制限 (driver 上ではただのコード)。
4. **lowering 詳細**: per-site `__ScpsStepN` enum (`__ScpsDoneN(R)` +
   arm ごと `__ScpsYN_i(P.., k)`) を SEnum で inject、body を継続 closure
   に分割、`let rec __scps_driveN` が dispatch。driver の各 arm は
   `let __scps_onceN = [false]` + `let resume = (rv) -> if once[0] {
   stderr 診断 + assert(false) trap } else { once[0]=true;
   __scps_driveN(k(rv)) }` を束縛して元の arm body を無変更で置く。
   one-shot trap を `Error::Throw` にしなかったのは、#944 entry boundary
   が Error row を宣言した entry しか wrap しない (row なしプログラムでは
   raw WebAssembly.Exception が host に漏れてメッセージが消える) ため。
5. **検証**: scheduler 形 fixture
   (`fixtures/effect_resume_store_scheduler.vibe`, want 10230 — 2 回の
   suspend を外側から順に resume して完走)、値経由 post-processing
   (`effect_resume_value_postprocess.vibe`, want 1017)、one-shot 二重
   resume trap (`effect_resume_one_shot_trap.vibe`)、非 tail 直呼び #942
   非退行 (`err_resume_non_tail.vibe`)、ineligible hard error
   (`err_effect_resume_store_ineligible.vibe`)。gate 50/50。stage2=stage3
   fixpoint 維持 (コンパイラ自身の ~4k with-Error handle は trigger しない
   ことの実証でもある)。

**3b への引き継ぎ**: yield bubbling (perform が関数呼び出しの向こうに
ある場合に callee の戻りを `__Step` 系へ持ち上げる)。3a の
「call があったら hard error」の error message がそのまま 3b の TODO
マーカーになっている。3c は @vibex/concurrent の TaskCell に継続 slot を
足して cooperative scheduler の内部を suspend ベースへ差し替える。

### 追記29 (2026-07-25): Phase 3b 実装 — yield bubbling (call 越え suspend)

3a の「body 内の call は perform と pure builtin のみ」制約を解除した。
suspend-class の handle body から、**concrete な row に対象 effect を含む
top-level 関数を呼べる** (再帰含む)。wasm_of_ocaml の選択的 CPS +
double compilation を per-effect enum で実装:

1. **step 型を per-site から per-effect へ**: `__ScpsStep_<E>`
   (`__ScpsDone_<E>` + effect **宣言**の全 op ぶんの
   `__ScpsY_<E>_<op>`)。site と clone をまたいで共有するには site 独立の
   型が必要 (3a の per-site enum はこの時点で廃止)。backend は untyped
   tagged なので Done の payload 型が呼び出し元ごとに違っても問題ない。
2. **bubble combinator**: effect ごとに
   `let rec __scps_bubble_E = (st, k) -> match st { Done(v) => k(v),
   Y_op(p.., kk) => Y_op(p.., (rv) -> __scps_bubble_E(kk(rv), k)) }` を
   1 個 inject。「callee の step を 1 段上へ再 wrap する」の実体。
3. **CPS clone (double compilation)**: row が E を含む callee `f` ごとに
   `__scps_cps_E_f` を合成 — f の body を同じ spine split に通した版
   (直接 perform → Y 構築、needing call → bubble 合成、worklist で再帰)。
   **オリジナルの f は無変更** — replay / Phase 2 inline / evidence-dict
   の呼び出し元はビット単位で今まで通り。clone の EFn は意図的に
   `eff=None`: evidence_dict_pass は row 文字列から needing 集合を作るの
   で、perform を失った clone が E の evidence 適格性を沈めないため。
4. **call site**: `let x = f(a)  REST` →
   `__scps_bubble_E(__scps_cps_E_f(a), (x) -> split(REST))`。
   tail `f(a)` → `__scps_cps_E_f(a)` (step passthrough — Done がそのまま
   この計算の Done)。
5. **緩和された call policy** (soundness は checker の row 検査に還元):
   body 内で安全な call = perform / pure builtin / enum・suberror ctor /
   **concrete row が E を含まず row 変数も持たない** top-level 関数
   (unhandled な E perform が f から到達可能なら checker が f の row に
   E か row 変数を強制する — だから concrete E-free row は E を perform
   できない)。row 変数 (`with e`) を持つ non-needing callee は
   closure 引数経由で E を注入されうるので hard error のまま (これが
   3b の残 TODO マーカー)。loop / let mut spine 上の suspend も未対応
   (→ #1230 / 追記36 で対応済み)。

**上流正規化との相互作用 (実測)**: trivial な row-var wrapper
(`apply(f) = f()`) + capture-free closure の組は、本 pass の前に
#786 lambda hoisting (closure → row 付き top-level fn) と
desugar_trait_dict の trivial-wrapper inlining (`apply(inner)` →
`inner()`) で「row が E を含む関数への直接呼び出し」へ潰れるため、
row-var reject を踏まずに 3b がそのまま処理する (最初の reject fixture
がこれで compile に成功して発覚)。reject を踏むのは non-trivial
wrapper + capturing closure の組から。

fixtures: `effect_resume_call_bubbling.vibe` (helper 途中 suspend +
再帰 helper の多段 suspend + 2 site で enum 共有、want 3131365)、
`effect_resume_rowvar_wrapper_normalized.vibe` (上記正規化の positive
pin、want -95)、`err_effect_resume_store_ineligible.vibe` (non-trivial
row-var callee reject)、`err_effect_resume_store_loop.vibe` (loop spine
reject — #1230 / 追記36 で break を含むループの reject へ差し替え)。
gate 50 更新。

### 追記30 (2026-07-25): 3c — @vibex/concurrent への接続と
safe-mut builtin list

`@vibex/concurrent` に suspendable task API (adopt/settle/park/wake/
pump — docs/concurrency.md 実装ノート「3c」参照) を実装し、2 task の
mid-body 相互 interleave の conformance lock (`suspend_test.vibe`) が
Phase 3a/3b の lowering 上で green。パターンの要点:

- handle site は adoption site (user code) に置く — lowering は lexical
  なので、library に保存された closure runner からは suspend できない。
  `spawn` 内部の差し替えと channel の mid-body blocking は
  **closure-CPS ABI** (row に suspend 対象 effect を持つ closure 値を
  step-returning 形でコンパイルし、呼び出し規約を分岐する) が前提 —
  これが Phase 3 の次の大物。
- arm の `resume` は `TaskHandle::park(h, resume)` で fn 境界を越えて
  保存される — #1070 の store ケースはこの shape (capturing closure を
  引数渡し→struct field へ保存→後で呼ぶ) では現行 head で正しく動く
  ことを probe で確認済み。
- RC 会計の未踏ケースを 1 つ発見し**修正済み** (#1097): match で
  pattern-bind した payload (継続 closure) を arm 内の closure literal が
  capture すると、env は borrow のまま scrutinee が先に死んで dangle
  していた (2 つ目の site が freed block を再利用した時点で trap;
  capture-free 継続は static closure なので無害だった)。修正は
  compile_match の payload dup 数に「capture する literal 1 個につき
  +1」を加算する `md_capturing_fn_count` (common_analysis)。過剰分は
  bounded leak (owned-captures closure ABI までの暫定)。fixture
  `rc_match_payload_closure_capture_test.vibe` + gate 51、
  suspend_test の interleave はローカル配列 capture に戻して
  library-level の regression lock とした。
- eligibility の実用上の穴として `Array::push` 等の mutation builtin が
  body で呼べなかったため、`scps_is_safe_mut_builtin` を追加した。
  idp_pure_builtin_names と別リストにしたのは意図的: 共有リストへの
  追加は Phase 2 inline / evidence pass の適格性 (= replay 側の副作用
  重複回数) を同時に変えてしまい、replay 値で pin 済みの fixture 群を
  巻き込むため。suspend lowering に必要な性質は「perform できない・
  user closure を呼べない」だけで、mutation の有無は無関係。

### 追記31 (2026-07-25): owned-captures ABI + closure-CPS + replay 撤去の設計

3c までの残ギャップ (追記30「次の大物」) に着手するにあたり、実装前調査
(closure コンパイルモデル・handle dispatch カバレッジ・本 ADR の既決事項の
棚卸し) から確定した設計。3 つの vertical を A → B → C の順で入れる。
依存関係: B は A を前提とする (park で継続 closure が生成 frame を越えて
escape するため、borrow env のままでは health が #1097 の場当たり dup に
恒久依存する)。C は B の後に着手し、カバレッジ実測で範囲を最終決定する。

#### Vertical A: owned-captures closure ABI (RC lane)

現行 (#705): closure env の plain capture は **borrow** (creation で dup
しない)。補償は (i) callee prologue の per-invocation dup
(`md_consume_count` 分, compile_lambda.vibe:105-125) と (ii) #1097 の
match-payload 場当たり dup (`md_capturing_fn_count`) の 2 系統。
ref-cell capture (class 8) だけは例外的に owned (odd-tag + inc,
compile_lambda.vibe:404-421)。

変更 (すべて RC lane のみ。bump lane は header がなく drop も無いので不変。
gc backend も不変):

1. **creation で全 capture を guarded dup** (compile_lambda.vibe:422-427 の
   plain 分岐に追加)。scalar (even) は guarded dup が no-op、string/bytes
   fat pointer は rc runtime の high32 ガードで no-op — dup/drop 両側とも
   no-op なので釣り合う。未解決 capture (0 格納) も even なので無害。
2. **rc_drop の class 7 (closure) を再帰 drop 化**
   (bodies_core_a1a2.vibe:480-548): 現行は class-8 probe に合致した
   slot だけ再帰していたのを、odd slot の無条件 drop に置き換える
   (class-1 field vector の loop と同型になる。#769 の high32 ガードは
   generic drop 入口が持っているので probe 側の特別扱いは不要になる)。
3. **letrec self-capture は weak のまま** (cycle 回避): self slot は
   creation 時 0 で置かれ letrec binder が後から patch する
   (compile_expr_tail.vibe:1110-1125, dup なし = 従来通り)。drop 側は
   `slot & -4 == 自 env の block アドレス` の slot を skip する。
   自己参照以外の一般 cycle は RC の既知の限界としてリーク許容。
4. **#1097 の `md_capturing_fn_count` 補償を撤去** (compile_match.vibe の
   2 dup site から該当項を除去、common_analysis の関数自体は削除)。
   creation dup が同じ +1 を普遍的に供給するため、残すと +2 で恒久リーク
   が倍増する。**1 と 4 は同一コミットで入れること。**
5. **prologue の per-invocation dup (#705) は維持**。owned-captures が
   直すのは escape/lifetime であり、per-call の消費収支 (env は常に
   ちょうど 1 参照を保有、body は呼び出し毎に消費) は別問題。

検証: `rc_match_payload_closure_capture_test` (38013) は無変更で green
のまま (leak が消えるだけ)、新 fixture として「heap capture を持つ closure
が生成 frame の死後に呼ばれる」escape ケース (borrow では use-after-free、
owned で正値) を VIBE_RC=1 で pin。heap KPI は capture dup 分の増と
#1097 leak 撤去分の減が相殺方向 — CI 実測で判断。

#### Vertical B: closure-CPS ABI

**wasm レベルの ABI 変更は不要**というのが調査の主結論: closure 型は
linear backend では全 arity `(i64 × (k+1)) -> i64` の 1 本 (type index
9+k) で、step enum 値も普通の i64 tagged value。「呼び出し規約の分岐」
(追記30) は関数型の row で静的に決まり、checker が row 不一致の代入・
適用を既に弾くため、実行時 dispatch も第 2 slot も要らない。全て
suspend_cps_pass 内の AST 変換で完結する:

1. **CPS-mode effect**: triggered handle site (arm が resume を値参照)
   を 1 つでも持つ effect E。scps の pre-scan で判定済みの情報。
2. **E-needing closure literal の step 化**: body から E の perform が
   (scps の needing 解析で) 到達可能な `EFn` literal は、body を
   `scps_split_tail` で分割した step-returning 形で **1 回だけ**
   コンパイルする (named fn の `__scps_cps_E_f` と違い original を残さ
   ない — closure は値が 1 つで dual entry を持てないため)。
3. **closure 値経由の needing call**: 現行 hard error
   ("cannot see through") のうち、callee の row が **具体的に E を含む**
   と静的に分かるものを bubble 書き換えに緩和する:
   `let x = f(a) REST` → `__scps_bubble_E(f(a), (x) -> REST')`、
   tail は step passthrough。row の出所は (α) 囲む fn の param 宣言型
   `TyFn(_, _, Some(row))` (top-level fn の param 注釈は必須なので常に
   ある)、(β) 同一 spine 上で 2. の step 化対象 literal に let 束縛された
   local。それ以外 (row 変数、注釈なし中間 local) は従来通り hard error。
4. **規約整合の全域ガード**: closure は単一コンパイルなので、同じ E に
   ついて「triggered handle」と「untriggered handle (evidence/idp/replay
   行き)」が併存し、かつ E-needing closure literal が存在するプログラムは
   規約が衝突する。この組み合わせは scps pre-scan で検出して hard error
   にする (v1。effect を分割せよというメッセージ)。closure literal が
   無ければ従来通り併存可 (3b の dual-entry が吸収する)。
5. **@vibex/concurrent への接続**: `TaskGroup::spawn(g, f)` を
   suspendable に差し替え (handle site を spawn 内部へ移動、
   f: `() -> T with Async` param 経由の needing call が 3. の (α))。
   adoption-site handle 制約 (追記30) はこれで解消。channel の mid-body
   blocking は同じ機構で spawn の後に続ける。

fixtures: (i) library fn 内 handle + closure param 経由 suspend の正値
pin、(ii) spawn 2 本の mid-body interleave (suspend_test の spawn 版)、
(iii) 規約衝突 (4.) の compile error pin、(iv) row-var closure が
引き続き error である pin。

**実装ノート (同日、A/B 着地)**:

- Vertical A は設計通り (creation dup + class-7 再帰 drop + letrec
  self-skip + `md_capturing_fn_count` 撤去)。fixture
  `rc_closure_owned_capture_escape.vibe` (gate 52、want 4067) が
  borrow モデルの silent corruption (50067) を pin。gate 51 (38013) は
  無変更で green (補償が creation 側へ移っただけ)。
- Vertical B は suspend_cps_pass の 5 フェーズ化で実装:
  (1) CPS-mode effect 収集 → (2) 全 stmt prepass (literal step-split +
  E-row param 位置の arg 規約 fixup) → (3) 既存 walk + scope threading →
  (4) clone worklist → (5) 規約整合ガード。
- **top-level fn 値 (SLet の EFn) は prepass の split 対象外** — そこは
  3b の needing-fn 世界 (original 無変更 + clone)。当初 top ノードにも
  criterion (iii) を適用して dual entry を破壊し、clone が split 済み
  body から再 clone されて `Done(Y(..))` の二重包みになった
  (`effect_resume_call_bubbling` trap で発覚)。literal split は
  「式位置の literal」に限る。
- **suspend する closure literal には明示 row 注釈が必須**:
  `() -> T with E { ... }`。#761 により無注釈 lambda の effect は
  enclosing の declared row へ継承 (誤検出回避のための既定) されるため、
  literal 自身の row に封じ込めるには注釈で宣言する。注釈なしだと
  enclosing fn の row mismatch として checker が弾く (安全側)。
- capture-free な literal 引数は upstream #786 hoisting で top-level fn
  化されて届く — その場合は prepass の「E-row param 位置の needing fn
  参照 → clone 参照」書き換えが同じ規約を配線する (capturing literal は
  hoist されず in-place split)。
- fixtures: `effect_closure_cps_param.vibe` (2130、resume 値形 2-yield
  trace)、`err_effect_closure_cps_mixed_convention.vibe` (guard reject)、
  gate 53。spawn 版 interleave は `suspend_test.vibe` の
  `spawn_suspend` 2 テスト (library-level lock、battery 経由)。

### 追記32 (2026-07-25): Vertical C 第一スライス — replay loop の
first-party 実行消滅

追記31 の Vertical C を 2 手で実施し、**first-party 非テストコードで
replay back-edge が実行時に走る箇所は 0 になった** (frontier codegen の
削除自体は未実施 — 下記 quarantine)。

1. **Profiler の perform 直呼び化**: `profiler_now_us` (cli/dispatch.vibe
   / entry/compiler/file_compile) の `perform Profiler::NowUs` を builtin
   `Profiler::now_us()` の直呼びへ。調査で判明した旧経路の実態:
   entry.vibe の handler は `NowUs => resume(0)` で、replay は handle
   body (CLI dispatch 全体!) を perform 毎に再実行し、memo に残るのは
   resume 値の 0 だけ — `--profile-tsv` は「全 stage 0µs + 本体 N+1 回
   実行」だった。builtin 自身の row が `Profiler` を持つため全 signature
   が row-neutral に保たれ、entry/dispatch_test の handler は dead arm
   として残存 (throw が二度と届かない)。dispatch_test の fake-tick
   handler が担っていた「非ゼロ elapsed の保証」は実タイムスタンプが
   引き継ぐ。
2. **edp worth 拡張**: `edp_try_plan_for_effect` の worth に「handle
   site が存在する」を追加。needing 空の self-discharging dispatcher
   (lsp_server.vibe の Lsp handler: 全分岐 bare perform + 全 arm tail
   resume、branch 条件は row "" の pure fn) が不可視に replay 行き
   だったのを evidence 移行対象へ。適格性は従来の site 単位判定のまま
   なので、eligible な site に限れば replay と evidence は意味論等価
   (M2 重複は unsafe body でしか顕在化せず、unsafe body は migrate
   しない) — 既存 replay-pin fixture の値は全て不変で gate green。
   Lsp 形の probe は同値のまま -204 bytes (replay 機構消滅) を確認。

**quarantine (frontier codegen が残る非 Error handle、いずれも実行時に
throw が届かない or fixture 専用)** — **追記34 V2 で全解消 (2026-07-26)**:
- entry.vibe / dispatch_test の Profiler handle — dead arm (row 放流の
  ためだけに残存)。**V2 の vacuous-handle elimination が source 無変更の
  まま codegen で消去**。
- cache_underlying.vibe / module_graph_path.vibe の Env handle —
  元から vacuous (body は builtin 直呼びで throw しない)。**同上、VHE で
  消去** (host-row label pun の解 — 追記34 V2 実装ノート参照)。
- `fixtures/effect_local_closure_by_value_hof_escaping.vibe` (206) —
  当時唯一の「本物の replay 実行」残存 (#786 fallback)。**追記34 V1 の
  型主導 total 化で evidence へ移行済み**。shadowed-needing クラスも
  V2 の α-rename + local-literal safety で evidence 化。`is_error`
  単発経路は Error の実装として残る (replay ではない)。

#### Vertical C: replay loop の撤去 (Phase 3d)

dispatch カバレッジ実測の結論: **bootstrap は replay loop に依存して
いない**。compiler 自身の ~4k handle は全て `with Error` で、tail6 の
`is_error` 分岐は `uses_frontier = false` の単発実行 (replay ではない)。
frontier 付き replay loop の第一級消費者は以下だけ:

- `lsp_server.vibe` の Lsp handler (self-discharging、replay-safe に
  書かれている旨のコメント付き) — `vibe lsp` 実行時のみ
- `cli/entry.vibe` の Profiler handler — `--profile-tsv` /
  `--profile-callstack` 指定時のみ throw が発生 (通常は不活性)
- replay 値/経路に pin された fixtures: `effect_local_closure_by_value_hof_escaping`
  (206, #786 fallback), `effect_handle_two_layer`,
  `gc_backend_effect_pure_builtin_index`, gate 4b (#737 深い再帰 resume
  canary、FileIo memo 経路)

撤去手順 (B 着地後に実測で再スコープ) — **追記34 V2 で完了 (2026-07-26)**:
1. ~~Lsp / Profiler の 2 site を evidence 適格へ移行するか、effect を
   使わない直接 dispatch へ書き換える。~~ Lsp は Vertical C で evidence
   移行済み、Profiler は V2 の vacuous-handle elimination が消去。
2. ~~gate 4b の FileIo 再帰 shape と two_layer の nested handle shape を
   edp のカバレッジ拡張で evidence へ吸収し re-baseline する。~~ V1/V2 の
   カバレッジ (containment / nested 他効果 / local-literal safety) で
   evidence 化。
3. ~~tail6 の frontier 経路と perform 側の counter/memo 短絡、
   `eff_reserve` 領域を削除する。~~ 削除済み。`is_error` 単発経路は Error
   の実装として存続。**非 Error handle が migration をすり抜けて live に
   残ることは hard error** (evidence vector 表現は引き続き本 vertical の
   範囲外 — row 変数 `with e` の callee は今も不適格要因)。

### 追記33 (2026-07-25): channel blocking スライスと desugar 内部
primitive の safe-mut 追加

`@vibex/concurrent` の `Sender::send_wait` / `Receiver::recv_wait`
(`with Async`、deposit → suspend → 自己再帰リトライ) を closure-CPS
機構の上に実装した (docs/concurrency.md 実装ノート参照)。compiler 側の
変更は 1 点だけ: `scps_is_safe_mut_builtin` に parser desugar の内部
primitive **`__set_field`** (`o.f = v` の脱糖先) と **`__index`**
(`a[i]`) を追加した。suspend-class clone body が struct field を変異する
(Channel.pend_seq 等) と `__set_field` の ECall として届き、safe list に
無いため "cannot see through" で reject されていた。両者とも
checker-verified effect-free / function-typed 引数なしで、追記30 の
基準そのまま。idp/edp の共有 list に足さない理由も追記30 と同一。

### 追記34 (2026-07-25): closure-value evidence の設計 — 「型主導・全域」
での dict-param 化 (追記25 の解決形)

実装前調査 (evidence dict の受け渡し実態 / closure layout 変更の blast
radius) と実測から確定した設計。**結論: 追記25 が想定した「closure 値
そのものに evidence を持たせる env slot / ABI 変更」は不要**。closure-CPS
(追記31 Vertical B) と同じ「規約は checker の row 型で静的に決まる」原理を
edp に適用すれば、既存の dict-param 機構 (trait dict と同形の先頭 value
引数) のまま #1070 一般ケースが解ける。

**確定した事実**:
- evidence は既に「先頭 param + 呼び出し側 prepend」の構造的 ABI
  (`edp_rewrite_needing_fn` / `edp_prepend_dict_arg` / anonymous ERecord)。
  closure literal への param 前置も `edp_maybe_migrate_efn` (#1075) として
  実装済み。
- #1070 系の 4 制約 (single-use / universal-call-site / no-value-reference /
  handle-confinement) は全て「同じ closure 値が migrated ABI と未 migration
  ABI の両方から呼ばれると arity が割れる」ことの回避 proof。従って
  **migration を proof-directed-partial から type-directed-total に変えれば
  4 制約は原理ごと消える**: row に E を含む関数型の値は、literal も param
  も local も named-fn 参照も一律「`__ev_E` を先頭に取る」規約でコンパイル
  する。同じ row 型 = 同じ arity なので mismatch が構造的に起きない。
- `effect_local_closure_by_value_hof_escaping` 形は実測で本物の replay
  実行 (副作用カウンタ probe: handle body 再実行で hits=4、M2 重複あり)。
  dtpw wrapper inlining は当たっていない (agent の静的追跡は誤り)。
  移行後は hits=2 (M2 解消) — 値 206 は不変。

**変換規則 (edp の拡張、全て AST レベル)**:
1. row に E を含む **annotated closure literal** → 無条件で `__ev_E`
   param 前置 + body 書き換え (既存 edp_maybe_migrate_efn の証明ゲートを
   型主導に置換)。無注釈 literal は #761 により enclosing row へ帰属する
   ので、suspend 側 (追記31) と同じ「明示 row 注釈必須」規約。
2. **row-E typed param/local 経由の呼び出し** `f(a)` → `f(<ev>, a)`。
   `<ev>` は lexical に決まる: 囲む needing fn の `__ev_E` param、または
   handle site の dict literal。
3. **needing fn の値参照** — migrated named fn は既に arity+1 なので、
   値としてそのまま row-E closure 型位置に流せる (規約が一致するため
   wrapper 合成は不要)。
4. **整合ガード (v1)**: row-E closure 値が存在するプログラムでは E の
   migration が全域で成立しなければ hard error (replay への silent
   fallback 禁止 — scps の規約整合ガードと同型)。row-E closure 値が
   存在しないプログラムは従来の proof-directed 動作のまま
   (`evidence_dict_needing_shadowed_by_local` の negative pin は不変)。
5. row 変数 (`with e`) は据え置き (evidence vector 表現は後続、本文
   529-549 の決定通り)。

**やらないこと (調査で棄却)**: env slot 方式 (Option B) は creation 時に
evidence が存在しない (dict は handle site 生成で、closure は site の外で
作られる) ため dynamic write channel が必要になり、static closure
`(slot<<2)|2` の物質化・class-7 drop の slot 迂回など ~30 emit site に
波及する。hidden arg 方式 (Option A) は全 user fn / linked import の
cross-module ABI を破壊し bootstrap seed と衝突する。型主導 dict-param は
どちらのコストも払わない。

**着地順**: V1 = 型主導 total 化 + hof_escaping の evidence 移行
(re-baseline: 値 206 不変、M2 重複解消を新 fixture で pin) + ガード。
V2 = 一次 replay 消費者ゼロ化の確認後、frontier 経路 (uses_frontier /
perform counter・memo / eff_reserve) の削除。

**実装ノート (同日、V1 着地)**:

- 実装は edp 内で完結: `edp_row_lit_scan` (row-E literal / 直接束縛名の
  read-only 収集) + `edp_any_row_typed_param` で closure-value mode を
  判定し、mode ON なら (i) eligibility の call_safe を「literal 束縛名 +
  各 fn 自身の row-E param 名」で型主導に拡張し row-E literal body も
  安全性検査へ参加、(ii) apply 側で `edp_sweep_row_lits_stmts` が全
  row-E literal を無条件 migration (bottom-up、`__ev_` 先頭 param の
  idempotency guard で proof 経路との二重前置を防止)、(iii) needing /
  handle rewrite の safe-call set にも同じ拡張。mode OFF (row-E closure
  値なし) は全経路が従来と bit 同一。
- **ガード**: mode ON で migration が成立しない場合は
  `evidence_dict_pass` が error list を返し (suspend_cps_pass と同じ
  契約に変更、callers throw)、replay への silent fallback を禁止。
- 実測: `effect_local_closure_by_value_hof_escaping` (206) は evidence
  移行後も値不変で green のまま、M2 重複は
  `effect_closure_value_evidence_m2.vibe` (2062、replay なら 2064) が
  pin — gate 54。ineligible guard は
  `err_closure_value_evidence_ineligible.vibe` (同一 effect の nested
  handle) が pin。40 系 (call_evidence 3013 / hof_general 210 /
  handle_owner_param 285 / wrapper 105 / shadowed negative 47) は全て
  値不変。
- これにより**「本物の replay 実行」の残存は
  `evidence_dict_needing_shadowed_by_local` (negative pin、mode OFF) の
  クラスのみ**になった。V2 (frontier 削除) の残作業 = shadowed-needing
  クラスの扱いの決定 (hard error 化 or 命名規則) + 削除本体。

**V2 実装ノート (2026-07-26、frontier 物理削除)**:

replay エンジンを codegen から物理削除した。着地は 4 パーツ:

1. **vacuous-handle elimination (VHE)**。effect E について、program 全体に
   perform が 1 つも無ければ、E の全 handle を body に置換して消去する
   (`edp_program_user_performs` / `edp_erase_effect_handles`、
   evidence_dict_pass の先頭)。row discharge は checker の仕事で codegen
   到達時点では済んでいるので、消去は意味論不変 (E の tag を throw
   しうるものが存在せず、builtin 直呼び `Env::get(..)` は handler に
   届かない — arm は構造的に dead)。これが V2 のブロッカーだった
   host-row label pun の解: cache_underlying.vibe /
   module_graph_path.vibe の module-private Env handle と entry.vibe /
   dispatch_test の dead-arm Profiler handle は **source 無変更のまま**
   VHE が消し、Env の builtin-charged needing 集合が migration に入る
   ことも無い (compiler program に perform Env/Profiler はゼロ)。
   rename 案 (private effect の改名) は「handle の存在自体が host row の
   discharge 機構」なので不成立と判明 (改名すると row が上流へ漏れる)、
   reachability narrowing 案は前回 revert の通り不健全 — 「そもそも
   handler が発火しえない handle を節ごと消す」のが唯一の健全解だった。
   perform が存在する effect は host-label pun でも handle を保持して
   通常の migration に乗る — fs_effect_test の `with Fs` mock は arm が
   op の**引数**を受けて resume 値がそのまま勝つ (replay 時代は real
   builtin が先に走って arm には**結果**が届いていた) 正しい mock
   意味論になった。
2. **shadowed-needing の解消 = seed-scoped α-rename + local-literal call
   safety**。(a) needing 名を shadow する binder を `__edpsh_N_<name>` に
   α-rename (`edp_alpha_rename_shadowed`、RC lane の
   uniquify_shadowed_bindings (#712) の seed 限定版 local copy)。name-only
   match が正確になり、#1074 の program-wide drop
   (edp_drop_shadowed_needing) は「rename が拾えなかった残骸を落とす
   保守ネット」に格下げ。(b) eligibility
   (edp_has_unsafe_construct) を scope-tracked 化: `let`/`let rec` 束縛の
   closure literal 名への呼び出しは safe (literal body は同 traversal が
   定義位置で検査済み、内部の perform は edp_rewrite_needing_body が
   in place で書き換え、dict は通常の closure capture で届く)。param /
   `let mut` / pattern binder による shadow は last-wins で global 集合
   (needing / pure_fns) より優先して UNSAFE — #1074 と同型の「local
   rebind を top-level と誤認する」穴を pure_fns 側でも塞いだ。この (b)
   が無いと「effectful fn 内の pure local helper closure」という普通の
   コードが全部 reject になる (replay という受け皿の消滅で顕在化)。
   `evidence_dict_needing_shadowed_by_local` は negative pin (47, replay)
   から **positive pin (47, evidence)** に反転。
3. **perform 側**: counter/memo 短絡 (compile_call.vibe) を削除。codegen
   に届く perform = migration されなかった perform (live handle なし) =
   実行されたら必ず unhandled なので、旧 memo-miss leg と同じ
   「値 (host-mapped は builtin 呼び, それ以外は payload) + bare throw」
   に縮退。throw の stack polymorphism は dead 経路の validity にも
   効いている — canonical builtin 名を占有する value alias (fs.vibe #795) を
   持つ program では op_is_builtin leg の再帰コンパイルが alias hijack
   で不整合 stack を残すが、throw 下では無害 (V2 初版が host-mapped の
   throw を落として direct wiring を試み、dead な fs wrapper が invalid
   wasm になって発覚 — 「unhandled host perform が値を返す」改善は
   alias hijack の是正とセットで後続)。`resume` は codegen 到達自体を
   internal error 化 (tail6 が非 Error arm をコンパイルしなくなったので
   到達不能)。
   **stmt カバレッジ**: `test`/`bench` block と top-level expr /
   `let mut` は今まで edp の handle 収集・eligibility・apply の対象外で、
   その中の handle は全て silent replay だった。V2 で site-bearing
   statement として一級化 (collect / eligibility / apply / α-rename /
   shadow 検出 / closure-arg candidate 収集を統一) — test 内 mock
   handler が evidence で動く。
4. **handle 側 + 領域**: compile_expr_tail6 は `with Error` 専用に縮退
   (Error 経路は byte 単位で不変)。非 Error handle の到達は dead fn 内
   のみ許され、単一の `unreachable` に落とす。live な非 Error handle が
   migration 後に残っていたら evidence_dict_pass が hard error
   (`edp_first_live_replay_handle`、dce keep flags で dead fn は除外)。
   `eff_reserve` は 0 — module ごとに (n_effects+1) × 128 KiB の
   below-frontier 領域が消えた。#665 の multi-op dispatch / #553 の
   memo 領域 / #737 の深い再帰 resume 経路は機構ごと消滅。

**replay の受け皿消滅が顕在化させた eligibility カバレッジ穴 (battery
実測、いずれも今まで silent replay に落ちていた)**:
- `__to_string` (string interp の desugar 生成物、gate 4b) と `not`
  (quickcheck_effect の `if not(prop())`) が pure builtin list に無く
  needing body を ineligible に沈めていた → 両 list (idp/edp) に追加。
- raw host-import 呼び出し (`vibe_<area>_<op>_raw` 規約 —
  lib/@vibe/http client 側 #794、lib/@vibe/fs の stat_token) が
  「不明 callee」扱いで package の effect 全体を all-or-nothing で
  沈めていた → host import は user effect を perform できず closure も
  受けないので inert。top-level 束縛が無い規約名のみを inert callee
  集合 (pure_fns) に追加 (`edp_append_free_host_inert_names` —
  同名 top-level fn/value がある場合は通常規則のまま)。
- **perform-free row-E fn の inert 化** (`edp_fn_is_perform_free` /
  `edp_append_perform_free_row_fns`): body が E を perform せず全 call が
  inert な row-E fn (fs の stat_token = raw host call 1 本) は dict 不要
  なので needing から除外し、呼び出しも inert 扱い。migration して
  しまうと「handle 外からの naked call」(test の real-host lane) が
  dict を供給できず arity break する — index_import_test の stat_token
  test が実測でこれを踏んだ。plan filter と eligibility/apply の
  pure_fns append が同一 predicate・同一順で計算し verdicts を一致させる。
- **重複 SEffectDef の二重 apply** (invalid wasm): merge lane は同じ
  effect 宣言ファイルを 2 つの import 綴りで二重に取り込みうる
  (index_import_test は package index 経由と `./fs_effect.vibe` 直の
  両方で fs_effect.vibe に到達)。同一 label を 2 回 plan/apply すると
  needing def の dict param が二重前置され (call 側は初回 apply で
  消費済みの handle が 1 個しか付けない)、"not enough arguments on the
  stack" の invalid module になる — pre-V2 は test handle が収集されず
  plan 自体が立たなかったため潜伏。`edp_collect_effect_defs` の name
  dedup + `edp_rewrite_needing_fn` の effect-specific idempotency guard
  (#1116 の edp_params_have_dict) の二重防御で構造的に不可能化。
- **checker-builtin effect label の handle** (SEffectDef なし):
  `effect Http {..}` 宣言なしで builtin Http row を discharge する
  儀式的 handle (http_e2e_test) は migration の作りようがない (dict の
  op 表が無い)。初版は "Http" を test/bench ambient row に足して回避したが、
  非 test の同型 wrapper が残ると hard error になる穴を Codex が指摘
  (#1119 P2) → **VHE の候補集合を「宣言された effect + handle site が
  名指す label」に拡張** (`edp_collect_handle_effect_names`)。builtin
  label でも perform ゼロなら消去されるので、http_e2e_test は元の
  wrapper 付きのまま compile し、それ自体がこの経路の回帰 pin になる
  (ambient 追加は撤回)。`Error` は唯一実 codegen を持つので候補から除外。

**意味論の意図的変更 (どちらも replay-era artifact の削除)**:
- host-mapped op の perform を user handle で「横取り」する形
  (`handle {..} with Env { Get(n) => resume("fake") }` の下で
  `perform Env::Get(x)`) は、旧実装では arm が builtin の **結果** を
  payload として受けて resume 値で上書きできた (引数ではなく結果が届く
  replay 依存の奇妙な形)。V2 では builtin 直呼びになり handler は
  発火しない。in-tree の該当例はゼロ (レガシー dead file とコンパイル
  専用テスト文字列のみ)。
- 非 Error handle で evidence 移行できない形は一律 hard error
  (`err_effect_handle_replay_removed.vibe` が needle
  "replay engine was removed" で pin)。旧 silent replay は消滅。

検証: stage2==stage3 fixpoint、compiler gate 55/55 (新設 55 = vacuous 46 /
reject needle "replay engine was removed"、40ao = shadowed 47 の evidence
化、4b = FileIo 深再帰が evidence 経由で 42)、unit battery 469/469
(fs/http/quickcheck/tutorial の test-block handle 群が evidence で green、
fs mock は正しい意味論で不変、http_e2e は ambient Http + 直接呼び出しに
書き換え)。

### 追記35 (2026-07-31): 外部資料による4パターン検証と wasip3 整合 (ADR-0089)

発表資料「代数的エフェクトの高速化技法と発展的な機能」(関数型まつり 2026)
の代表パターンを本 ADR の実装上で実測検証した。結果と、そこから導いた
wasip3 `future<T>`/`stream<T>` との言語表面整合の決定は
[ADR-0089 (wasip3-effect-alignment.md)](wasip3-effect-alignment.md) 参照。
要点のみ: (a) `Yielded(x, resume)` を ADT payload に入れて handle の外で
drive する資料 p69-75 の Coroutine 形がそのまま通ることを
`fixtures/effect_talk_coroutine_status_test.vibe` で新規に pin、(b) 高階
エフェクト (effectful block を op 引数に取る形) は evidence migration が
closure を追えず needle "replay engine was removed" の診断で reject
(純粋 block なら通る — `effect_talk_tracing_span_test.vibe`)、(c) 格納した
継続を別の `handle` で包んでも元 driver に配送され続ける (handler switch は
silent no-op だった — **#1347 で診断が入り silent ではなくなった**、
ADR-0089 Part A の横断ギャップ 3 参照)、(d) generic effect は TDEffect 未登録の
まま両 handler class ともコンパイル・実行できてしまい検査が全て素通りする
(arity 誤りも通る) ことを実測確認 — ADR-0071 正規化実装までの warning 追加を
ADR-0089 が提案。

### 追記36 (2026-07-31): loop / let mut spine の suspend 対応 (#1230)

追記27〜29 が「未対応」と書いていた **loop / `let mut` spine 上の
suspend** を実装した。`scps_split_tail` に 2 つのアームが増えただけで、
step enum の形も継続の表現 (プレーンな closure) も ABI も変えていない。

- **`let mut x = v` → `let x = [v]` (1 要素セル)**。読みは
  `Array::get(x, 0)`、書きは `Array::set(x, 0, ..)` (`scps_cellify`)。
  分割後の「残りの計算」は closure になるので、素の可変ローカルのままだと
  継続がコピーを掴んでしまい resume 後の書き込みが見えない。セルは
  ヒープ値なので spine 上のすべての継続が同じ 1 個を共有する。driver が
  既に one-shot フラグに `[false]` を使っているのと同じ手口。
- **`while c { body }` → 再帰する step 返し closure** (`scps_split_while`)。
  `let rec lp = () -> { if c { <body; lp() の分割> } else { <その後の分割> } }; lp()`。
  ループの継続が `lp` への末尾呼び出しになるので、closure-CPS 経路
  (`scps_as_cps_local_call`) がそのまま bubbling してくれる。`lp` を
  cps-local に登録するのはそのため。
- `body` に `lp()` を足すのは `ESeq(body, lp())` **ではなく** body の
  TAIL スロットへの押し込み (`scps_seq_append`) である必要がある —
  splitter が sequence の HEAD に suspendable を認識するのは、その head が
  perform / needing call そのものであるときだけだから。分岐は各アームに
  `lp()` が複製されるが、`lp()` は 0 引数の自己呼び出しなので実害はない。

**合成先はトップレベル関数である必要はなかった** (#1230 の途中で一度
そう記録したが、誤り)。「local closure は see-through できない」という
`scps_calls_ok` の規則は *pass が書いていないコード* に対する eligibility
判定であって、pass 自身が型検査後に生成するコードには適用されない。
`rewrite_self_tail_calls` は `suspend_cps_pass` より **前** に走るので、
トップレベル関数に合成しても TCO は掛からず、スタック挙動の点でも差は
ない。perform するイテレーションは step を driver に返して抜けるので、
ネイティブスタックが伸びるのは「連続して perform しないイテレーション」
の分だけ。

**据え置き**: ループ内の `break` / `continue` / `return` は引き続き
hard error (`scps_has_loop_ctl`)。ループ本体が関数になった時点で飛び先が
無く、書き換えにはこのスライスが用意していない escape continuation が
要る。`for` / `loop` 形も未対応。sequence の HEAD が「perform を内側に
抱えた複合式」(`while c { if p { perform .. } else { () }; rest }` の
`if`) であるケースも従来どおり reject — これは今回のループ対応とは独立の
splitter の既存制限。

fixtures: `effect_resume_store_loop.vibe` (positive、want 101020383 —
`183` の桁が `acc`/`i` 両方が全 suspend/resume 往復を生き延びた pin)、
`err_effect_resume_store_loop.vibe` (break を含むループの reject へ差し替え)。
gate 50 更新。検証: stage2==stage3 fixpoint、compiler gate 73/73、
unit battery 473/473。

### 追記37 (2026-07-31): needing 値の escape を eta 展開で通す (#1261)

追記34 V2 の「型主導・全域」は **param の型が row を持つ ⇒ その param 経由の
呼び出しに dict を前置する** (`edp_row_typed_param_names`) を前提にしている。
row-E の関数値が **row を持たない関数型 param** に流れ込むとこの前提が破れ、
定義側だけ dict param を前置された状態で呼び出し側は旧 arity のまま
`call_indirect` する → wasm 自身の `null function or function signature
mismatch`。#1261 の原型:

```vibe
fn apply1(f: (x: Int) -> Int) -> Int { f(1) }
handle { apply1((x) -> { perform Async::Suspend(x) }) } with Async { .. }
```

checker はこれを弾かない。closure リテラル内の `perform` は **リテラルが
置かれた関数の row** に字句的に計上される (リテラル自身の型は row 無し) 一方、
`dlh_hoist_expr` は hoist 前に body から row を **backfill する** (追記20)。
同じリテラルを checker は row 無し、codegen は row 有りと分類する食い違いが
入口。

**修正: escape する値を eta 展開する** (`edp_etawrap_stmts`)。
`apply1(susp)` を `apply1((__edpw_0) -> susp(__edpw_0))` に書き換えてから
通常の body 書き換えに渡すと、ラッパ **内側** の呼び出しに dict が前置され、
外に出るのは「evidence を閉じ込めた row-free arity の closure」になる。
両側の arity が一致し、受け側は何も知らなくていい。手で
`f: (x: Int) -> Int with Async` と書いたときに起きることと同じ結果を、
注釈なしで得る。

捕まえる evidence が **escape 地点でスコープにあるもの** で正しいのは、
checker がリテラルの `perform` を enclosing 関数に計上する以上、それを
discharge する handler は構成上その escape を囲んでいるものだから。

**適用範囲を「実際に書き換えられる領域」に限る** (`in_scope`)。needing 関数の
body の中と、`ename` の `handle` の **body** の中だけ。そこ以外では
ラッパの内側にも dict が前置されず、arity 不一致を場所を変えて再現するだけに
なる。したがって次の2形は引き続き hard error (追記34 V2 の方針どおり):

- row も handle も持たない関数から値を渡す (`fn outer() { apply1(susp) }`) —
  `outer` は dict を受け取らないので、そもそも渡せる evidence が無い
- row を宣言していても **自分では perform しない** 関数から渡す —
  `edp_append_perform_free_row_fns` が needing から外すので同じく dict 無し

ラベル付き param を持つ関数も、ラッパの位置渡しでは届かないので非対象
(escape として reject される)。ラッパの param は `__edpw_N` の固定新名で、
`edp_alpha_rename_shadowed` 後に needing 名を shadow する binder を
持ち込まない。

fixtures: `effect_needing_value_escape_wrapped.vibe` (#1261 原型、want 42)、
`err_effect_needing_value_escape.vibe` (rescue 不能な形へ差し替え)、
`effect_needing_value_annotated.vibe` (注釈済みの等価形、据え置き)。
gate 50 更新。検証: stage2==stage3 fixpoint、compiler gate 73/73、
unit battery 477/477。

**残す論点**: checker 側で「関数型引数の row subsumption を検査する」案
(#939 / #955 の FnType row subsumption を実引数チェックへ繋ぐ) は入れて
いない。今回の eta 展開で silent trap もコンパイルエラーも消えたので入口の
検査は必須ではなくなったが、リテラルの row 分類を checker と codegen で
揃えること自体は別途の設計判断として残る。

### 追記38 (2026-08-03): 分割済み literal の二重 Done 包み (#1371、#1382 で修正済み)

**修正そのものは #1382 (`d0207493`) で landed 済み**。ここに残すのは、その
landed 分に含まれていない (a) ライブラリ非依存の最小 repro と (b) 隣接する
未修正ホールの記録。

body が**ちょうど needing 関数への tail call** である suspend-class closure
literal が壊れていた。`scps_split_tail` の `tail_needing` 分岐は「clone が
既に step を返すのでそのまま通す」ので、分割結果が clone 呼び出しそのものに
なる:

```text
() -> Int with Yield { callee(1) }
  ==> () -> { __scps_cps_Yield_callee(1) }
```

この body は `__ScpsDone_Yield` も `__ScpsY_Yield_*` ctor も
`__scps_bubble_Yield` も含まない。ところが `scps_literal_is_step_for` が見て
いたのは**その3つの名前だけ**だったので未分割と誤判定され、
`scps_prepass_expr` の arg-position fixup が分割済みの literal をもう一度
`Done` 包みしていた。driver は即 `Done` にマッチし、**中の step オブジェクト
(heap pointer) を計算結果として返す** — 継続は一度も走らない。

#1371 はこれを「CPS 分割された callee 内の `throw` が伝播しない」と報告して
いたが、**`throw` は症状であって原因ではない**。継続が走らないのでその中の
throw も起きないだけで、suspend の後が `x + 4` だけの callee も同じ壊れ方を
し、同種の garbage (実測 699 / 730 / 1152、data layout 依存) を返していた。
let 束縛の綴り (`let v = callee(1); v`) は `__scps_bubble_E` 合成に分割される
ため最初から無事で、これが「throw 特有」に見えた原因でもある。

#1382 の修正は `scps_literal_is_step_for` に clone namespace
(`__scps_cps_<eff>_*`) も分割済みの証拠として数えさせるもので、同じ判定を使う
もう一方の呼び出し元 (let 束縛を cps-local として登録する規則) の同じ盲点も
同時に塞いでいる。

**regression lock の分担**: landed 分の
`lib/@vibex/concurrent/suspend_test.vibe` "CPS-split callee results" 4本は
`spawn_suspend` 経由の library-level。`fixtures/scps_tail_needing_literal_test.vibe`
の7本はそれと独立で、hand-written な suspend-class handle だけの最小形
(tail / let / 先行 let / capture あり / needing 連鎖 / perform しない needing /
handle site 版) — concurrent library の変更が壊れても、lowering 側の回帰は
こちらで切り分けられる。

**残る隣接ホール**: `scps_split_tail` の `tail_cps` 分岐 (step 型 closure
binding への tail call) も、同じく生成 namespace の名前を含まない形を返す。
literal の body がちょうど `f()` (f は自身の E-row param) なら原理的に同じ
二重包みになるはずだが、その形は callee の arity と噛み合わないため
**再現できていない**。実例が出たら同じ場所を直す。

### 追記39 (2026-08-03): 名前を持たない closure literal (IIFE) の正規化漏れ (#1385)

edp の eligibility (`edp_has_unsafe_construct`) は **callee が bare
`EIdent` でない call を無条件に opaque とみなす**。`ECall(EDot(..))` を弾く
ための fallback だが、**IIFE** — `(() -> Int with E { .. })()` — も同じ
形なので巻き込まれる。追記34 V2 が replay を撤去した後、これは「その effect
全体が migration 不能」= hard error を意味する。

IIFE 自体は想定済みで、`dlh_hoist_expr` に
`(lit)()` → `ELet(fresh, lit, fresh())` の正規化がある (追記20 の周辺)。
名前が付けば `edp_row_lit_scan` の `binds` に載り、その名前経由の呼び出しに
evidence が前置される。**問題はその発火条件が `dlh_has_perform(body)` =
「body が直接 perform するか」だったこと**。row を宣言しつつ、その row を
**別の row-carrying 関数を呼ぶことで消費する** literal は「effectful でない」
と判定され、無名のまま残っていた。

```vibe
fn bump0() -> Int with Async { let w = perform Async::Suspend(1)  w + 100 }
handle { (() -> Int with Async { bump0() })() } with Async { .. }
```

**この形をユーザは普通 IIFE として書かない**。`dtpw_inline_trivial_wrappers`
(#1070) が作る:

```vibe
fn apply0(f: () -> Int with Async) -> Int with Async { f() }
handle { apply0(() -> Int with Async { bump0() }) } with Async { .. }
```

`apply0` は body が「自分の唯一の param への同アリティ直接呼び出し」ちょうど
なので trivial wrapper と判定され、`apply0(lit)` は `(lit)()` に簡約される。
1引数の綴り `apply1(f) { f(1) }` は同アリティ forward ではないので簡約されず
無事 — **0引数のときだけ壊れる**という非対称はここから来ていた
(#1380 が「planning 側の非対称」として範囲外に残したもの。planning は無関係
だった)。

**修正**: naming の発火条件を「body が直接 perform する **または** 宣言
された effect row が空でない」(`dlh_row_is_effectful`) に広げる。row を持つ
literal は定義上 effectful なので委譲形も拾う。ゲートが元々狭かったのは pure
な `derive(Eq)`/`derive(Ord)` comparator closure を触って壊した実績があるため
だが、あれらは row を持たないので row 基準では巻き込まない。

**ELet の hoist 判定 (`dlh_has_perform`) は広げていない**。名前を付けるのは
意味論を変えないが、top-level へ **移動** するのは変える (suberror ctor の
scope 破壊が記録されている)。広げたのは naming 側だけで、row はあるが直接
perform しない literal は「ローカルの `let` に束縛されるが hoist はされない」
— 手で `let g = ...` と書いたときと同じ形に落ちる。

fixtures: `effect_iife_needing_call.vibe` (素の IIFE、want 142)、
`effect_trivial_wrapper_needing_call.vibe` (#1070 経由で IIFE になる形、
want 142)。どちらも修正前の compiler では上記 hard error になることを確認済み。

### 追記40 (2026-08-08): row-free closure param の実引数フロー証明 (#1536 (a) v1)

suspend CPS split が「closure パラメータの呼び出し」を無条件拒否していた件の
第一スライス。`pred: (x: T) -> Bool` のような **row-free** な関数型 param は
#761 の字句帰属ゆえに「row が空 ⇒ perform しない」を型からは保証できないが、
**CPS clone `__scps_cps_E_f` に到達する呼び出しは `f` の by-name call site
だけ** (値経由の呼び出しは untouched な original を走る) という事実が使える:
全 by-name site が当該 slot に suspend-inert な値を渡すと証明できれば、clone
内の `pred(v)` は plain call として健全に受理できる。

- **suspend-inert の判定** (`scps_inert_taint`): perform を 1 つでも含む
  literal は taint (alias 綴りがあるため effect 単位の照合はせず全 perform を
  対象にする — 意図的な過剰拒否)。needing 名の参照 (call でも値でも)、
  `__scps_`/`__Scps` 名前空間への参照 (phase 2 prepass が step 化した機械が
  引数内にある = suspend する)、不透明 callee、nested handle も taint。
- **委譲** (`async_iter_any` → `async_iter_find` 転送形): site の実引数が
  囲む top-level fn 自身の row-free param なら、その slot を再帰的に証明する
  (`scps_param_slot_inert`、循環は coinductive に inert 扱い)。fn 本体の
  どこかで同名が再束縛されていたら保守的に降りる。
- **phase 順序**: この証明は phase 4 (clone 排出) で走るが、phase 3 が
  suspend 文脈の call site を clone 綴りに書き換え済みなので、site 走査は
  `f` と `__scps_cps_E_f` の**両方の綴り**を対象にする (片方だけだと taint
  した引数を見逃す)。
- **機構**: `sctx` は広げない。証明済み param を clone 内だけ
  `__scps_inert_<site>_<name>` へ shadow-aware に α-rename する
  (`scps_rename_ident`) — 両 eligibility walker は `__scps_` prefix を既に
  受理し、split は needing でも cps-local でもない呼び出しを bubble しない
  ので、rename だけで plain call 意味論が得られる。未証明 param は従来の
  `cannot see through` 拒否のまま。
- **範囲外**: literal param (spawn_suspend closure 自身の param — call site を
  名前で列挙できない)、row 変数 callee (追記34 の据え置きどおり)、builtin
  `Stream::next` の retarget (#1536 残件)。

fixtures: `effect_closure_param_inert.vibe` (want 5)、
`effect_closure_param_inert_transitive.vibe` (委譲形、want 5)、
`err_effect_closure_param_taint.vibe` (1 site が perform する literal を渡す
→ 拒否維持)。これで `async_iter_find` / `_any` / `_all` が suspend body から
呼べる。

### 追記41 (2026-08-09): eager `Stream::next` の synthetic retarget (#1536 (a) v2)

`Stream::next` は eager Array-backed builtin で、従来は `compile_call` が
`Future::ready(Some(s[0]) | None)` へ直接 lower していた。その時点は
`suspend_cps_pass` より後なので、resume を値参照する `handle ... with Async`
の body では opaque builtin call と判定され、`await(Stream::next(s))` が拒否
されていた。

`linked_compile` は suspend CPS の直前に、shadow-aware な total walk で
`Stream::next` を user bindings/references と衝突しない fresh private top-level
fn へ retarget する。synthetic fn は `Future::ready`（user が shadow 可能）を
呼ばず、既存 lowering と同じ ready-cell `[0, if 0 < Array::length(s) {
Some(Array::get(s, 0)) } else { None }]` を直接構築する。通常の call argument
evaluation により `s` は一度だけ評価される。concrete row-free top-level call になったので
CPS eligibility は see through できる。これは eager `Stream::next` だけの
retarget であり、`host_stream_next`、row-variable callee、literal-param flow は
この slice の範囲外のまま。

fixtures: `effect_stream_next_suspend_retarget.vibe` (want 42; `Some(41)` と
argument の一回評価を pin)、`effect_stream_next_retarget_hygiene.vibe`
(`__sn_next` collision、shadowed `Future::ready`、empty layout を pin)。

### 追記42 (2026-08-09): sequence HEAD の let 連鎖を継続 spine へ float する (#1536 (a) v3)

「sequence の HEAD が perform を内側に抱えた複合式」は追記27 以来の不適格形
だったが、**async-iterator `for` の脱糖出力 (`build_await_iter_for`) が
構造的に必ずこの形になる** — `for` は自己完結の
`ELet(__iter_src, .., ELetMut(.., ELetMut(.., EWhile)))` 1 式に落ち、文位置の
`for` ではそれが `ESeq(<for 機械>, rest)` の HEAD に置かれる。手書きの
while+let-mut spine (適格) と脱糖出力の差はこの木の左右バランスだけで、
`async_iter_collect` / `_fold` / `_count` (と suspend body 内のあらゆる非末尾
`for`、brace block 文) が実質これだけで塞がっていた (#1536 の残りの名指し被害)。

`scps_split_tail` の ESeq arm に let-floating を足した:

- `ESeq(ELet(x, v, k), b)` → `ELet(nx, v, ESeq(k[x:=nx], b))`
  (ELetMut も同形、`ESeq(ESeq(a1, a2), b)` は右結合へ再結合)。
  float 後は既存の ELet/ELetMut/while arm がそのまま split する。
- **binder は無条件に fresh 名へ α-rename する** (`scps_rename_ident`、
  shadow-aware で代入先も追う)。scope を `b` の上へ広げるので、`b` 内の
  自由な `x` (外側 binding への参照) を捕獲しないことが正しさの条件 —
  rename で構造的に排除する。fresh 名は `__scps_seq<site>_<x>` を基底に、
  **その綴りが `k`・`b` のどこにも出現しなくなるまで数値 suffix を bump
  して mint する** (`scps_seq_float_fresh` — Codex P1 on #1607: user code が
  生成綴りを文字どおり書いていると、tail の外側参照の捕獲か、`k` 内の同綴り
  binder による rename 済み出現の捕獲が起き、どちらも黙って誤る。probe は
  scope-blind な出現検査 `scps_mentions_name` = binder + 参照 + 代入先)。
  同名 float どうしの `nx` 衝突は「内側 literal binder が外側を shadow する」
  surface scoping がそのまま成り立つので無害。
- 判定と変換が同じ関数なので、`vibe check` の #1574 ミラー
  (`effect_lowering_prelude` 経由) と codegen は自動で lockstep。
- suspend しない HEAD は従来どおり素通し (while arm と同じ理由 — 不要な
  再構成をしない)。

**残る不適格 (このスライスの範囲外)**: EIf/EMatch/EForIn(array)/ELoop が
suspend を抱えて HEAD に立つ形、代入 RHS 直書きの perform
(`acc = perform ..` — cellify 後に call-arg 位置へ落ちる)、row 変数 callee、
literal param。

fixtures: `effect_for_await_suspend.vibe` (want 20; 逐次 2 loop で同名
`__iter_*` の反復 float を pin)、`effect_seq_head_block_suspend.vibe`
(want 1105; inner binder が outer 名を shadow し tail が outer を参照する形 —
rename を外すと捕獲で黙って誤る、その P0 側を pin)、
`effect_seq_head_reserved_name_collision.vibe` (want 3011; user code が
生成綴り `__scps_seq0_x` を文字どおり束縛/参照する形 — probe を外した対照
実験では 1015 に化ける)。実害側は
`async_iter_test.vibe` の suspend-class handle 内 terminals テスト。

### 追記43 (2026-08-10): sequence HEAD の EIf / EMatch へ継続を分配する (#1536 (a) v4)

`scps_split_tail` は sequence HEAD が suspending `EIf` なら
`EIf(c, ESeq(t, b), ESeq(el, b))` へ、suspending `EMatch` なら各 arm body に
`ESeq(body, b)` を置く形へ分配する。condition / scrutinee は transform の外に
残るので一回だけ評価され、選ばれなかった branch / arm の tail は実行されない。

match の pattern binder は tail の元の外側参照を捕獲し得るため、arm ごとに
`__scps_match<site>_<arm>_<name>` を基底とする fresh name へ alpha-rename してから
分配する。freshness は pattern・arm body・shared tail の全出現を probe する。
`effect_seq_head_if_suspend.vibe` (want 41100) は condition 一回評価と branch-local
shadow を、`effect_seq_head_match_suspend.vibe` (want 3200) は scrutinee 一回評価と
pattern capture を pin する。

### 追記44 (2026-08-12): direct selection input を継続 spine に名前付けする (#1536 (a) v5)

`if` condition / `match` scrutinee が **direct target perform、concrete needing call、
または既に step-typed な CPS-local call そのもの**なら、scope-blind collision probe で
fresh な binder を作り `ELet(tmp, input, EIf/EMatch(tmp, ...))` へ正規化する。これで
入力は一回だけ評価され、既存の let/bubble spine が selection 後の branch/arm と tail
を処理する。tail-position と sequence-HEAD の両方で同じ変換を使う。

`perform Op() > 0` や `Some(perform Op())` のように suspend を内包する compound input
は direct shape ではなく、評価順序の一般 CPS 化を暗黙に始めないため拒否を維持する。
positive fixtures は if/match の一回評価・tail 一回実行・名前/pattern capture 回避を、
negative fixtures は compound input の fail-closed 診断を固定する。

### 追記45 (2026-08-12): direct assignment RHS を継続 spine に名前付けする (#1536 (a) v6)

継続 spine 上の通常代入 `x = rhs` で `rhs` が追記44と同じ **direct target
perform、concrete needing call、または CPS-local call そのもの**なら、代入式全体を
scope-blind probe して fresh binder を作り、`let fresh = rhs; x = fresh; rest` として
既存 split に渡す。probe は identifier だけでなく assignment target も見るため、
生成名と同じ綴りをユーザーが代入先に使っても capture しない。operation・代入・
continuation は各一回だけ実行する。compound RHS と `+=` 等の EAssignOp は引き続き
fail-closed であり、この追記は loop / nested handle / row-variable callee を広げない。

### 追記46 (2026-08-12): direct while condition を再帰 loop spine に名前付けする (#1536 (a) v7)

`while condition { body }` の condition が追記44と同じ direct recognized suspension
そのものなら、既存の `let rec lp = () -> ...` loop closure の内側で fresh binder に
一回だけ束縛し、resumed Bool を `if` で選択する。したがって operation は各 condition
check ごとに一回、body は true ごとに一回、loop 後の continuation は最初の false
後に一回だけ実行される。fresh probe は condition/body/continuation 全体を見る。
compound condition、loop control、for-in/loop、nested-argument suspension は引き続き
fail-closed。

**残る不適格**: EForIn(array)/ELoop HEAD、compound while/selection input、compound
assignment RHS、loop control、row 変数 callee、literal param flow。

### 追記47 (2026-08-13): loop control (`break` / `continue`) を CPS spine に載せる (#1536)

`while c { body }` の body が `break` / `continue` を持つとき、脱出継続を独立した
closure に切り出す。`let k = (bv) -> <rest の split>` と
`let rec lp = () -> <body' の split>` を作り、body' では `break` を `k(unit)`、
`continue` を `lp()` へ書き換え、残った tail には `lp()` を append する
(末尾まで落ちたら再入、という surface の意味論と一致する)。書き換えの前に
`scps_loop_normalize_ctl` が「seq head の if/match が transfer を持つ形」を各枝へ
分配し、transfer の後ろの dead statement を落とす — これが無いと `break` の後に
body の残りが走る。両 closure は step-typed cps-local として登録されるので、既存の
closure-CPS bubbling がそのまま結果を運ぶ。`return` を含む body は fail-closed
(closure から関数の return は表現できない)。surface の `loop (p = e, ..) { .. }` は
parser (`desugar_loop_body`) がこの形へ脱糖するので、ELoop のケースは持たない。

### 追記48 (2026-08-13): compound input を評価順のまま線形化する (#1536 (a) v8)

追記44/45/46 は「spine の slot が **direct recognized suspension そのもの**」の形
だけを受けていた。同じ操作を別の綴りで書いた瞬間 — 被演算子
(`acc + perform Op(i)`)、呼び出し引数 (`Array::push(out, perform Op(i))`)、
コンストラクタ引数 (`Some(perform Op(i))`)、compound な `while` 条件
(`perform Next() > 0`)、`+=` — reject されるので、**受理される綴りが「何をしたか」
ではなく「どこに置いたか」で決まっていた**。

`scps_anf_compound` が最初の suspension で止まる A-normalization を行う:

```
f(g(x), perform Op(i)) + 1
  ==>  let h0 = g(x); let h1 = perform Op(i); f(h0, h1) + 1
```

**元が suspension より前に評価するものは、評価順のまま先に名前を付ける**ので並べ替えは
起きない (リテラルと identifier だけは名前を付けない — 値が変わりようがないため。
`let mut` の読みは `scps_cellify` が既に `Array::get(cell, 0)` にしているので
identifier ではなく、ちゃんと名前が付いて元の位置で読まれる)。suspension より後ろは
そのまま残るので resume 後に走る。2 個目以降の suspension は residual に残り、次の
pass で拾われる。callee は名前を付けない — by-name call を local binding 経由の呼び出しに
変えてしまうと、それこそ suspend lowering が see-through できない唯一の形になる。

**必ず評価されるとは限らない位置だけがこの ANF では fail-closed のまま**:
`if` / `match` の枝、`&&` / `||` の右辺。後続スライスでは、式全体が tail の
`l && r` / `l || r` だけをそれぞれ `if l { r } else { false }` /
`if l { true } else { r }` に変換し、既存の branch splitter へ渡す。これにより
selected RHS は suspend できるが、assignment/call/selection/sequence-head 等に
ネストした non-tail short-circuit は引き続き fail-closed であり、generic ANF は
conditional RHS を走査しない。closure literal は
`scps_prepass_expr` が literal 自身の spine で step-split し、既存の
nested different-effect handle は handler ownership を保った lowering を使うため、
この compound ANF が外へ float する対象ではないが blanket reject でもない。

同時に `scps_cellify` の **P0 silent-wrong** を 1 件直した。`EAssignOp` の
フィールドは `(name, op, value, cont)` だが、この pass の 3 箇所が `(op, name, ..)` と
読んでいた。cellify では「これは box した local か?」の比較が `"+"` と変数名の比較に
なるため**一度も成立せず**、`value += ..` は raw local に書き続ける一方で周囲の読みは
cell 読みになっており、**書き込みが suspension を跨いで黙って消えていた**
(`effect_assignment_op_rhs_suspend` が pin)。残り 2 箇所は `scps_rename_ident`
(float した binder の rename が代入先を飛ばす) と `scps_refs_name`
(代入先としてしか使われない名前が「言及されていない」と判定され、生成 binder の
衝突 probe が漏れる)。同じフィールド順の取り違えは suspend lowering の外にも残っている
— 一覧は #1657。

**残る不適格**: EForIn(array) HEAD (反復対象が Array であることの静的証明が要る —
codegen は String を実行時判別する #807)、loop body 内の `return`、row 変数 callee、
literal param flow、`if` / `match` branch および non-tail `&&` / `||` RHS の
条件付き suspension。

### 追記49 (2026-08-13): selection が束縛値そのものなら束縛ごと枝へ分配する (#1536)

追記43 は `if` / `match` が **sequence HEAD** (= 文位置) に立つときだけ継続を枝へ
分配していた。値として使われる同じ selection —

```
let v = if ready { perform Op(1) } else { 0 }
v + 1
```

— は追記48 の generic ANF に落ちて reject される。ANF は「必ず評価される位置」しか
歩かないので、枝の中の suspension に名前を付けることはできない (選ばれない枝の
operation を走らせてしまう)。つまりここでも**受理される綴りが「何をしたか」ではなく
「どこに置いたか」で決まっていた** — 文位置の `if` は通り、同じ `if` を `let` に
束縛した瞬間に通らない。

名前を付けられないだけで、**束縛を selection の外に置いておく理由は無い**:

```
let x = if c { t } else { e }  REST
  ==>  if c { let x = t  REST } else { let x = e  REST }
```

condition / scrutinee は元の位置に残るので**ちょうど一回・枝より先に**評価され、
各枝は自分の値を `x` に束縛して継続を一回だけ走らせる。追記43 が sequence HEAD で
やっている継続分配と同じ機構で、違いは枝の値が捨てられるか binder に食われるかだけ。
`let mut` 初期化子も同じ (分配後は枝ごとに継続を box する — cell はそのためにある)。

`match` の腕は追記43 と同様、継続を腕の下へ移す前に**パターン binder を alpha-rename**
する: 継続は元々 match の外にあったので、そこで自由な名前が腕の束縛に捕まっては
ならない (`fixtures/effect_let_selection_match_capture_test.vibe` が pin。捕獲すると
17 ではなく 16 を返す)。追記43 と共有の `scps_float_match_arm_rename` に切り出した。

**`break` / `continue` / `return` を含む selection は fail-closed のまま** — transfer は
このパスが組む loop 形に対して書き換えられるので、その下へ継続を複製するのは
このスライスの範囲外。selection が compound の中にネストしている形
(`1 + (if c { perform .. } else { 0 })`) もこの時点では reject
(後述の追記52 が、そこでは selection を丸ごと名前に束ねてこの分配へ渡すことで解消した)。

**残る不適格**: 追記48 の一覧から「`let` / `let mut` の値そのものである selection」を
引いたもの。

### 追記50 (2026-08-13): block が束縛値そのものなら束縛を内側へ移す (#1536)

追記49 と同じ「どこに置いたか」問題がもう一段ある。分配した枝の中に**文がある**と、
枝の値は `{ log(); perform Op() }` という block になり、`ELet(x, ESeq(a, v), b)` の形で
また generic ANF に落ちて reject される。文位置の同じ block は追記42 の
sequence-HEAD float が既に受けているので、値位置だけが取り残されていた。

block の文前置は値より先に走るので、**束縛はそれを追い越して内側へ入れる**だけでよい:

```
let x = { a; v }         REST  ==>  a;           let x = v  REST
let x = { let y = e; v } REST  ==>  let y' = e;  let x = v[y:=y']  REST
```

float した `let` binder は継続の上へスコープが広がるので、追記42 と同じ
`scps_seq_float_fresh` の probe で alpha-rename する (`REST` は元々 block の外に
あったので、そこで自由な名前は外側の束縛を指す)。`fixtures/effect_let_block_value_suspend_test.vibe`
が pin — 捕獲すると 762 ではなく 812 を返す。

どちらの書き換えも値を**厳密に小さく**するので、結果を再 split すれば収束する。
追記49 の分配と合わせて、「文を含む枝」が初めて通る。

block の文前置は `ESeq` とは限らない — 中の代入文は**残りの block を自分の継続として
持つ** (`EAssign(y, v1, <残り>)`) ので、`ESeq` / `EAssign` / `EAssignOp` の 3 綴りを
同じ「何も束縛しない前置」として扱う。

### 追記51 (2026-08-13): 代入の RHS にも同じ 2 つの書き換えを与える (#1536)

追記49/50 は束縛 (`let` / `let mut`) だけだった。同じ形を代入で書くと
(`acc = if c { perform .. } else { 0 }`, `acc = { log(); perform .. }`) まだ reject される。
値が新しい binder に入るか既存の target に入るかは、suspension の位置とは無関係な違い。

書き換えは同じ (binder を作らない分だけ簡単):

```
x = if c { t } else { e }  REST  ==>  if c { x = t  REST } else { x = e  REST }
x = { a; v }               REST  ==>  a;  x = v  REST
```

**適用箇所が 2 つある**のがこのスライスの本質:

- **cellify より前** (`scps_float_direct_assign`) — この spine が box した target 向け。
  `x = v` が `Array::set(x, 0, v)` になった後では `v` は builtin の引数であり、そこから
  float すると**他の引数の評価を複製する**ことになる。だから box 化の前に形を直す
- **継続 spine 上** (`scps_split_tail` の `EAssign` arm) — spine の外で束縛された target 向け。
  こちらは代入のまま split に届く

両者が食い違うと綴りによって受理が変わるので、fixture を 2 本置いて同じ書き換えを pin した
(`effect_assign_selection_suspend_test.vibe` / `effect_assign_outer_selection_suspend_test.vibe`)。
`match` の腕の alpha-rename と `break` / `continue` / `return` の fail-closed は追記49 と同じ。

### 追記52 (2026-08-13): compound の中の selection は「丸ごと名前を付ける」(#1536)

追記48 の ANF が `if` / `match` の枝へ降りないのは正しい — 選ばれない枝の operation を
走らせてしまう。だがそこから導かれるのは「枝の中の suspension に名前を付けられない」までで、
**selection 自体に名前を付けられない**ではなかった。ANF が到達する位置は定義上すべて
**必ず評価される**ので、selection は元の位置のまま 1 つの部分式として名前を付けられる:

```
value = 1 + (if c { perform Op(1) } else { 0 })
  ==>  let h = if c { perform Op(1) } else { 0 };  value = 1 + h
```

そして `let h = <selection>` は追記49 が分配する形そのもの。つまり**新しい機構は要らず、
ANF が「降りる」か「拒否する」の二択だったところに「丸ごと名前を付ける」を足すだけ**で、
conditional 位置から何かを float することなく受理できる。

これで #1536 が挙げていた「compound にネストした `if` / `match` の枝」は無くなる
(旧 `err_effect_compound_branch_suspend` / `err_effect_compound_match_branch_suspend` は
`effect_compound_selection_suspend_test.vibe` に置き換えた — `order` の桁が suspension を
またぐ移動が無いことを pin する)。

transfer (`break` / `continue` / `return`) を含む selection はここでは blocked にしてある —
分配側が拒否するため、名前を付けると ANF がまた名前を付けて**収束しない**ループになる。
(現在の型検査では `1 + (if c { break } else { .. })` は書けないので surface からは
到達しないが、コンパイラが hang しないための fail-closed。)

### 追記53 (2026-08-13): non-tail の `&&` / `||` も丸ごと名前を付ける (#1536)

追記52 の理屈は `&&` / `||` にもそのまま当てはまる — 右辺へ降りないのは正しいが、
**短絡式自体**は必ず評価される位置にあるので名前を付けられる。違うのは受け側で、
`let h = l && r` は追記49 の分配ではなく #1667 の let-shortcircuit 経路に落ち、
**そちらは None を返しうる**。None が返ると値がそのまま ANF に戻ってまた名前が付き、
収束しない。

そこで **判定手続き自身に訊く**: `scps_let_shortcircuit_bind` を probe として呼び、
`Some` のときだけ丸ごと名前を付ける。この関数の Some/None は RHS と sctx だけで決まり、
束縛名や継続には依存しないので、ダミーの名前と `EUnit` を渡した probe の答えが本番と
一致する。判定を写した述語を別に書くと lockstep が崩れるが、本物を呼べば崩れようがない。

同時に let-shortcircuit の**終端が compound でもよい**ようにした。生成される束縛は
**選ばれた枝の中**に置かれるので、そこでは何もかもが必ず評価される — spine の線形化が
要求する前提そのもの。これで次の 3 形が通る (どれも旧 reject fixture):

```
value = if value == 0 && perform Ask::Get(1) > 0 { 5 } else { 6 }  // non-tail、compound 終端
let a = true && (true && perform Ask::Get(1) > 0)                  // 入れ子の短絡
let b = true && twice(perform Ask::Get(2)) > 3                     // 呼び出し引数
```

bypass は保たれる (`effect_compound_shortcircuit_suspend_test.vibe` の `b` と
`effect_shortcircuit_compound_rhs_test.vibe` の `c` が pin)。

**残る不適格**: 選ばれた RHS が `return` / `break` / `continue` する形
(`err_effect_let_shortcircuit_return_suspend` — transfer を合成 resume 継続へ移すと、
元のスコープではなくその closure を指してしまう)、および RHS の spine 要素が
direct でない suspension を持つ形。条件付き位置そのものはこれで塞がった。

### 追記54 (2026-08-13): split される body の `return` を fail-closed にする (#1536)

上の条件付き位置を潰す作業中に実測で見つけた**先行するバグ**。suspend lowering は body を
「step を返す部品」へ書き換えるので、その body に書かれた `return` は**もう関数を抜けない** —
自分の値を step のつもりで driver に手渡す。結果、**型検査を通り、clean にコンパイルされ、
`return` を通った実行だけが runtime で trap する** (`unreachable`)。

```
fn helper() -> Int with Ask {
  let a = perform Ask::Get(1)
  if a > 0 { return a * 100 } else { () }   // ← compile 成功 / 実行で trap
  a
}
```

チェックされていたのは**ループ body の `return` だけ** (`scps_body_has_return` は
loop→再帰変換の適格性判定にしか使われていなかった)。ループの外も、そして
**suspension より前の guard-clause 形も**同じ理由で壊れている — `return` が抜ける先の
部品は「変換後の関数」であって元の関数ではない。

split する 3 箇所 (handle body / needing fn clone / closure literal) すべてで、split の前に
`scps_body_has_return` で refuse する。診断は**効く編集を述べる**: 「早期脱出の値を返すのでは
なく作れ (束縛して後で選べ)、または `return` を handle の外へ出せ」。

**nested closure の `return` はそのまま受理される** — それはその closure を指すので正しく、
`scps_body_has_return` は `EFn` で走査を止める (`effect_resume_store_loop_nested_return` が
positive 側、`err_effect_return_in_split_body` /
`err_effect_return_guard_in_split_body` が negative 側)。

本来の解 (escape 継続を lowering に持たせて `return` を通す) は残件のまま。今回のスライスは
「黙って壊れる」を「その場で断る」に変えただけで、書けるコードは増えていない。

### 追記55 (2026-08-13): `return` を tail へ寄せる — escape 継続は要らなかった (#1536)

追記54 の時点では「escape 継続を step machine に通す」のが本来の解だと考えていた。実際には
**needing fn の clone と closure literal に限れば、その機構は要らない**。そこでの
`return v` は「**この computation の値が v**」という意味であり、それは**body の tail が
既に意味していること**そのものだから。だから運ぶのではなく、**元から指している tail へ寄せる**:

```
return v;  REST                        ==>  v            (REST は到達不能)
if c { .. return .. } else { .. }; REST ==>  if c { ..; REST } else { ..; REST }
```

2 つ目は suspension スライス群と同じ継続分配で、`match` の腕の capture 規則も同じ
(`scps_seq_float_match_arms` を再利用)。**枝が実際に return するときだけ**発火するので、
return しないコードの形は変わらない。

**部分実装が安全な理由**: 寄せきれなかった `return` (ループの中、let 初期化子の中、被演算子の中)
は**そのまま残し**、呼び出し側が「まだ `return` が残っていれば追記54 の refuse」を行う。
つまりこの変換が不完全であることのコストは**拒否**であって、決して miscompile ではない。
だから届く範囲から先に着地させられる。

handle body は対象外 — そこの `return` は**囲む関数**から抜ける意味で、handle の値ではないので
`done(v)` 化は誤り。追記54 の refuse のまま。ループの中も同じく refuse のまま
(`bubble(lp(), k)` が done 値を**ループの値**として k に渡すため、escape しない)。

実測 (`effect_return_in_split_body_test.vibe` = 5007560,
`effect_return_match_arm_split_test.vibe` = 311): suspension の後の return、
前の early exit (取る/取らない)、tail return、そして腕の binder が外側 `n` を shadow する
match — 捕獲すると 311 ではなく 306 になる。

### 追記56 (2026-08-13): loop 内の `return` と、その下で見つかった P0 (#1536)

ループ body の `return` は追記55 の hoist では扱えない — **loop body の tail は「次の反復」で
あって関数の値ではない**から。だが新しい機構は要らなかった: `break` は既にこの loop を
出られる (追記47) し、loop の**後ろ**の spine 上の `return` は追記55 が扱える。だから
「値を控えて、loop を出て、外で返す」に書き換えるだけでよい:

```
while c { .. return v .. }   ==>  let mut returned = false
REST                              let mut slot = 0
                                  while c { .. slot = v; returned = true; break .. }
                                  if returned { return slot } else { REST }
```

**入れ子の loop の中の `return`** も同じ書き換えで通る: `break` は 1 段しか出ないので、
**各段が record-and-break し、その直後に `if returned { break }` の guard を置いて
exit を 1 段ずつ外へ運ぶ**。3 段でも同じ (`effect_return_nested_loop_test.vibe` が
2 段 / 3 段 / return を取らない場合を pin)。

#### この書き換えが最初に誤答した — 原因は先行する P0 だった

実装後の最初の実測が **700 ではなく 800** を返した。切り分けると、原因は `return` ではなく
**`break` そのもの**だった:

```vibe
while i < 5 {
  let v = perform Ask::Get(i)
  if v > 6 { acc = v * 100; break } else { () }   // ← 前に文が 1 つある
  i = i + 1
}
```

`scps_is_ctl_terminator` が**裸の** `break` / `continue` しか transfer と認めていなかったため、
「文が 1 つ前に付いた transfer」= 普通の綴りが transfer と見なされず、normalizer は継続を
落とさず、rewrite も切らなかった。rewrite 後の transfer は**ただの呼び出し** (`k(v)`) なので、
実行は**それを素通りして loop を続けた**。同じ loop を effect 抜きで書けば 700、
suspension を入れると 800 — **黙って別の答えを返していた** (P0)。

`scps_is_ctl_terminator` を「この式は必ず transfer するか」に広げた (spine の tail を辿り、
selection は**全枝が transfer するときだけ**真。nested loop / closure / handle には入らない)。
`effect_transfer_after_resume_test.vibe` が pin (70011302)。

**教訓**: 追記55 の hoist は設計上正しかったが、土台が壊れていた。既存 fixture は transfer を
**suspension より前**にしか置いておらず、resume の後ろの transfer を誰も見ていなかった。

### 追記57 (2026-08-13): handle body の `return` は cell で外へ出す (#1536)

needing fn の clone と違い、handle body の `return v` は「**handle の値**」ではなく
「**囲む関数から抜ける**」意味なので、追記55 の hoist (tail へ寄せる) は使えない。
代わりに **cell を handle の外に置く**:

```
let r = handle { .. return v .. } with E { .. }   REST
  ==>  let mut returned = false
       let mut slot = 0
       let r = handle { .. slot = v; returned = true; 0 .. } with E { .. }
       if returned { return slot } else { REST }
```

handle の外に出た `return` は**普通の spine 上の return** なので、この handle 式自体が
split される body の中にあれば追記55 がそれを拾う。loop pass が spine 上へ持ち上げた
`return` も、この capture が cell 書き込みへ変換するので合成できる (`loop_early` が pin)。

hoist の終端を `flag == ""` で分岐させただけで、走査そのものは追記55 と同じものを共有する。

#### 撤回して戻した経緯 — 原因は async ではなかった

最初の実測で **`return 777` が 1554**、`return a * 100` (a=5) が 1000 と、**きっちり 2 倍**の
値が返った。`return` を取らない経路は正しかった。黙って誤るので一度撤回したが、原因は
**probe スクリプトが `VIBE_RC` を pin しておらず RC レーンで走っていた**ことで、
**RC backend では entry 関数の `return` が untag されない** (#1696、P0) という別のバグだった。
`VIBE_RC=0` (ゲートと同じ) で測り直すと 500 / 6 / 777 と正しい。

**教訓 2**: 誤った値を見て止めたのは正しかったが、原因の見立ては外れていた。計測環境が
ゲートと同じ設定かどうかを先に確かめること。

### 追記58 (2026-08-14): Array と示せる `for-in` を while 形へ落とす (#1536)

`for x in xs { .. perform .. }` — async で最も自然な反復 — が長く不適格だった。理由は
**codegen が `EForIn` を最後まで保持し、実行時に iterand が String かを判別して byte を
materialize する** (#807) ため。source level で while へ書き換えると **String は 0 回反復に
なって黙って誤る**。

必要なのは「Array である」証明だが、**checker のチャンネルは要らなかった**。次の**構文的**
証明で足りる:

- **`Array[..]` と注釈された引数** (`fn total(xs: Array[Int])`)
- **spine 上で配列リテラルに束縛された `let`** (`let xs = [1, 2]`)

証明できた名前に対してだけ、split の前に while 形へ落とす:

```
for x in xs { body }  ==>  let mut i = 0
                           while i < Array::length(xs) {
                             let x = Array::get(xs, i)
                             i = i + 1
                             body
                           }
```

`Array::length` は毎回読み直す (`for` の意味論どおり — body が配列を伸ばせばその分回る)。
**index は body の前に進める**ので、body の `continue` が空回りしない。

**証明できないものは一切書き換えない**ので、この pass が変えられるのは**今日 reject されている
プログラムだけ** — 現在通っているコードの挙動は変わらない。String は
`err_effect_string_for_suspend` が「引き続き reject」を pin する (書き換えていたら 0 回反復で
黙って誤っていた)。

`effect_array_for_suspend_test.vibe` (385548729) が**受理だけでなく意味論**を pin する:
引数由来 36 / リテラル由来 23 / `break` 23 / `continue` 24 (index が進む) / 伸長 87 /
handle body に直接書いた形 29。

**String iterand も同じ形で通る** (追記58b): codegen は String の char code を配列へ
materialize して回す (#807) が、**String は immutable なので直接 index で回しても同じ列**に
なり、`String::length` / `String::char_code_at` は codegen 自身が materialize に使っている
builtin。証明も同じ構文的なもの (`String` 注釈の引数 / 文字列リテラル束縛)。
**証明できない iterand は依然として一切書き換えない** — 実行時に String になりうる値を
array 形へ落とさないのはこの一点で守られている。

> 実装時に 5 回続けて誤診した。原因は述語でも builtin でも site でもなく、**関数本体を丸ごと
> 差し替えたときの splice ミス**だった。証明済みの名前を診断に吐く instrumentation を 1 回
> 入れたら (`strseed=1 S=s/found`) 部品が全部正しいことが分かり、そこから surgical に
> 書き直して通った。**読んで当てるのをやめて計測に切り替える**のが最短だった。

書き換えは **3 つの split site すべて**に置く — needing fn の clone、handle body 自身、
closure literal。最初は clone だけに入れており、`handle { for x in xs { .. perform .. } }` と
直接書いた形が取り残されていた (handle body も他と同じ spine で、そこでは引数が無いので
証明は spine 上の配列リテラル束縛から来る)。

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

### 追記59 (2026-08-14): row 変数 callee は「一階なら安全」(#1536)

`with e` を宣言した callee は「provably effect-free」ではないとして一律 reject していた。
理由は「row 変数は closure 引数経由で migrated effect に具体化されうる」。正しいが、
**その具体化は引数を通してしか起きない**。

したがって: **宣言された引数の型がどこにも関数型を含まない callee は、call site が
どうであれ `e` を空 row にしか具体化できない** — 呼び出しは handled effect を perform しえない。

```vibe
fn twice(x: Int) -> Int with e { x * 2 }        // ← 一階。suspend body から呼べる
fn apply(f: (Int) -> Int with e, x: Int) -> Int with e { f(x) }   // ← 拒否のまま
```

判定は宣言だけで閉じる (call site の型推論は要らない)。`Array[(Int) -> Int with e]` のように
**型引数の中の関数型も数える**ので、`TyFn` を再帰的に探す。注釈の無い引数・定義が見つからない
callee は従来どおり拒否。

#### 見つけ方 — 5 連続の誤診の原因は「stale な生成ソース」だった

実装後の実測が `REJECTED` のままだったので、また誤診を重ねかけた。今度は最初から
instrumentation を入れたところ、**そのデバッグ出力自体が現れなかった**。調べると
`lib/@vibe/compiler/_cli_adapter_module_source.vibe` (生成物) が編集より**古いまま**で、
`VIBE_PREBUILT_MODULE_SOURCE` でそれを食わせていたため、**ここ数回のビルドは変更を
一切含んでいなかった**。生成物を消して再生成させたら `generate_bundle: seed could not
flatten the live tree / unexpected in pattern: =1` — instrumentation の中に書いた
`None => all = false` (波括弧なしの代入) が seed の parse error だった。

つまり **`ensure_generated.sh` が "ok" を返しても生成物が最新とは限らない**。この直前の
String iterand の 5 連続誤診も、同じ stale ビルドを見ていた可能性が高い。

**教訓 (今夜 3 つ目)**: 否定的な実測が続いたら、まず**測っている対象が自分の変更を含んで
いるか**を確かめる。`grep <新しい識別子> <生成ソース>` の一行で済む。

### 追記60 (2026-08-14): `for` の iterand が CALL でも証明できる (#1536)

追記58 の証明は**名前**に限っていたので、`for x in items()` のように iterand が呼び出しだと
落ちていた。**callee の宣言された戻り型**で同じ証明ができる:

```vibe skip
fn items() -> Array[Int] { [1, 2, 3] }
for x in items() { .. perform .. }        // ← 通るようになった
```

値は loop の前に一度だけ束縛する (`for` が iterand を一度だけ評価するのと同じ)。名前の場合は
既に名前があるので束縛は増やさない。

戻り型の取得先に注意: **`fn_defs` の `Option[TypeExpr]` スロットは binding の注釈**
(`let f: T = ..`) であって関数の戻り型ではない (通常 `None`)。戻り型は `EFn` 側にあるので、
stmts を走査して `SLet(_, _, name, _, EFn(_, _, _, ret, _, _))` から読む。最初これを
取り違えて「証明が効かない」状態になった — **構築側 (`edp_collect_fn_defs`) を読めば
ビルド 0 回で分かった**。

### 追記61 (2026-08-14): step-split literal を plain な param へ渡す形は reject する (#1707)

**P0 (黙って誤る)。** effect を perform する closure literal は **step を返す**ようにコンパイル
されるので、**その effect を row に持つパラメータにしか渡せない**。plain なパラメータへ渡すと
callee は普通の規約で呼び、**step オブジェクトがそのまま値**になる (実測: 5 が 177、15 が 301 —
ヒープポインタが Int として読まれている)。

prepass には**逆向きの fixup が既にあった** — pure な literal が row 付きパラメータへ来たら
Done-wrap する。それが `if prow != ""` の内側にあり、**step-split 済み literal が row を持たない
パラメータへ来る場合**を素通りしていた。

**row 変数のパラメータは免除**する。`TaskGroup::run[T, rg, e](body: (..) -> T with e)` は
呼び出し側で `e` にその effect を具体化できるので、step 返しの literal を受け取れる。
**具体的な row が effect を含まない場合だけ**が plain 規約のパラメータ。

#### 3 回失敗してから通った — 手順の記録

| 試行 | 仮説 | 結果 |
|---|---|---|
| 1 | `scps_calls_ok` の `EFn` arm が cps_locals を保持している | **効果ゼロ** → literal は既に step-split 済みで、問題は body でなく**渡され方**だと判明 |
| 2 | arg-position fixup の「鏡」が無い | **P0 は直ったが** `lib/@vibex/concurrent/suspend_test.vibe` (supported な形) を壊した |
| 3 | needing callee を免除 | `TaskGroup::run` は cneeding に無く、**変わらず** |
| 4 | **row 変数のパラメータを免除** | **通った** — P0 は reject、suspend_test は 27 tests pass、601/601、gate green |

**教訓 A**: `scripts/compiler_gate.sh` はこの regression を捕まえない。
**`VIBE_STAGE2_WASM=<stage2> bash scripts/unit_test_runner.sh` (601 files) が捕まえる。**
この領域を触るときは両方回す。

**教訓 B (追記59 の修正)**: 生成ソースの鮮度を識別子で grep してはいけない — **bundler が
識別子を潰す**ので、変更が入っていても 0 件になる。**新しい文字列リテラル**
(診断メッセージなど) で grep すること。
