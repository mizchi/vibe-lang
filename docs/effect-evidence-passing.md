# ADR-0076: effect handler を evidence passing 化する (suspend 点 IR で WasmFX/WASI 0.3 前方互換)

Status: proposed (実装 Phase 1/2/2b は着地済み、2026-07-22 — 「段階導入計画」の実装ノート参照)

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
- **Phase 3**: yield bubbling (選択的 CPS) を実装し、非 tail-resumptive
  経路も evidence passing へ移行。replay loop・`eff_reserve`・memo
  アドレッシングを削除。`~16K` bound と M2 が全域で解消する。
  selfhost bootstrap bump が必要 (compiler 自身の effect 呼び出しが
  新経路でコンパイルされる)。**前提**: 現行の「単一小文字ラベルは全
  operation を authorize する」row-polymorphism hack には evidence dict
  を組み立てるための operation 集合情報がなく、replay 経路を完全に
  削除するにはこの hack を使う関数にも evidence を割り当てられる必要が
  ある — ADR-0071 の構造化 row (少なくとも row variable 部分) が
  Phase 3 着手までに着地していることを前提とする (詳細は下記
  「検討済みの論点」参照)。着地していない場合は、hack を使う関数だけ
  replay 経路を残す長期 hybrid に切り替える。
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
