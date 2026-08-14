# ADR-0089: 言語表面と wasip3 Future/Stream の整合 — Async 統一・Future/Stream 実体化・AsyncIter stream protocol

Status: proposed

Date: 2026-07-31

Related: #1218, #1227, ADR-0012(async/WASI 0.3), ADR-0068(構造化並行),
ADR-0071(effectset), ADR-0076(evidence passing / suspend CPS),
ADR-0085(`Exception[E]`), ADR-0088(capability authorization surface)。
lowering の source of truth は [spec/wasi-p3-async.md](spec/wasi-p3-async.md)。

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
eager identity codegen で非同期性が無い、(2) `lib/@vibex/concurrent` の
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
| Exception(`throw -> !`、継続破棄) | **動作** | built-in `Error`(ADR-0073)が同型: Error arm の `resume` は checker が拒否、arm 値が handle 結果、throw 以降は実行されない。[fixtures/effect_talk_exception_test.vibe](../fixtures/effect_talk_exception_test.vibe) |
| State(可変セル + 末尾 resume、資料 p132 の primitive 形) | **動作** | mut セルを閉じ込めた tail-resumptive handler。needing fn 内の `while` + `let mut` も evidence-dict 経路で通ることを確認。[fixtures/effect_talk_state_appdb_test.vibe](../fixtures/effect_talk_state_appdb_test.vibe)(資料 p63 AppDB の再現) |
| State(古典的な状態渡し継続 `(s) => resume(s)(s)`) | **不可** | vibe の `handle` に return/value 節が無く、arm が lambda を返すと `handler arm value type mismatch with the handle body's type: expected Int, got (Int) -> Int`。primitive 形が資料自身の推奨でもあるため、これは追わない |
| Coroutine(`Yielded(x, resume)` を返す) | **動作(制約付き)** | first-class `resume` を **ADT payload に格納して handle の外へ返し、driver ループで Done まで再入**する資料 p69-75 の形がそのまま通ることを新規に pin。[fixtures/effect_talk_coroutine_status_test.vibe](../fixtures/effect_talk_coroutine_status_test.vibe)。制約: one-shot(2回目は trap、gate 50)、suspend body は spine 形状のみ、linear backend のみ |
| Handler switch(非スコープ再開、資料 p76) | **不可(診断あり)** | 格納された継続には元の driver が lexically 焼き付いており、新しい `handle ... with Yield { ... }` の下で呼んでも**新 handler は無視されて元の arm に配送され続ける**(実測: log=[101,102])。**#1347 (2026-08-02) で silent ではなくなった** — checker が「発火しえない handle」として reject する(下記)。[fixtures/err_handler_switch_dead_handle.vibe](../fixtures/err_handler_switch_dead_handle.vibe)、compiler_gate 83 |
| 高階エフェクト: 純粋 block(`Span(String, () -> Int)`) | **動作** | operation の関数型パラメータ + arm からの block 呼び出しは通り、span の開始/終了 pairing を arm に閉じ込められる(資料 p86 の startSpan/endSpan 誤用問題は構造的に起きない)。[fixtures/effect_talk_tracing_span_test.vibe](../fixtures/effect_talk_tracing_span_test.vibe) |
| 高階エフェクト: effectful block(資料 p87 の本丸) | **不可(仕様として非対応)** | `Span(String, () -> Int with Log)` + 外側 `handle .. with Log` は、arm 経由で呼ばれる closure が evidence migration から見えず reject(invalid module にはならない)。**#1347 (2026-08-02) で診断文を専用化** — 汎用文言は「handle の body を restructure せよ」と言っていたが、原因は operation の**シグネチャ**側にあり body の書き換えでは直せない。現在は原因の operation を名指しし、非対応であることを明示する: ``effect 'Log' cannot be compiled here: operation `Tracing::Span` takes a block whose own row carries 'Log' ... Higher-order effects (an operation parameterised by an EFFECTFUL block) are not supported``。[fixtures/err_higher_order_effectful_block.vibe](../fixtures/err_higher_order_effectful_block.vibe)、compiler_gate 84。Provider effect(資料 p89)も同じ壁 |
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
   のみ。詳細は docs/effectset.md の 2026-08-02 進捗を参照。
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
`@vibex/concurrent` の宣言 `effect Async { Suspend(Int) -> Int }` の
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
north star と一致、実装は `lib/@vibe/prelude/async_iter.vibe`)に一本化し、
`ByteStream` = `stream<u8>` とする。`lib/@vibe/console/byte_stream.vibe` の
pull closure が実働プロトタイプであり、host shim(現 WASI 0.2
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

### 6. 最初の具体ステップ — probe first

`tools/wasip3_component_probe` に「`future<T>` **値**を渡す probe は未作成
(`future.read` の literal encoding は実測でなく推定)」と明記されていた。
本 repo の流儀(probe first → byte-exact emitter)に従い、実装順序は:

1. `future<T>` 値 probe(`spawned_future/` の scaffolding を流用)—
   **作成済み** (`future_value/`, #1218)。実測: future.* built-in は
   `[future-<op>-N]<導入元 WIT 関数名>` で命名され (per-function ×
   per-type-index、global counter ではない)、`future.read` は
   `[async-lower][future-read-0]...` として async-lowered で到着 (既存の
   waitable-set 機構にそのまま乗る = stackful 構成では既存 [async-lower]
   import call と同型に emit できる)。task/waitable 側の機構は bare-async
   probe と完全一致 (future 値は future.* 一族だけを追加する)。詳細は
   `future_value/canon-imports-exports.wit-abi.txt`。host 側 driver
   (wasmtime の FutureWriter で値を書く側) は未作成 — emitter 実装時の
   end-to-end 検証で作る。
2. `future.*` / `stream.*` canon emitter — **完了** (#1218):
   `emit_canon_future_*` / `emit_canon_stream_*`
   (new/read/write/drop-readable/drop-writable) + `(future u32)`/`(stream
   u8)` 型 section + 固定シェイプ `comp_emit_component_wasm_future_value` /
   `comp_emit_component_wasm_stream_value`(self-contained 単一 task の
   read/write rendezvous — async canonopt を両側に付けると §3.3 の
   self-round-trip deadlock を回避できることを probe で発見)。probe =
   `future_value/component.wat`・`stream_value/component.wat`(wasmtime 47
   実測 42、`-W component-model-more-async-builtins=y` 必須)、gate =
   `scripts/test_future_value_component_gate.sh` /
   `scripts/test_stream_value_component_gate.sh`。実測 pin: packed i64 は
   readable が下位 32bit / BLOCKED = 0xffffffff / pending read への write は
   eager COMPLETED / event = FUTURE_READ(4)・STREAM_READ(2) / stream の
   read/write core sig は (handle, ptr, count) -> status。詳細は
   spec/wasi-p3-async.md §3.12
3. Async 統一(Decision 1)と `suspend_cps_pass` の `while`/`let mut`
   不適格解消 — **進行中 (#1218)**。実測で判明した現状: (a) `while`/`let
   mut` の spine 不適格は #1230 の loop widening
   (`scps_split_while` + `ELetMut` boxing) で既に解消済み — 残る spine
   不適格は suspend する loop 内の `break`/`continue`/`return`・条件/
   scrutinee/引数位置の suspend・nested closure/handle。(b) row を pump に
   通す再測定では新しい壁 = **nominal row 付き builtin (`sleep`) が
   suspend lowering (scps_calls_ok) から不透明** — これが label pun の
   実害であり Decision 1 の対象そのもの。**increment 1 landed**: entry
   row が `Async` を持つプログラムに限り、`sleep` を `perform
   Async::Suspend(-ms)` する合成 fn (`__slp_perform`) へ retarget し、
   entry boundary に tail-resumptive な default handler
   (debt を row-free `sleep_blocking` で settle) を注入
   (`linked_compile.vibe` `lc_inject_async_sleep_boundary`、#944 Error
   boundary と同型)。gate §77 (挙動 parity 42 + 混在規約 reject fixture)。
   既知の制限: Async-row entry + suspend-class handler (TaskGroup) の
   併用は ADR-0076 の混在 guard が明確な診断で reject
   (err_async_boundary_mixed_convention.vibe)。**発見した潜在バグ**:
   builtin と同名の top-level `fn sleep` は従来 compiler でも arity
   miscompile ("not enough arguments on the stack") — evidence pass が
   builtin nominal row で分類し codegen が bound fn に dispatch する齟齬。
   合成 fn を別名にして回避、修正は別チケット対象。
   **increment 2 landed**: `handle ... with Async` が builtin row を
   discharge できるようになった — checker
   (`checker_effects.vibe` の EHandle arm が `Async::` arm を持つ handle の
   body を `in_async` で検査) + codegen keying 拡張
   (`lc_expr_has_async_handle`: handle-with-Async を含むプログラムでも
   sleep→perform retarget が発火。boundary wrap は entry-row キーのまま)。
   これで **sleep が仮想化可能**になった (handler が `Suspend(-ms)` を
   受けて時間を偽装できる — テスト用仮想クロックの入口)。gate §77 に
   discharge fixture (7 + 20 + 15 = 42、handler 実受信 + 非 blocking) を
   追加。arm 自身の body は async context ではない (handled computation の
   外で走る) ことも checker test で pin
4. `Future[T]` 実体化(Decision 2)→ AsyncIter/ByteStream の p3 接続
   (Decision 3)→ wit_gen(Decision 5)→ serve handler の async func 化。
   **Decision 2 の意味論確定 + 最初の increment 群 landed (#1218)**:
   統合の形は「`Async` が唯一の suspension effect(制御、Int payload)、
   `Future[T]` は handler 側継続状態の第一級化(データ、typed 値は heap の
   cell 経由)」— typed operation (`perform Async::Await(f) : T`) への
   完全一体化だけが ADR-0071 generic-instantiation 待ちで、Int 制御 +
   heap データの分業は evidence passing として恒久設計。実装済み:
   (a) `Future::pending/ready/resolve` を idp/edp_pure_builtin_names に
   追加(evidence 移行に対して inert — 以前は boundary 付き entry で
   pending future を触るだけで全 body が ineligible)、(b) entry boundary
   の poll-wait deadlock trap(tail-resumptive boundary は Suspend(1) を
   充足できない — resume では同じ未解決 cell を再 poll する livelock に
   なるため `assert(req < 1)` = `unreachable` trap。gate §77 に
   compile-and-trap fixture)、(c) **pump_all の forced sleep settle**
   (`conc_force_settle_sleep_debt`): resumable poller が全員 no-progress の
   sweep 後、sleeper が居れば仮想時間を進めて retry — 「future を await する
   poller + あとで resolve する sleeper」「sleeping producer を recv_wait
   する consumer」が偽陽性 deadlock trap にならない(sleeper ゼロの stall
   だけが真の deadlock として trap)、(d) `TaskHandle::result_wait`
   (suspendable-lane join: terminal status を poll、非 terminal は
   Suspend(1) で park — task handle IS a future の library 形)、
   (e) checker: `Future[T]` capture を Spawnable-legal に(cell は現行
   poll モデルでは scheduler 非結合の共有メモリ。waiter list が付く
   waitable slice で region tag を得て sp_same_region 側へ移行する)。
   **waitable 第3 park 種 + `waitable-set.wait` backend も landed
   (spec §3.13)**: host 供給 `future<u32>` の e2e — viberun に
   `get-future` import(wasmtime 47 は FutureWriter 型を持たないため
   `FutureReader::new` の producer 形、tokio timer で resolve)、probe
   `host_future_value/component.wat` + byte-exact 移植
   `comp_emit_component_wasm_host_future_value`(async-lowered import →
   future.read BLOCKED → waitable.join → `waitable-set.wait` で task が
   本当に suspend → FUTURE_READ completion event で wake)。300ms delay で
   42 を ~311ms(wall clock が genuine park/wake の証明)、gate =
   `test_host_future_value_component_gate.sh`。in-guest scheduler 側は
   Suspend payload >= 2 を waitable handle 用に予約し poller 扱いに
   (完了源が無い in-guest では deadlock trap に縮退 — silent livelock
   ではなく)。**step 4 本体(実 `.vibe` ソースの await → component 経路)
   も landed (spec §3.14)**: surface `host_future_get() -> Future[Int]`
   (cell 第3状態 state 2 = waitable) → 拡張 `__aw_poll` が
   `perform Async::Suspend(handle + 2)` (予約 waitable band) → entry
   boundary の `__entry_settle` が `vibe.host_future_wait` (component
   adapter 実装) 経由で `waitable-set.wait` に park — canonical ABI が
   task 全体を suspend するので tail-resumptive arm で充足できる (poll-wait
   の Suspend(1) と違い)。composition は
   `comp_emit_component_wasm_async_hostfuture` (memhost メモリ + 値渡し
   i64 adapter で vfs 式 shim/fixup 循環を回避、u32 lift)、wrap は
   compiled core の `vibe.host_future_get` import sniff で自動 route。
   実測: `let run: () -> Int with Async = () -> { let f =
   host_future_get(); await(f) }` が 300ms producer delay で 42 を
   ~313ms (gate = `test_hostfuture_source_component_gate.sh`)。
   **resolve→直接 wake の waiter list も landed (spec §3.15、意味論不変)**:
   TaskCell/Channel の waiter list + `direct_wait` skip + 完了 notify
   (result_wait / send_wait / recv_wait)、builtin future は library hooks
   `__aw_wait`/`__aw_notify_resolve` の auto-link 経由で `await` の
   poll round が登録付きになり `Future::resolve` が直接 wake する。
   notify 漏れは once-per-progress の fallback valve で poll に縮退し、
   deadlock trap は保存 (安全弁が意味論不変を構成的に保証)。
   **Decision 5 (wit_gen async) も landed**: `with Async` export →
   `async func` (Async は import に出さない — async lift で実現される
   suspension effect)、`Future[T]` → `future<T'>`、nominal `ByteStream` →
   `stream<u8>`。一般 `Stream[T]`/guest 産 AsyncIter は Decision 4 の
   boundary 規則どおり hard error のまま (docs/effect-wit-mapping.md)。
   **host import async の一般化 (c) も landed (spec §3.16)**: 匿名1本
   固定だった host future が `host_future_named("price")` で名前つき N 本に
   なる — 名前ごとに core import `vibe.host_future_get$price` →
   component import `price: func() -> future<u32>` + adapter getter を
   1組ずつ生成し、wait 半分と `future.read`/`drop-readable` canon は共有。
   名前は compile time に決まる import 名なので **string literal 必須**
   (component label 形 `[a-z][a-z0-9-]*` を検証)。1名 (匿名) のときの
   index 配置は step 4 と同一。並行性は adapter の **eager read** で
   成立する — getter が pair 生成直後に `future.read` を発行し
   (handle ごとの landing slot と read 状態を記録)、wait は park と回収
   だけを行う。wasmtime は read が pending になってからしか
   `FutureReader` producer を polling しないので、read を await 時まで
   遅らせると2本目が逐次化する (実測 422ms → ~300ms)。実測: `price` (40, 300ms) と `qty`
   (2, 100ms) を await 前に両方作る program が 42 を ~300ms で返す —
   逐次なら 400ms なので **2本が重なって in-flight** であることが wall
   clock で示される (gate =
   `test_named_hostfutures_component_gate.sh`、host 側は viberun の
   `VIBE_ASYNC_FUTURES`)。
   残り: component 内 sleep (adapter は vibe.sleep を
   提供しない — composer が明確な診断で reject)、TaskGroup 併用
   (mixing guard reject のまま)。
   **Decision 3 の named host streams も landed (spec §3.18)**: D3 終端
   probe (§3.17) の実測を受けて、`host_stream_named("body") ->
   HostStream` (pure、cell `[3, handle]`。当初は `Stream[Int]` だったが
   #1366 で分離 — 下の follow-up 参照) + `host_stream_next(s) -> Int
   with Async` (1 byte / -1 = EOS、EOS 後は cell を閉じて以後 -1) が
   実ソースで動く。lowering は §3.16 と同型で park が「future 1本ごと」
   から「read 1回ごと」に変わる: read は `Suspend(handle + 2048)` (予約
   stream 帯 — future 帯 [2, 1025] と handle 上限 1023 で構成的に不交) で
   park し、entry boundary の stream arm が adapter の
   `vibe.host_stream_read` (stream.read → BLOCKED なら waitable-set.wait
   → 終端 status `amount 0 / code 1` は drop-readable して -1) で settle
   する。composer は core import `vibe.host_stream_get$body` sniff で
   per-name `stream<u8>` component import + 共有 canon pair を生成し、
   future と stream の混在 program は 1 つの adapter/composition を共有
   (hf-only の出力はバイト不変)。future と違い **eager read はしない** —
   park が read 単位なので、呼び出し間に pending read を残すと
   double-read になる。実測: while ループで stream を終端まで飲む
   program が `VIBE_ASYNC_STREAMS="body=10|15|17"` で 42、mixed
   (future `price` 30 + stream 5|7) も 42 (gate =
   `test_named_hoststreams_component_gate.sh`)。残り (D3 の続き):
   AsyncIter / `for await` への接続 (host_stream_next は直接 scalar
   read — 一般 `Stream[T]` protocol への統一は Decision 4 の boundary
   規則と合わせて別スライス)。`for await` 側は **#1350 で削除済み**:
   iteration の suspend 可能性は effect row が既に語っており構文レベルの
   `await` マーカーは二重表現だったため、素の `for` に一本化した
   (同期/非同期の選択は `C::next` の戻り型だけで決まるので、マーカーは
   元から情報を足していなかった)。host stream の現状の消費形は素の
   `while` + `host_stream_next`。
   **D3 follow-up: park 経路の実測2件を adapter/probe に反映 (spec §3.17
   追加実測)**: viberun の `VIBE_ASYNC_STREAMS` に `@delay_ms`
   (per-byte 遅延の custom StreamProducer) を足して BLOCKED → park 経路を
   初実走させたところ、(1) waitable-set は **unjoin してから drop**
   (さもないと `resource has children` trap — probe と adapter の両方に
   latent)、(2) 終端には**最終バイト同梱の CLOSED**
   (`amount 1 / code 1`) という第2形状があり、通知後の再 read は host
   trap する — adapter は per-handle closed latch (drop を次 read まで
   遅延して handle 再利用の aliasing 窓を塞ぐ形) で吸収。gate に
   delayed lane (42 + wall ≥ 0.8×3×delay = park の実在) を追加。
   **明示 close も landed (spec §3.18.1)**: `host_stream_close:
   (HostStream) -> Unit` (**`Async` 無し** — `stream.drop-readable` は
   block しない) が部分消費した readable end を解放する。冪等性は cell の
   state word が担保する (1 handle への二重 drop は host 側 trap なので
   load-bearing)。**use で gate** するので、drain するだけの program は
   close import も adapter func も持たず既存出力はバイト不変。
   **`for` からの消費も landed (#1366、spec §3.18.2)**: ただし戻り型を
   `Stream[Int]` から **`HostStream` へ分離した上で**。同一静的型のままだと
   `for` が eager array パスを選び cell の 2 語を足して**期待 42 に対し 4**
   を返していた (診断も trap も無い)。型を分けたことで eager combinator を
   host stream に適用すると型エラーになる。
   残り (D3 の続き): eager `Stream[T]` combinator の退役と AsyncIter への
   一本化 (#1538)、`ByteStream` の p3 接続 (#1539)、`Stream::next` protocol の
   接続 (#1536 — これは stream 配線ではなく **suspend lowering の適格性**の
   問題)、実 provider = `wasi:http` incoming-body (#1540 — serve composition と
   host-stream composition の**統合**であって配線ではない、spec §3.19)。

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
