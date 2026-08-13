# WASI 0.3 (Preview 3) async — 設計と段階移行

Status: **proposed** (ADR-0012 を更新)。最終更新 2026-08-07（#1230/#1341 の棚卸しで §2/§6/§7 を現行仕様だけに整理）。

WASI 0.3 は 2026-06-11 に ratify され、`stream<T>` / `future<T>` が Component
Model の first-class 型として導入された。本ドキュメントは vibe を WASI 0.3 の
async モデルへ寄せていくための設計判断を定める。北極星は
**`Async` effect row + `Future[T]` + AsyncIter**、stream の抽象哲学は
**既存 `Iterator` に寄せた pull ベース**。

### この文書の読み方

| 節 | 中身 | 性質 |
|---|---|---|
| §1, §2 | 言語モデル (型・await・stream・effect row) | **現行仕様**。ここだけ読めば今の言語が分かる |
| §3 | codegen / ABI の実測記録 (§3.1〜§3.19) | **実測ログ**。canon built-in の byte encoding・実機で確かめた制約の source of truth。時系列で積む |
| §4, §5 | WIT 境界マッピング / バージョン整合 | 現行仕様 |
| §6, §7 | 現在地・残作業・未解決 | 現行状態 |

着地までの経緯・撤去した surface・当時の見立ては
[archive/spec/wasi-p3-async-history.md](../archive/spec/wasi-p3-async-history.md)
へ退避してある。

> **言語表面との整合**: `Async` ラベル二重定義の統一、phantom
> `Future[T]` の実体化、eager `Stream[T]` の退役と AsyncIter への一本化、
> `Coroutine`↔`stream` の二層対応、wit_gen の `future<T>`/`stream<T>`/
> `async func` マッピングは [ADR-0089](../wasip3-effect-alignment.md) が
> 決定した。本ドキュメントは lowering / ABI 側の source of truth のまま。

旧 [docs/archive/report/support-wasip3.md](../archive/report/support-wasip3.md)（2026-05-22、
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
  component-model-async-builtins=y` 等）。**46**（46.0.1）は ratified
  `0.3.0` を async-by-default で同梱し、#821 でそちらへ cutover 済み
  （§5 参照）。

## 2. 言語モデル

> この節は**現行仕様だけ**を書く。着地までの経緯・撤去した surface・当時の
> 見立ては [archive/spec/wasi-p3-async-history.md](../archive/spec/wasi-p3-async-history.md)
> へ退避した (2026-08-07、#1230/#1341 の棚卸し)。実装の現在地は §6、
> ABI 実測は §3。

### 2.1 `async` キーワードは無い — `Async` は effect row のラベル

vibe には `fn` の色付けが無く、副作用は effect row で表す。したがって
**`async` キーワードは導入しない**。「async 関数」= **row に `Async` を持つ
関数** (`with Async`) である。

- `await(f)` は `(Future[T]) -> T with Async` の builtin
  (`checker/builtins_async.vibe`)。予約語ではないので parser 変更は無い
  (`ECall(EIdent("await"), [f])`)。
- `Async` を持つ計算を非 `Async` 文脈で使うと effect-escape 検査
  (`EEEffectfulCallOutsideEffect`) が落とす。
- `effect Async { Suspend(Int) -> Int }` の**宣言は
  `lib/@vibex/concurrent/concurrent.vibe`** にあり (#752 の「宣言が契約」方式)、
  checker builtin の row ラベル `"Async"` と名前で一致する。だから
  `handle .. with Async` で discharge できる (`TaskGroup::spawn_suspend` が
  実際にそうしている)。**builtin の nominal row を handler が放電できない
  という制約は無い** — 一致しているのは名前であって、経路は perform。

### 2.2 `Future[T]` — 2 語セル `[state, payload]`

`Future[T]` は型レベルの phantom ではなく、**実行時に 2 要素配列**である
(`compile_call.vibe` の `future_ready_expr` 系)。state slot が「まだ解決して
いない」を持てるので、producer を足すたびに表現を作り直さずに済む。

| state | 意味 | payload | producer |
|---|---|---|---|
| 0 | ready | 値 | `Future::ready(x)` / `Stream::next` / `Stream::fold` |
| 1 | guest 内 pending | 未定 (resolve が書く) | `Future::pending()` |
| 2 | host future (waitable) | host future handle | `host_future_get()` / `host_future_named("x")` |
| 3 | host stream セル | readable end の handle | `host_stream_named("x")` |

state 3 を future と別値にしてあるのは、**stream セルを future として await
できないようにする**ため (逆も同じ)。

`Future::resolve(f, v)` が state 1 のセルを完了させる。**payload を書いてから
state をクリアする**順序が load-bearing で、逆順だと awaiter が「ready なのに
値がまだ」を観測しうる。

#### `await` の lowering — codegen ではなく AST パス

`await` は `await_poll_pass` (`codegen/common_base/inline_direct_perform.vibe`)
が **`__aw_poll(fut)` 呼び出しへ書き換える**。`desugar_trait_dicts` の直後、
全 effect パスの**前**に走る。`compile_call` で wasm を直接吐く位置は
`suspend_cps_pass` / `evidence_dict_pass` の後なので、そこで
`perform Async::Suspend` を出しても discharge する相手がいないため。

```text
__aw_poll(fut) -> Int with Async:
  while 0 < Array::get(fut, 0) {
    let __aw_w = perform Async::Suspend(<payload>)   // or __aw_wait(fut)
    ()
  }
  Array::get(fut, 1)
```

`Suspend` の payload 帯 (`@vibex/concurrent` の規約 + ADR-0089):

| payload | 意味 |
|---|---|
| 0 | yield |
| 1 | poll wait (retry) |
| 負 | sleep debt |
| handle + 2 | host future の waitable 帯 |
| handle + 2048 | host stream の read 帯 |

**展開は式の位置ではなく spine へ持ち上げる** (`awp_tail`)。`let a = await(x)`
は `let __aw_f = x; while ..; let a = Array::get(__aw_f, 1)` になる。式の位置で
入れ子にすると「ソース構文では書けない形」(`let` の value に `let`+`while`)
が下流パスへ流れ、複数 await でコンパイラが無限再帰する — 実際に踏んだ
(#1230)。

条件は `EBinOp("<")` であって builtin `lt` ではない。evidence migration の
see-through 走査が `lt` を pure callee として知らないため、`while lt(..)` に
すると `await` を含む handle が全部 ineligible になる (実測済み)。

`waiter_hooks` が立つと round は `__aw_wait(fut)` を通り、resolve 側が直接
起こす (O(rounds×awaiters) の解消、§3.15)。notify が漏れても once-per-progress
の fallback valve で poll へ縮退し、deadlock trap は保存される。

#### `Future[T]` と `Spawnable` — region を持たせないという決定

`TaskGroup::spawn` の capture 検査 (`checker_spawnable.vibe` の
`sp_spawnable_ok`) は、`TaskGroup[r]` / `TaskHandle[r,_]` / `Sender[r,_]` /
`Receiver[r,_]` を **同じ nursery の region `r` と一致するときだけ**通す。
`Future[T]` は **region パラメータを持たず、無条件に通す**。

> **決定 (実装済み)**: `Future` に region 引数は足さない。現在の poll モデルでは
> セルは**スケジューラ結合ゼロの共有メモリ**で (await は state slot を再読する
> だけ、resolve は 2 ストア)、guest は single-threaded なので、`Send` が防ぐ
> ような cross-nursery hazard が存在しない。
>
> **再検討の条件**: セルが**スケジューラから見える waiter list** を持った
> 時点で、`Future` は region tag を持ち `sp_same_region` 側の分岐へ移る必要が
> ある。
>
> (#1230 の議論では一度「`Future[r, T]` へ arity を増やす」と記録したが、
> 実装時にこちらを採った。arity を増やしても `Future::pending()` は引数が
> 無いので `r` が fresh 変数のままで spawn サイトの region と結びつかず、
> `Sender` のように `TaskGroup` を引数に取る constructor へ作り替えない限り
> 検査は成立しない — つまり「型引数を 1 本足す」では済まなかった。)

#### suspend lowering の適格性 (ADR-0076)

`await` が `perform` になる以上、await を含むコードは suspend CPS split
(`scps_*`) の適格性に従う。現在の境界:

- **適格**: let / seq / tail / branch-tail の spine、`while` + `let mut`
  (#1230 で widening 済み。`let mut x = v` → 1 要素セル、`while` → `let rec`
  ローカル closure への末尾再帰)、**sequence HEAD に立つ let 連鎖複合式**
  (brace block 文・文位置の async-iterator `for` の脱糖出力 — #1536 (a) v3
  の let-floating が継続 spine へ再バランスする、ADR-0076 追記42)、
  **row-free closure パラメータの呼び出しのうち、全 by-name call site の
  実引数が suspend-inert と証明できるもの** (#1536 (a)。下記)、`if` condition /
  `match` scrutinee が direct target perform・concrete needing call・CPS-local call
  そのものの形 (fresh let へ一回評価してから selection、ADR-0076 追記44)、
  **継続 spine 上の通常代入 (`=`) の RHS が同じ direct 形そのもの** (fresh let
  へ一回評価してから一回だけ代入、追記45)、**`while` condition が同じ direct
  形そのもの** (再帰 loop closure 内で check ごとに一回評価、追記46)、
  **ループ内の `break` / `continue`** (脱出継続を closure に切り出し、transfer を
  CPS spine 上の呼び出しにする、追記47)、**複合式に埋まった suspension**
  (被演算子・呼び出し引数・コンストラクタ引数・compound な `while` 条件・
  `+=` 等の compound assignment — 元の評価順のまま let 連鎖へ線形化する、追記48)、
  **`let` / `let mut` の値そのものである `if` / `match`** (束縛と継続を枝へ分配する。
  condition / scrutinee は元の位置で一回だけ評価され、`match` の腕は継続を移す前に
  alpha-rename される、追記49)、**`let` / `let mut` の値そのものである block**
  (`{ 文..; 値 }` — 束縛を文前置の内側へ移す。float した binder は alpha-rename される、
  追記50。これにより「文を含む枝」が通る)、**代入 (`=`) の RHS が同じ selection / block
  そのもの** (box した target は cellify の前に、spine 外の target は継続 spine 上で、
  同じ 2 つの書き換えを受ける、追記51)
- **不適格**: ループ内 `return`、配列 `for` 形、**必ず評価されるとは限らない位置に
  埋まった suspension** (compound の中にネストした `if` / `match` の枝、
  `&&` / `||` の右辺)、実引数証明が
  成立しない closure パラメータの呼び出し、row 変数 callee (`with e`)。closure
  literal は prepass が literal 自身の spine で step-split し、supported nested
  different-effect handles は既存の handler-ownership lowering を維持するため、
  compound ANF の blanket rejection には含めない

closure param を**無条件に**許すのは不健全 — closure literal 内の `perform`
は「リテラルが置かれた関数の row」に字句的に計上されるので (#761)、「宣言
row が空 ⇒ perform しない」が成り立たない。#1536 (a) の受理はそのため
**実引数フローの証明**に基づく: CPS clone `__scps_cps_E_f` に到達するのは
`f` の by-name call site だけ (値経由の呼び出しは untouched な original を
走る) なので、全 by-name site が当該 slot に suspend-inert な値 — perform を
一切含まず・needing 名を参照せず・不透明 callee を呼ばない closure literal、
または委譲元 fn 自身の同様に証明済みの row-free param (`async_iter_any` →
`async_iter_find` の転送形) — を渡すと証明できた slot に限り、clone 内の
`pred(v)` を plain call として受理する。1 site でも perform する literal を
渡せば slot 全体が taint し、従来どおり `cannot see through` で拒否される
(fixtures/err_effect_closure_param_taint.vibe)。これで `async_iter_find` /
`_any` / `_all` は suspend body から呼べる。`await(Stream::next(s))` は
synthetic retarget (#1536 (a) v2, ADR-0076 追記41) で書けるようになり、
`for` 駆動の terminal (`async_iter_collect` / `_fold` / `_count`) は
let-floating (#1536 (a) v3, 追記42) で書けるようになった。

### 2.3 同期 effect との関係

同期 effect (`handle`/`perform`/`resume`) は evidence-passing で実装されて
おり (#817、replay は全廃)、`Async` もその上に乗る。`Async::Suspend` は
ただの operation で、特別扱いされるのは **payload 帯の意味づけ**と、
`await_poll_pass` がそれを合成する点だけ。同期 effect の意味論は不変。

### 2.4 stream 系の型 — 今 3 つある

north star は **AsyncIter** (`next(Self) -> Future[Option[(T, Self)]]`、
ADR-0089 Decision 3) への一本化だが、**今日の実装には 3 つの表現が併存する**。
混同すると静かに壊れるので、区別を明示する:

| 型 | 実行時表現 | 用途 | 位置づけ |
|---|---|---|---|
| `Stream[T]` | `Array[T]` (eager) | `empty`/`once`/`map`/`filter`/`fold`/`next`、`String::to_bytes`/`Stream::to_string` | **legacy**。ADR-0089 D3 で退役予定 |
| `HostStream` | 2 語セル `[3, handle]` | `host_stream_named`/`host_stream_next`/`host_stream_close` | **generic named-host-stream 専用**の p3 境界実体。stream の readable handle 1本しか保持できず、completion future を伴う provider の所有/lifecycle は表せない (§3.18.3) |
| AsyncIter | trait (`lib/@vibe/prelude/async_iter.vibe`) | `for x in it` の pull protocol | 目標形、host stream とは未接続 |

`host_stream_named` の戻り型が `Stream[Int]` **ではない**のは #1341 の実測に
よる: 同じ静的型だと `for` が array パスを選び、cell の 2 語 (state 3 +
handle) を足して**それらしい小さい数**を返していた (期待 42 に対し 4)。
診断も trap も無い最悪の失敗形だったので、**型で分けた**。今は
`Stream::map` を host stream に適用すると型エラーになる。

`for x in s { ... }` は iterand の型で eager ループか await ループかが決まる。
**`for await` という別綴りは #1350 で廃止** — iteration が suspend しうる
ことは effect row が既に語っており、構文マーカーは二重表現だった。
その `for` 自身が `Async` を要求するかどうかは **iterand の型**から読む
(#1358): `next` が `Future` を返す iterator trait を実装した型、または
`HostStream` なら、囲む row に `Async` が要る。desugar が await ループを
選ぶのと同じビットを見ているので、両者の判定は定義上一致する。

`ByteStream = Stream[Int]` (WASI `stream<u8>` / HTTP body) は現在 legacy 側
に属する。p3 の `stream.read` へ繋ぐのは未着手。

### 2.5 `Task[T]` は撤去済み (#1227)

`Task::spawn`/`join`/`cancel`/`race`/`timeout` は front-end から**撤去済み**で、
書くと `unknown name` になる。`spawn` が thunk を即時実行していたため
`spawn(f); spawn(g)` が常に直列化する — 並行に見えて黙って直列化し、警告も
失敗もしなかったのが理由。

動く並行 surface は `lib/@vibex/concurrent` (`TaskGroup::spawn_suspend` /
`TaskHandle::join` / `sleep_wait`)。公開意味論の source of truth は
[ADR-0068 詳細仕様](../concurrency.md)。真の subtask spawn
(waitable-set / `future.cancel-*`) は M-conc-2 として未着手。

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

1. `async fn` を、suspend point（各 `await` / async `for` の `stream.read`）で
   分割した状態機械関数へ変換。ローカルは線形メモリ上の frame に退避。
2. `await f` は `future.read` を発行し、`BLOCKED` なら `waitable-set.wait` に
   登録して制御を返す。完了時に状態機械を resume。
3. `Stream[T]::next()` は `stream.read`（1 要素ぶん）を `future` 化して返す。
   async `for` はこれを繰り返し、`None`（EOF）で終了。
4. async export（HTTP handler 等）は `task.return` で結果を返し、
   `async-lift` 規約で wasmtime に lift される。

この lowering は `lib/@vibe/compiler/codegen/` に実装する（CLAUDE.md の source-of-truth 方針）。
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
  `-W` フラグ**（M0 で誤記載していた。docs/report も修正）。**正しいフラグ名は
  `component-model-more-async-builtins`（🚝）**で、stream/future の canonical
  built-ins はこれで有効化される（§3.3 の M2c-3 spike で確定）。

検証基盤: 既存 `src/x/cm_async/cm_async_probe.wat`（flag 受理の sync probe）に
加え、本 spike の `cm_async_lift_probe.wat`（async-lift 実動 probe）を追加。

### 3.3 M2c-3 feasibility spike: 真の `stream<u8>` canonical built-ins（landed）

M2c までの `Stream[T]` は eager Array backing（`String::to_bytes` /
`Stream::to_string` / `for` が body を先頭で materialize）。M2c-3 は WASI
0.3 `stream<u8>` の **`stream.read` ベース**へ置き換え、handler が request body
を逐次読み body 全体を保持しない形にする。codegen 着手前に §3.1 と同様、
wasmtime 45 が受理する最小形を手書き probe で確定した
（`src/x/cm_async/cm_stream_read_probe.wat` / `run_stream_probe.sh`、`run` => 42）。

確定事項（wasmtime 45.0.0 / wasm-tools 1.252, x86_64 linux）:

1. **runtime 実行を確認**（parse だけでなく）。`stream.new` は **base M1b フラグ
   のみで実行可**（probe の `run` が `stream.new` を呼び、非ゼロの packed handle
   pair が返れば 42）。一方 **`stream.read` / `stream.write` は
   `-W component-model-more-async-builtins=y`（🚝）が必須**（無いと module が
   parse 失敗）。これで §3.1 の「async-builtins フラグは 45 で無効」を補正
   （正しい名は `more-` 付き）。
2. wasm-tools 1.252 が受理する WAT 形:
   - `(core func $snew (canon stream.new $st))` — lower 後 `[] -> [i64]`
     （readable | writable<<32 の packed end indices）。
   - `(core func $sread (canon stream.read $st (memory $li "memory")))` /
     `stream.write` 同様 — `(param i32 i32 i32) -> i32`（handle, ptr, len → status）。
3. **memory cycle**: read/write の canon は、それらを import する core instance
   と同じ memory を参照できない（instance ↔ canon の循環）。先に別の libc memory
   module を instantiate し、canon は `(memory $li "memory")` を指す。
4. **単一タスクの self write→read は deadlock**: reader 不在の `stream.write` は
   block（stackful suspend）し、同じタスクが唯一の reader 候補のため進まない
   （probe で instantiate→実行→block を確認）。つまり実 `stream.read` には
   **並行 producer**（spawn した subtask、もしくは host 提供の readable end =
   HTTP request body）が必要。この producer 配線が M2c-3 の次スライス。

### 3.3.1 producer 調査: intra-wasm subtask は不可、producer は host（追記）

§3.3 の deadlock を解消する producer を**コンポーネント内の subtask** で用意できるか
を WAT で検証した結果、**この方向は wasmtime 45 では行き止まり**と判明した。確定事項:

- async-lowered cross-component 呼び出しの core ABI を確定:
  `(canon lower (func $f) async (memory $li "memory"))` は core func
  `(param <result-area-ptr>) -> (i32 status)` を生成（同期 lower は param なしで
  結果を直接返す）。`waitable-set.new` / `waitable-set.wait (memory ...)` の
  canon も wasm-tools 1.252 が受理する。
- **しかし async-lifted な親 `run` から別コンポーネント instance の関数を呼ぶと
  `wasm trap: cannot enter component instance` で trap する。これは async 固有
  ではなく、sync 親 → sync 子でも同じく trap する**（component instance の
  reentrance 制約）。つまり「self-stream の writable 端を別 wasm subtask に渡して
  並行に書く」構成は、コンポーネント境界の reentrance 制約に阻まれて成立しない。
- 単一タスク self round-trip は §3.3 の通り deadlock。両 intra-wasm 経路が塞がる。

**設計含意（pivot）**: 実 `stream.read` の producer は **host 側**であるべき。WASI
0.3 の HTTP handler では request body の readable end（`stream<u8>`）を **wasmtime
（host）が供給**し、handler はそれを `stream.read` で読むだけ。host が producer
なので wasm↔wasm の reentrance は発生せず、deadlock もしない。したがって M2c-3 の
codegen は「self stream を作って書いて読む」ではなく、「**import した
`wasi:http` の readable stream を `stream.read` で消費する**」形を直接の目標とする。

実装順（改訂）:
- (a) `component_codegen.vibe` に `stream.read` の canon emit（`(memory ...)`
  option 付き、`more-async-builtins` 前提）と、readable `stream<u8>` を引数に取る
  async import の lower を追加。
- (b) host 供給の readable stream（まずは `wasi:http/types` の incoming-body、
  または最小の host test harness が供給する `stream<u8>`）を `stream.read` ループ
  で Array に読み込み、`for` / `Stream::next` をそのループへ lower。
- (c) gate / probe は host 提供 stream を使う（`--invoke` だけでは host stream を
  供給できないため、wasi:http world での e2e、もしくは host harness を用意する）。

### 3.2 M1b 実装ブループリント（byte-level encoding map）

`cm_async_lift_probe.wat` を `wasm-tools dump` して抽出した、component encoder が
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

最初の縦串 PoC は await 無し（`() -> Int with Async` の body が定数 / 純粋
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
universal な source-compile）に、entry が `() -> Int with Async`（name
"run"、no params）であることを **AST の TyFn effect 注釈から検出**して
`comp_emit_component_wasm_async_trampolined` で包む hook を追加。

**実測（stage1 selfhost compiler、`let run: () -> Int with Async = () -> { 42 }`）**:
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
`let run: () -> Int with Async = () -> { 42 }` をコンパイル → component
（`wasm-tools validate` OK）→ wasmtime 45 で **42 を返す**。M1（async front-end）
〜 M1b（codegen + orchestration）の縦串が `.vibe` ソースから実機実行まで完成。

注: 現状は narrow PoC（entry 名 "run" / `() -> Int` / await 無しで Async
宣言）。`await` 本体の codegen、非 Int 戻り値、param 付き entry、複数 wasi
import（fd_write 以外）、entry 名一般化は後続。

回帰保護: この E2E は `scripts/test_async_component_gate.sh`
（pkf task `test-async-component`、CI gates-shard `cli` shard）に
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
dispatch に lowering を追加した。これにより **await を使う async プログラムが
初めてコンパイル&実行可能**になった（従来は codegen 無しで不可）。gate を
`await(Future::ready(42))` body へ更新し、selfhost → async component →
wasmtime 45 で **42** を実測。

当初は `await`/`Future::ready` を**引数の値そのもの**へ lower する identity
だったが、`Future[T]` を **2要素配列 `[state, payload]`**（`state = 0` が ready、
`future_ready_expr` / `future_state_ready`）に変えた（#1230）。ready しか無い今も
挙動は同じ（`await` は slot 1 を読むだけ）だが、**pending future を後から足すのに
表現を作り直さなくて済む** — M1b-3c は `await` に slot 0 の分岐を生やすだけになる。
future を作る側は `Future::ready` / `Stream::next` / `Stream::fold` の3つで、
`Future[T]` を返す user-level コード（`lib/@vibe/prelude/async_iter.vibe` の
`AsyncIterator::next`）は元から `Future::ready(..)` 経由なので影響しない。
`Stream::fold` はこの変更まで `Array::fold` への名前 alias だったが、戻り値が
`Future[A]` なので専用ブランチに分離した（`Stream::map`/`filter` は `Stream` を
返すので alias のまま）。

さらに `await` の lowering 位置を `compile_call.vibe` から **AST パス
`await_poll_pass`** へ移した（#1230）。`compile_call` は wasm を直接吐く位置で、
`suspend_cps_pass` / `evidence_dict_pass` が走り終わった後なので、pending future
が要る `perform Async::Suspend(..)` を出しても discharge できる相手がいない。
新パスは `desugar_trait_dicts` の直後（= async `for` が `await(..)` を生成した
直後）かつ全 effect パスの**前**に走り、`@vibex/concurrent` の `Receiver::recv_wait`
と同じ suspend-and-retry 形へ **spine に持ち上げて**展開する:

```
let __aw_f_N = <future>
while 0 < Array::get(__aw_f_N, 0) {
  let __aw_w = perform Async::Suspend(1)
  ()
}
let __aw_v_N = Array::get(__aw_f_N, 1)
<await があった式（await は __aw_v_N に置換）>
```

`1` は poll wait（`concurrent.vibe` の payload 規約: 0 = yield / 1 = poll /
負 = sleep debt）。producer が future を解決するときは slot 1 を書いて slot 0 を
クリアする。`await(Future::ready(x))` は `x` へ潰す peephole 付き。

**その場に埋めるのではなく持ち上げるのが要点**: vibe にはブロック式が無いので、
その場展開だと `let a = await(..)` が `ELet(a, ELet(f, .., ESeq(EWhile, ..)), ..)`
という**ソースでは書けない形**になり、1関数内に2つ並んだ時点でコンパイラ自身が
無限再帰した。持ち上げれば合成物は常に let/seq spine 上に載る ―― `scps_split_tail`
（追記36 のループ対応）が同じ理由で最初から取っていた規律と同じ。持ち上げるのは
**無条件に評価される位置**だけで、分岐・ループ本体・closure 本体は自分の spine で
処理する。

fixture は `fixtures/async_await_multi.vibe`（let-value / match scrutinee /
被演算子の各位置に await、want 50）。

**producer**: `Future::pending() -> Future[T]` が state 1（未解決）の future を
作り、`Future::resolve(f, v)` がその場で完了させる（payload を書いてから state を
クリアする ―― 逆順だと awaiter が「ready なのに値がまだ」を観測しうる）。
これで `Future[T]` は ready / pending の両方を作れる。まだ未解決の future を
await する側には continuation を park する driver が要る（in-tree では
`@vibex/concurrent` の `spawn_suspend` の `handle .. with Async`）。fixture
`fixtures/async_future_pending.vibe` は await 前に resolve する形で、表現と
builtin 2本を pin している（スケジューリングは pin していない）。

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

### 3.8 M1b-3c-1b landed — blocking await の codegen（spawn 相当は退化ケースのみ、#1230）

**まず結論の範囲を明確にする（#1240 review で指摘され訂正した）**: 本節が
実証したのは「**host async import を待つ blocking await**を、待機ループを
別関数に括り出した形で emit できる」ことであり、**真の interleaving spawn
（親の処理と並行して走る第2の guest 計算）ができることではない**。後者は
未解決のまま（M-conc-2 / M1b-3c-2 送り）。詳細は本節末尾の「実証範囲の限界」
を参照。

その上で、§3.7 が「self-contained future は subtask spawn ＝最小 async
executor（context.get/set + waitable-set 管理）が必要でより重い」と書いて
いた点については、実機実証（`tools/wasip3_component_probe/spawned_future/`、
wit-bindgen 0.60 の `spawn_local` を使った probe を新規構築し
`wasm-tools dump` でバイト単位に検証）で以下が分かった:

- `wit_bindgen::spawn_local`（guest が「writer subtask を spawn する」ために
  使う API）は canonical-ABI レベルでは**何も残さない**——`futures::stream::
  FuturesUnordered` による純粋な guest 内部の cooperative executor であり、
  `future.new`/`.read`/`.write` を一切呼ばない。writer の結果を `run` に渡す
  `oneshot::channel()` も guest メモリ内だけで完結する ordinary Rust future。
- 実測で増える import/export は `context-get/set`、`waitable-set-poll`、
  `[callback][async-lift]run`。このうち `context.get/set` については、
  wit-bindgen の `async_support.rs` / `subtask.rs` が spawn の有無に関係なく
  無条件に呼んでいるため、**spawn 固有の要件ではなく** wit-bindgen が
  デフォルトで使う **callback 方式**（`[callback]` export 経由で毎 wake
  event に再入する明示的 state machine）由来と考えられる。ただし後述の通り、
  これは「stackful 方式なら interleaving spawn も executor 無しでいける」
  ことの証明にはなっていない。
- 手書き WAT（`spawned_future/component.wat`）で「待機ループを `$writer`
  という**ただの内部 wasm 関数**に分離し、`$run` がそれを呼んで
  `task.return` する」という構造にしても、`stackful/component.wat`
  と全く同じ canon 集合（`task.return`、`[async-lower]<host-import>`、
  `waitable-set.new/.wait/.drop`、`waitable.join`、`subtask.drop`）だけで
  正しく動作する（300ms の genuine suspend を経て 42 を返す、wasmtime 47
  実機確認済み）。

この結果に基づき、`component_codegen.vibe` に
`comp_emit_component_wasm_async_spawned_future`（固定シェイプの
self-contained コンポーネントを合成する emitter。`future.*` 系 canon
emitter は追加していない——emit するシェイプには不要なため）と対応する canon
built-in emitter群（`waitable-set.new/.wait/.drop`、`waitable.join`、
`subtask.drop`、`canon lower ... async`）を実装し、
`scripts/test_spawned_future_component_gate.sh`（probe の Rust host
driver を再利用し、genuine blocking wait を経て 42 を返すことを実行時
確認）で検証した。vibe ソース構文レベルの spawn/future プリミティブの
追加と実 `.vibe` エントリへの配線（`await(x)` を任意のユーザーコードから
このコーデックに繋ぐこと）は別チケット（M1b-3c-2 相当）に委ねる——本節は
M1b-1 と同じ「emitter・byte-exact 検証のみ」フェーズ。

#### 実証範囲の限界（#1240 review で訂正）

Phase B の `$writer` は `$run` が**同期的に呼ぶただの内部 wasm 関数**で
あり、第2の Component-Model task ではない。Phase B の中で並行に走るものは
何も無い。したがって Phase B が示したのは:

> `spawn f; await t` は、**spawn と join の間に観測可能な親の処理が
> 一切無い**退化ケースにおいて、直接呼び出しへコンパイルして正しく動く
> （そのケースでは spawn は意味論的に no-op なので消えてよい）

ということだけである。**真の spawn（親の処理と interleave する第2の guest
計算）が追加機構を要さないことは示していないし、示せない**——stackful
fiber は1本の call chain しか走らせないので、並行な guest 計算には別 task
か guest 側 poll executor のどちらかが要る。Phase A の実測はむしろ逆を
示唆する（`wit_bindgen::spawn_local` は `FuturesUnordered` executor 一式 +
`context.get/set` + `waitable-set.poll` を引き込む）。

つまり現在の lowering の下では、**spawn と join の間に親子間の
handshake や観測可能な処理があると順序が変わるか deadlock する**——
これは linear backend の eager `Task::spawn`（§2.5。**#1227 で撤去済み**）
が抱えていた制限と同じもので、今回それを超えてはいない。真の
interleaving spawn は **M-conc-2 / M1b-3c-2 の未解決事項として残る**。

> **追記（§3.11 で訂正）**: 上段の「並行な guest 計算には別 task か guest 側
> poll executor のどちらかが要る」という推論は **誤りだった**。stackful 方式では
> `waitable-set.wait` の payload[0](どの waitable が発火したか)による完了順
> ディスパッチだけで interleaving が成立する——第2のスタックも
> `context.get/set` も `waitable-set.poll` も要らない。Phase A が見ていた
> `FuturesUnordered` + `context.get/set` は wit-bindgen の **callback 方式**の
> 都合であって interleaving の要件ではなかった。実機反証は §3.11。

### 3.9 M1b-3c-2 landed — async component を production runtime が駆動できるようになった（#1230）

§3.8 までの async component は、**プロジェクト内のどのツールでも動かせなかった**。
`func_wrap_concurrent` な host import を持つ component は素の
`wasmtime --invoke` では deadlock trap する（§3.7 bug #1）ため、
`scripts/test_spawned_future_component_gate.sh` は
`tools/wasip3_component_probe/spawned_future/host/` の**専用 Rust host バイナリ**
を gate 実行時に cargo build して駆動していた（crates.io アクセスが必要）。

M1b-3c-2 でこの driver を production runtime 側に取り込んだ:

- **`runtime/viberun` の wasmtime を 45 → 47.0.2 に bump**し、
  `component-model` / `component-model-async` / `async` feature を有効化した。
  既存の同期 core-module パスは**ソース無改修**で移行できた（API 破壊なし）。
- **component / core module をヘッダで判別**する（`\0asm` の後ろ 4 byte が
  `0d 00 01 00` なら component、`01 00 00 00` なら core module）。component なら
  新設の `run_async_component` に振り分ける。
- `run_async_component` は §3.7 の罠を踏まえ、
  `instantiate_async` + `Store::run_concurrent` + `TypedFunc::call_concurrent`
  の組で駆動する（`call_async` では deadlock trap する）。Engine は同期パスと
  別に建てるが、Config は**共有の `engine_config()` から派生**させ、component/
  concurrency オプションを追加するだけにする——`Config::new()` から作ると
  `max_wasm_stack`（`MOONRUN_WT_WASM_STACK_MB`、既定 64 MiB）が失われ、深い
  再帰を含む guest が core-module パスでは動くのに component パスでだけ
  call-stack exhaustion する（#1242 review）。Store には他の全 store と同じ
  `MOONRUN_WT_MEMORY_MB` limiter を付ける（同 review、当初は付け忘れており
  `--help` が謳う上限が component パスだけ無視されていた）。
- host import `get-async` は**本物に suspend する timer**（`tokio::time::sleep`、
  `wasi:clocks` backing がやるのと同じこと）で実装した。ブロッキングな
  `std::thread::sleep` では await の意味が消えるため使わない
  （core-module 側の `vibe.sleep` import が抱えている制限そのもの）。

gate はこれで probe 専用バイナリへの依存が消え、`viberun <component.wasm>` を
呼ぶだけになった。

#### 副産物: eager-completion パスの実バグを発見・修正

実 host を繋いだことで、**probe の host では原理的に踏めなかったバグ**が出た。
`$writer` の epilogue が `subtask.drop` を**無条件に**呼んでいたが、
async-lowered call が**即座に完了した場合**（status RETURNED が call から直接
返る = §3.8 の `br_if $done` 経路）は **subtask が生成されない**——packed 結果の
handle bit は 0 である。そのため host import が suspend せずに解決した瞬間に
`unknown handle index 0` で trap した。

これは実 host では**ごく普通に起きる**（キャッシュ済みの値、timeout 0、
既にデータが届いている socket read など）。probe の host は常に 300ms 寝るので
blocked パスしか通らず、永久に露見しなかった。

修正は #1240 review の waitable-set leak 修正と同じ形——両 drop を同一の
「blocked パスを通った」フラグでガードする（両リソースは blocked パスの同一
直線コード上で同時に生まれるため、フラグ1つで正しい）。emitter
(`component_codegen.vibe`) と probe WAT の両方に適用済み。gate は
**blocked パス（300ms 実測で suspend/resume を確認）と eager パス（delay 0）の
両方**を検証するようになった。

### 3.10 M1b-3c-3 landed — 本物の並行 await（host 操作が同時に in-flight、#1230）

§3.8 の「実証範囲の限界」で未解決として残した並行性のうち、**片方は既存の
canon 集合だけで到達できる**ことが分かった。まず2つの問いを分離する:

| | 何が並行するか | 必要なもの |
|---|---|---|
| **M1b-3c-1c** | **guest の計算が2本** interleave する | 第2の CM task か guest 側 poll executor。**未解決** |
| **M1b-3c-3（本節）** | guest の計算は1本、待っている **host 操作が複数同時に in-flight** | **何も追加不要** — waitable set に複数 subtask を join する設計そのもの |

後者は `Promise.all` / `join!` の形であり、stackful fiber が1本の call chain
しか走らせないという制約と矛盾しない（guest は1本のまま、待っている相手が
複数になるだけ）。

probe（`tools/wasip3_component_probe/concurrent_awaits/component.wat`）で
実機確認したうえで、`comp_emit_component_wasm_async_concurrent_awaits` として
emitter 化した。**canon 集合は M1b-3c-1b から一切増えていない**
（`task.return`、`[async-lower]get-async`、`waitable-set.new/.wait/.drop`、
`waitable.join`、`subtask.drop`）。並行性を生むのは **操作の順序だけ**——
どちらの async-lowered call も、**どちらかを待ち始める前に発行する**。
「A を発行→A を待つ→B を発行→B を待つ」は同じ命令列・同じ戻り値でありながら
2倍の時間がかかる。

検証は2つ独立に立てた（片方だけでは弱いため）:

- **値**: `run` は 84（= 42 + 42）を返す。各 call が自分専用の結果スロットに
  書くので、片方しか完了しなかった／同じスロットを2回読んだ実装は 42 になり
  落ちる。
- **時間**: host が1呼び出しあたり 300ms suspend する条件で、並行なら ~300ms、
  直列なら ~600ms。両側で挟む（`>= 0.8×` で「本当に suspend した」、
  `< 1.6×` で「直列ではない」）。**並行性を実際に検査しているのはこちら**——
  値チェックは直列実装でも同じように通ってしまう。

実測（`runtime/viberun` 経由、M1b-3c-2 で駆動可能になったもの）:

| delay | 1 call（spawned-future） | 2 calls（concurrent-awaits） |
|---|---|---|
| 300ms | 42 / 310ms | **84 / 312ms** |
| 1000ms | 42 / 1028ms | **84 / 1015ms** |

2本の 1000ms 呼び出しが1本と同じ 1015ms で終わる——スケールは 1× であって
2× ではない。gate は `scripts/test_concurrent_awaits_component_gate.sh`
（`pkf run test-concurrent-awaits-component`）。JIT の cold start（実測 ~200ms）
が並行/直列の判別幅を食うため、計測前に warmup 実行を1回挟んでいる。

**残る未解決は M1b-3c-1c のまま**: 親の処理と interleave する第2の *guest*
計算は、本節の機構では作れない。

### 3.11 M1b-3c-1c — interleaving は ABI 側の追加機構を要さなかった（§3.8 の予測を訂正、#1230）

§3.8 は「真の interleaving spawn には**別 task か guest 側 poll executor の
どちらかが要る**」と書き、根拠として Phase A の実測（`wit_bindgen::spawn_local`
が `FuturesUnordered` executor 一式 + `context.get/set` + `waitable-set.poll`
を引き込む）を挙げていた。**これは誤りだった** ——
`tools/wasip3_component_probe/interleaved_tasks/` で実機反証した。

Phase A が見ていたものは wit-bindgen の **callback 方式**（`[callback]` export
経由で毎 wake event に再入する明示的 state machine）の都合であって、
interleaving 自体の要件ではない。stackful 方式では
`waitable-set.wait` が **payload[0] で「どの waitable が発火したか」を返す**
——完了順ディスパッチに必要なものはそれだけである。

#### probe の設計（偽装できない形にした）

```
  task A   await get-after(300) -> await get-after(300) -> log 1
  task B   await get-after(100)                         -> log 2
```

どちらも「片方を待ち始める前に」発行する。結果は `log[0]*10 + log[1]`。

| | 結果 | 実測時間 | 意味 |
|---|---|---|---|
| `component.wat` | **21** | **613ms** | B の継続が A の途中で走った。合計は **A 自身の 2×300ms** ——B は完全に重なった |
| `serial_control.wat` | **12** | **713ms** | A を最後まで待ってから B。300+300+100 |

タイムライン: t=0 で A の1st と B を発行 → **t=100 で B が解決し B の継続が走る**
（A はまだ1st await 中）→ t=300 で A が state machine を1つ進めて 2nd await を発行
→ t=600 で A の継続。

負の対照（`serial_control.wat`）は同一の canon 集合・同一の値・同一の log
エンコードで順序だけを変えたもので、**値と wall-clock の両方で反対の答えを出す**
ことを gate が確認する（`scripts/test_interleaved_tasks_probe_gate.sh`）——
これが無いと「21 を返す」という assertion が判別的である保証が無い。

#### 確立したこと / 残ること

**確立**: 2つの論理的な guest 計算が、**1本の stackful fiber 上で** await 点で
interleave する。**第2のスタックも `context.get/set` も `waitable-set.poll` も
不要**で、canon 集合は M1b-3c-1b から不変。

**残る**: A が2つの await をまたいで持ち越す状態を、この probe は**メモリ上の
スロットに手で置いた state machine** として書いた。任意の vibe ソースに対して
この変換を行うのが **ADR-0076 の CPS/suspend lowering** そのものである。
つまり M1b-3c-1c の残作業は **ABI 側ではなく codegen 側に局所化された**——
「別 task か poll executor が要る」という §3.8 の前提が消えたぶん、当初の
見積もりより小さい。

emitter（固定シェイプの component 合成）は本節では作っていない——M1b-3c-1a と
同じ「mechanics 実証のみ」フェーズ。実 `.vibe` ソースからこの形へ落とすには
上記の state 表現が先に要る。

### 3.12 ADR-0089 step 2 — `future.*` / `stream.*` canon emitter landed（#1218）

§3.6 の canon 表のうち **`future.new/read/write/drop-readable/drop-writable`
と `stream.new/read/write/drop-readable/drop-writable` を初めて emitter 化**
した（`emit_canon_future_*` / `emit_canon_stream_*` +
`emit_comp_future_type_section` / `emit_comp_stream_type_section` +
固定シェイプ `comp_emit_component_wasm_future_value` /
`comp_emit_component_wasm_stream_value`、gate =
`scripts/test_future_value_component_gate.sh` /
`scripts/test_stream_value_component_gate.sh`)。probe は
`tools/wasip3_component_probe/future_value/component.wat` と
`stream_value/component.wat`（hand-authored、wasmtime 47 実測 42）。

**§3.3 の「self round-trip は deadlock」の回避方法が確定**: M2c-3 spike は
BLOCKING read で producer 不在 → deadlock だったが、**read/write の両方に
`async` canonopt を付けると片側が fiber ではなく waitable として park する**
ため、単一 task が自分自身と rendezvous できる:

```
future.new -> async future.read (BLOCKED)
  -> waitable.join(readable, ws)
  -> async future.write 42   ; pending read があるので copy は即時完了
  -> waitable-set.wait        ; FUTURE_READ (event code 4)
  -> read buffer から値を load -> drop-readable/-writable -> ws.drop
```

実測で pin した encodings（すべて probe が diagnostic 値として報告する形で
検証、trap に頼らない）:

- `future.new` の packed i64 は `(writable << 32) | readable`
  （**readable が下位 32bit**。逆に読むと future.read が wrong-handle で trap）
- async `future.read`/`future.write` の BLOCKED は `0xffffffff`
- pending read に対する write は **call から直接 COMPLETED が返る**
  （§3.9 の eager-completion パスと同じ「即時完了」形。subtask は作られない）
- 完了 event は FUTURE_READ = **4**（payload[0] = readable end index）。
  stream 側は STREAM_READ = **2**、read/write の core sig は
  `(handle, ptr, count) -> status`（future より 1 引数多い）、完了 status は
  `(amount << 4) | code` に pack される
- wasmtime 47 でも future.*/stream.* canon は
  `-W component-model-more-async-builtins=y`（🚝）が必要（§3.3 の 45 での
  観測から不変）。**この component は host import を持たない**ので、
  `func_wrap_concurrent` driver（viberun）不要 — 素の
  `wasmtime --invoke run()` で駆動できる（§3.9 bug #1 の deadlock 条件に
  当たらない）

canon section のバイト形状（`wasm-tools dump` で回収、emitter 各関数の doc
comment にも記載): component 型 `(future u32)` = `65 01 79`、
`future.new` = opcode `0x15` + typeidx、`.read`/`.write` = `0x16`/`0x17` +
typeidx + canonopts（async `06`、memory `03 <idx>`）、
`.drop-readable`/`.drop-writable` = `0x1a`/`0x1b` + typeidx。

これで §3.6 の blocking-await ループの **`future.read` 側の部品が全部
byte-exact で手元に揃った**。残る M1b-3c 系の未着手は「実 `.vibe` ソースの
await をこの経路に配線する」（ADR-0076 の suspend lowering との接続、
ADR-0089 step 3-4）と、host 供給 future を read する形の e2e（host 側
FutureWriter driver が必要 — viberun に future を返す import を足す）。
→ **後者は §3.13 で landed。**

### 3.13 ADR-0089 D2 — host 供給 `future<u32>` の e2e（waitable-set.wait backend 実測、#1218）

§3.12 末尾の残件「host 供給 future を read する e2e」が landed。これは
ADR-0089 Decision 1 の 3-backend 分割のうち **`waitable-set.wait` backend の
初の end-to-end 実測**であり、Decision 2 の「waitable を第3の wait 種として
park する」形が component lowering レベルで実現した:

- **host 側** (`runtime/viberun` `run_async_component`): root import
  `get-future: func() -> future<u32>` を追加。wasmtime 47 に FutureWriter
  型は無く、**producer ベース** — `FutureReader::<u32>::new(store, async {
  tokio::time::sleep(delay); Ok(42) })` が pair を作って readable end を
  即時返し、producer future は guest の read が pending になってから
  event loop に poll される（pull 型だが「writer が delay 後に書く」と
  観測上同一）。delay は `VIBE_ASYNC_GET_DELAY_MS` /
  `VIBE_ASYNC_DELAY_SCALE_PCT` を `get-async` と共有。
- **guest 側** (probe `tools/wasip3_component_probe/host_future_value/
  component.wat` → byte-exact 移植
  `comp_emit_component_wasm_host_future_value` +
  `comp_generate_host_future_value_guest_core_module`):

```
[async-lower]get-future        ; eager RETURNED (code 2) — pair 生成は suspend しない
  -> handle = results buffer から load
  -> async future.read (BLOCKED — producer timer 未発火)
  -> waitable.join(fut, ws) -> waitable-set.wait
       ; ここで task が本当に SUSPEND する。host が timer を回し、
       ; 完了は completion order で FUTURE_READ (4) event として届く
  -> read buffer -> 42 -> drop-readable (writable 側は host 所有) -> ws.drop
```

- **実測**: delay 300ms で `42` を **311ms**（wall clock が genuine
  suspend/wake の証明 — §3.10 と同じ論法）、delay 1ms/50ms でも 42。
  gate = `scripts/test_host_future_value_component_gate.sh`
  （pkf task `test-host-future-value-component`、viberun 駆動 +
  wall-clock ≥ 0.8×delay assert + probe parity）。
- **新しく pin した encodings**: component-level import 型は
  **`func async` が必須**（sync `(func (result (future u32)))` に async
  canonopt を付けると `wasm-tools validate` が "the async canonical option
  requires an async function type" で reject — WIT 上の綴りは
  `func() -> future<u32>` のままで、async は lowering 規約）。async
  functype の result に **defined type index を置く形は `43 00 00 <s33
  idx>`**（primitive valtype byte の位置に正の type index）。import
  externdesc は `00 <name> 01 <functype idx>`
  （`emit_comp_async_functype_section_result_type` /
  `emit_comp_import_section_typed`）。
- **diagnostic 帯域**（task.return 値、trap に頼らない）: 5000+code =
  get-future が eager に完了しなかった / 1000+x = read が BLOCK しなかった /
  3000+ev = wait が FUTURE_READ 以外を返した。

**in-guest scheduler との関係**: `@vibex/concurrent` の pump は linear
backend 上で動き host waitable を持たないため、Suspend payload の
**>= 2 を waitable handle 用に予約**した上で in-guest では poller として
park する（= 完了源が無いので deadlock trap に縮退。yield 扱いだと silent
livelock になる — spawn_suspend arm の判定を `r == 1` から `r >= 1` に変更）。
waitable park 種の実体は本節の component lowering 側にあり、実 `.vibe`
ソースの await をこの経路へ配線する step 4 本体（suspend lowering との接続）
は **§3.14 で landed**。

### 3.14 ADR-0089 step 4 本体 — 実 `.vibe` ソースの await → `waitable-set.wait`（#1218）

§3.13 の残件「実ソースの await をこの経路へ配線する」が landed。以下の
program が selfhost compiler の single-source lane（entry 名 `run`）で
コンパイルされ、**自動で** adapter-backed async component に wrap されて
viberun 上で 42 を返す（producer delay 300ms で実測 ~313ms —
wall clock が genuine park/wake の証明）:

```vibe
let run: () -> Int with Async = () -> {
  let f = host_future_get()
  await(f)
}
```

**lowering チェーン全体**（gate =
`scripts/test_hostfuture_source_component_gate.sh`、pkf task
`test-hostfuture-source-component`）:

1. **surface**: `host_future_get() -> Future[Int]`（pure builtin、
   checker/builtins_async.vibe）。component-level import
   `get-future: func() -> future<u32>` の readable end を Future cell に
   包む。cell は第3の状態 **state 2 = waitable**（`[2, handle]`; 0=ready,
   1=pending に追加）。compile_call が
   `EArray([2, vibe_hf_get_raw()])` に AST lower する。
2. **await**: await_poll_pass が program の `host_future_get` 使用を key に
   拡張形 `__aw_poll` を注入 — loop 内で `__aw_pay(fut)`（state 2 なら
   **`handle + 2`**、それ以外は 1）を計算して `perform
   Async::Suspend(payload)`、resume 値を `__aw_settle(fut, v)` で cell に
   書き戻す（payload 先、state 後 — Future::resolve と同順）。helpers は
   synthesized row-free top-level fn（suspend CPS の spine 制約を満たす
   let-chain 形）。非使用 program の `__aw_poll` はバイト不変。
3. **boundary**: `lc_inject_async_sleep_boundary` の keying を拡張 —
   `host_future_get` を呼ぶ Async-row entry は sleep 無しでも boundary
   handler を得る。arm は synthesized `__entry_settle(q)`:
   `1 < q → vibe_hf_wait_raw(q - 2)` /（sleep machinery 併用時のみ
   `q < 0 → sleep_blocking(-q)`）/ else `assert` trap（poll-wait の
   Suspend(1) は tail-resumptive boundary では従来どおり充足不能）。
   waitable payload は poll-wait と違い **boundary で充足できる**:
   canonical ABI が `waitable-set.wait` の中で task 全体を suspend する
   ので、tail-resumptive arm が block してよい。
4. **host imports**: `vibe.host_future_get () -> i64` /
   `vibe.host_future_wait (i64) -> i64`（builtin_registry の
   `vibe_hf_get_raw`/`vibe_hf_wait_raw`、checker_visible=false)。i64 は
   guest-tagged（内部 Int = value << 1、generic vibe.* call path の規約）。
   **component の adapter module だけが実装を提供する** — plain-wasm host
   に waitable 機構は無いので、`vibe run`（core lane）ではこの program は
   unknown-import で instantiate に失敗する（仕様）。
5. **composition**（`comp_emit_component_wasm_async_hostfuture`、wrap は
   `preprocess_compile.vibe` が core の `vibe.host_future_get` import を
   sniff して p1 shape から自動 route）: buffers は memhost memory に
   置き、値は i64 で渡すため **vfs の shim/fixup 循環が不要** —
   memhost → canon defs（async-lower get-future / future.read /
   drop-readable / task-return(u32) / waitable-set.new/join/wait/drop）→
   adapter（`host_future_get` = lower(8) → RETURNED assert → handle、
   `host_future_wait` = read(fut,0) → BLOCKED なら ws_new/join/wait →
   FUTURE_READ assert → drop-readable → ws_drop → mem[0]、eager 完了も
   同経路で値を返す）→ fd_write stub → main(wasi=stub, vibe=adapter) →
   u32 trampoline（`(i64)->i64` の run を wrap_i64 → task.return）→
   async lift。result は **u32**（viberun の typed driver に合わせる —
   trampolined-p1 の s64 と違う点に注意）。
6. **駆動**: viberun `run_async_component` の既存 `get-future`
   FutureReader import（§3.13）がそのまま producer。

制限（記録）: sleep を併用する component は従来どおり未対応（adapter は
`vibe.sleep` を提供しない — composer が明確な診断で reject）。TaskGroup
（spawn_suspend）との併用は D1 以来の mixing guard が reject。in-guest
pump backend では Suspend(handle+2) は poller 扱い → 完了源が無く
deadlock trap（§3.13 の縮退規則）。

### 3.15 ADR-0089 — resolve → direct wake の waiter list（in-guest poll モデルの最適化、#1218）

§3.13/§3.14 の残件だった「poll モデルの O(rounds×awaiters) 最適化」が
landed。**意味論は不変** — 変わるのは「pump が待ち条件の変わりようがない
poller を毎ラウンド resume して再検査させる」無駄だけで、観測可能な結果・
決定性・deadlock trap はすべて保存される。設計は「wake = 再開可能化」:

1. **データ**（`lib/@vibex/concurrent`）: `TaskCell` に `direct_wait` flag
   と `waiters: Array[TaskCell]`、`Channel` に `waiters`。待つ側
   （`TaskHandle::result_wait` / `Sender::send_wait` / `Receiver::recv_wait`）
   は park 直前に**待ち先へ自分を登録**して `direct_wait` を立て、pump は
   立っている task を skip する。完了側（terminal 遷移 / channel の
   push・take・close）が flag を下ろす = wake。下りた task は通常の
   round-robin で resume され**従来どおり条件を再検査する**ので、spurious
   wake は単なる 1 poll と等価（`TaskHandle::wake` の手動 wake も同じ理由で
   安全なまま）。
2. **自己識別**: suspend payload は Int で cell を運べないため、module
   global `conc_running_stack`（push/pop bracket: spawn_suspend の初回 leg
   と park_kind wrapper の resumed leg）の top が「今走っている task」。
   task 外（entry-level の blocking helper）は stack が空 → 登録 no-op →
   従来の plain poll に自然に縮退する。
3. **builtin future**（resolve → direct wake の本体): compiler hooks
   `__aw_wait(f)` / `__aw_notify_resolve(f)` を library が export し、
   linked lane が「entry が import している dep がこの2名を export して
   いれば **auto-link**」する（ユーザは magic 名を import しない）。
   `await_poll_pass` は両 hook が呼べるとき `__aw_poll` の 1 round を
   `perform Async::Suspend(1)` から `let __aw_w = __aw_wait(fut)`
   （登録 + 同じ Suspend(1)）へ差し替え — **imported concrete-Async-row
   named fn の spine call は recv_wait と同型**なので suspend CPS /
   evidence migration の実証済み機構にそのまま乗る（配線前に手書き mimic
   fixture で実測してから配線）。`Future::resolve` の lowering は
   func_table に notify が居るとき payload/state 書き込みの**後**に
   `__aw_notify_resolve(f)` を追記。future cell の同定は登録時に slot 2 へ
   採番した id（await は slot 0/1 しか読まない）+ parallel-array registry。
   `host_future_get` を使う program は従来の waitable 形が優先
   （hooks 形と排他、boundary 駆動なので in-guest direct wake の出番なし）。
4. **安全弁**（意味論不変の要）: notify 漏れ（resolve が hook 無し unit で
   コンパイルされた等）があっても、pump は「resume できる task が無い」
   とき・pump_all は stall 検出時に、**progress epoch ごとに1回だけ**
   全 `direct_wait` を一括クリアして poll に縮退する
   （`conc_clear_direct_waits` + `TaskGroup.direct_valve_used`、
   `conc_progress` が re-arm）。本当に blocked な task は再登録するので、
   次の stall はこれまでどおり deadlock trap（`conc_require`）。pump_all は
   ループ脱出時に parked task が残っていれば同じく trap — 「pump_all が
   parked を残して静かに return する」新経路は作らない。
5. **sleep との相互作用**: `conc_settle_sleep_debt` は direct-parked task を
   `other_parked` に数えない — 「sleeper が resolve する future を待つ
   awaiter」が仮想時計を堰き止めて force-settle 待ちになる従来の遠回り
   （§3.13 の stall counter 経路）が、直ちに settle される形に改善。

検証: `suspend_test.vibe` に direct-wake 意味論の pin を追加（複数 awaiter
の一斉 wake / 手動 wake の spurious-poll 安全性 / direct-parked consumer +
sleeping producer の clock 非阻塞 / builtin future の複数 awaiter direct
wake）。既存の D2 fixture 群（cross-task resolve、result_wait、channel）は
hooks mode で異なる schedule を通るが観測結果は不変。

### 3.16 ADR-0089 (c) — named host future（host import async の一般化、#1218）

§3.13/§3.14 の host future は**匿名の1本**（component import
`get-future: func() -> future<u32>`）に固定されていた。(c) はこれを
**名前つき N 本**へ一般化する — WIT 由来の async import が「1 import =
1 名前」であることに合わせた形。

```vibe
let run: () -> Int with Async = () -> {
  let a = host_future_named("price")
  let b = host_future_named("qty")
  await(a) + await(b)      // 2本が同時に in-flight
}
```

1. **surface**: `host_future_named: (String) -> Future[Int]`（pure。await
   だけが `Async` を運ぶのは `host_future_get` / `Future::pending` と同じ）。
   引数は **string literal 必須** — component import 名は compile time に
   決まるものであり値ではない。名前は component-model の label 形
   `[a-z][a-z0-9-]*` に制限し、違反は codegen 時の明示エラー
   （`compile_call.vibe`）。
2. **cell**: lowering は `host_future_get` と同一の `[state=2, handle]`
   （waitable cell）。違うのは handle の出どころだけで、`__aw_poll` の
   `Suspend(handle + 2)` 経路・entry boundary の `__entry_settle`・
   `vibe.host_future_wait` はそのまま共有される（park は handle 単位なので
   wait 半分は 1 本で足りる）。
3. **core import**: 名前ごとに `vibe.host_future_get$<name> () -> i64`。
   採番順は「匿名（あれば）→ 名前をソートした順」で、**プログラム内の
   出現順に依存しない**（同じ名前集合なら同じバイト列）。名前付きだけを
   使うプログラムは匿名 `host_future_get` import を持たない。
4. **composer**: `comp_core_host_future_names` が core import 名の列を
   読み、`comp_emit_component_wasm_async_hostfuture` が名前ごとに
   component import `<name>: func() -> future<u32>` + canon lower-async +
   adapter の getter を1組ずつ生成する。`future.read` /
   `future.drop-readable` の canon 定義は**共有**（すべて同じ
   `future<u32>` 型）。名前が1本のときの構造（import 0-6 / func 7,8）は
   step 4 のものと同一で、変わったのは下の eager read だけ。
5. **eager read（並行性の要）**: adapter の getter は pair を作った直後に
   `future.read` を**発行**し、handle ごとの landing slot
   (`HF_VALUE_BASE + handle*4`) と read 状態 (`HF_STATE_BASE + handle*4`:
   1 = blocked / 2 = 即完了) に記録する。`host_future_wait` は再 read せず
   park と回収だけを行う。wasmtime は `FutureReader` の producer を
   「read が pending になってから」しか polling しないため、read を await
   時まで遅らせると2本目の timer が1本目の完了後にしか始まらない —
   実測で 300ms + 100ms が 422ms（逐次）だったものが eager read で
   ~300ms（重畳）になる。
6. **host**: viberun は `VIBE_ASYNC_FUTURES="price=40:300,qty=2:100"` の
   各エントリを root import として link する（値と遅延が名前ごとに違うので
   完了順が観測できる）。

gate = `scripts/test_named_hostfutures_component_gate.sh`（pkf task
`test-named-hostfutures-component`）: WIT に `price` / `qty` が現れ匿名
`get-future` が現れないこと、値 42 = 40 + 2（各 await が自分の future に
settle）、wall が `0.8×P` 以上かつ `0.9×(P+Q)` 未満（park している かつ
2本が**重なっている** = 逐次実行ではない）、および単一名 program が他方の
名前を import しない control。byte level は `component_codegen_test.vibe` の
2-name composition テスト。

### 3.17 ADR-0089 Decision 3 — host 供給 `stream<u8>` の終端 probe（#1218）

Decision 3（AsyncIter/ByteStream の p3 接続）の emitter を書く前に、
**推測できない runtime の事実**が1つある: guest が host 供給の
`stream<u8>` を1バイトずつ読んでいったとき、**stream の終わりがどう
報告されるか**。`stream.read` は `(amount << 4) | code` を packed status
で返すが、どの code が「writer は居なくなった、もう来ない」を意味するかは
仕様書からではなく実測で決めるべきもの（§3.12/§3.13 の probe → byte-exact
移植という手順と同じ）。

**probe**: `tools/wasip3_component_probe/host_stream_value/component.wat`。
`body: func() -> stream<u8>` を import し（host 側は viberun の
`VIBE_ASYNC_STREAMS="body=10|15|17"`、producer は wasmtime 自身の
`Vec<u8>` StreamProducer なので**runtime の挙動**を測っている）、1バイト
ずつ読んで合計を返す。

**実測（wasmtime 47.0.2、2026-08-02）**:

- 3回の1バイト read はいずれも 1 item を転送する
- **4回目の read が `amount = 0` / `code = 1` を返す** = 終端。
  待つべき別の「closed」イベントは無く、**writer が居なくなったことを
  見つけた read がその場で inline に報告する**
- 合計 42（= 10 + 15 + 17）が返るので、終端の前にバイトが本当に届いて
  いることも同時に確認できている

つまり reader 側の終端判定は `(status >> 4) == 0 && (status & 0xf) == 1`。
gate = `scripts/test_host_stream_value_probe_gate.sh`（pkf task
`test-host-stream-value-probe`）が 42 を pin しているので、wasmtime の
bump で encoding が変わったら「終わらない reader」ではなく gate failure に
なる。

**このスライスで landed したのはここまで**（probe + viberun の host stream
import + gate）。残りの Decision 3 = guest surface
（`host_stream_named(name) -> ByteStream` / `ByteStream::next(s) -> Int
with Async`）、`Suspend` の stream 帯と entry boundary の settle arm、
per-name `stream<u8>` component import を出す composer、AsyncIter/`for await`
への接続。設計は §3.16 の named host futures と同型で、park が「future 1本
ごと」から「read 1回ごと」に変わる点だけが違う。
→ **guest surface / stream 帯 / composer は §3.18 で landed**。`for await`
という別綴りは **#1350 で削除済み** — iteration の suspend 可能性は effect
row（`with Async`）が既に語っており、構文レベルの `await` マーカーは
二重表現だったため、素の `for` に一本化した（同期/非同期の選択は iterand の
型だけで決まる）。**`for` からの消費は #1341 で landed**（§3.18.2）。残るは
一般 `Stream::next`（`Future[Option[T]]` protocol）と eager `Stream[T]`
combinator の退役。

**追加実測（2026-08-02、per-byte delay producer 追加後）** — viberun の
`VIBE_ASYNC_STREAMS="body=10|15|17@60"`（`@delay_ms` = 1バイトごとに遅延
する custom StreamProducer）で BLOCKED → park 経路を初めて実走させたところ、
runtime 事実が2つ増えた:

1. **park 後の set 解体は unjoin が先**。join したままの waitable-set を
   `waitable-set.drop` すると `resource has children` で trap する。
   `waitable.join(handle, 0)`（set 0 = remove）で外してから drop する。
   Vec producer では read が一度も BLOCK しないため、probe 自身の
   「join したまま drop」がこの日まで latent だった。
2. **終端は最終バイトと INLINE でも届く**。1 item ずつ渡して drop する
   producer では最後の read が `amount 1 / code 1`(バイト + CLOSED 同時)
   を返し、その後にもう一度 read すると
   `cannot read after being notified that the writable end dropped` で
   trap する。つまり終端は「別 read の `amount 0 / code 1`」(buffered
   producer)と「最終バイト同梱の `code 1`」(per-item producer)の
   **2形状**あり、reader は両方を扱わなければならない。

probe gate は no-delay run(分離終端)+ delayed run(inline 終端 + wall
clock 下限 = park の実在)の両方を pin する。adapter 側の反映は §3.18 の
5 を参照。

### 3.18 ADR-0089 Decision 3 — named host stream（実ソースの stream 読み、#1218）

§3.17 の終端実測を受けた本体スライス。次の実ソースが single-source lane
（entry 名 `run`）でコンパイルされ、自動で adapter-backed async component に
wrap され、viberun（`VIBE_ASYNC_STREAMS="body=10|15|17"`）上で **42** を
返す:

```vibe skip
// doctest-skip: needs an Async-row entry + component adapter; not runnable standalone
let run: () -> Int with Async = () -> {
  let s = host_stream_named("body")
  let mut sum = 0
  let mut b = host_stream_next(s)
  while 0 <= b {
    sum = sum + b
    b = host_stream_next(s)
  }
  sum
}
```

lowering は §3.16 の named host futures と同型で、park が「future 1本ごと」
から「read 1回ごと」に変わる:

1. **surface**: `host_stream_named: (String) -> HostStream`（pure。名前は
   §3.16 と同じ string-literal + component-label 検証）と
   `host_stream_next: (HostStream) -> Int with Async`（次の byte 0-255、writer
   が居なくなったら -1。以後の read は cell 側で latch されて -1 のまま）。
   §3.17 の予告した `ByteStream::next` ではなく `host_stream_next` の綴りに
   したのは、eager な `Stream[Int]`（`String::to_bytes` 等）と表現が異なる
   ため — AsyncIter への統一は Decision 4 の boundary 規則と合わせて別
   スライス。
2. **cell**: `[state 3, handle]`（state 3 = host stream。future cell の
   0/1/2 と不交なので取り違えは構造的に起きない）。生成は
   `vibe_hs_get_raw$<name>` → core import `vibe.host_stream_get$<name>`。
3. **read = Suspend の stream 帯**: `host_stream_next(..)` 呼び出しは
   boundary machinery が注入 fn `__hs_next` に retarget する
   （sleep→`__slp_perform` と同じ shadow-aware rename）。`__hs_next` は
   state 3 のとき `perform Async::Suspend(handle + 2048)` — **予約 stream
   帯 [2048, 3071]**（future 帯は handle + 2 = [2, 1025]、adapter が
   handle ≤ 1023 を enforce するので帯は構成的に不交）。resume 値を
   row-free `__hs_fin` が処理する: v < 0 なら cell を閉じて（state 3 → 0）
   -1、それ以外は byte をそのまま返す。
4. **boundary**: `__entry_settle` に stream arm が増える
   （`2047 < q → vibe_hs_read_raw(q - 2048)`、hs machinery が発火した
   program のみ — future-only / sleep-only の boundary はバイト不変）。
   machinery keying は hf と同じ entry-row-keyed（user の
   `handle ... with Async` 下では in-guest scheduler の poller 縮退 =
   deadlock trap、§3.13）。
5. **adapter**: 共有 `host_stream_read (i64) -> i64` — `stream.read(h,
   slot, 1)` を発行し、BLOCKED なら waitable-set.wait で park
   （STREAM_READ = 2 のみ受理）、**wake 後は unjoin
   （`waitable.join(h, 0)`）してから set を drop**（さもないと
   `resource has children` trap — §3.17 追加実測 1）。終端は2形状
   （§3.17 追加実測 2）: zero-transfer status は code 1 = CLOSED のみ
   受理して `stream.drop-readable` 後に -1、**最終バイト同梱の CLOSED**
   （`amount 1 / code 1`）は per-handle closed latch
   （`comp_hs_closed_base()`、handle*4）を立ててバイトを返し、次の read が
   「latch クリア + drop-readable + -1」を一括で行う — drop まで handle
   index は再利用されないので latch が別 stream に aliasing する窓は
   構造的に無い。それ以外の zero-transfer code は loud trap。**future の
   eager read はしない** — park が read 単位なので、呼び出し間に pending
   read を残すと次の read と衝突する（double-read）。per-name getter は
   pair 生成 + handle 返し（+ latch の防御的クリア）だけ。
6. **composer**: `vibe.host_stream_get$<name>` sniff で wrap を key
   （future と OR）。per-name component import `<name>: func() ->
   stream<u8>` + 共有 `stream.read`/`stream.drop-readable` canon pair。
   future と stream の混在 program は 1 つの adapter / composition を共有し
   （`price: future<u32>` と `body: stream<u8>` が同じ WIT に並ぶ）、
   **hf-only の component 出力はバイト不変**。

gate = `scripts/test_named_hoststreams_component_gate.sh`（pkf task
`test-named-hoststreams-component`）: stream lane（上の while program が
42 = 10+15+17、WIT に `body: ... stream<u8>`、`get-future` 無し）+
**delayed lane**（`body=10|15|17@60` — 各 read が BLOCKED → park する経路と
inline 終端を実走、42 + wall ≥ 0.8×3×delay で park の実在を pin）+ mixed
lane（future 30 + stream 5+7 = 42、両 import が WIT に出る）。byte level は
`component_codegen_test.vibe` の stream-only / mixed composition テスト。
検証済みの consume 形: 直列 let 読み、while ループ、自己再帰、EOS 後の
再読（latch で -1）。

#### 3.18.2 `for b in <host stream>` — 表現の分離と読み出しへの接続（done, #1341）

D3 の「AsyncIter への接続」の最初のスライス。**着手前に測った事実が設計を
決めた**:

```vibe skip
let run: () -> Int with Async = () -> {
  let s = host_stream_named("body")
  let mut sum = 0
  for b in s { sum = sum + b }
  sum
}
```

これは **エラーにならず 4 を返していた**（`VIBE_ASYNC_STREAMS="body=10|15|17"`、
期待値 42）。原因は型ではなく**表現の衝突**である: `host_stream_named` の
戻り型は `Stream[Int]` で、これは eager な配列バックの stream と同一の静的型
だった。ところが実行時表現は非互換で、eager 側は要素の配列、host stream 側は
2語の cell `[state, handle]`。`for` は静的型しか見ないので array ループを選び、
cell の2語（state 3 + handle 1）を足していた。**診断も trap も出ない、
それらしい小さい数**という最悪の失敗形。

したがって修正は「`for` に host stream 対応を足す」ではなく、まず
**表現ごとに別の名前型を与える**こと:

- `host_stream_named(name) -> HostStream`（`Stream[Int]` ではない）
- `host_stream_next(HostStream) -> Int with Async`
- `host_stream_close(HostStream) -> Unit`

これで eager 用の `Stream::map` / `Stream::fold` / `Stream::to_string` を
host stream に適用するのは**型エラー**になり、静かなゴミではなくなる。

その上で desugar（`build_host_stream_for`, desugar_trait_dict.vibe）が
`for` を read へ落とす:

```vibe skip
let __hs_src = <iter>
let mut __hs_b = host_stream_next(__hs_src)
while 0 <= __hs_b {
  let <name> = __hs_b
  <body>
  __hs_b = host_stream_next(__hs_src)
}
```

これは §3.18 の gate が #1339 以来走らせてきた手書き while ループそのもの
なので、**新しい codegen は無い — 表面だけ**。AsyncIter protocol
（`next -> Future[Option[(T, Self)]]`）は経由しない: host stream の read
primitive はスカラの `host_stream_next` であり、protocol を挟むと
`Future[Option[...]]` の割り当てを1バイトごとに行うことになる。

**index binding は非対応**（`for b, i in s`）。read 回数を数えることになるが、
byte offset は再走査可能なコレクションの位置とは別物なので、それらしい誤った
意味を与えるより未対応のままにした。

row 要求は #1358 と同じ理由で必要（read ごとに park する）。`HostStream` は
AsyncIterator の impl を持たないので、`afe_async_iterand`（checker_effects）に
明示の分岐を置いた。回帰ロックは
`scripts/test_named_hoststreams_component_gate.sh` の `for` lane —
while ループと同じ 42 を返すこと、および `{ Async }` の無い row で
**reject されること**の両方を pin する。

**projection（Codex review on #1369 で修正）**: 当初この routing は
identifier と直接の `host_stream_named(..)` 呼び出しにしか効かず、
`for b in h.s`（struct field 経由）は 42 ではなく 4 を返していた。原因は
**両方の pass に struct の field 型が無かった**こと — desugar の
`struct_sets` は field 名だけを持ち、async effect pass も同様だった。
両者に `Struct.field -> 型名` の表を持たせて解消した:

- desugar: `collect_struct_field_types` が `fn_returns` に予約キー
  (`struct_field_type_key`, `.` は識別子に現れないので衝突しない) で相乗り。
  `infer_arg_type_name` の `EDot` arm がそれを引く。**sort の前に push する
  必要がある** — この表は binary search されるので、後から append しても
  見えない（最初の実装はこれを踏み、seeding を別の collector に置いてしまい
  無効だった）。
- checker_effects: 同じ表を module cell で持ち、`afe_expr_head_name` の
  `EDot` arm が引く。これが無いと desugar だけが await ループを組み立て、
  row 無しで park できてしまう（#1358 が塞いだ穴の別ルート）。

副産物として `let s = h.s; for b in s` も通る（`extend_var_types` が
`infer_arg_type_name` を通すため）。回帰ロックは gate の projected `for`
lane（bytes を読むこと + `{ Async }` 無しの row が reject されること）。

**#1538 の boundary slice（done）**: `HostStream` は routing key であると同時に、
**legacy `Stream[T]` consumer への入力では barrier** である。checker は
`HostStream` を期待する `Stream[T]` に渡すと型エラーにするので、
`Stream::map` / `Stream::fold` / `Stream::to_string` と、同じ型を受け取る
ユーザー定義関数は state-3 cell を eager array として読めない。この判定は
この二つの compiler-owned nominal name にだけ閉じており、`CtNamed` 全体の
concreteness や通常の user-defined/generic nominal assignability は広げない。

任意の非 `Stream[T]` parameter（例えば `take_int(s)`）に `HostStream` を渡す
ことまでを拒否する一般 nominal barrier ではない。その横断的な型検査強化は
別作業のままにする。この狭い fail-closed boundary は generic `HostStream` と
legacy eager `Stream[T]` の誤交差を防ぐ一般安全策であり、#1539 の provider
lifecycle を実装した証拠ではない。#1539 の既存 `stdin_stream` は
`Stdin` authority を持つ `Option[String]` pull closure で、§3.18.3 の ratified
stdin route は別の provider-aware lifecycle を必要とする。

**残り**: 一般 `Stream::next`（`Future[Option[T]]`）を host read へ落とす件は
まだ。実測では `await(Stream::next(s))` は ADR-0076 の evidence-passing
migration に弾かれて**コンパイルすら通らない**（"the site is not eligible
for evidence-passing migration"）ので、これは D3 の接続作業ではなく
suspend lowering 側の適格性の話。eager `Stream[T]` combinator の退役も別途。

#### 3.18.1 `host_stream_close` — 部分消費した stream の明示解放（done）

§3.18 が follow-up として残していた制限（途中で読むのをやめた stream の
readable end を解放する surface が無い）を埋めたスライス。read 半分は EOS に
到達したときだけ drop するので、それ以前に読むのをやめた handle は component
instance の寿命まで残っていた。

surface は `host_stream_close: (HostStream) -> Unit`。**`Async` は付かない** —
`stream.drop-readable` は block しない canon call なので park も予約帯も
boundary settle arm も要らず、注入 fn `__hs_close` が adapter を直接呼ぶ。

```vibe skip
// doctest-skip: needs an Async-row entry + component adapter; not runnable standalone
let run: () -> Int with Async = () -> {
  let s = host_stream_named("body")
  let a = host_stream_next(s)
  let b = host_stream_next(s)
  host_stream_close(s)          // 残りは読まない
  host_stream_close(s)          // 二重 close は no-op
  let after = host_stream_next(s)  // close 後の read は -1
  a + b + (after + 1)
}
```

冪等性は **cell の state word が担保する**（飾りではなく load-bearing:
1つの handle に `stream.drop-readable` を2回投げると host 側で trap する）。
`__hs_close` は state 3 のときだけ drop し、同じ step で cell を閉じる
(3 → 0) ので、2回目の close も close 後の read も adapter には届かない。
inline-terminal read が立てた CLOSED latch も同時にクリアする — その drop が
まさに latch の待っていた settle なので。

**gating on use（byte 互換の要）**: `__hs_close` は source が実際に
`host_stream_close` を呼んだときだけ注入される。`vibe_hs_close_raw` を参照する
のはこの注入 fn だけで、import はその名前の使用で gate されるため、無条件に
注入すると **drain するだけの program にも close import と adapter func が
生えて**、既に pin されている stream composition のバイトが動く。adapter 側の
close func も同じ sniff（guest が `vibe.host_stream_close` を import するか）で
gate し、**func list の最後に append** するので既存 index は不変。

gate lane = `test_named_hoststreams_component_gate.sh` の close lane
（5 bytes 中 2 bytes だけ読んで close → 再 close → close 後 read で 42、
かつ drain-only component に close import が無いこと + closing component に
guest import と adapter export が両方あることを .wat で確認）。

### 3.18.3 #1539 — `wasi:cli/stdin@0.3.0` lifecycle measurement and shadow provider prerequisite

`tools/wasip3_component_probe/stdin_read_via_stream/component.wat` retains the
ratified `wasi:cli/stdin@0.3.0` result type
`tuple<stream<u8>, future<result<_, error-code>>>`, including the nominal
`wasi:cli/types@0.3.0/error-code` alias. It also retains the preview-2
`wasi:cli/run@0.2.12` command export. Thus an error result cannot be silently
accepted as a representation-compatible non-nominal value.

**Measured on pinned wasmtime 47.0.2:** with binary stdin `10,15,17`, `drain`
performs canonical async `stream.read` calls for each byte, observes the
separate zero-item EOF status, drops the readable stream, and awaits canonical
`future.read` completion success; it returns `42`. `drop` obtains the same
pair, drops its readable stream immediately, awaits completion success, and
returns `43`. BLOCKED stream/future reads use `waitable-set.new`,
`waitable.join`, and `waitable-set.wait`; the end is unjoined before its set is
dropped. Other statuses, events, byte values, EOF forms, and result tags are
diagnostic return paths, not success.

`bash scripts/test_wasi_cli_stdin_p3_probe_gate.sh` is the merged executable
probe/gate for this measurement. The generated shadow is validated by
`bash scripts/test_wasi_cli_stdin_provider_component_gate.sh`; phase C of
`scripts/test_wasi_p3_guarantee_gate.sh` (`pkf run test-wasi-p3`) invokes both.
It parses, validates, and prints the component, generates deterministic binary
input, and executes both async-lifted lanes. Required mode requires exactly
wasmtime 47.0.2; missing tools, an unpinned provider, and
ABI/type/link/command-export failures fail closed. The default local mode skips
unavailable tools or an unpinned provider. The aggregate remains outside
`ci-required`.

#### Why the current `HostStream` ABI cannot represent stdin

The current generic `HostStream` cell is exactly `[3, handle]`: one readable
`stream<u8>` handle identified by a named host-stream getter. It has no slot
for another owned resource, no provider identity, and its
`host_stream_named("name")` import is modeled as a getter for that one stream.
It is therefore correct for the generic named-host-stream contract in §3.18,
but it is not a lossless carrier for stdin.

`wasi:cli/stdin@0.3.0::read-via-stream` is instead a **synchronous
acquisition** which returns **two separately owned readable handles** in one
result: the readable byte stream and the readable completion future. The latter
settles the stdin lifecycle after the stream is drained or dropped. Replacing
that call with `host_stream_named("stdin")` would discard the completion handle
at acquisition, make its ownership unrepresentable, and make lifecycle failure
invisible. It must not be treated as an alias or special name of the generic
HostStream ABI.

In particular, `stream.drop-readable` releases only the stream resource. It
does **not** by itself complete the stdin lifecycle: the completion future must
still be read, its result checked, and then released. This corrects the stale
short-hand that described stream drop alone as a completed stdin close.

#### Provider-aware contract (shadow lifecycle + atomic public source route)

The #1539 prerequisite is a distinct, opaque provider-aware handle whose
adapter state retains both owned ends from `read-via-stream`:

```text
acquire stdin provider (sync, Stdin authority)
  -> opaque stdin-provider handle { readable-stream, completion-future, state }
read opaque handle -> byte | EOF                  with Async
close opaque handle -> lifecycle-complete result  with Async
```

The compiler now exposes this contract through one unforgeable nominal scalar:

```text
Stdin::read_via_stream() -> StdinStream with Stdin
StdinStream::next(StdinStream) -> Int with Async
StdinStream::close(StdinStream) -> Unit with Async
StdinStream::read_chunk(StdinStream, Int) -> Option[String] with Async
```

`StdinStream` is neither `Int`, generic `HostStream`, nor `Stream[T]`; source
cannot construct it and it is not `Send`. The four public provider builtins are
**direct-call-only**: any value-position reference (local/top-level alias,
chain, compound/container/field, returned value, or unknown HOF transport) is a
checker error. A user-defined wrapper with an explicit `Stdin` or `Async` row is
an ordinary function and may be passed as a value under the existing effect
rules. This deliberately does not add the generic higher-order effect-flow
propagation deferred by #1536. Their observable authority and effect
requirements are fixed as follows:

- Acquisition is synchronous but requires `Stdin` authority. It calls
  `read-via-stream` once and transfers ownership of **both** returned readable
  handles into the opaque provider state.
- Reads require `Async` because canonical `stream.read` may block. They retain
  the existing byte/EOF behavior only after the provider adapter has performed
  the required read/wait/unjoin work.
- EOF and early close both require `Async`: each must release the stream end,
  await the completion future, validate success, and release the future end.
  Therefore lifecycle-complete close cannot be a synchronous operation.
- A completion `error-code` is fail-closed. There is no approved public
  `Stdin`/`Exception`/`Result` mapping yet; an adapter must not turn it into
  EOF, success, a generic integer, or a legacy `Option` value.
- `read_chunk(stream, n)` is a direct compiler-owned, use-gated operation with
  `Async`. For positive `n`, it reads one provider byte at a time and returns
  exactly `n` bytes except for the final short chunk. Bytes are validated as
  `0..255` and appended through one-byte `String::from_char_code`, without
  UTF-8 expansion. It does not promise to preserve internal provider read
  boundaries. EOF settles before `None`; subsequent calls return `None`. An
  exact multiple needs one extra call to observe EOF. For `n <= 0`, it returns
  `None` without reading or settling, so the caller must close the stream.
  Early stopping likewise requires explicit, idempotent `close`. A pull
  closure/direct-`for` adapter remains blocked on transitive higher-order
  effect evidence (#1536) and is not part of this surface.

The existing `host_stream_close(HostStream) -> Unit` is deliberately
synchronous and only drops its one generic stream handle (§3.18.1). It cannot
wait for or validate a missing completion future, so it **cannot safely
implement** provider stdin close. Reusing it would either leak/unjoin the
future or silently report a failed lifecycle as a successful close.

#### Staged prerequisite and invariants

Stages 1--3 were first implemented by the production-unused shadow emitter
`comp_emit_component_wasm_stdin_provider_shadow` and its private component
scenarios. #1539 now also has a bounded **core-only** route: `linked_compile`
reserves checker-invisible raw rows for exact core imports
`vibe.stdin_provider_acquire () -> i64`, `stdin_provider_read (i64) -> i64`,
and `stdin_provider_close (i64) -> i64`; the stdin-first wrapper sniffs parsed
module/name pairs and the dedicated arbitrary-core composer validates exact
signatures before composing the nominal stdin/types imports.

The guest receives only a tagged-i64 bridge instance. The bridge rejects odd
or high-bit-aliased wire IDs before i32 narrowing, and only then calls the
proven opaque lifecycle functions. The full shadow instance, scenario exports,
canonical stream handle, and completion-future handle never cross into the
compiled guest. The bridge ABI is `wire = value << 1`; read returns tagged
bytes or tagged `-1` after settlement and close returns tagged zero.

The three raw registry rows remain `checker_visible=false`. Exact direct calls
lower through compiler-owned ABI wrappers to those imports; the `read_chunk`
wrapper additionally implements repeated hidden raw reads. Public operation
values never reach codegen because the checker rejects them. Source
emits only the exact `vibe.stdin_provider_*` core imports and the nominal
`wasi:cli/types@0.3.0` + `wasi:cli/stdin@0.3.0` component imports.

`stdin_stream`, generic HostStream, and named future/stream behavior remain
unchanged. `host_stream_named("stdin")` is reserved and rejected. A source core
that mixes stdin-provider imports with named future/stream imports is explicitly
rejected in this bounded slice. GC and standalone/non-Async-entry compilation
are also rejected explicitly; linear and RC component lanes are supported.

The provider permits multiple active acquisitions. Adapter IDs allocate
monotonically from 16 slots and are never recycled: capacity overflow traps
before another canonical acquisition, while concurrent/reentrant use of the
same open slot traps on its non-open phase. Successful EOF/close remains
idempotent through aliases. Wasmtime 47 source gates measure drain, early close,
function aliases, a sequential second acquisition, and two simultaneously open
acquisitions.

Load-bearing invariants for stages 1--3:

- Each successful acquisition owns exactly one stream end and one
  completion-future end; up to 16 acquisitions may coexist, and neither end may
  escape as a generic `[3, handle]` HostStream.
- EOF and early close converge on one settlement state machine. Once settlement
  begins, subsequent reads/closes are idempotent at the opaque-handle boundary
  and cannot issue a second drop, read, join, or unjoin.
- Every successful join has exactly one unjoin before its waitable set is
  dropped. Each stream/future readable end is dropped exactly once, including
  all diagnostic/failure exits.
- A completion error, unexpected status, or unexpected event is a failing
  transition, never EOF or successful close. Public propagation remains
  intentionally undecided and fail-closed.

The synthetic compiled-shaped drain and early-close cores are composed and
validated by `test_wasi_cli_stdin_provider_guest_component_gate.sh`; they check
bytes 10/15/17, EOF/repeated reads, early settlement, and repeated close on the
pinned Wasmtime 47.0.2 lane. The original shadow gate and exact 208-byte nominal
prefix remain separately preserved.

This is only the successful-close lifecycle slice. **Read-error injection is
unmeasured** (`io`, `illegal-byte-sequence`, and `pipe` have no claimed runtime
measurement). The forced completion-tag, wrong-byte, and extra-byte
expected-trap scenarios are controls of cleanup/fail-closed branches, not
measurements of provider-generated errors. Each byte-mismatch control settles
and drops both owned ends through the shared close path before trapping. Those
shadow-scenario controls introduced no API by themselves; the production
checker-visible `StdinStream` source/console API is the surface documented in
§3.18.3 above.

### 3.19 ADR-0089 Decision 3 — `wasi:http` incoming-body の実 provider 配線（未着手 / 設計）

§3.18 + §3.18.1 の host stream は **viberun の test provider**
（`VIBE_ASYNC_STREAMS="body=10|15|17"`、wasmtime 自身の `Vec<u8>`
StreamProducer）を相手に実測されている。production の相手 —
`wasi:http` の incoming request body — に繋ぐのが D3 の残件だが、これは
「provider を差し替える」配線作業では**ない**。以下が実測した構造的な壁。

**現状、serve 経路と host-stream 経路は互いに素な2つの composition である**:

| | serve 経路 | host-stream 経路 |
|---|---|---|
| emitter | `comp_emit_component_wasm_string_handler`（`VIBE_SERVE_COMPONENT=1`） | `comp_emit_component_wasm_async_hostfuture` |
| guest surface | `handler(method, url, headers, body: String) -> String` | `host_stream_named(name) -> HostStream` |
| body の扱い | full adapter が **materialize** する（`Request::consume_body` + `StreamReader::collect` → String） | 生の `stream<u8>` を per-name component import として受ける |
| compose | `wac plug`（adapter component + guest） | 自前の core module 合成（adapter core module を同梱） |

つまり body は guest に届く時点で既に String に潰れており、`stream<u8>` は
adapter の内部で消費し終わっている。`host_stream_named("body")` が
production で意味を持つには:

1. **full adapter が body を materialize せず export する**:
   `world adapter` に `export body: func() -> stream<u8>;` を足し、
   `Request::consume_body` の `StreamReader` を collect せずそのまま返す
   （handler import 側は `body: string` 引数を落とす）。adapter は request
   ごとの reader を持ち回る必要がある。
2. **serve emitter が host-stream machinery を積んだ component を出す**:
   string-handler trampoline を export しつつ `body: func() -> stream<u8>`
   を import し、hoststream adapter core module を同梱する — 現在の2つの
   emitter の**合流**であって、どちらかの拡張ではない。
3. **compose が2辺になる**: `wac plug` が handler 辺に加えて body 辺も繋ぐ。

検証には `wasmtime serve` + curl が要る（既存の
`test_wasi_http_p3_full_gate.sh` と同じ tooling 前提、不在時 skip）。

この3点は独立に着手できず、2 が 1 と 3 の両方に依存する。**「incoming-body
provider を配線する」ではなく「serve composition と host-stream composition を
統合する」スライスとして起票し直すのが正しい**（現状の見積もりを
「配線」と書くと規模を誤らせる）。

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
`test-wasi-http-p3-full`、CI gates-shard cli shard、serve+curl で検証、
tooling 不在時 skip）。

**確立できた point**:
- serve フラグ（wasmtime 45）: `-Sp3 -Shttp -W exceptions=y -W
  concurrency-support=y -W component-model-async=y
  -W component-model-async-stackful=y`。旧 P3 スクリプトの
  `-W component-model-async-builtins=y` は **wasmtime 45 で無効**（reject）だった。
- handler 戻り値の status untag は不要: vibe `Int`/`String` は default 経路で
  **raw**（untag 済み）で component 境界を渡る。

**#537 で selfhost 経路化済み（2026-07）**: handler の componentize は selfhost
compiler の `VIBE_SERVE_COMPONENT=1`（packed-string trampoline、
`comp_emit_component_wasm_string_handler`、`(offset<<32)|len` の現行 string ABI
に一致）に置き換え、compose は `wac plug`、起動は `runtime/vibe serve`。
legacy `vibe.exe --compose-p3` 依存は解消（gate:
`test_wasi_http_p3_full_gate.sh` selfhost 版）。effect→WIT surface は
[../effect-wit-mapping.md](../effect-wit-mapping.md)。

**未解決（architectural）**:
- clean な `-> tuple<s64, string>` 返却は不可: string-lift trampoline が
  **single-value 返却のみ対応**（vibe tuple は core で `(result i64 i64)`）。
  そのため status+headers+body を単一文字列規約で符号化している。本来の
  tuple/record 返却には trampoline の multi-value 拡張が必要。
- trailers、client/proxy（outbound）経路は後続。

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

### 5.1 ratified `0.3.0` cutover（wasmtime 46、#821、done）

wasmtime 46.0.1 リリースに合わせて ratified `wasi:http@0.3.0` への cutover を
実施した。要点:

- 46 は `wasi:http@0.3.0`（RC サフィックスなし）を serve する。旧 RC world
  （`@0.3.0-rc-2026-03-15`）を link しようとすると
  `resource implementation is missing` で失敗する（2026-07-12 の再検証で確認）。
- `lib/@vibe/wasi/wit/p3/`（vendored WIT）を `wasmtime-wasi-http` 46.0.1 の
  `src/p3/wit/` から再 vendor。差分は機械的なバージョン文字列置換のみ
  （`0.3.0-rc-2026-03-15` → `0.3.0`）＋ 2 件の非構造差分
  （`deps/cli.wit` の `cli-exit-with-code` が `@unstable` → `@since(0.3.0)`
  に昇格、`deps/sockets.wit` のドキュメントリンク更新）。詳細は
  `lib/@vibe/wasi/wit/p3/VENDOR.md`。
- `scripts/build_wasi_http_p3_full_adapter.sh` の `include` 文字列、
  `scripts/test_wasi_p3_guarantee_gate.sh` の `VIBE_P3_WIT_PIN` 既定値を
  `0.3.0` に更新。
- `component-model-async` は 46 で default-on のため、45 world 起源の RC flag
  （`-W exceptions=y -W concurrency-support=y -W component-model-async=y
  -W component-model-async-stackful=y`）は 46 上では無害な no-op として
  受理される（実害はないが、もはや必須ではない）。
- CI (`ci.yml` `wasi-p3-gate`): wasmtime 46.0.1 leg を primary にし
  `phases: async,http` 両方を実行。旧 pin 45.0.2 leg は
  「vendored WIT がもう RC world を持たないため phase B は 46 でしか
  link できない」ことを踏まえ `phases: async` のみの compat leg として
  残す（phase A は wasi:http WIT に依存しないため 45 でも無回帰で通る）。
  `WASMTIME_VERSION` 系の pin（`ci.yml` の `compiler-gate` /
  `cli-install.yml` / `scripts/install_wasmtime_release.sh`）もすべて
  46.0.1 に統一。

## 6. 現在地と残作業

> 着地済み stage の全行 (M0 〜 ADR-0089 D3、34 行) は
> [archive/spec/wasi-p3-async-history.md](../archive/spec/wasi-p3-async-history.md)
> へ退避した (2026-08-07)。ここには**動いているもの**と**残っているもの**だけを書く。
> ABI の実測記録は §3 (§3.1〜§3.19) がそのまま source of truth。

### 6.1 動いている縦串 (2026-08-07)

| 縦串 | 実体 | gate |
|---|---|---|
| async component の生成と実行 | `.vibe` の `() -> Int with Async` entry → async lift + trampoline → wasmtime 47 の production runtime (`runtime/viberun`) が `instantiate_async` / `run_concurrent` で駆動 | `test_async_component_gate.sh` |
| ready future の await | `Future::ready` / `Stream::next` / `Stream::fold` → `[0, payload]`、`__aw_poll` が slot 1 を読む | 同上 (7 lane) |
| guest 内 pending future | `Future::pending()` → `[1, _]`、`Future::resolve` が完了、await は poll-wait で park。resolve → direct wake の waiter list 付き (§3.15) | `fixtures/async_future_pending.vibe` |
| host future の await | `host_future_get()` / `host_future_named("x")` → `[2, handle]` → `Suspend(handle+2)` → boundary settle → adapter の `future.read` + `waitable-set.wait` | `test_hostfuture_source_component_gate.sh` / `test_named_hostfutures_component_gate.sh` |
| 並行 await | 複数 host 操作を同時に in-flight (2×1000ms が 1015ms) | `test_concurrent_awaits_component_gate.sh` |
| host stream の読み | `host_stream_named("body")` → `[3, handle]`、`host_stream_next` (1 byte / -1 = EOS) → `Suspend(handle+2048)` → adapter の per-read `stream.read` + park。`host_stream_close` で部分消費した readable end を解放 | `test_named_hoststreams_component_gate.sh` |
| `for` からの host stream 消費 | iterand の型で await ループを選ぶ (#1366)。`{ Async }` 無しの row は reject | 同上 (`for` lane) |
| WIT マッピング | `with Async` export → `async func`、`Future[T]` → `future<T'>`、nominal `ByteStream` → `stream<u8>` | `wit_gen_test` (D5 pin) |

### 6.2 残作業

| 項目 | 内容 | 依存 |
|---|---|---|
| **suspend lowering の適格性** (#1536) | row-variable callee と residual literal-param flow が `scps_calls_ok` を通らない。row-free closure-param flow、eager `await(Stream::next(s))` retarget、sequence-HEAD let 連鎖の float (`for` 駆動 terminal)、direct if-condition/match-scrutinee は済み (§2.2 末尾) | — (ADR-0076 本体) |
| **AsyncIter への一本化** (#1538) | eager `Stream[T]` combinator の退役 / AsyncIter 上への再実装。`Stream::next` protocol と host stream read の接続 | 上の適格性 |
| **stdin provider / `StdinStream` の p3 接続** (#1539) | **atomic public source route + additive compiler-owned direct chunk operation まで実装**: unforgeable nominal `StdinStream`、exact authority/effects、exact `vibe.stdin_provider_*` raw imports、tagged-i64 bridge、任意 core composer、stdin-first sniff、`StdinStream::read_chunk` を実装。pull-closure/direct-`for` adapter は transitive HOF effect evidence (#1536) 待ち。既存 `stdin_stream(chunk_size)` は standalone-capable のまま未変更 (§3.18.3) | Wasmtime 47 real-source drain/early-close/function-alias/sequential-reacquire/multiple-active + binary `00 80 ff 41 42` manual while-loop chunks (linear/RC, n=4/1/0/negative, EOF/post-close) gate; GC/standalone/mixed reject; generic `[3, handle]` `HostStream` import は不使用 |
| **実 provider = `wasi:http` incoming-body** (#1540) | serve composition と host-stream composition の統合が要る (§3.19 に構造的な理由と 3 点の分解) | — |
| **M-conc-2: 真の subtask spawn** (#1537) | waitable-set / `future.cancel-*` による実並行・キャンセル。ADR-0068 の nursery を backend へ落とす | ADR-0076 CPS/suspend lowering |
| **M1b-3c-1c: interleaving spawn の emitter** (#1537) | ABI 側の問いは §3.11 で解決済み (`waitable-set.wait` の完了順ディスパッチだけで足りる)。残るのは await をまたぐ task 状態の表現 = ADR-0076 の CPS/suspend lowering | 同上 |
| **M3** | outbound async HTTP client (`Future[Response]` + streaming body)、`wasi:http/service` + `middleware` world | 上の provider |
| **M4** | parity/gate/CI、docs、ADR-0012 → accepted | 全部 |

## 7. 未解決事項

- **await をまたぐ task 状態の表現** (ADR-0076 の CPS/suspend lowering)。
  §3.11 が「ABI 側に追加機構は要らない」を実機で確定させたので、これは
  未知ではなく**目標形の分かっている codegen 作業**。現在の `scps` パスが
  取りこぼす形は §2.2 末尾に列挙してある。
- `T` → canonical `T'` の表現 (特に enum/record を `future`/`stream` の要素に
  する場合)。現在の host future/stream は `u32` / `u8` に限られている。
- eager `Stream[T]` を退役させたあとの `ByteStream` の綴り
  (nominal 型として残すか、AsyncIter の特殊化にするか)。ADR-0089 Decision 4
  の boundary 規則 (何が WIT に出られるか) と一体で決める。

> **解決済み**: canonical ABI の frame レイアウト / suspend-resume 表現
> (§3.7〜§3.11 で確定、stackful lift + `waitable-set.wait` の完了順
> ディスパッチ)。`Async` effect row と既存 row 推論の統合 (§2.1 —
> `async` キーワードを導入せず row のラベルにした時点で特別規則は無い)。
> wasmtime 46 の ratified `0.3.0` cutover (#821、§5.1)。
