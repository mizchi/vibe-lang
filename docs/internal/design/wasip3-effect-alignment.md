# ADR-0089: 言語表面と wasip3 Future/Stream の整合 — Async 統一・Future/Stream 実体化・AsyncIter stream protocol

Status: proposed

Date: 2026-07-31

Related: #1218, #1227, ADR-0012(async/WASI 0.3), ADR-0068(構造化並行),
ADR-0071(effectset), ADR-0076(evidence passing / suspend CPS),
ADR-0085(`Exception[E]`), ADR-0088(capability authorization surface)。
lowering の source of truth は [spec/wasi-p3-async.md](wasi-p3-async.md)。

## Context

発表資料「代数的エフェクトの高速化技法と発展的な機能」(りよ @ymdfield、
関数型まつり 2026)は、代数的エフェクトの代表パターン(Exception / State /
Coroutine / 高階エフェクト)と、その高速実装としての Evidence Passing
(State→可変セル、Exc→ネイティブ例外へ primitive 化、継続系のみ限定継続)を
整理している。vibe は ADR-0076 で同方式(evidence dict + suspend CPS +
one-shot first-class `resume`)を既に採用しているため、本 ADR ではまず
**資料の4パターンが現行 vibe で構築できるかを fixture で実証し**(Part A)、
その結果を踏まえて **wasip3 (Component Model async) の `future<T>` /
`stream<T>` と言語表面の抽象を一致させる方針**を決定する(Part B)。

wasip3 側の現状は、repo 内に**3つの分断された async スタック**がある:
(1) `Future[T]`/`Stream[T]`/`Task[T]`/`await` は checker 上の phantom 型 +
eager identity codegen で非同期性が無い、(2) `lib/@vibe/concurrent` の
TaskGroup/park/wake/pump は実働する in-guest 協調スケジューラだが host との
接点が blocking sleep のみ、(3) `component_codegen.vibe` の CM async emitter
(`task.return`/`waitable-set.*`/async lift)は wasmtime 47 で byte 検証済み
だが固定形状のみで、**`future.*`/`stream.*` の canon emitter と WIT 生成の
async 対応は存在しない**。`vibe serve` は Rust adapter が p3 の stream/future
を全部吸収し、guest は 4-string の同期関数のままである。生成コードとの摩擦を
小さくするには、この3スタックを1本の抽象に載せ直す必要がある。

## Part A: 資料4パターンの検証結果(2026-07-31、seed compiler で実測)

| 資料のパターン | 判定 | 根拠 / fixture |
| --- | --- | --- |
| Exception(`throw -> !`、継続破棄) | **動作** | built-in `Error`(ADR-0073)が同型: Error arm の `resume` は checker が拒否、arm 値が handle 結果、throw 以降は実行されない。[fixtures/effect_talk_exception_test.vibe](../../../fixtures/effect_talk_exception_test.vibe) |
| State(可変セル + 末尾 resume、資料 p132 の primitive 形) | **動作** | mut セルを閉じ込めた tail-resumptive handler。needing fn 内の `while` + `let mut` も evidence-dict 経路で通ることを確認。[fixtures/effect_talk_state_appdb_test.vibe](../../../fixtures/effect_talk_state_appdb_test.vibe)(資料 p63 AppDB の再現) |
| State(古典的な状態渡し継続 `(s) => resume(s)(s)`) | **不可** | vibe の `handle` に return/value 節が無く、arm が lambda を返すと `handler arm value type mismatch with the handle body's type: expected Int, got (Int) -> Int`。primitive 形が資料自身の推奨でもあるため、これは追わない |
| Coroutine(`Yielded(x, resume)` を返す) | **動作(制約付き)** | first-class `resume` を **ADT payload に格納して handle の外へ返し、driver ループで Done まで再入**する資料 p69-75 の形がそのまま通ることを新規に pin。[fixtures/effect_talk_coroutine_status_test.vibe](../../../fixtures/effect_talk_coroutine_status_test.vibe)。制約: one-shot(2回目は trap、gate 50)、suspend body は spine 形状のみ、linear backend のみ |
| Handler switch(非スコープ再開、資料 p76) | **不可(診断あり)** | 格納された継続には元の driver が lexically 焼き付いており、新しい `handle ... with Yield { ... }` の下で呼んでも**新 handler は無視されて元の arm に配送され続ける**(実測: log=[101,102])。**#1347 (2026-08-02) で silent ではなくなった** — checker が「発火しえない handle」として reject する(下記)。[fixtures/err_handler_switch_dead_handle.vibe](../../../fixtures/err_handler_switch_dead_handle.vibe)、compiler_gate 83 |
| 高階エフェクト: 純粋 block(`Span(String, () -> Int)`) | **動作** | operation の関数型パラメータ + arm からの block 呼び出しは通り、span の開始/終了 pairing を arm に閉じ込められる(資料 p86 の startSpan/endSpan 誤用問題は構造的に起きない)。[fixtures/effect_talk_tracing_span_test.vibe](../../../fixtures/effect_talk_tracing_span_test.vibe) |
| 高階エフェクト: effectful block(資料 p87 の本丸) | **不可(仕様として非対応)** | `Span(String, () -> Int with Log)` + 外側 `handle .. with Log` は、arm 経由で呼ばれる closure が evidence migration から見えず reject(invalid module にはならない)。**#1347 (2026-08-02) で診断文を専用化** — 汎用文言は「handle の body を restructure せよ」と言っていたが、原因は operation の**シグネチャ**側にあり body の書き換えでは直せない。現在は原因の operation を名指しし、非対応であることを明示する: ``effect 'Log' cannot be compiled here: operation `Tracing::Span` takes a block whose own row carries 'Log' ... Higher-order effects (an operation parameterised by an EFFECTFUL block) are not supported``。[fixtures/err_higher_order_effectful_block.vibe](../../../fixtures/err_higher_order_effectful_block.vibe)、compiler_gate 84。Provider effect(資料 p89)も同じ壁 |
| 分散 Tracing として | **部分的に可** | 純粋 block 形 + mut セル(State)+ handler での backend 切り替えまでは今日書ける。block が Fs/Http を伴う実用形は上記の高階ギャップに依存する |

### 横断ギャップ(実測で確定)

1. **generic effect の無検査ギャップは #1340 で解消済み**(この項の当初の
   実測は歴史的記録として残す)。当初: `effect State[S]` は checker に
   TDEffect 登録されず、perform の arity/型/arm 網羅性検査がすべて素通り
   (`perform State::Get(1, 2, 3)` が 0-arity 宣言に対して通る)、row に
   `State[Int]` とは書けなかった(parse error)。**現在**: generic effect
   も registry に登録され、perform/handle site が使用箇所ごとに fresh
   inference vars で instantiate した signature に対して検査する(handle
   は式ごとに 1 instantiation を全 arm で共有)。`with State[Int]` も
   parse する(型引数1個のみ、containment は base 名比較の v1)。残るのは
   row 包含での `State[Int]`/`State[String]` の区別(ADR-0071 の
   `OperationRef = (OperationId, NormalizedEffectArguments)` 正規化の完全形)
   のみ。詳細は docs/internal/design/effectset.md の 2026-08-02 進捗を参照。
2. **non-resume arm の意味論不整合**: `Error` arm と suspend-class arm は
   継続破棄(abort)だが、通常の tail-resumptive arm で `resume` を書かないと
   **暗黙の `resume(arm 値)`** になる(#1087、fixture で 99 になることを pin)。
   資料の「継続を捨てる = 脱出」という直観と食い違うため、少なくとも
   diagnostics/doc で明示する。
3. handler switch は evidence への下位 evidence vector 退避(資料 p133 と同じ
   結論)が必要。~~現状は silent no-op。当面は「診断を出す」を先行させる。~~
   → **#1347 (2026-08-02) で診断が入った**。実装は checker 側の3条件連言:
   (a) その effect をプログラムのどこかが perform しており、(b) この handle
   の body からは静的に到達せず、(c) body が opaque な値呼び出しを含む。
   3条件すべてが必要で、(a) が無いと `entry.vibe` の `Profiler` handle や
   `cache_underlying.vibe` の label pun (誰も perform しないラベルを包む、
   vacuous erasure が意図的に消しているサイト) を、(c) が無いと
   `http_e2e_test` の client-only `Http` handle を誤検出する。
   到達判定は #885/#1361 の overlay を参照するので、row 付き
   パラメータ・注釈つきローカル (`let f: () -> T with E = ..`) 経由で
   perform に届く body は対象外 — 実装中に `TaskGroup::spawn_suspend` と
   `fixtures/effect_crossfn_test.vibe` で実際に踏んで修正した。
   **動的検出は安価な代替にならない**: 継続を呼んだ時点で「今 E を担当する
   handler」を比較するには evidence を動的ベクタで持ち回る必要があり、
   それは p133 の退避そのもの = handler switch の実装とほぼ同コスト。
   よって選択肢は「静的診断」か「機能実装」の二択で、前者を先に置いた。

## Part B: wasip3 `future<T>` / `stream<T>` との整合(決定)

方針: **suspend の operation を1つに統一し、`Future[T]`/stream を実働機構の
上に実体化して、p3 の canon 組込みへ 1:1 で下ろせる形にする**。決定は6点。

### 1. `Async` の統一 — 1つの operation、3つの backend

builtin nominal `Async`(`await`/`sleep` 等の文字列 row)と
`@vibe/concurrent` の宣言 `effect Async { Suspend(Int) -> Int }` の
**ラベル二重定義(host-row label pun)を解消**し、suspend operation を
`Async::Suspend` の1つに統一する。`sleep` 等の builtin は perform 形へ寄せ、
`sleep_blocking` 分裂を解消する。backend は3つ:
in-guest pump(現行 `TaskGroup::pump`)/ p3 `waitable-set.wait`
(spec §3.11: completion-order dispatch で追加 ABI 不要と実証済み)/
JSPI(ブラウザ)。

row 上の位置づけを明確にする: **`Async::Suspend` は ADR-0075 に従い source
semantic row に現れる通常の operation である**(だからこそ Decision 5 の
「`with Async` を持つ export → `async func`」という WIT 射影が定義できる)。
**row に現れないのは backend の選択**(pump / waitable-set / JSPI)という
lowering 詳細であり、backend を替えても source の row は変わらない。
ADR-0068 の「Async は non-transitive(色付け回避)」は backend 選択の
非伝播として維持し、operation 自体の追跡は ADR-0075 の executable contract
に従う。effect-taxonomy-review.md の「suspend 機構と spawn/task coordination
の分解」とも両立する: spawn 側は従来どおり `Spawn[r]` capability が担う。

### 2. `Future[T]` の実体化 — phantom から handle へ

checker-only phantom(`CtNamed`、eager identity codegen)をやめ、
`TaskCell.cont: Option[(Int) -> Unit]` + `TaskStep[T]`(構造的に future その
もの)を核とする handle 型に置き換える。`TaskHandle::park_kind` の
`(poll, sleep)` に **waitable を第3の wait 種**として追加し、pump の
sleep-debt 相殺(#1227)を `waitable-set.wait` の completion-order dispatch に
一般化する。`await` は spec §3.6 の read → BLOCKED → wait → retry ループとして
lower する(source 上は `perform Async::Suspend` 系に脱糖)。

### 3. eager `Stream[T]` の退役 — stream protocol は AsyncIter に一本化

`Stream[T]` builtin(`Array::*` への remap)と phantom `Task[T]`
(spec §2.5 で歴史的プロトタイプと明記済み)を退役させる。stream の言語表面は
`AsyncIterator[T]`(`next(Self) -> Future[Option[(T, Self)]]`、spec §2.4 の
north star と一致、実装は `lib/@vibe/builtin/async_iter.vibe`)に一本化し、
`ByteStream` = `stream<u8>` とする。`lib/@vibe/console/byte_stream.vibe` は
removed; the nominal protocol now lives in `lib/@vibe/console/index.vpkg`。host shim(現 WASI 0.2
`input-stream.blocking-read`)を p3 `stream.read` ループへ差し替えるだけで
p3 に接続できる形になっている。

### 4. Coroutine ↔ stream の対応 — guest 内と境界の二層

資料の `Coroutine[A,B]` / `Yielded(x, resume)`(Part A で動作確認済み)は
**AsyncIter producer の guest 内実装**と位置づける(yield = perform、handler が
継続を保持して `next` ごとに1ステップ進める)。p3 境界では guest 内 producer が
dead end(spec §3.3: `cannot enter component instance`、producer は host 側)
なので、**「guest 内 = coroutine/scheduler、コンポーネント境界 = host が
所有する `stream<T>`」の二層**とし、境界を越える stream を coroutine で
直接実装しようとしない。(generic effect の検査は #1340 で着地したが、
公開 API を非 generic 特殊化(`ByteStream` 等)で提供する方針自体は
boundary handle が nominal であるべきという理由で変わらない。)

### 5. WIT 生成のマッピング

`wit_gen.vibe` に3マッピングを追加する(現状 `Async` はコメント fallback):
`Future[T] → future<T'>`、`with Async` を持つ export → `async func`、
そして stream は **Decision 4 の境界規則と整合させるため、`stream<T'>` へ
写像するのは nominal な boundary-stream handle(`ByteStream` 等、host が
producer 端を所有する型)に限る**。一般の guest 産 AsyncIter 値が component
signature に現れた場合は、wit_gen の既存方針(unmapped 型は hard error)の
まま reject する — guest 内 coroutine を producer とする AsyncIter を
`stream<T>` として広告すると、lowering が実装できない ABI を生成してしまう
(spec §3.3 の intra-component producer dead end)。AsyncIter は guest 内
protocol にとどめ、境界では host 所有 stream との接続を adapter が行う。これにより `vibe serve` の 4-string
trampoline を将来 `wasi:http/service` の
`handle: async func(request) -> result<response, error-code>` 直接 export に
置換する道が開く(spec §4.1 の「文字列 encode は trampoline の単一値返却
制約の回避」という未解決の解消)。resource-qualified capability との WIT の
関係は ADR-0075/0088 の系譜に従う。

### 6. The first concrete steps — probe first

`tools/wasip3_component_probe` stated that "a probe passing a `future<T>`
**value** does not exist yet (the literal encoding of `future.read` is
estimated, not measured)". Following this repo's practice (probe first, then a
byte-exact emitter), the order is:

1. A `future<T>` value probe, reusing the `spawned_future/` scaffolding.
   **Done** (`future_value/`, #1218). Measured:
   - future.* built-ins are named `[future-<op>-N]<name of the WIT function
     that introduced them>` (per function × per type index, not a global
     counter).
   - `future.read` arrives async-lowered as `[async-lower][future-read-0]...`.
     It rides the existing waitable-set machinery unchanged, so in the
     stackful setup it can be emitted exactly like an existing
     `[async-lower]` import call.
   - The task/waitable machinery matches the bare-async probe exactly: a
     future value only adds the future.* family.
   
   Details: `future_value/canon-imports-exports.wit-abi.txt`. The host-side
   driver (writing the value through wasmtime's FutureWriter) was not built;
   the end-to-end check at emitter time provides it.
2. The `future.*` / `stream.*` canon emitters. **Done** (#1218):
   - `emit_canon_future_*` / `emit_canon_stream_*`
     (new/read/write/drop-readable/drop-writable), plus the `(future u32)` /
     `(stream u8)` type sections.
   - The fixed-shape `comp_emit_component_wasm_future_value` /
     `comp_emit_component_wasm_stream_value`: a self-contained single-task
     read/write rendezvous. The probe found that putting the async canonopt
     on both sides avoids the §3.3 self-round-trip deadlock.
   - Probes: `future_value/component.wat` and `stream_value/component.wat`
     (42 measured on wasmtime 47; `-W component-model-more-async-builtins=y`
     is required). Gates: `scripts/test_future_value_component_gate.sh` and
     `scripts/test_stream_value_component_gate.sh`.
   - Measured pins: a packed i64 carries the readable end in its low 32 bits;
     BLOCKED = 0xffffffff; a write to a pending read completes eagerly; the
     events are FUTURE_READ(4) and STREAM_READ(2); the core signature of
     stream read/write is (handle, ptr, count) -> status. Details:
     spec/wasi-p3-async.md §3.12.
3. `Async` unification (Decision 1) and removing the `while` / `let mut`
   ineligibility in `suspend_cps_pass` (#1218). What measurement showed:
   - (a) The `while` / `let mut` spine ineligibility was already removed by
     #1230's loop widening (`scps_split_while` plus `ELetMut` boxing). The
     spine ineligibilities left are `break` / `continue` / `return` inside a
     suspending loop, a suspension in a condition, scrutinee or argument
     position, and nested closures/handles.
   - (b) Re-measuring with the row routed through the pump hit a new wall: a
     **builtin with a nominal row (`sleep`) is opaque to the suspend lowering
     (`scps_calls_ok`)**. That is the concrete harm of the label pun, and
     exactly what Decision 1 targets.
   
   **Increment 1 landed.** Only for a program whose entry row carries
   `Async`, `sleep` is retargeted to a synthesized function (`__slp_perform`)
   that performs `Async::Suspend(-ms)`, and the entry boundary gets a
   tail-resumptive default handler that settles the debt through the row-free
   `sleep_blocking` (`linked_compile.vibe`, `lc_inject_async_sleep_boundary`,
   the same shape as #944's Error boundary). Gate §77 pins the behaviour
   (42).

   Since #2065 wall 2, an Async-row entry that spawns suspend-class tasks
   (TaskGroup) compiles as well: the boundary arm takes its suspend-class
   spelling and sits inside the exception boundary
   (`async_boundary_spawn_suspend_test.vibe`). Host futures and streams
   beside such tasks stay refused, because a task cannot park on a host
   waitable yet (`err_async_boundary_host_waitable_spawn.vibe`).

   **A latent bug found on the way:** a top-level `fn sleep` with the
   builtin's name was already an arity miscompile with the old compiler ("not
   enough arguments on the stack"). The evidence pass classified it by the
   builtin's nominal row while codegen dispatched to the bound function. The
   synthesized function takes a different name to avoid it; the fix is a
   separate ticket.

   **Increment 2 landed:** `handle ... with Async` can discharge the builtin
   row. The checker (the EHandle arm of `checker_effects.vibe`) checks the
   body of a handle with an `Async::` arm under `in_async`. Codegen keying
   was extended (`lc_expr_has_async_handle`): the sleep→perform retarget
   fires for a program containing a handle-with-Async too, while the boundary
   wrap stays keyed on the entry row. This makes **sleep virtualizable**: a
   handler receiving `Suspend(-ms)` can fake time, which is the entry point
   for a virtual clock in tests. Gate §77 gained a discharge fixture (7 + 20 +
   15 = 42: the handler really receives, and nothing blocks). A checker test
   pins that an arm's own body is not an async context (it runs outside the
   handled computation).
4. `Future[T]` materialization (Decision 2) → connecting AsyncIter/ByteStream
   to p3 (Decision 3) → wit_gen (Decision 5) → making the serve handler an
   async func.

   **Decision 2's semantics are settled, and the first increments landed
   (#1218).** The integration is: `Async` is the only suspension effect
   (control, Int payload), and `Future[T]` makes the handler-side
   continuation state first-class (data; a typed value goes through a heap
   cell). Only the full merge into a typed operation (`perform
   Async::Await(f) : T`) waits on ADR-0071's generic instantiation; the split
   of Int control and heap data is the permanent design, as evidence
   passing. Implemented:
   - (a) `Future::pending/ready/resolve` were added to
     idp/edp_pure_builtin_names, so they are inert to evidence migration.
     Before, merely touching a pending future in an entry with a boundary
     made the whole body ineligible.
   - (b) The entry boundary's poll-wait deadlock trap. A tail-resumptive
     boundary cannot satisfy `Suspend(1)`: resuming would re-poll the same
     unresolved cell, a livelock, so it is `assert(req < 1)`, an
     `unreachable` trap. Gate §77 has a compile-and-trap fixture.
   - (c) **pump_all's forced sleep settle**
     (`conc_force_settle_sleep_debt`). After a sweep in which every
     resumable poller made no progress, if a sleeper exists, virtual time
     advances and the sweep retries. So "a poller awaiting a future plus a
     sleeper that resolves it later" and "a consumer doing `recv_wait` on a
     sleeping producer" are not false-positive deadlock traps; only a stall
     with no sleepers traps, as a real deadlock.
   - (d) `TaskHandle::result_wait` (a join on the suspendable lane: poll the
     terminal status and park with `Suspend(1)` while it is not terminal) —
     the library form of "a task handle IS a future".
   - (e) The checker makes a captured `Future[T]` Spawnable-legal. In the
     current poll model the cell is shared memory not tied to a scheduler; it
     moves to the `sp_same_region` side once the waitable slice, with its
     waiter list, gives it a region tag.

   **The third park kind for waitables and the `waitable-set.wait` backend
   landed too (spec §3.13).** End to end for a host-supplied `future<u32>`:
   - viberun has a `get-future` import. wasmtime 47 has no FutureWriter type,
     so it uses the producer form of `FutureReader::new`, resolved by a tokio
     timer.
   - The probe is `host_future_value/component.wat`, and its byte-exact port
     is `comp_emit_component_wasm_host_future_value`: async-lowered import →
     `future.read` BLOCKED → `waitable.join` → the task really suspends in
     `waitable-set.wait` → it wakes on the FUTURE_READ completion event.
   - With a 300 ms delay it returns 42 in ~311 ms; the wall clock is the
     proof of a genuine park/wake. Gate: `test_host_future_value_component_gate.sh`.
   - The in-guest scheduler reserves Suspend payloads >= 2 for waitable
     handles and treats them as pollers. With no completion source in-guest
     this degrades to a deadlock trap, never a silent livelock.

   **Step 4 itself — `await` in real `.vibe` source reaching the component —
   landed too (spec §3.14).**
   - The surface is `host_future_get() -> Future[Int]` (the cell's third
     state, state 2 = waitable).
   - The extended `__aw_poll` performs `Async::Suspend(handle + 2)` (the
     reserved waitable band).
   - The entry boundary's `__entry_settle` parks in `waitable-set.wait`
     through `vibe.host_future_wait` (implemented by the component adapter).
     The canonical ABI suspends the whole task, so a tail-resumptive arm can
     satisfy it, unlike poll-wait's `Suspend(1)`.
   - The composition is `comp_emit_component_wasm_async_hostfuture`. It uses
     memhost memory plus a pass-by-value i64 adapter to avoid the vfs-style
     shim/fixup cycle, with a u32 lift. The wrap is routed automatically by
     sniffing the compiled core's `vibe.host_future_get` import.
   - Measured: `let run: () -> Int with Async = () -> { let f =
     host_future_get(); await(f) }` returns 42 in ~313 ms with a 300 ms
     producer delay (gate `test_hostfuture_source_component_gate.sh`).

   **The waiter list for a direct resolve→wake landed too (spec §3.15; the
   semantics do not change).**
   - TaskCell/Channel have a waiter list, a `direct_wait` skip, and a
     completion notify (result_wait / send_wait / recv_wait).
   - For builtin futures, the library hooks `__aw_wait` /
     `__aw_notify_resolve` are auto-linked, so an `await` poll round
     registers, and `Future::resolve` wakes the waiter directly.
   - A missed notify degrades to polling through a once-per-progress fallback
     valve, and the deadlock trap is preserved. The safety valve keeps the
     semantics unchanged by construction.

   **Decision 5 (wit_gen async) landed too.**
   - A `with Async` export becomes an `async func`. Async is not emitted as an
     import: it is the suspension effect the async lift implements.
   - `Future[T]` becomes `future<T'>`, and the nominal `ByteStream` becomes
     `stream<u8>`.
   - A general `Stream[T]` or a guest-produced AsyncIter stays a hard error,
     per Decision 4's boundary rule (docs/internal/design/effect-wit-mapping.md).

   **The generalization (c) of async host imports landed too (spec §3.16).**
   - The host future, once one fixed anonymous import, becomes N named ones
     through `host_future_named("price")`.
   - Each name gets its own core import `vibe.host_future_get$price`, its own
     component import `price: func() -> future<u32>`, and an adapter getter.
     The wait half and the `future.read` / `drop-readable` canons are shared.
   - The name is an import name decided at compile time, so it **must be a
     string literal**, checked against the component label shape
     `[a-z][a-z0-9-]*`. With one (anonymous) name the index layout is the same
     as step 4.
   - Concurrency comes from the adapter's **eager read**. The getter issues
     `future.read` right after creating the pair, recording a landing slot
     and read state per handle, and the wait only parks and collects.
     wasmtime polls a `FutureReader` producer only once a read is pending, so
     delaying the read until the await serializes the second future
     (measured 422 ms → ~300 ms).
   - Measured: a program that creates `price` (40, 300 ms) and `qty` (2,
     100 ms) before awaiting either returns 42 in ~300 ms. Sequentially it
     would take 400 ms, so the wall clock shows **the two in flight
     together** (gate `test_named_hostfutures_component_gate.sh`; the host
     side is viberun's `VIBE_ASYNC_FUTURES`).

   **Sleep inside a component landed too (#1342, spec §3.18.6).**
   - `vibe.sleep` now keys the same adapter composition. It async-lowers the
     component import `sleep-for: async func(ms: u32) -> u32` and parks the
     returned **subtask** in `waitable-set.wait`, a different shape from the
     future/stream getter/wait pair.
   - Gate `test_async_sleep_component_gate.sh` asserts that a host future
     created before a sleep progresses during it (two delays of D take ~D;
     sequentially ~2D).
   - Host imports the self-contained wrap cannot satisfy now **fail closed**.
     Before, it wrote a component that could not be instantiated and exited 0.

   **TaskGroup under an Async entry (#2065) has landed in two walls.**
   - Wall 1: the evidence pass admits a row-variable callee that is first
     order (`edp_callee_first_order`), or whose every function-typed argument
     is a closure literal that cannot perform the effect
     (`edp_argcond_admits`). So a spawn-free `TaskGroup::run` answers
     (`fixtures/async_taskgroup_run_boundary_test.vibe`).
   - Wall 2: when the program spawns suspend-class tasks, the boundary arm
     binds `resume` first (the suspend-class spelling of the same handler) and
     sits inside the exception boundary. `TaskGroup::spawn_suspend`
     discharges what its task performs, because its row is concrete without
     `Async` and its parameter's type carries `Async`. The suspend pass
     exempts a value argument only in such a position
     (`fixtures/async_boundary_spawn_suspend_test.vibe`). The laundering
     shapes stay refused (`err_effect_closure_literal_launder.vibe`).
   - What remains is ADR-0089 D2's third park kind. A spawned task cannot
     park on a host waitable, so an Async entry that settles a host future or
     stream beside spawned tasks is refused
     (`err_async_boundary_host_waitable_spawn.vibe`).

   **Decision 3's named host streams landed too (spec §3.18).** Following the
   measurements of the D3 terminal probe (§3.17):
   - `host_stream_named("body") -> HostStream` (pure; the cell is
     `[3, handle]`) and `host_stream_next(s) -> Int with Async` (one byte, or
     -1 at EOS; after EOS the cell is closed and it returns -1 from then on)
     work in real source. It was first typed `Stream[Int]`, and #1366 split
     it off; see the follow-up below.
   - The lowering has §3.16's shape, but the park is per read instead of per
     future. A read parks with `Suspend(handle + 2048)`, the reserved stream
     band. It is disjoint from the future band [2, 1025] by construction,
     since handles top out at 1023.
   - The entry boundary's stream arm settles through the adapter's
     `vibe.host_stream_read`: `stream.read`, then `waitable-set.wait` if
     BLOCKED; the terminal status `amount 0 / code 1` drops the readable end
     and returns -1.
   - The composer sniffs the core import `vibe.host_stream_get$body` and
     generates a per-name `stream<u8>` component import and a shared canon
     pair. A program mixing futures and streams shares one
     adapter/composition, and future-only output is byte-identical.
   - Unlike futures there is **no eager read**. The park is per read, so a
     read left pending between calls would double-read.
   - Measured: a program draining a stream with a while loop returns 42 with
     `VIBE_ASYNC_STREAMS="body=10|15|17"`, and so does the mixed program
     (future `price` 30 + stream 5|7) (gate
     `test_named_hoststreams_component_gate.sh`).
   - Remaining (the rest of D3): connecting to AsyncIter / `for await`.
     `host_stream_next` is a direct scalar read, and unifying it with the
     general `Stream[T]` protocol is a separate slice, together with Decision
     4's boundary rule.
   - `for await` was **removed by #1350**. Whether an iteration can suspend
     is already stated by the effect row, so a syntactic `await` marker said
     the same thing twice; plain `for` is the one spelling. The choice
     between sync and async is decided by `C::next`'s return type alone, so
     the marker never added information. The current way to consume a host
     stream is a plain `while` with `host_stream_next`.

   **D3 follow-up: two measurements on the park path, reflected in the
   adapter/probe (spec §3.17, additional measurements).** viberun's
   `VIBE_ASYNC_STREAMS` gained `@delay_ms` (a custom StreamProducer with a
   per-byte delay), which ran the BLOCKED → park path for the first time:
   - (1) A waitable-set must be **unjoined before it is dropped**. Otherwise
     the trap is `resource has children`, a latent bug in both the probe and
     the adapter.
   - (2) The end has a second shape: **CLOSED carrying the last byte**
     (`amount 1 / code 1`). Re-reading after that notification traps in the
     host. The adapter absorbs it with a per-handle closed latch, which
     delays the drop until the next read to close the handle-reuse aliasing
     window.
   - The gate gained a delayed lane: 42, plus wall ≥ 0.8×3×delay, which
     proves the park happened.

   **Explicit close landed too (spec §3.18.1).** `host_stream_close:
   (HostStream) -> Unit` (**no `Async`**; `stream.drop-readable` does not
   block) releases a partly consumed readable end.
   - The cell's state word makes it idempotent. That is load-bearing, since a
     double drop of one handle traps in the host.
   - It is **gated on use**: a program that only drains has neither the close
     import nor the adapter function, and existing output is byte-identical.

   **Consuming from `for` landed too (#1366, spec §3.18.2)**, but only after
   the return type was **split from `Stream[Int]` into `HostStream`**. With
   the same static type, `for` chose the eager array path and summed the
   cell's two words, **returning 4 where 42 was expected**, with no
   diagnostic and no trap. With the types split, applying an eager
   combinator to a host stream is a type error.

   Remaining (the rest of D3):
   - retiring the eager `Stream[T]` combinators and unifying on AsyncIter
     (#1538);
   - connecting `ByteStream` to p3 (#1539);
   - connecting the `Stream::next` protocol (#1536 — not stream wiring but
     **suspend-lowering eligibility**);
   - the real provider, `wasi:http` incoming-body (#1540 — the **merge** of
     the serve composition and the host-stream composition, not wiring;
     spec §3.19).

## Non-goals

- handler switch(非スコープ再開)・高階エフェクト(effectful block)・
  multi-shot resume の実装。Part A のギャップ記録と診断改善提案まで。
- generic effect の実装(ADR-0071 正規化の実装項目として別途。ここでは
  ブロッカーであることの記録のみ)。
- p3 の実 provider(outbound async HTTP client = spec M3 等)の実装。
- ADR-0088 の認可モデルの変更(直交。`Async::Suspend` は row に現れる
  operation、row に現れないのは backend 選択という Decision 1 の整理、
  および spawn/task coordination は `Spawn[r]` capability という
  ADR-0068/0075 の整理を維持)。

## Risks / 検討課題

- **suspend 系は linear backend のみ**(`suspend_cps_pass` は wasm-gc lane に
  未配線)。Decision 2-4 の間、gc lane の扱いを明示する必要がある。
- one-shot 検査は動的 trap のみ(静的 affine 検査なし)。`Future[T]` を
  公開 API にするなら誤用診断の改善が要る。
- ~~handler switch の silent no-op(Part A)は、coroutine を stream producer に
  使う際の誤用経路になる — 「格納された継続を別 handle で包んだ」ことを
  検出する診断を先行して足すべき。~~ → #1347 で着地(上記 横断ギャップ 3)。
  残る制限: 診断は「発火しえない handle」を捕まえる形なので、包み直した
  handle の body が**別途本物の perform も含む**場合はすり抜ける(その
  handle は実際に発火するため、死んではいない)。そこまで捕まえるには
  「格納された継続」という値の由来を追う必要があり、機能実装(p133 の
  evidence vector)を待つ。
- ~~generic effect の「無検査で通る」現状は、資料パターンの写経がそのまま
  型穴になる(検査されていると誤認する)。ADR-0071 実装までの間、
  generic effect 宣言に warning を出す案を検討する。~~ → warning は
  #1302 で導入後、#1340 の instantiation 検査着地に伴い削除済み(型穴
  そのものが閉じた)。

## 検証

- Part A: 上記4 fixture(`fixtures/effect_talk_*_test.vibe`)は
  `scripts/unit_test_runner.sh` の自動発見対象であり、CI battery で回帰固定
  される。不可ケースの診断文字列は本文に記録済み(将来 err fixture 化の候補)。
- Part B: 実装フェーズで probe → emitter → 統一の各段に spec §6 の stage
  table と同形の gate を追加する。
