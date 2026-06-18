# WASI 0.3 (Preview 3) async — 設計と段階移行

Status: **proposed** (ADR-0012 を更新)。最終更新 2026-06-16。

WASI 0.3 は 2026-06-11 に ratify され、`stream<T>` / `future<T>` が Component
Model の first-class 型として導入された。本ドキュメントは vibe を WASI 0.3 の
async モデルへ寄せていくための設計判断と段階プランを定める。北極星は
**`async`/`await` + `Future[T]` + `Stream[T]`**、stream の抽象哲学は
**既存 `Iterator` に寄せた pull ベース**。

旧 [docs/report/support-wasip3.md](../report/support-wasip3.md)（2026-05-22、
同期 effect ベースの Model 1）の async 部分は本ドキュメントが supersede する。
同期 effect capability（`HttpRequest`/`HttpResponse`/`HttpClient` を `perform`
で扱う）は引き続き有効で、async はその上位に位置づける。

## 1. WASI 0.2 → 0.3 の要点

- `pollable` → `future<T>`、`input-stream`/`output-stream` → `stream<u8>`。
  `wasi:io` の poll/pollable は canonical ABI に吸収。
- `subscribe()` で pollable を取る代わりに、関数が `future<...>` を返す。
  `start-foo` / `finish-foo` の 2 段 API は `foo: async func(...)` に統合。
- 例: `read-via-stream: func() -> result<input-stream, error-code>`
  → `read-via-stream: func() -> tuple<stream<u8>, future<result<_, error-code>>>`。
- `wasi:http` は 0.2 の `proxy` world を廃し、**`wasi:http/service`** と
  **`wasi:http/middleware`** の 2 world に（vendored submodule で確認:
  `deps/wasmtime/crates/wasi-http/src/p3/wit/deps/http.wit` の `world service` /
  `world middleware`）。
- ランタイム: wasmtime **45** は 0.3 を **release candidate** として
  フラグ付きで実行（`-W component-model-async=y -W
  component-model-async-builtins=y` 等）。**46** が ratified `0.3.0` を
  async-by-default で同梱予定（本ドキュメント時点では未リリース、最新 stable
  は 45.0.2 / 2026-06-15）。

## 2. 言語モデル

### 2.1 型

- `Future[T]` — 単一の非同期値。`await f : T`。
- `Stream[T]` — pull ベースの **async iterator**。既存 `Iterator`/`Iterable`
  (ADR-0044) の形を踏襲する:

  ```vibe
  trait AsyncIterator[T] {
    next(Self) -> Future[Option[T]]   // None で終端
  }
  ```

  WASI 0.3 の `stream<u8>` は `ByteStream = Stream[Int]`（byte=Int）として
  露出する。HTTP の request/response body はこの `ByteStream`。

### 2.2 構文

vibe には `fn` キーワードが無く、関数は `let f: (A) -> B with { E } = (x) -> {}`
形式で副作用は effect row (`with { E }`) で表現する。したがって **`async`
キーワードは導入しない**。代わりに:

- **`await` は effectful な操作**で、`Async` effect を帯びる。`throw`→`Error`
  / `perform Eff::Op`→`Eff` と同じ扱い。「async 関数」= **effect row に
  `Async` を持つ関数**（`with { Async }`）であり、特別な宣言構文ではない。
  `await(f)` は `Future[T]` を待って `T` を得る。
- `Async` を持つ計算を非 `Async` 文脈で使うと、既存の effect-escape チェック
  (`checker_effects.vibe` の `EEEffectfulCallOutsideEffect`) がエラーにする。
- `for await x in s { ... }`（`Stream[T]` の逐次 pull、`s.next()` を `await`
  するループへ desugar）は M2 で導入予定の糖衣。

実体（状態機械 lowering）は §3 が担い、replay effect handler の上には載せない。

#### M1a 実装メモ（landed）

front-end は **lexer/parser/AST/core-Type の変更ゼロ**で着地した:

- `await` は予約語ではないため `await(f)` は通常の呼び出し
  `ECall(EIdent("await"), [f])` として既存 parser でそのまま通る。
- checker builtin として登録（`vibe/compiler/checker/builtins_async.vibe`、
  `lookup_builtin` 経由）:
  - `await : (Future[T]) -> T with { Async }`（`throw` と同型、effect=`Async`）
  - `Future::ready : (T) -> Future[T]`（pure、テスト用に future を構築）
- `Future[T]` は `CtNamed("Future", [..])` で構造的に表現（core `Type` enum
  非変更）。要素型は他 builtin と同様 `CtUnknown`（gradual）。
- `Async` は open string の effect 名なので effect-escape チェックがそのまま
  機能する。検証: `checker_async_test.vibe` 6/6、`checker_effects_test.vibe`
  19/19（無回帰）。bundle 再生成済み（sync OK）。

### 2.3 同期 effect との関係

vibe の既存 effect system（`handle`/`perform`/`resume`）は **replay ベース・
同期**で、`handle` あたり ~16K perform の hard bound を持つ（ADR-0055, #553,
#556）。長寿命の async stream をこの replay-memo に載せると破綻するため、
**async は effect handler の replay 機構の上に build しない**。`Async` は
型レベルの effect row 注釈としてのみ用い、codegen は専用の状態機械 lowering
（§3）に分岐する。同期 effect（Error/Stdout/HttpRequest 等）の意味論・実装は
不変。

### 2.4 `Stream[T]` — async iterator（WASI 0.3 `stream<T>`）

WASI 0.3 の `stream<T>` を、vibe の `Iterator`（ADR-0044）と**同じコンビネータ
形**で扱う pull ベースの async 列として言語に取り込む。sync の `Iterator::*` と
同形の API で、`next` が `Future` を返し `fold` が `Async` を帯びる点だけが違う:

- `Stream::next : (Stream[T]) -> Future[Option[T]] with { Async }`（`None` で終端）
- `Stream::empty : () -> Stream[T]` / `Stream::once : (T) -> Stream[T]`（pure）
- `Stream::map : (Stream[T], (T)->U) -> Stream[U]`（lazy, pure）
- `Stream::filter : (Stream[T], (T)->Bool) -> Stream[T]`（lazy, pure）
- `Stream::fold : (Stream[T], A, (A,T)->A) -> Future[A] with { Async }`
- `ByteStream = Stream[Int]` が WASI `stream<u8>` / HTTP body に直結。
- 将来構文 `for await x in s { ... }`（`s.next()` を `await` するループへ desugar）
  は M1a の `await` と同じく後続（front-end は builtin 呼び出しで先行）。

**狙い**: sync collection と async stream を**同じ pipeline コード**で書ける
（effect row が `{}` か `{ Async }` かの差だけ）。`Iterator` の async 兄弟。

### 2.5 構造化並行 + キャンセル — `Task[T]`（WASI 0.3 task / waitable-set / cancel）

WASI 0.3 の task / `waitable-set` / `future.cancel-*` を、**構造化並行**と
**キャンセル**として言語に取り込む。子タスクは囲う async スコープに束縛され、
スコープ離脱で join/cancel される（leak/孤児タスク無し）:

- `Task::spawn : (() -> T with { Async }) -> Task[T] with { Async }` — 子タスク生成
- `Task::join : (Task[T]) -> T with { Async }` — 結果を待つ
- `Task::cancel : (Task[T]) -> Unit with { Async }` — キャンセル要求
- `Task::race : (Task[T], Task[T]) -> T with { Async }` — 先着、敗者は cancel
- `Task::timeout : (Int, () -> T with { Async }) -> Option[T] with { Async }`
  — 期限切れで `None`（内側 task を cancel）

`await` がキャンセル点であり、cancellation は `Async` effect row に沿って伝播
する。effect handler と相性が良く、spawn/join/cancel をハンドラで mock/制御
できる（テスト容易・合成可能）。将来構文 `scope { ... }`（離脱で子を join/cancel）
は後続。

#### 2.4/2.5 front-end（landed）

M1a と同じ要領で、lexer/parser/core-Type を変えずに着地:
- `Stream[T]` / `Task[T]` は `CtNamed("Stream"/"Task", _)` で構造表現（要素型は
  gradual な `CtUnknown`）。`Future[Option[T]]` は `CtNamed("Future",
  [CtOption(CtUnknown)])`。
- builtin は `vibe/compiler/checker/builtins_async.vibe`（`lookup_stream` /
  `lookup_concurrency`、`lookup_builtin` 経由）に登録。suspend / runtime 接触
  操作（`*::next`/`fold`/`spawn`/`join`/`cancel`/`race`/`timeout`）は `Async`
  effect を帯び、effect-escape チェックがそのまま機能する。
- 検証: `checker_async_test.vibe` 13/13、`checker_effects_test.vibe` 19/19
  （無回帰）。
- **`Task[T]` codegen（synchronous eager model, landed）**: 単一スレッドの
  linear backend では「spawn = thunk を即時実行し、Task 値 = 解決済み結果」
  「join = identity」「cancel = drop して Unit」「race = 先行 task の値」という
  同期セマンティクスへ lower（`compile_call.vibe`）。`Task::spawn` は 0 引数
  closure（thunk）を `call_indirect`（closure type 9）で呼ぶ。`await` /
  `Future::ready` と同じ系列で、async component（`with { Async }`）に包まれ
  wasmtime 45 上で実行可能。回帰 gate `test_selfhost_async_component_gate.sh`
  に Task entry を追加（spawn/join/cancel/race → 42）。
  - **free-var capture 修正**: inlined async builtin（`await`/`Future::ready`/
    `Task::spawn|join|cancel|race`）は func table に居ないため、nested lambda
    body 内で free 変数として捕捉され誤った indirect-apply に lower される
    バグがあった（`() -> { Task::join(t) }` が `Task::join` を closure 値として
    capture）。`collect_free_vars_expr` でこれら名前を演算子同様に除外して修正。
- **`Stream[T]` codegen（eager Array-backed model, landed）**: linear backend
  では `Stream[T]` を既存の eager Array 機構で表現する。`Stream::map` /
  `Stream::fold` は同一引数順・同一値表現なので **既存の inline `Array::map` /
  `Array::fold` lowering をそのまま再利用**（`compile_call` の fname remap）。
  `Stream::empty` = `array_new`、`Stream::once(x)` = `array_new` + `Array::push`、
  `Stream::filter` は述語が truthy な要素のみ push する loop を inline emit。
  gate に Stream entry を追加（empty/once/map/filter/fold → 42、wasmtime 45）。
  inline builtin の free-var capture 除外に Stream 名も追加。
- 後続: `Stream::next`（`Future[Option[T]]` を返す → Option 構築 codegen が
  必要、`Task::timeout` と同じ ctor emit 基盤を共有）と、真の subtask spawn
  （waitable-set / `future.cancel-*` による実並行・キャンセル、§3.6 / §3.7）。

## 3. codegen 戦略: Component Model async canonical ABI（stackless）

vibe は compiled でネイティブ coroutine を持たないため、各 `async` 関数を
**状態機械（stackless coroutine）に lower** し、Component Model async の
canonical built-ins を直接呼ぶ。これは wit-bindgen が Python/JS/C# 向けに採る
方式と同じで、**WASM stack-switching proposal（エンジン未安定）に依存しない**。

使用する canonical built-ins（wasmtime 45 のフラグ — §3.1 の M1b spike で
確定 — `-W concurrency-support=y -W component-model-async=y` ＋ stackful
form では `-W component-model-async-stackful=y`）:

- `future.new` / `future.read` / `future.write` / `future.cancel-read`
- `stream.new` / `stream.read` / `stream.write` / `stream.cancel-read`
- `task.return`（async export の結果返却）/ `task.wait` 相当の
  `waitable-set.new` / `waitable-set.wait` / `waitable.join`
- `async-lower` / `async-lift`（import/export の async 呼び出し規約）

lowering 概要:

1. `async fn` を、suspend point（各 `await` / `for await` の `stream.read`）で
   分割した状態機械関数へ変換。ローカルは線形メモリ上の frame に退避。
2. `await f` は `future.read` を発行し、`BLOCKED` なら `waitable-set.wait` に
   登録して制御を返す。完了時に状態機械を resume。
3. `Stream[T]::next()` は `stream.read`（1 要素ぶん）を `future` 化して返す。
   `for await` はこれを繰り返し、`None`（EOF）で終了。
4. async export（HTTP handler 等）は `task.return` で結果を返し、
   `async-lift` 規約で wasmtime に lift される。

この lowering は selfhost compiler 側
(`vibe/compiler/codegen/`) に実装する（CLAUDE.md の source-of-truth 方針）。
既存の effect region / replay 機構とは独立した新パスとする。

### 3.1 M1b feasibility spike（landed、実測 — wasmtime 45.0.0 / x86_64 linux）

wit-bindgen の `async func() -> u32` を手動で最小化し、async-lifted export が
wasmtime 45 で**実際に動く**ことと、emit すべき最小形を確定した
（blueprint: `src/x/cm_async/cm_async_lift_probe.wat`、戻り値 42 を確認）。

確定した最小形（callback-less / **stackful** form）:

- 戻り値型の component type は async: `(type (func async (result T)))`。
- `task.return` は `(core func (canon task.return (result T)))` で lower し、
  core module に import として供給。
- async lift は `(canon lift (core func ...) async)`（callback 無し）。
- **stackful form では core function は値を返さない（void）**。結果は
  `task.return` 経由のみで届ける。status-i32 を返すのは callback/stackless
  form で、stackful では reject される。
- フラグ: `-W concurrency-support=y -W component-model-async=y
  -W component-model-async-stackful=y`。

**設計含意（重要）**: stackful form なら **backend は straight-line code を
emit できる**（結果計算 → `task.return` → return）。await を含む場合も
`future.read` / `waitable-set.wait` で**ブロックする直線コード**を書けばよく、
§3 冒頭の明示的 stackless 状態機械分割は **不要**。wasmtime の
`component-model-async-stackful` は host fiber 実装で、WASM stack-switching
proposal（非 x86_64 で未サポート）とは別物のため、エンジン依存も回避できる。
これは当初の stackless 設計を大幅に簡素化する。

トレードオフ / 未確認:
- callback/stackless form（wit-bindgen が採用）は stackful フラグ不要
  （`concurrency-support=y component-model-async=y` のみで動作）だが、明示的な
  callback 状態機械の生成が必要で codegen が重い。**PoC は stackful 直線形を
  主とし、callback form を portable fallback として記録**。
- `component-model-async-stackful` の非 x86_64 / wasmtime 46 default での
  可用性は要確認。
- 別途、`component-model-async-builtins` は **wasmtime 45.0.0 では無効な
  `-W` フラグ**（M0 で誤記載していた。docs/report も修正）。

検証基盤: 既存 `src/x/cm_async/cm_async_probe.wat`（flag 受理の sync probe）に
加え、本 spike の `cm_async_lift_probe.wat`（async-lift 実動 probe）を追加。

### 3.2 M1b 実装ブループリント（byte-level encoding map）

`cm_async_lift_probe.wat` を `wasm-tools dump` して抽出した、selfhost encoder が
emit すべき正確なバイト列（wasmtime 45 で検証済み）。`component_codegen.vibe`
は既に async func type opcode `0x43`(67) と sync canon lift を持つので、不足は
(a) async lift option、(b) `task.return` canon、(c) core 側の import + void entry。

**core module**（`linked_compile.vibe`、async entry のとき）:
- import section: `import "cm" "task-return"`、func 型 `(param i32) (result)`
  = `02 63 6d  0b 74 61 73 6b 2d 72 65 74 75 72 6e  00 00`
  （module名"cm" / name"task-return" / kind=func(00) / typeidx=0）。
- entry func body: 値を計算し `call $task_return` して **void で return**
  = 例 `41 2a  10 00  0b`（i32.const 42; call task_return; end）。
- 型: task_return 用 `(param i32)->()` = `60 01 7f 00`、entry `()->()` = `60 00 00`。

**component sections**（`component_codegen.vibe`）:
- task.return canon: section `08`、内容 `01` + `09 00 79 00`
  （`09`=task.return opcode、`00 79`=result Some(u32, valtype `0x79`)、`00`=options空）。
  valtype をパラメタ化（s32=`0x7a`? 等は要確認、u32=`0x79` は実測済み）。
- async component func type: `43 00 00 79`
  （`0x43`=async functype opcode、`00`=params数0、`00`=result-form tag、`79`=u32）。
  既存 `emit_comp_func_type(is_async=1)` が `0x43` を出すが result は s64(`0x78`)
  固定 — 結果型をパラメタ化する必要あり。
- core instance: task.return core func を `FromExports`("task-return") で 1 つの
  core instance にし、main module 実体化の `cm` 引数に渡す。
- async canon lift: `00 00 <core_func_idx> 01 06 00`
  （`00`=lift, `00`=func sort, core_func_idx, options vec len `01`, **async opt
  `0x06`**, type_idx）。現 `emit_canon_lift_func` は options に async(`0x06`)を
  含めないので async 変種を追加する。
- export: 既存 `emit_comp_export_section` を流用。

**フラグ**: `-W concurrency-support=y -W component-model-async=y
-W component-model-async-stackful=y`。

最初の縦串 PoC は await 無し（`() -> Int with { Async }` の body が定数 / 純粋
計算）で `task.return` 経路を通し、その後 `await(Future::ready(x))` → 単一
`future.read` ブロックへ広げる。

### 3.3 M1b codegen stage 1（landed）+ stage 2 の前提発見

**stage 1（done）**: `component_codegen.vibe` に async component emitter を実装:
`emit_canon_task_return` / `emit_canon_lift_async_section`（async canonopt
`0x06`）/ `emit_comp_async_functype_section`（opcode `0x43`）/
`comp_emit_component_wasm_async`。`component_codegen_test.vibe` 10/10 で、emit
結果が §3.2 の検証済みバイト列と一致すること（および sync lift には async
option が混入しないこと）を確認。emitter は既存 sync lift と同じ構成ヘルパ
（header / core module / core instance / alias / export）を再利用するため、
runnable な probe とのバイト一致＝全体も valid と判断できる。

**stage 2 で判明した前提（重要）**: selfhost ツリーには **`--component`
オーケストレーションが存在しない**（`comp_emit_component_wasm*` は定義・テスト
のみで、CLI からは呼ばれていない。`vibe compile --component` / `--compose-p3`
の実体は host (`src/`) 側）。したがって「実 `.vibe` → async component を
`vibe compile` で生成して wasmtime で動かす」真の E2E には、まず **selfhost 側に
component-compile オーケストレーション（entry → core wasm → component wrap）を
構築する**必要がある。これは linked_compile の小改修ではなく独立した feature で、
core-side の async entry 生成（`cm.task-return` import + void entry）もその中に
位置づくべき。M1b は「emitter（stage 1, done）」と「orchestration + core-side
（stage 2, 別 feature）」に再分割する。

stage 2 の真の E2E 検証は、selfhost component-compile orchestration 着地後に
`vibe compile --component async.vibe` → wasmtime 45 で実施する。それまでの
emitter の正しさは byte-exact 一致（runnable probe 基準）で担保する。

### 3.4 M1b-2 アプローチ確定（trampoline、実測済み）

core-side（`linked_compile.vibe`）を改修せずに済む **trampoline 方式**を実測で
確定した（`src/x/cm_async/cm_async_trampoline_probe.wat`、wasmtime 45 で 42）。
selfhost は既に entry を `run : () -> i64`（値を直接 return）で core wasm に
コンパイルできるので、それを**そのまま main module** とし、小さな async
**trampoline module**（`("main","run")` と `("cm","task-return")` を import、
void `run` = `call entry; call task-return`）で包む。string-lift が 2 つ目の
core module を合成するのと同じ構造で、`linked_compile.vibe` は無改修。

確定した component core-func index 空間: `task.return` canon = 0 / alias
`main."run"` = 1 / alias `tramp."run"` = 2、async lift は core func 2 を参照。
trampoline core module は result valtype（vibe Int = i64 = `0x7e`）を埋めた
ほぼ定数のバイト列（`comp_generate_string_trampoline` と同じ要領で生成可能）。

これで M1b-2 の codegen アプローチは実機で裏付けられた。残る emitter 実装は:
`comp_generate_async_trampoline(core_valtype)`（trampoline module 生成）+
`comp_emit_component_wasm_async_trampolined(main_core, entry_name, valtype)`
（2 module 合成: main / tramp / task.return canon / instances(main, cm,
env-alias, tramp) / async functype / alias tramp.run / async lift / export）。
さらに orchestration（async entry → main core wasm → wrap → 出力）と CLI 配線。

### 3.5 M1b-2c orchestration（landed）+ M1b-2d（WASI import 配線）

`compile_source_wasi_only`（cli adapter 経路 `selfbuild_cli_args_entry` が通る
universal な source-compile）に、entry が `() -> Int with { Async }`（name
"run"、no params）であることを **AST の TyFn effect 注釈から検出**して
`comp_emit_component_wasm_async_trampolined` で包む hook を追加。

**実測（stage1 selfhost compiler、`let run: () -> Int with { Async } = () -> { 42 }`）**:
- 出力が **component**（magic `0d 00 01 00`）になり `wasm-tools validate` OK。
- 非 async entry（`run : () -> Int`）は **plain core module のまま**（無回帰）。
- ただし wasmtime 実行は instantiate で失敗: main core module が
  `wasi_snapshot_preview1.fd_write` を 1 件 import しており、async component が
  これを充足していない。

**M1b-2d（landed、縦串完成）**: 真の run を達成した。
- `comp_generate_wasi_fd_write_stub`: no-op `fd_write`(`(i32,i32,i32,i32)->i32`=0)
  の core module。`comp_emit_component_wasm_async_trampolined_p1` がこれを
  3 つ目の module として同梱し、main の instantiation に `wasi_snapshot_preview1`
  引数として供給（preview1 adapter 不要で自己完結）。core instances:
  0=wasi-stub / 1=main(+wasi) / 2=cm / 3=env / 4=trampoline。
- nullary vibe fn は `(param i64)->result`（i64 は unit 引数）に lower される
  ため、trampoline は dummy `i64.const 0` を積んで entry を呼ぶよう修正。
- selfhost core は effect 基盤で exnref を使うため、実行に wasmtime の
  exceptions proposal を有効化。

実測フラグ:
`-W exceptions=y -W concurrency-support=y -W component-model-async=y
-W component-model-async-stackful=y`。

**実測結果**: stage1 selfhost compiler が
`let run: () -> Int with { Async } = () -> { 42 }` をコンパイル → component
（`wasm-tools validate` OK）→ wasmtime 45 で **42 を返す**。M1（async front-end）
〜 M1b（codegen + orchestration）の縦串が `.vibe` ソースから実機実行まで完成。

注: 現状は narrow PoC（entry 名 "run" / `() -> Int` / await 無しで Async
宣言）。`await` 本体の codegen、非 Int 戻り値、param 付き entry、複数 wasi
import（fd_write 以外）、entry 名一般化は後続。

回帰保護: この E2E は `scripts/test_selfhost_async_component_gate.sh`
（pkf task `test-selfhost-async-component`、CI selfhost-gates `cli` shard）に
固定。wasmtime/wasm-tools 不在時は graceful skip。非 async control が plain
core module のままであること（async wrap が通常ビルドに漏れない）も検証する。

### 3.6 M1b-3（`await` 本体 codegen）spike — canon built-in blueprint

wit-bindgen で `future<u32>` を await する component（`import await-val: func()
-> future<u32>` を `run: async func() -> u32` が `.await`）を生成し、`await` の
lowering に必要な canonical built-ins を抽出した:

| canon | 用途 |
|---|---|
| `future.new <ty>` | future 生成 → (writable, readable) handle |
| `future.read <ty> (memory M) async` | readable を読む（buffer へ）。status: COMPLETED / BLOCKED |
| `future.write <ty> (memory M) async` | writable へ書く（`Future::ready` の resolve） |
| `future.drop-readable/writable <ty>` | handle 破棄 |
| `future.cancel-read/write <ty>` | 読み書きキャンセル |
| `waitable-set.new` / `.poll (memory M)` / `.drop` / `waitable.join` | BLOCKED 時の待機 |
| `context.get/set i32 <n>` | task-local context（executor 用） |
| `task.return (result T)` / `task.cancel` | 結果返却（M1b で実装済） |

これらは **core-level canonical built-ins**で、core module に import として供給
する（`task.return` と同様）。

**重要な発見**: `await` は **単一 call ではなくループ**。`future.read` が
COMPLETED なら buffer から値を load、**BLOCKED なら waitable-set に登録して
`.wait`/`.poll` で待ち、ready 後に再 read** する必要がある（wit-bindgen が
futures-rs executor 一式を取り込むのはこのため）。stackful lift 下では待機が
fiber を suspend するので明示的状態機械は不要だが、**read→(block時)wait→retry の
ループ + memory buffer 管理**を core codegen で emit する必要があり、`task.return`
（単発 call）より大幅に重い。

**M1b-3b（landed、ready-future fast path）**: `await(Future::ready(x))` のような
**ready future の await は値 `x` と等価**なので、`compile_call.vibe` の builtin
dispatch に identity lowering を追加した（`await`/`Future::ready` を引数の値へ
lower）。これにより **await を使う async プログラムが初めてコンパイル&実行可能**に
なった（従来は codegen 無しで不可）。gate を `await(Future::ready(42))` body へ
更新し、selfhost → async component → wasmtime 45 で **42** を実測。

**M1b-3c（todo、真の blocking await）**: 実 async ソース（host async import /
subtask spawn）から得た future を待つ場合は §3.6 のとおり `future.read` +
waitable-set 待機ループが必要。これは (a) async source 基盤、(b) core module へ
の future canon built-in import + buffer + ループ emit、(c) component への
future<T> 型 + canon 定義、を要する本格改修。spike で canon の signature/option
は判明済みなので blueprint→byte で進められる。

### 3.7 M1b-3c spike — blocking await の実機確認（mechanics proven）

self-contained で**実際にブロックする** await を wit-bindgen で構成し wasmtime 45
で実行確認した: guest が future を作り（`future.new`）、**writer subtask を spawn**
（`wit_bindgen::spawn`）し、`future.read` で**ブロックして** writer の書き込みを
待ち、値を得て `task.return`。`-W exceptions -W concurrency-support
-W component-model-async -W component-model-async-stackful` で **42 を返す**。

つまり blocking await の runtime mechanics（spawn → block-on-read → resume）は
wasmtime 45 で動くことが確定。残るは selfhost codegen での再現:

最小 await ループ（host async source から得た future を待つ場合、spawn 不要）:
```
loop {
  st = future.read(handle, buf)        ; async option
  if st == COMPLETED { break buf }     ; 値が来た
  ws = waitable-set.new                 ; BLOCKED
  waitable.join(handle, ws)
  waitable-set.wait(ws)                 ; stackful fiber を suspend
}                                        ; ready 後に再 read
```
- **host async source からの await**（上記、spawn 不要）が最小。ただし async
  source（host async import を提供する runner、または wasi:clocks 等）の用意が前提。
- **self-contained future**（guest が future を生成して待つ）には subtask spawn
  ＝最小 async executor（context.get/set + waitable-set 管理）が必要で、より重い
  （wit-bindgen は futures-rs executor 一式を取り込む）。

**M1b-3c codegen の規模**: selfhost core codegen に future canon built-in の
import・memory buffer・上記待機ループ（+ self-contained なら最小 executor +
spawn）を emit する大型 feature。mechanics と canon は確定済みなので実装は
blueprint→byte で進められるが、async 全体で最大の塊。

## 4. WASI 0.3 境界マッピング

| vibe | WASI 0.3 |
|---|---|
| `Future[T]` | `future<T'>`（`T'` は T の canonical 表現） |
| `Stream[T]` | `stream<T'>`、`ByteStream` = `stream<u8>` |
| `async fn handler(...)` export | `wasi:http/service` の `handle: async func(request) -> result<response>` |
| outbound `await HttpClient::fetch(...)` | `wasi:http` client の async func（`future<response>`） |
| request body / response body | `stream<u8>`（`ByteStream`）。Phase1 の "body 渡せない" 問題を 0.3 ネイティブに解消 |

worlds: 受信は `wasi:http/service`、proxy/中継は `wasi:http/middleware`。

### 4.1 M3 — async HTTP handler（wasmtime 45 で実動、full adapter に集約）

vibe handler → host `--compose-p3` → `wasmtime serve` → curl の縦串を wasmtime 45
で確立した。試行錯誤で複数の adapter 派生（status / body / reqbody / status_body）
を作ったが、**最 comprehensive な `build_wasi_http_p3_full_adapter.sh` に集約し、
派生は削除**した（CI gate も `test_wasi_http_p3_full_gate.sh` 1 本）。

**full adapter のコントラクト**: handler は
`(method: String, url: String, headers: String, body: String) -> String`。
- 入力: request の method / url / **headers**（`request.get-headers().copy-all()`
  を `"name: value\n"` 行に serialize）/ **body**（`Request::consume-body` +
  `StreamReader::collect`）。
- 出力: HTTP 応答風文字列 `"STATUS\n<Header: value 行>\n\n<body>"`。先頭行 =
  status code、空行までの行 = response headers（`Fields::append`）、残り = body。
  空行が無ければ `"STATUS\nBODY"` に degrade。

実測（wasmtime 45、auth + routing + headers）:
`handler = (method, url, headers, body) -> String { if String::contains(headers,
"x-token: secret") { "200\ncontent-type: text/plain\n\nok" } else { "401\n
unauthorized" } }` → `x-token` ありで **200 "ok"**（`content-type` ヘッダ付き）、
なしで **401 "unauthorized"**。gate `test_wasi_http_p3_full_gate.sh`（pkf
`test-wasi-http-p3-full`、CI selfhost-gates cli shard、serve+curl で検証、
tooling 不在時 skip）。

**確立できた point**:
- serve フラグ（wasmtime 45）: `-Sp3 -Shttp -W exceptions=y -W
  concurrency-support=y -W component-model-async=y
  -W component-model-async-stackful=y`。旧 P3 スクリプトの
  `-W component-model-async-builtins=y` は **wasmtime 45 で無効**（reject）だった。
- handler 戻り値の status untag は不要: vibe `Int`/`String` は default 経路で
  **raw**（untag 済み）で component 境界を渡る。

**未解決（architectural）**:
- clean な `-> tuple<s64, string>` 返却は不可: host `--compose-p3` string-lift が
  **single-value 返却のみ対応**で、vibe tuple が core で `(result i64 i64)` になり
  trampoline の `(result i64)` と不一致（`target_func` type mismatch で serve
  不能、実測）。そのため status+headers+body を単一文字列規約で符号化している。
  本来の tuple/record 返却には string-lift 拡張 or selfhost compose が必要。
- compose は host `--compose-p3`（`src/`、legacy）依存。selfhost compose 経路化、
  trailers、client/proxy（outbound）経路は後続。

## 5. バージョン / WIT 整合（M0、本コミットで実施）

WASI 0.3 RC のバージョン文字列がリポジトリ内で 3 重にズレていた:

- repo の P3 アダプタ/プローブスクリプト: `@0.3.0-rc-2026-02-09`
- vendored wasmtime submodule の WIT: `@0.3.0-rc-2026-03-15`
- legacy MoonBit host codegen (`src/codegen/*`): `@0.3.0-draft`
- ratify 済み最終版: `@0.3.0`

M0 では **selfhost / adapter 経路を vendored submodule の実体
`@0.3.0-rc-2026-03-15` に統一**する（アダプタの `include`/`import` 文字列が
ランタイム提供の WIT と一致しないと wit-bindgen が解決失敗するため、これは
correctness 修正）。`src/codegen/*` の `@0.3.0-draft` は legacy host 経路
（CLAUDE.md: `src/` は通常触らない）なので M0 では据え置き、別途追跡する。
wasmtime install 既定は 45.0.0 → 45.0.2（WASIp1 fd_renumber leak の security
patch、p3 WIT 不変）。

ratified `0.3.0` への最終 cutover は wasmtime 46（async-by-default）リリース
時に、フラグ撤去とあわせて行う。

## 6. 段階プラン

| Stage | 内容 | 状態 |
|---|---|---|
| **M0** | wasmtime 45.0.2 bump、P3 WIT 文字列を `rc-2026-03-15` に統一、ADR-0012 更新 + 本 spec 起票 | done |
| **M1a** | async front-end: `await` builtin (`(Future[T]) -> T with { Async }`) + `Future::ready` + `Future[T]`=CtNamed、effect-escape 検証。lexer/parser/core-Type 非変更 | done |
| **M1b-1** | codegen emitter（component 側）: `comp_emit_component_wasm_async` + `task.return` canon + async lift + async functype。byte-exact verified（test 10/10） | done |
| **M1b-2a** | アプローチ確定（**trampoline 方式**、`linked_compile` 無改修）を実測（`cm_async_trampoline_probe.wat` が wasmtime 45 で 42）。2-module 合成の exact byte blueprint 確定 | done |
| **M1b-2b** | emitter 実装: `comp_generate_async_trampoline` + `comp_emit_component_wasm_async_trampolined`（2-module 合成）+ byte test | 未着手 |
| **M1b-2c** | orchestration: `compile_source_wasi_only` が entry の `() -> Int with { Async }`（name="run"）を AST から検出し、core wasm を `comp_emit_component_wasm_async_trampolined` で包む。selfhost compiler（stage1）で `.vibe` → **component を出力**（magic 0d 00 01 00、`wasm-tools validate` OK）、非 async は plain core のまま（無回帰） | done |
| **M1b-2d** | 真の run: fd_write stub module を component に同梱し main の instantiation に供給、entry の `(param i64)->i64` 規約に合わせ trampoline が dummy i64 引数で呼ぶよう修正、wasmtime に exceptions flag。**縦串完成: selfhost が `.vibe` async entry → async component → wasmtime 45 で 42 を返す** | **done** |
| **M1b-2e** | 回帰保護 gate（`test-selfhost-async-component`）＋ CI 配線 | done |
| **M1b-3a** | `await` codegen spike: wit-bindgen reference から `future.new/read/write` + waitable-set 等 canon built-in の signature/option を抽出（§3.6） | done |
| **M1b-3b** | `await`/`Future::ready` の codegen（ready-future identity lowering）: `await(x)`/`Future::ready(x)` を引数の値へ lower。**await を使う async プログラムが初めてコンパイル&実行可能**。gate を `await(Future::ready(42))` body に更新し E2E で 42 | done |
| **M1b-3c** | 真の blocking await: `future.read` + waitable-set 待機ループ（async source = host async import / subtask spawn が前提）。core codegen に future canon built-in の import + buffer + ループを emit | spike done（§3.7、mechanics 実機確認）/ codegen 未着手 |
| **M-conc-1** | `Task[T]` codegen（synchronous eager model）: `spawn`（thunk を即時実行・closure type 9 で `call_indirect`）/`join`（identity）/`cancel`（drop→Unit）/`race`（先行値）を `compile_call` で lower。inlined async builtin の free-var capture バグ（nested lambda 内で `Task::join` 等を closure として捕捉）を `collect_free_vars_expr` で修正。gate に Task entry 追加（spawn/join/cancel/race → 42、wasmtime 45） | done |
| **M-conc-2** | 真の subtask spawn（waitable-set / `future.cancel-*`）+ `Task::timeout`（Option 構築） | 未着手 |
| **M2a** | `Stream[T]` codegen（eager Array-backed model）: `map`/`fold` を inline `Array::map`/`Array::fold` へ remap、`empty`=`array_new`、`once`=`array_new`+`push`、`filter` を inline loop で emit。gate に Stream entry 追加（empty/once/map/filter/fold → 42、wasmtime 45） | done |
| **M2b** | `Stream::next`（`Future[Option[T]]`、Option 構築 codegen）+ `Task::timeout`。真の `stream.read` 上の async iterator、HTTP body を stream 化、`for await` | 未着手 |
| **M3** | outbound async HTTP client（`Future[Response]` + streaming body）、`wasi:http/service` + `middleware` world | 未着手 |
| **M4** | parity/gate/CI、docs、ADR-0012 → accepted | 未着手 |

## 7. 未解決事項

- canonical ABI の async 状態機械を selfhost codegen で生成する際の frame
  レイアウト / suspend-resume の具体表現（M1 で確定）。
- `Async` effect row と既存 effect row 推論の統合（await 透過性、`async fn`
  の effect 注釈規則）。
- `T` → canonical `T'` の表現（特に enum/record を `future`/`stream` 要素に
  する場合）。
- wasmtime 46 リリース後の ratified `0.3.0` cutover とフラグ撤去のタイミング。
