# wasi-p3-async — 退避した経緯ログ (2026-08-07)

`docs/spec/wasi-p3-async.md` の §2 (言語モデル) と §6 (段階プラン) は、
着地したもの・撤去したもの・当時の見立てが同じ節に積み重なって
「今の仕様」を読み取れない状態になっていた。#1230 / #1341 の棚卸しで
live spec 側を現行仕様だけに整理し直し、**当時の記録**をここへ退避した。

出典を辿る用途のみ。**現行仕様は live spec を見ること** —
ここの記述は当時のもので、更新しない。

---

## 退避 1: §2 言語モデルの landing log (2026-07 〜 2026-08-02)

### 2.5 `Task[T]` eager prototype と v0.4.0 での置換

> **公開意味論の source of truth は
> [ADR-0068 詳細仕様](../concurrency.md)。** 本節の型は WASI 0.3 lowering を
> 探索するために先行実装した historical prototype であり、region-bound
> `Task[r,T]`、nursery、typed channel へ破壊的に置換する。WASI task /
> `waitable-set` / `future.cancel-*` はその backend lowering として使い、
> language surface を host primitive に固定しない。

> **RETIRED (#1227)**: 以下の5操作は front-end から**撤去済み**。現在
> `Task::spawn` 等を書くと `unknown name` でコンパイルが落ちる。撤去理由は
> `spawn` が thunk を即時実行するため `spawn(f); spawn(g)` が常に `f` 完了後に
> `g` を始めること——並行に見えて黙って直列化し、警告も失敗もしなかった。
> 動く並行 surface は `lib/@vibex/concurrent`（`TaskGroup::spawn_suspend` /
> `TaskHandle::join` / `sleep_wait`）。以下は撤去された surface の記録。

- ~~`Task::spawn : (() -> T with Async) -> Task[T] with Async`~~ — 子タスク生成
- ~~`Task::join : (Task[T]) -> T with Async`~~ — 結果を待つ
- ~~`Task::cancel : (Task[T]) -> Unit with Async`~~ — キャンセル要求
- ~~`Task::race : (Task[T], Task[T]) -> T with Async`~~ — 先着、敗者は cancel
- ~~`Task::timeout : (Int, () -> T with Async) -> Option[T] with Async`~~
  — 期限切れで `None`（内側 task を cancel）

この surface の `spawn` は child lifetime を型に持たず、`race` の loser
ownership も定義していなかった。v0.4.0 では generative `nursery` が `Spawn[r]` handler
を設置し、blocking `join` / channel operation が `Async::suspend` を要求する。
cancel point、failure propagation、handler task-affinity は ADR-0068 に従う。

#### 2.4/2.5 front-end（landed）

M1a と同じ要領で、lexer/parser/core-Type を変えずに着地:

**Stream 側（landed、現行）**
- `Stream[T]` は `CtNamed("Stream", _)` で構造表現（要素型は gradual な
  `CtUnknown`）。`Future[Option[T]]` は `CtNamed("Future",
  [CtOption(CtUnknown)])`。
- builtin は `lib/@vibe/compiler/checker/builtins_async.vibe` の `lookup_stream`
  （`lookup_builtin` 経由）に登録。suspend / runtime 接触操作
  （`*::next`/`fold`）は `Async` effect を帯び、effect-escape チェックが
  そのまま機能する。

**Task 側（RETIRED in #1227、以下は当時の記録）**
- ~~`Task[T]` は `CtNamed("Task", _)` で構造表現。~~
- ~~builtin は同ファイルの `lookup_concurrency` に登録。`spawn`/`join`/`cancel`/
  `race`/`timeout` は `Async` effect を帯びる。~~ 現在
  `lookup_concurrency` は**無条件に `None` を返す**——これらの名前は
  `unknown name` になる。
- 検証: `checker_async_test.vibe` は「登録されている」ことを assert する4
  テストを、「登録されていない」ことを pin する1テストに置き換えてある
  （#1227）。`checker_effects_test.vibe` 19/19（無回帰）。
- **`Task[T]` codegen（synchronous eager model, RETIRED in #1227）**: 単一スレッドの
  linear backend では「spawn = thunk を即時実行し、Task 値 = 解決済み結果」
  「join = identity」「cancel = drop して Unit」「race = 先行 task の値」という
  同期セマンティクスへ lower（`compile_call.vibe`）。`Task::spawn` は 0 引数
  closure（thunk）を `call_indirect`（closure type 9）で呼ぶ。`await` /
  `Future::ready` と同じ系列で、async component（`with Async`）に包まれ
  wasmtime 45 上で実行可能だった。**#1227 でこの lowering ごと撤去し**、
  `test_async_component_gate.sh` の Task entry も外した（`option` entry の
  `Task::timeout` は `Stream::next(Stream::once(1))` に差し替え、合計 42 を維持）。
  checker 側の pin は上の「Task 側（RETIRED）」を参照。
  - **free-var capture 修正**（撤去前の記録）: inlined async builtin
    （`await`/`Future::ready`/`Task::spawn|join|cancel|race`）は func table に
    居ないため、nested lambda
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
- **`Stream::next` codegen（Option 構築, landed）/ `Task::timeout`（RETIRED in
  #1227）**: いずれも
  実 `Option` ctor（`Some`/`None` は linear backend で常に tag 0/1 登録済み）を
  生成する。`compile_call` で **Option 式を AST 合成して `ce` に委譲**し、既存の
  ctor lowering と `Array::length`/`get`・0 引数 closure 呼び出しを再利用:
  - `Stream::next(s)` → `let s = …; if 0 < length(s) { Some(s[0]) } else { None }`
    （eager model では head を peek。`await` が ready future を unwrap）。
  - ~~`Task::timeout(ms, thunk)` → `Some(thunk())`~~（同期 model では必ず完了、
    deadline は評価して捨てた）。**#1227 で撤去**。gate の `option` entry は
    `Stream::next(Stream::once(1))` に差し替えて Some 経路の網羅を維持している。
  合成式経由なので `match { Some(x) => … None => … }` が正しく動く（gate の
  Option entry が `Stream::next` の Some/None 両経路を網羅 → 42。timeout 分は
  #1227 の撤去で外した）。
- **`String::to_bytes` codegen（ByteStream consume, landed）**: HTTP body を
  Stream 化する第一歩。`String::to_bytes(s) : Stream[Int]`（= `ByteStream`、
  WASI 0.3 `stream<u8>`）が文字列のバイト列を eager に Array へ展開し、handler
  が request body を Stream combinator（map/filter/fold/next）で消費できる。
  `compile_call` で `let mut arr = []; while i < length(s) { Array::push(arr,
  char_code_at(s, i)); i = i + 1 }; arr` を AST 合成して `ce` に委譲するため、
  `String::length`/`char_code_at`（`i32.load8_u` で byte 単位）と loop counter
  が source と同じ (RC) tagging 規約に従う。gate に body entry を追加（`")"` →
  map(+1) → filter(>0) → fold(sum) → 42）。
- **`Stream::to_string` codegen（ByteStream produce, landed）**: response body
  生成側。`Stream::to_string(bs) : String`（`Stream[Int] -> String`）が byte 列を
  String へ collect する。`compile_call` で `let mut acc = ""; while i <
  length(bs) { acc = String::concat(acc, String::from_char_code(bs[i])); i = i +
  1 }; acc` を AST 合成して `ce` に委譲。アキュムレータの `""` リテラルのため、
  `linked_compile` が str_table に `""` を**常に seed**するよう修正（`StringBuilder
  ::freeze` の join separator の潜在的脆弱性も同時に解消）。gate に round-trip
  entry を追加（body → map → `to_string` → 再度 `to_bytes` → fold → 42）。これで
  handler が request body を ByteStream で消費し、response body を ByteStream から
  生成できる（両方向そろった）。
- **async iterator サーフェス構文（landed → #1350 で `for` に一本化）**:
  `for x in stream { ... }` で Stream を要素ごとに消費できる。当初は
  `for await x in stream` という別綴りで導入したが、**同期/非同期の選択は
  iterand の型（`C::next` の戻りが `Future` か）だけで決まっており構文
  マーカーは情報を足していなかった**ため、#1350 で `for await` と
  `__await_iter` マーカーを撤去し `for` に統合した（iteration が suspend
  しうることは effect row `with Async` が既に語る — ADR-0089 D1 が
  `sleep` から関数色付けを外したのと同じ理由）。eager Stream model では
  `Stream[T]` は実行時 `Array[T]` なので `EForIn`（tag 18 =
  `Array::length`/`Array::get` ループ）へそのまま lower される。checker の
  `EForIn` は `Stream[T]` でも iterate できる（`CtArray` に加え
  `CtNamed("Stream", [elem])` を受理し elem を bind）。gate は
  `String::to_bytes("ABC")` を `for` で sum → 198 − 156 → 42。
- **streaming ベンチ & `String::join` の O(n) 化（perf, landed）**:
  `scripts/bench_streaming.sh`（`pkf run bench-streaming`）が stage1 経由で
  streaming ops を wasm 化し wasmtime で計測する。初回計測（4 KB × 300 iters）で
  `Stream::to_string` が 1.77s と突出（他 ops は 0.03〜0.06s）。原因は
  `Stream::to_string` → `String::join(parts, "")` の `String::join` が
  `acc = concat(acc, piece)` を繰り返す **O(n²)**（毎回 prefix 全体を copy、
  bump heap に O(n²) のゴミ→4 KB で OOM/OOB リスク）だった。`gen_string_join_body`
  を **単一確保 + memcpy の O(n)**（pass1 で総 length を合算、一度確保、pass2 で
  各 piece と separator を memcpy）に書き換え。結果 `to_string` 1.77s→**0.117s
  (~15×)**、`pipeline` 1.24s→**0.155s (~8×)**。`StringBuilder::freeze`
  （= `join(parts, "")`）も同経路で高速化。`Stream::to_string` の codegen も
  acc-concat ループから parts 配列 + 1 回 join へ変更（O(n²)→O(n)）。
- **M2c-3 stream.read feasibility spike（landed）**: 真の `stream<u8>` canonical
  built-ins が wasmtime 45 で実行可能なことと最小形を確定（§3.3、
  `src/x/cm_async/cm_stream_read_probe.wat`）。`stream.new` は base フラグで実行
  可、`stream.read`/`write` は `-W component-model-more-async-builtins=y` が必須。
  単一タスク self round-trip は deadlock するため並行 producer が要る、という
  次スライスの要件も確定。
- **M2c-3 producer 調査（landed）**: intra-wasm subtask producer は
  cross-component reentrance trap で不可と確定し、producer は host（HTTP body の
  readable `stream<u8>`）とする pivot を記録（§3.3.1）。
- 後続: `component_codegen` に `stream.read` canon emit、host 供給の readable
  `stream<u8>`（`wasi:http` incoming-body / host harness）を `stream.read` ループ
  で消費し `for` / `Stream::next` をそこへ lower。真の subtask spawn
  （waitable-set / `future.cancel-*` による実並行・キャンセル）（§3.3 / §3.6 / §3.7）。

---

## 退避 2: §6 段階プランの全 stage 行 (M0 〜 ADR-0089 D3)

各行の「状態」は退避時点のもの。実装の現在地は live spec §6 を見ること。

| Stage | 内容 | 状態 |
|---|---|---|
| **M0** | wasmtime 45.0.2 bump、P3 WIT 文字列を `rc-2026-03-15` に統一、ADR-0012 更新 + 本 spec 起票 | done |
| **M0.1** | wasmtime 46.0.1 / ratified `wasi:http@0.3.0` cutover（#821）: vendored WIT 再取得、adapter/gate の pin 更新、CI wasmtime pin を 45.x→46.0.1、45.x leg は async-only の compat leg に縮小（§5.1） | done |
| **M1a** | async front-end: `await` builtin (`(Future[T]) -> T with Async`) + `Future::ready` + `Future[T]`=CtNamed、effect-escape 検証。lexer/parser/core-Type 非変更 | done |
| **M1b-1** | codegen emitter（component 側）: `comp_emit_component_wasm_async` + `task.return` canon + async lift + async functype。byte-exact verified（test 10/10） | done |
| **M1b-2a** | アプローチ確定（**trampoline 方式**、`linked_compile` 無改修）を実測（`cm_async_trampoline_probe.wat` が wasmtime 45 で 42）。2-module 合成の exact byte blueprint 確定 | done |
| **M1b-2b** | emitter 実装: `comp_generate_async_trampoline` + `comp_emit_component_wasm_async_trampolined`（2-module 合成）+ byte test | 未着手 |
| **M1b-2c** | orchestration: `compile_source_wasi_only` が entry の `() -> Int with Async`（name="run"）を AST から検出し、core wasm を `comp_emit_component_wasm_async_trampolined` で包む。selfhost compiler（stage1）で `.vibe` → **component を出力**（magic 0d 00 01 00、`wasm-tools validate` OK）、非 async は plain core のまま（無回帰） | done |
| **M1b-2d** | 真の run: fd_write stub module を component に同梱し main の instantiation に供給、entry の `(param i64)->i64` 規約に合わせ trampoline が dummy i64 引数で呼ぶよう修正、wasmtime に exceptions flag。**縦串完成: selfhost が `.vibe` async entry → async component → wasmtime 45 で 42 を返す** | **done** |
| **M1b-2e** | 回帰保護 gate（`test-async-component`）＋ CI 配線 | done |
| **M1b-3a** | `await` codegen spike: wit-bindgen reference から `future.new/read/write` + waitable-set 等 canon built-in の signature/option を抽出（§3.6） | done |
| **M1b-3b** | `await`/`Future::ready` の codegen（ready-future lowering）。**await を使う async プログラムが初めてコンパイル&実行可能**。gate を `await(Future::ready(42))` body に更新し E2E で 42。当初の identity lowering は #1230 で `Future[T] = [state, payload]`（`state = 0` が ready）へ差し替え済み — pending を足すときに表現を作り直さないため（§3.6 参照） | done |
| **M1b-3c** | 真の blocking await: `future.read` + waitable-set 待機ループ（async source = host async import / subtask spawn が前提）。core codegen に future canon built-in の import + buffer + ループを emit | spike done（§3.7、mechanics 実機確認）/ codegen 未着手 |
| **M1b-3c-1b** | blocking await（host async import）の component_codegen.vibe emitter。待機ループを別関数に括り出した形で、`future.*` canon 無しに動くことを実機検証（§3.8）。byte-exact 検証のみで実 `.vibe` ソースへの配線は対象外。**spawn 相当は「spawn と join の間に観測可能な処理が無い」退化ケースのみ**——真の interleaving spawn は未達（§3.8「実証範囲の限界」） | done（#1230、`comp_emit_component_wasm_async_spawned_future` + `scripts/test_spawned_future_component_gate.sh`） |
| **M1b-3c-1c** | 真の interleaving spawn: 親の処理と並行して走る第2の guest 計算。**§3.11 で ABI 側の問いは解決**——`waitable-set.wait` の完了順ディスパッチだけで interleave し、別 task も poll executor も `context.get/set` も不要（§3.8 の予測を実機反証、負の対照付き gate で固定）。残るのは **await をまたぐ task 状態の表現＝ADR-0076 の CPS/suspend lowering** のみで、codegen 側に局所化された | mechanics done（#1230、`tools/wasip3_component_probe/interleaved_tasks/` + `scripts/test_interleaved_tasks_probe_gate.sh`）/ emitter・実ソース配線は未着手 |
| **M1b-3c-3** | **本物の並行 await**（§3.10）: guest の計算は1本のまま、**複数の host 操作を同時に in-flight** にして待つ。canon 集合は M1b-3c-1b から不変——並行性を生むのは「どちらも待ち始める前に両方発行する」という操作順序だけ。`comp_emit_component_wasm_async_concurrent_awaits` + probe + gate（値 84 と **両側の wall-clock** で検証、2×1000ms が 1015ms = 1× スケール）。M1b-3c-1c（guest の計算が2本 interleave）とは別問題で、そちらは未解決のまま | done（#1230） |
| **M1b-3c-2** | async component を **production runtime が駆動**できるようにする（§3.9）: `runtime/viberun` の wasmtime を 45→47.0.2 bump（同期パスはソース無改修）、component ヘッダ判別 + `instantiate_async`/`run_concurrent`/`call_concurrent`、`get-async` を `func_wrap_concurrent` + 実 suspend する tokio timer で実装。gate が probe 専用 Rust host バイナリ依存を脱却。**副産物**: eager-completion 時に subtask が生成されないのに `subtask.drop` していた実バグを発見・修正（emitter + probe WAT 両方）、gate が blocked/eager 両パスを検証 | done（#1230） |
| **M-conc-1** | ~~`Task[T]` codegen（synchronous eager model）: `spawn`（thunk を即時実行・closure type 9 で `call_indirect`）/`join`（identity）/`cancel`（drop→Unit）/`race`（先行値）を `compile_call` で lower。inlined async builtin の free-var capture バグ（nested lambda 内で `Task::join` 等を closure として捕捉）を `collect_free_vars_expr` で修正。gate に Task entry 追加（spawn/join/cancel/race → 42、wasmtime 45）~~ | **retired (#1227)** — 黙って直列化するため撤去。動く surface は `lib/@vibex/concurrent` |
| **M-conc-2** | 真の subtask spawn（waitable-set / `future.cancel-*`）。M-conc-1 の surface は #1227 で撤去したので、置き換えではなく新規に載せる | 未着手 |
| **M2a** | `Stream[T]` codegen（eager Array-backed model）: `map`/`fold` を inline `Array::map`/`Array::fold` へ remap、`empty`=`array_new`、`once`=`array_new`+`push`、`filter` を inline loop で emit。gate に Stream entry 追加（empty/once/map/filter/fold → 42、wasmtime 45） | done |
| **M2b** | `Stream::next`（`Future[Option[T]]`、Option 構築 codegen）: 実 `Some`/`None` ctor を AST 合成して `ce` に委譲。gate の Option entry が Some/None 両経路を網羅（→ 42、wasmtime 45）。併載していた `Task::timeout` 分は #1227 の撤去で `Stream::next(Stream::once(1))` に差し替え | done |
| **M2c-1** | HTTP body を ByteStream 化（consume）: `String::to_bytes(s) : Stream[Int]`（`ByteStream`）。handler が request body を Stream combinator で消費可能。AST 合成 loop を `ce` に委譲（RC tagging 安全、byte 単位）。gate に body entry 追加（→ 42、wasmtime 45） | done |
| **M2c-2** | response body 生成 `Stream::to_string`（`Stream[Int] -> String`）: AST 合成 loop を `ce` に委譲。`linked_compile` が `""` を常に str_table へ seed（`StringBuilder::freeze` の脆弱性も解消）。gate に round-trip entry 追加（body → map → to_string → to_bytes → fold → 42）。**handler の request/response body 両方向が ByteStream で扱える** | done |
| **M2c-3 (surface)** | `for await x in s { ... }` サーフェス構文。**言語仕様: `for await` は pull-only** — iterable は pull closure `() -> Option[T]` を要求し、`None` まで駆動する。eager iteration（Array/`Stream[T]`）は plain `for` を使う（#582）。**selfhost compiler は `await` マーカー自体を pull シグナルとして扱い**、`for await x in s` を parser で `let __pull_next = s; let mut cont = true; while cont { match __pull_next() { Some(x) => body, None => cont = false } }` へ desugar（`build_pull_for_in`、codegen に型情報不要）。マーカー無し `for x in arr` は eager `EForIn`。**host compiler は現状 iterable の型で eager/pull を出し分ける permissive 実装**（`await` マーカーを無視し eager `for await` も許容する）だが、spec 適合プログラム（pull closure のみ `for await`）は host/selfhost で同一挙動。host 側の hard enforcement は ROI 低のため見送り（#582）。gate の for-await entry は pull closure（bytes("ABC") を yield）で → 42 | done |
| **M2c-3 (spike)** | 真の `stream<u8>` canon built-ins の wasmtime 45 実行可否と最小形を確定（§3.3、`cm_stream_read_probe.wat` → 42）。`stream.read`/`write` は `more-async-builtins` 必須、self round-trip は producer 不在で deadlock | done |
| **M2c-3 (producer 調査)** | producer を intra-wasm subtask で用意する案を検証 → cross-component reentrance（`cannot enter component instance`）で行き止まり。producer は **host**（HTTP body の readable `stream<u8>`）とする pivot を確定（§3.3.1） | done |
| **ADR-0089 step 2 (future.*/stream.*)** | `future.new/read/write/drop-*` と `stream.new/read/write/drop-*` の canon emitter + `(future u32)`/`(stream u8)` 型 section + 固定シェイプ `comp_emit_component_wasm_future_value`/`comp_emit_component_wasm_stream_value`（self-contained 単一 task の read/write rendezvous、§3.12）。probe（`future_value/component.wat`・`stream_value/component.wat`、wasmtime 47 実測 42）→ byte-exact 移植。gate = `test_future_value_component_gate.sh`/`test_stream_value_component_gate.sh`（wasmtime CLI 直駆動、`more-async-builtins` flag） | done（#1218） |
| **ADR-0089 step 4 (実ソース await → waitable)** | 実 `.vibe` ソースの `await` を component 経路へ配線（§3.14）: `host_future_get() -> Future[Int]`（cell state 2 = waitable）→ 拡張 `__aw_poll` の `Suspend(handle + 2)` → entry boundary `__entry_settle` → adapter の `future.read`/`waitable-set.wait`。`comp_emit_component_wasm_async_hostfuture`（memhost + 値渡し i64 adapter、u32 lift、wrap は core import sniff で自動 route）。gate = `test_hostfuture_source_component_gate.sh`（viberun 駆動、42 + wall >= 0.8×delay + p1 routing control） | done（#1218） |
| **ADR-0089 resolve→direct wake** | in-guest poll モデルの O(rounds×awaiters) 最適化（§3.15、意味論不変）: waiter list + `direct_wait` skip + 完了 notify（library）、`__aw_wait`/`__aw_notify_resolve` hooks の auto-link（compiler）、once-per-progress の fallback valve で notify 漏れは poll に縮退・deadlock trap は保存 | done（#1218） |
| **ADR-0089 Decision 5 (wit_gen async)** | `with Async` export → `async func`（`Async` は import に出さない — async lift で実現される suspension effect）、`Future[T]` → `future<T'>`、nominal `ByteStream` → `stream<u8>`（一般 `Stream[T]`/guest 産 AsyncIter は spec §3.3 の boundary 規則により hard error のまま）。docs/effect-wit-mapping.md 更新 + wit_gen_test に D5 pin | done（#1218） |
| **ADR-0089 (c) (named host futures)** | host import async の一般化（§3.16）: `host_future_named("x") -> Future[Int]`（string literal 必須、label 検証）→ 名前ごとの core import `vibe.host_future_get$x` → 名前ごとの component import `x: func() -> future<u32>` + adapter getter。wait 半分と `future.read`/`drop-readable` canon は共有、1名（匿名）のときの index 配置は step 4 と同一。並行性は adapter の **eager read**（getter が `future.read` を発行、wait は park と回収のみ）で成立する。viberun は `VIBE_ASYNC_FUTURES` で任意名を link。gate = `test_named_hostfutures_component_gate.sh`（42 = 40+2、wall が `[0.8×P, 0.9×(P+Q))` で overlap 実証、単一名 control） | done（#1218） |
| **ADR-0089 D3 (終端 probe)** | host 供給 `stream<u8>` を1バイトずつ読む probe（§3.17）で「終端は `amount 0 / code 1` を read が inline に返す」を wasmtime 47 実測、viberun に `VIBE_ASYNC_STREAMS` の host stream import を追加。gate = `test_host_stream_value_probe_gate.sh`（42 = 10+15+17 を pin） | done（#1218） |
| **M2c-3 (runtime)** | `component_codegen` に host 供給の readable `stream<u8>`（`wasi:http` incoming-body / host harness）を `stream.read` ループで消費する形を emit、`for`/`Stream::next` をそのループへ lower | guest surface + Suspend stream 帯 + composer + 明示 close（§3.18 / §3.18.1: `host_stream_named`/`host_stream_next`/`host_stream_close` の実ソースが `stream.read` + `waitable-set.wait` で終端まで読み、部分消費した readable end も解放できる。gate = `test_named_hoststreams_component_gate.sh`）は done。残り2件: (a) `for`/`Stream::next`（AsyncIter protocol）をこの read へ lower する接続、(b) 実 provider = `wasi:http` incoming-body（**serve composition と host-stream composition の統合が必要** — §3.19 に構造的な理由と3点の作業分解） |
| **ADR-0089 D3 (named host streams)** | 実ソースの host stream 読み（§3.18）: `host_stream_named("body") -> Stream[Int]`（string literal 必須、cell `[3, handle]`）+ `host_stream_next -> Int with Async`（1 byte / -1 = EOS、EOS 後は latch）→ `Suspend(handle + 2048)`（予約 stream 帯）→ boundary の `vibe_hs_read_raw` settle → adapter の per-read `stream.read` + park（eager read はしない — per-read park と衝突する）→ per-name component import `<name>: func() -> stream<u8>`。future との混在は 1 composition を共有、hf-only 出力はバイト不変 | done（#1218） |
| **ADR-0089 D3 (明示 close)** | 部分消費した host stream の readable end を解放する surface（§3.18.1）: `host_stream_close: (Stream[Int]) -> Unit`（**`Async` 無し** — `stream.drop-readable` は block しない）→ 注入 fn `__hs_close` が adapter を直接呼ぶ（perform も予約帯も boundary settle arm も不要）。冪等性は cell の state word が担保（1 handle への二重 drop は host 側 trap なので load-bearing）。**use で gate** し、drain するだけの program は close import も adapter func も持たない = 既存 stream composition はバイト不変。gate = close lane（5 bytes 中 2 bytes 読んで close → 再 close → close 後 read で 42 + .wat の import/export 検査） | done（#1218） |
| **M3** | outbound async HTTP client（`Future[Response]` + streaming body）、`wasi:http/service` + `middleware` world | 未着手 |
| **M4** | parity/gate/CI、docs、ADR-0012 → accepted | 未着手 |
