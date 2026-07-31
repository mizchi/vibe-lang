# WASI 0.3 (Preview 3) async — 設計と段階移行

Status: **proposed** (ADR-0012 を更新)。最終更新 2026-07-13（wasmtime 46 / ratified `0.3.0` cutover、#821）。

WASI 0.3 は 2026-06-11 に ratify され、`stream<T>` / `future<T>` が Component
Model の first-class 型として導入された。本ドキュメントは vibe を WASI 0.3 の
async モデルへ寄せていくための設計判断と段階プランを定める。北極星は
**`async`/`await` + `Future[T]` + `Stream[T]`**、stream の抽象哲学は
**既存 `Iterator` に寄せた pull ベース**。

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
- checker builtin として登録（`lib/@vibe/compiler/checker/builtins_async.vibe`、
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

### 2.5 `Task[T]` eager prototype と v0.4.0 での置換

> **公開意味論の source of truth は
> [ADR-0068 詳細仕様](../concurrency.md)。** 本節の型は WASI 0.3 lowering を
> 探索するために先行実装した historical prototype であり、region-bound
> `Task[r,T]`、nursery、typed channel へ破壊的に置換する。WASI task /
> `waitable-set` / `future.cancel-*` はその backend lowering として使い、
> language surface を host primitive に固定しない。

現行 front-end に着地している prototype surface は次のとおり:

- `Task::spawn : (() -> T with { Async }) -> Task[T] with { Async }` — 子タスク生成
- `Task::join : (Task[T]) -> T with { Async }` — 結果を待つ
- `Task::cancel : (Task[T]) -> Unit with { Async }` — キャンセル要求
- `Task::race : (Task[T], Task[T]) -> T with { Async }` — 先着、敗者は cancel
- `Task::timeout : (Int, () -> T with { Async }) -> Option[T] with { Async }`
  — 期限切れで `None`（内側 task を cancel）

この surface の `spawn` はまだ child lifetime を型に持たず、`race` の loser
ownership も定義していない。v0.4.0 では generative `nursery` が `Spawn[r]` handler
を設置し、blocking `join` / channel operation が `Async::suspend` を要求する。
cancel point、failure propagation、handler task-affinity は ADR-0068 に従う。

#### 2.4/2.5 front-end（landed）

M1a と同じ要領で、lexer/parser/core-Type を変えずに着地:
- `Stream[T]` / `Task[T]` は `CtNamed("Stream"/"Task", _)` で構造表現（要素型は
  gradual な `CtUnknown`）。`Future[Option[T]]` は `CtNamed("Future",
  [CtOption(CtUnknown)])`。
- builtin は `lib/@vibe/compiler/checker/builtins_async.vibe`（`lookup_stream` /
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
  wasmtime 45 上で実行可能。回帰 gate `test_async_component_gate.sh`
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
- **`Stream::next` / `Task::timeout` codegen（Option 構築, landed）**: いずれも
  実 `Option` ctor（`Some`/`None` は linear backend で常に tag 0/1 登録済み）を
  生成する。`compile_call` で **Option 式を AST 合成して `ce` に委譲**し、既存の
  ctor lowering と `Array::length`/`get`・0 引数 closure 呼び出しを再利用:
  - `Stream::next(s)` → `let s = …; if 0 < length(s) { Some(s[0]) } else { None }`
    （eager model では head を peek。`await` が ready future を unwrap）。
  - `Task::timeout(ms, thunk)` → `Some(thunk())`（同期 model では必ず完了、
    deadline は評価して捨てる）。
  合成式経由なので `match { Some(x) => … None => … }` が正しく動く（gate の
  Option entry が Some/None 両経路 + timeout を網羅 → 42）。
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
- **`for await` サーフェス構文（async iterator surface, landed）**: `for await x
  in stream { ... }` で Stream を要素ごとに消費できる。`await` は keyword では
  なく builtin call `await(...)` なので、parser（mode 25）は `for` の直後の
  `await` ident に binding 名が続く場合にマーカーとして skip する（loop 変数名が
  `await` の `for await in e` は `await` の後が `in` なので従来通り binding 扱い）。
  eager Stream model では `Stream[T]` は実行時 `Array[T]` なので、`EForIn`（tag
  18 = `Array::length`/`Array::get` ループ）へそのまま lower される（新 AST node
  なし）。checker の `EForIn` を `Stream[T]` でも iterate できるよう拡張（`CtArray`
  に加え `CtNamed("Stream", [elem])` を受理し elem を bind）。gate に `for await`
  entry を追加（`String::to_bytes("ABC")` を for-await で sum → 198 − 156 → 42）。
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
  で消費し `for await` / `Stream::next` をそこへ lower。真の subtask spawn
  （waitable-set / `future.cancel-*` による実並行・キャンセル）（§3.3 / §3.6 / §3.7）。

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
`Stream::to_string` / `for await` が body を先頭で materialize）。M2c-3 は WASI
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
  で Array に読み込み、`for await` / `Stream::next` をそのループへ lower。
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
これは linear backend の eager `Task::spawn`（§2.5、破棄予定の prototype）
が既に抱えている制限と同じもので、今回それを超えてはいない。真の
interleaving spawn は **M-conc-2 / M1b-3c-2 の未解決事項として残る**。

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

## 6. 段階プラン

| Stage | 内容 | 状態 |
|---|---|---|
| **M0** | wasmtime 45.0.2 bump、P3 WIT 文字列を `rc-2026-03-15` に統一、ADR-0012 更新 + 本 spec 起票 | done |
| **M0.1** | wasmtime 46.0.1 / ratified `wasi:http@0.3.0` cutover（#821）: vendored WIT 再取得、adapter/gate の pin 更新、CI wasmtime pin を 45.x→46.0.1、45.x leg は async-only の compat leg に縮小（§5.1） | done |
| **M1a** | async front-end: `await` builtin (`(Future[T]) -> T with { Async }`) + `Future::ready` + `Future[T]`=CtNamed、effect-escape 検証。lexer/parser/core-Type 非変更 | done |
| **M1b-1** | codegen emitter（component 側）: `comp_emit_component_wasm_async` + `task.return` canon + async lift + async functype。byte-exact verified（test 10/10） | done |
| **M1b-2a** | アプローチ確定（**trampoline 方式**、`linked_compile` 無改修）を実測（`cm_async_trampoline_probe.wat` が wasmtime 45 で 42）。2-module 合成の exact byte blueprint 確定 | done |
| **M1b-2b** | emitter 実装: `comp_generate_async_trampoline` + `comp_emit_component_wasm_async_trampolined`（2-module 合成）+ byte test | 未着手 |
| **M1b-2c** | orchestration: `compile_source_wasi_only` が entry の `() -> Int with { Async }`（name="run"）を AST から検出し、core wasm を `comp_emit_component_wasm_async_trampolined` で包む。selfhost compiler（stage1）で `.vibe` → **component を出力**（magic 0d 00 01 00、`wasm-tools validate` OK）、非 async は plain core のまま（無回帰） | done |
| **M1b-2d** | 真の run: fd_write stub module を component に同梱し main の instantiation に供給、entry の `(param i64)->i64` 規約に合わせ trampoline が dummy i64 引数で呼ぶよう修正、wasmtime に exceptions flag。**縦串完成: selfhost が `.vibe` async entry → async component → wasmtime 45 で 42 を返す** | **done** |
| **M1b-2e** | 回帰保護 gate（`test-async-component`）＋ CI 配線 | done |
| **M1b-3a** | `await` codegen spike: wit-bindgen reference から `future.new/read/write` + waitable-set 等 canon built-in の signature/option を抽出（§3.6） | done |
| **M1b-3b** | `await`/`Future::ready` の codegen（ready-future identity lowering）: `await(x)`/`Future::ready(x)` を引数の値へ lower。**await を使う async プログラムが初めてコンパイル&実行可能**。gate を `await(Future::ready(42))` body に更新し E2E で 42 | done |
| **M1b-3c** | 真の blocking await: `future.read` + waitable-set 待機ループ（async source = host async import / subtask spawn が前提）。core codegen に future canon built-in の import + buffer + ループを emit | spike done（§3.7、mechanics 実機確認）/ codegen 未着手 |
| **M1b-3c-1b** | blocking await（host async import）の component_codegen.vibe emitter。待機ループを別関数に括り出した形で、`future.*` canon 無しに動くことを実機検証（§3.8）。byte-exact 検証のみで実 `.vibe` ソースへの配線は対象外。**spawn 相当は「spawn と join の間に観測可能な処理が無い」退化ケースのみ**——真の interleaving spawn は未達（§3.8「実証範囲の限界」） | done（#1230、`comp_emit_component_wasm_async_spawned_future` + `scripts/test_spawned_future_component_gate.sh`） |
| **M1b-3c-1c** | 真の interleaving spawn: 親の処理と並行して走る第2の guest 計算（guest 側 poll executor か別 task が要る）。M-conc-2 と実質同一の機構 | 未着手（#1240 review で M1b-3c-1b の範囲外と確定） |
| **M1b-3c-2** | async component を **production runtime が駆動**できるようにする（§3.9）: `runtime/viberun` の wasmtime を 45→47.0.2 bump（同期パスはソース無改修）、component ヘッダ判別 + `instantiate_async`/`run_concurrent`/`call_concurrent`、`get-async` を `func_wrap_concurrent` + 実 suspend する tokio timer で実装。gate が probe 専用 Rust host バイナリ依存を脱却。**副産物**: eager-completion 時に subtask が生成されないのに `subtask.drop` していた実バグを発見・修正（emitter + probe WAT 両方）、gate が blocked/eager 両パスを検証 | done（#1230） |
| **M-conc-1** | `Task[T]` codegen（synchronous eager model）: `spawn`（thunk を即時実行・closure type 9 で `call_indirect`）/`join`（identity）/`cancel`（drop→Unit）/`race`（先行値）を `compile_call` で lower。inlined async builtin の free-var capture バグ（nested lambda 内で `Task::join` 等を closure として捕捉）を `collect_free_vars_expr` で修正。gate に Task entry 追加（spawn/join/cancel/race → 42、wasmtime 45） | done |
| **M-conc-2** | 真の subtask spawn（waitable-set / `future.cancel-*`）+ `Task::timeout`（Option 構築） | 未着手 |
| **M2a** | `Stream[T]` codegen（eager Array-backed model）: `map`/`fold` を inline `Array::map`/`Array::fold` へ remap、`empty`=`array_new`、`once`=`array_new`+`push`、`filter` を inline loop で emit。gate に Stream entry 追加（empty/once/map/filter/fold → 42、wasmtime 45） | done |
| **M2b** | `Stream::next`（`Future[Option[T]]`、Option 構築 codegen）+ `Task::timeout`: 実 `Some`/`None` ctor を AST 合成して `ce` に委譲。gate の Option entry が Some/None 両経路 + timeout を網羅（→ 42、wasmtime 45） | done |
| **M2c-1** | HTTP body を ByteStream 化（consume）: `String::to_bytes(s) : Stream[Int]`（`ByteStream`）。handler が request body を Stream combinator で消費可能。AST 合成 loop を `ce` に委譲（RC tagging 安全、byte 単位）。gate に body entry 追加（→ 42、wasmtime 45） | done |
| **M2c-2** | response body 生成 `Stream::to_string`（`Stream[Int] -> String`）: AST 合成 loop を `ce` に委譲。`linked_compile` が `""` を常に str_table へ seed（`StringBuilder::freeze` の脆弱性も解消）。gate に round-trip entry 追加（body → map → to_string → to_bytes → fold → 42）。**handler の request/response body 両方向が ByteStream で扱える** | done |
| **M2c-3 (surface)** | `for await x in s { ... }` サーフェス構文。**言語仕様: `for await` は pull-only** — iterable は pull closure `() -> Option[T]` を要求し、`None` まで駆動する。eager iteration（Array/`Stream[T]`）は plain `for` を使う（#582）。**selfhost compiler は `await` マーカー自体を pull シグナルとして扱い**、`for await x in s` を parser で `let __pull_next = s; let mut cont = true; while cont { match __pull_next() { Some(x) => body, None => cont = false } }` へ desugar（`build_pull_for_in`、codegen に型情報不要）。マーカー無し `for x in arr` は eager `EForIn`。**host compiler は現状 iterable の型で eager/pull を出し分ける permissive 実装**（`await` マーカーを無視し eager `for await` も許容する）だが、spec 適合プログラム（pull closure のみ `for await`）は host/selfhost で同一挙動。host 側の hard enforcement は ROI 低のため見送り（#582）。gate の for-await entry は pull closure（bytes("ABC") を yield）で → 42 | done |
| **M2c-3 (spike)** | 真の `stream<u8>` canon built-ins の wasmtime 45 実行可否と最小形を確定（§3.3、`cm_stream_read_probe.wat` → 42）。`stream.read`/`write` は `more-async-builtins` 必須、self round-trip は producer 不在で deadlock | done |
| **M2c-3 (producer 調査)** | producer を intra-wasm subtask で用意する案を検証 → cross-component reentrance（`cannot enter component instance`）で行き止まり。producer は **host**（HTTP body の readable `stream<u8>`）とする pivot を確定（§3.3.1） | done |
| **M2c-3 (runtime)** | `component_codegen` に `stream.read` canon emit、host 供給の readable `stream<u8>`（`wasi:http` incoming-body / host harness）を `stream.read` ループで消費、`for await`/`Stream::next` をそのループへ lower | 未着手 |
| **M3** | outbound async HTTP client（`Future[Response]` + streaming body）、`wasi:http/service` + `middleware` world | 未着手 |
| **M4** | parity/gate/CI、docs、ADR-0012 → accepted | 未着手 |

## 7. 未解決事項

- canonical ABI の async 状態機械を codegen で生成する際の frame
  レイアウト / suspend-resume の具体表現（M1 で確定）。
- `Async` effect row と既存 effect row 推論の統合（await 透過性、`async fn`
  の effect 注釈規則）。
- `T` → canonical `T'` の表現（特に enum/record を `future`/`stream` 要素に
  する場合）。
- ~~wasmtime 46 リリース後の ratified `0.3.0` cutover とフラグ撤去のタイミング。~~
  → resolved: wasmtime 46.0.1 で cutover 済み（#821、§5.1）。RC flag は
  46 上で無害な no-op として残置（撤去は任意、実害なし）。
