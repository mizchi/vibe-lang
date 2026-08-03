# ADR-0068 詳細仕様: 構造化並行と message passing

Status: proposed

Date: 2026-07-16

Related: ADR-0012, ADR-0050, ADR-0060, ADR-0068, ADR-0071, ADR-0075, ADR-0076,
#488, #806, #817, #818, #906

## 位置づけ

本書を v0.4.0 の並行処理に関する公開意味論の source of truth とする。
`docs/spec/wasi-p3-async.md` は WASI 0.3 への lowering、#488 は
shared-everything-threads の実験を扱う。両者が本書と衝突する場合、公開 API と
観測可能な挙動は本書を優先する。

`Task[T]` の eager prototype（`Task::spawn`/`join`/`cancel`/`race`/`timeout`）は
**#1227 で撤去した**。`spawn` が thunk を即時実行するため `spawn(f); spawn(g)` が
常に `f` 完了後に `g` を始める——並行に見えて黙って直列化する——という理由による。
現在これらの名前は `unknown name` でコンパイルエラーになる。撤去済みの
`Threads::*` probe と Int channel id API も同様に公開契約ではない。

**現行の動く並行 surface は `lib/@vibex/concurrent`** である:
`TaskGroup::spawn_suspend` が suspend 可能なタスクを生成し、`TaskHandle::join`
が結果を回収し、`sleep_wait`（#1253）は並行 sleep を直列化させず重ねる。本書が
記述する `Task[r,T]` / nursery / typed channel はその上に載る v0.4.0 の目標形。

本書のコードは提案中の surface を示す疑似 vibe であり、まだコンパイルできない。
「必須」は v0.4.0 の適合実装が満たす条件、「将来」は互換性を約束しない拡張を表す。

## 決定の要約

1. 公開モデルは **shared-nothing な構造化並行**とする。OS thread、Worker、
   Wasm thread を言語へ直接露出しない。
2. 最小コアは generative region を持つ `Nursery[r]`、`Task[r, T]`、
   `Sender[r, T]`、`Receiver[r, T]` と、compiler が判定する `Send` で構成する。
3. task の生成・cancel は代数的 effect `Spawn[r]::spawn` /
   `Spawn[r]::cancel`、待機は `Async::suspend` として追跡する。ADR-0071 の
   operation-level row と `effectset` をそのまま利用する。
4. handler evidence、continuation、可変参照は task-local とし、task や channel
   を越えて共有しない。message は deep-copy snapshot を基準意味論とする。
5. JSPI は suspend/resume の lowering であり、並列実行の方式ではない。
   browser の並列化には Worker 等を別途使う。JSPI の全 browser 出荷を
   v0.4.0 の blocker にしない。
6. WASI Component Model concurrency と shared-everything-threads は交換可能な
   backend とする。shared-everything は #488 の opt-in 実験であり、公開意味論や
   リリース条件を依存させない。
7. compiler の import DAG 並列 typecheck を最初の CPU-bound dogfood
   とする。worker は immutable dependency snapshot から `ModuleOutcome` を返し、
   `TypeDb`、diagnostics、link、cache publish は coordinator が決定的順序で行う。
8. native/WASI の production multi-worker backend は Wasmtime embedder が OS thread
   を管理し、worker ごとに独立した `Store + Instance + heap` を所有する形を目標と
   する。移行までは host Worker と worker-owned compiler daemon による shared-nothing
   prototype を許容する。WASI Threads の shared linear memory は既定 backend にしない。

## 用語

| 用語 | 意味 |
| --- | --- |
| task | nursery に束縛された、独立した実行・失敗・cancel の単位。runtime 上の軽量 process に相当する |
| nursery | child task と channel の lifetime を囲う lexical scope |
| process | mailbox と supervision を持つ長寿命 actor。v0.4.0 の最小コアには含めず、task 上の後続 abstraction とする |
| suspend point | task が scheduler へ制御を返し、cancel を観測できる operation |
| worker | backend の実行資源。Web Worker、host thread、Wasm thread 等。言語からは見えない |
| evidence | algebraic effect operation の handler を指す runtime capability |

task は「OS thread」を意味しない。同じプログラムを単一 thread の cooperative
scheduler、複数 Worker、WASI host task、shared-everything thread のいずれへ
lower しても、以下の意味論を保つ。

## Core surface

概念上の最小 surface は次のとおりとする。

```vibe skip
effect Async {
  suspend() -> Unit
}

effect Spawn[r] {
  spawn[T: Send, e](() -> T with { e }) -> Task[r, T]
  cancel[T](Task[r, T]) -> Unit
}

effectset Concurrent[r] = {
  Async::suspend,
  Spawn[r]::spawn,
  Spawn[r]::cancel,
}

enum TaskError {
  Failed(String);
  Cancelled;
}

enum SendError {
  Closed;
}

enum ChannelConfigError {
  NegativeCapacity;
}

// nursery { n => body } introduces a fresh r and handles Spawn[r].
// NOTE: 以下は v0.4.0 の提案 surface（region-bound `Task[r, T]` + `Spawn[r]`）で
// あり、#1227 で撤去した eager prototype の `Task::spawn` とは別物。名前は同じ
// だが型も意味論も異なる——現時点でコンパイルできる API ではない。
Task::spawn: [T: Send] (() -> T with { e })
  -> Task[r, T] with { Spawn[r]::spawn }
Task::join: (Task[r, T])
  -> Result[T, TaskError] with { Async::suspend }
Task::cancel: (Task[r, T]) -> Unit with { Spawn[r]::cancel }
Task::yield: () -> Unit with { Async::suspend }

Channel::bounded: [T: Send] (Nursery[r], Int)
  -> Result[(Sender[r, T], Receiver[r, T]), ChannelConfigError]
Sender::send: (Sender[r, T], T)
  -> Result[Unit, SendError] with { Async::suspend }
Receiver::recv: (Receiver[r, T])
  -> Option[T] with { Async::suspend }
```

`nursery { n => body }` は fresh な region `r` と `Nursery[r]` を導入し、
`Spawn[r]` handler を設置する標準構文である。式の結果は
`Result[T, TaskError]` とする。`Spawn[r]` は scope 外へ discharge されるが、
body が使った `Async::suspend` その他の operation は通常どおり外側へ残る。

`Task::spawn` は child の完了を待たず handle を返し、親にとって suspend point
ではない。cooperative backend は child を ready queue へ追加する。parallel
backend では handle が返る前に child が進む場合もあるため、spawn 直後の実行順を
プログラムから仮定してはならない。

child の返り値も child heap から joiner へ渡るため `T: Send` を要求する。
recover 可能な failure を `Result[U, E]` で返す場合は `U` と `E` も structural
`Send` でなければならない。

`race` と `timeout` は上記 primitive から構成できる library combinator とする。
#1227 で撤去した eager `Task::race` / `Task::timeout` の挙動は契約に含めない。task handle の
affine consumption が定義されるまでは、loser を暗黙に所有・cancel する primitive
`race(Task, Task)` を core に置かない。

## Region と structured concurrency

`r` は nursery ごとに生成される nominal な region であり、ユーザーが名前を
偽造できない。次を型検査で保証する。

- `Task[r, T]`、`Sender[r, T]`、`Receiver[r, T]`、`Nursery[r]` は nursery の
  戻り値、外側の mutable cell、escaping closure へ保存できない。
- nursery が `Closed` になる前に、その region の全 task は terminal state、
  channel waiter は解放済みでなければならない。
- close 開始後に同じ nursery へ spawn できない。
- child closure が capture できるのは `Send` な値、同じ `r` の許可された endpoint、
  fork 可能な effect evidence だけである。外側の `let mut` cell、`Write[r2]`
  capability、continuation の capture は reject する。

`nursery` の正常な body 終了は、未完了 child の join を開始する。body または child
が `Failed` になると nursery は fail-fast で sibling に cancel を要求し、全 child
の終了を待って `Err(Failed(...))` を返す。recover 可能な child failure は
`T = Result[U, E]` の値として表現する。

child boundary まで未処理の `Error::Throw(message)` が到達した場合は
`Failed(message)` へ変換する。child 内で handle された Error と、正常な返り値に
含まれる `Err(e)` は task failure ではない。

明示的に cancel された child の `Cancelled` は、それだけでは nursery 全体の
failure にしない。外側から nursery 自身が cancel された場合は全 child を cancel
し、`Err(Cancelled)` を返す。複数の failure が競合した場合、scheduler が最初に
観測した failure を代表値とし、順序は非決定的である。

Wasm trap、process abort、host の強制終了は初期仕様では `TaskError` へ変換せず、
instance 全体の failure とする。

## Lifecycle

task の状態遷移は次の形に限定する。

```text
Created -> Ready -> Running <-> Suspended
                     |              |
                     +-> Succeeded <-+
                     +-> Failed
                     +-> Cancelled
```

terminal state は一度だけ確定し、以後変化しない。`join` は複数回呼ばれても同じ
outcome を返す。`cancel` は idempotent で、terminal task には作用しない。

cancel は cooperative である。`join`、blocking `send` / `recv`、`yield`、
`sleep`、host await に加え、Ready task の dispatch を cancel point とする。したがって
まだ body を開始していない child も dispatch 前に cancel できる。要求は次の cancel
point で観測するが、Running task が次の cancel point より先に完了した場合は、その
完了 outcome が確定してよい。
cancel を観測しない CPU loop の prompt termination や fairness は v0.4.0 では
保証しない。

nursery は次の状態を取る。

```text
Open -> Cancelling -> Closing -> Closed
   \-----------------> Closing
```

cancel と non-local exit は stack を unwind し、登録済み finalizer をちょうど一度
実行しなければならない。したがって replay handler を generalized evidence
passing + 明示 suspend IR へ置き換える ADR-0076 (#817) と、`dynamic-wind` 相当の
finalization 規則は、並行 runtime を compliant と呼ぶ前提である
(ADR-0076 は「Cont[R] を破棄すれば通常の RC drop で capture 済み資源が解放
される」という Perceus ベースの最小保証までを約束し、明示的な finalizer 登録
API の要否は本 ADR 側の判断に委ねている)。

## Lean lifecycle oracle

task / nursery lifecycle の backend 非依存な部分は、次の Lean モデルを
machine-checkable oracle とする。

- `formal/VibeFormal/Async/State.lean`: task、nursery、cancel request の論理状態
- `formal/VibeFormal/Async/Transition.lean`: scheduler event ごとの遷移関係
- `formal/VibeFormal/Async/Trace.lean`: 許容された遷移だけからなる有限 trace
- `formal/VibeFormal/Proofs/AsyncSafety.lean`: terminal outcome と join result の安定性
- `formal/VibeFormal/Proofs/NurseryCorrect.lean`: spawn / close と nursery phase の安全性
- `formal/VibeFormal/Proofs/AsyncExamples.lean`: 正例と、拒否される壊れた trace

モデルでは task の未登録状態から `spawn` すると `Ready` になるため、上図の
`Created` は独立状態として保持しない。`Suspended` は待機理由を持つ `Blocked` として
表現する。task の terminal outcome は `Succeeded` / `Failed` / `Cancelled`、nursery
は `Open` / `Cancelling` / `Closing` / `Closed` を持つ。

遷移関係は次を固定する。

1. `spawn` は nursery が `Open` で task id が未使用のときだけ許可する。
2. cancel request は冪等であり、dispatch、suspend、blocked wait のいずれかでだけ
   `Cancelled` として観測できる。
3. 明示的に child 一個を cancel しても nursery の成功 cause は failure に変わらない。
4. 複数 child の failure は scheduler が最初に観測したものを保持する。どれが最初かは
   非決定的だが、`Closed` へ進む前に全 child が terminal でなければならない。
5. terminal task と `Closed` nursery は後続 trace で変化しない。したがって複数回の
   join は同じ outcome を観測する。

実装は event trace をこの遷移関係へ射影できなければならない。cooperative、JSPI /
Worker、WASI、shared-everything の差は、許容される次 event の選択として表し、公開
lifecycle を別定義しない。

この oracle は heap、thread、host waitable、channel queue、message linearization、
fairness、無限 trace、finalizer stack をまだモデル化しない。特に terminal state の
一回性は証明済みだが、具体的な unwind が各 finalizer をちょうど一度実行することは
未証明であり、#817 の lowering と別の refinement proof / differential test が必要で
ある。Channel semantics は後続の独立モデルでこの lifecycle oracle に接続する。

### Parallel refinement oracle

multi-worker backend は lifecycle を置き換えず、次の Lean overlay で async oracle を
refine する。

- `formal/VibeFormal/Parallel/State.lean`: worker slot、task assignment、heap owner
- `formal/VibeFormal/Parallel/Transition.lean`: claim / release と async event への射影
- `formal/VibeFormal/Parallel/Trace.lean`: physical worker trace
- `formal/VibeFormal/Proofs/ParallelSafety.lean`: assignment invariant、trace refinement、
  task-local heap の非共有
- `formal/VibeFormal/Proofs/ParallelExamples.lean`: 二 worker 実行、release、二重 claim と
  共有 access の拒否例

各 `Running` task はちょうど一つの worker slot に割り当てられ、同じ task を二 worker
が同時に claim できない。suspend / cancel / completion では slot を release し、wake 後
の再 dispatch は別 worker を選んでもよい。worker affinity と task migration は公開の
観測対象にしない。

すべての parallel step は対応する async step を内包し、parallel trace 全体を既存の
async trace へ射影できなければならない。したがって backend は thread を追加するために
cancel point、first-failure、nursery close 条件を変更できない。物理的に同時な実行は
event の interleaving として表す。task 間に共有 mutable location がないことを前提に、
この順序付けは公開観測を失わない。

heap safety は location ごとに owner task が一つだけ存在し、running task は owner が
自分である location だけ access できる、という copy-on-send の抽象 contract で表す。
この contract と worker assignment の一意性から、異なる worker は同じ task-local
location に access できない。実装の deep copy、fresh allocation、move 最適化がこの
owner relation を実現することは別の refinement obligation であり、現時点では Lean が
具体的 allocator や Wasm memory access を検証したものではない。

## Safe parallel API

v0.4.0 では `Thread`、worker handle、shared reference を新しい公開 primitive にしない。
安全な並列 API は既存の `nursery` / `Task[r, T]` / channel とし、`Task::spawn` された
child を同時に実行するかは backend と host policy が決める。同じプログラムは
cooperative な一 worker でも multi-worker でも同じ async oracle の trace だけを生成する。

API boundary は次を必須とする。

- spawn closure は `Spawnable[r]` を満たし、capture は `Send` value、許可された同一
  region endpoint、fork-safe evidence に限る。戻り値は `T: Send` とする。
- mutable cell、handler stack、continuation、`TaskContext`、`Task` / `Receiver` handle
  を worker 境界へ渡さない。message と child result は deep-copy snapshot を基準とする。
- raw blocking FFI を child から呼ばせず、host await は `Async::suspend` と明示された
  adapter を通す。backend 内部の blocking pool は公開 `Thread` API にしない。
- cancel / failure / finalizer は worker の kill ではなく task lifecycle event として処理
  する。host が worker を強制終了した場合は task failure への安全な変換を証明できない
  限り instance failure とする。
- external effect の実行順が必要な場合は、一つの owner task へ channel で集約する。
  worker id、completion time、CPU count から順序を作らない。

worker 数は compiler driver の `--jobs N` や embedding host の runtime config など
instance 外の resource policy とする。`N >= 1` を起動時に検証し、値を vibe program
から取得する安定 API は設けない。generic CLI の具体的な option spelling は実装時に
決める。これにより worker 数を増減しても program の分岐や compiler output が
変わらない。

`Parallel::map`、bounded work queue、ordered result collection は、上記 primitive から
作る library combinator とする。特に `Parallel::map` は入力 index 順に結果を返し、
task completion 順を公開しない。`FrozenArray[T]` と bounded channel の contract が
実装されるまでは core primitive や安定 API として先行追加しない。

## Channel semantics

初期 channel は bounded MPMC とする。capacity は 0 以上の `Int` で、0 は
rendezvous channel、負値は `NegativeCapacity` である。unbounded channel は
backpressure を失うため core に含めない。

- `send` は buffer に空きができるか receiver と rendezvous するまで suspend する。
- `recv` は message が届くか channel が close するまで suspend する。
- 同一 Sender から成功した send の program order は保持する。異なる Sender 間の
  順序は、成功した enqueue / rendezvous の linearization order で決まり、
  非決定的である。
- 最後の Sender handle が release されると channel は close する。buffer 済みの
  message をすべて受信した後、`recv` は `None` を返す。
- nursery の正常 close でも残る endpoint を close する。nursery cancel 時は
  waiter を cancel し、未配送 buffer を破棄して scope を閉じる。
- closed channel への `send` は `Err(Closed)`。空文字列、`-1`、false 等を sentinel
  に使わない。
- blocked send が cancel された場合、その message は enqueue されない。blocked
  recv が cancel された場合、message を消費しない。cancel と channel operation の
  競合は一つの linearization point で解決する。

message の値は send 成功の linearization point で snapshot される。基準実装は
deep copy であり、受信側は sender の heap への参照を得ない。zero-copy や move は
この観測結果を変えない最適化に限る。

明示 `close(sender)` は affine handle の consumption 規則が入るまで core に
含めない。close 責務は「任意の sender 一個」ではなく、最後の Sender の release と
nursery scope によって決まる。

## `Send` と capture safety

`Send` は user が `unsafe impl` できる通常 trait ではなく、compiler が型構造から
判定する marker とする。初期 allowlist は保守的にする。

`Send` になるもの:

- `Unit`、`Bool`、`Int`、`Double`、`String`
- 全 field が `Send` で mutable field を持たない tuple / struct / enum
- 上記から構成される `Option` / `Result`
- runtime が特別に認識する同一 nursery 内の `Sender[r, T]`

初期仕様で `Send` にならないもの:

- `Array`、`ArrayBuilder`、`Bytes`、mutable field を持つ struct、captured `let mut`
- closure、handler evidence、continuation、`Task` / `Receiver` handle
- host resource と opaque FFI value（contract で安全性を証明した組み込みを除く）

closure 自体を message として送ることはできない。spawn closure には別途
`Spawnable[r]` 判定を行い、全 capture が `Send` または許可された同一 region handle
で、child の effect row が閉じており、必要 evidence が fork 可能であることを
要求する。

`FrozenArray[T]` 等の immutable bulk container は compiler multi-worker dogfood の
前提として追加し、`T: Send` なら structural `Send` とする。mutable graph の
graph-copy、alias 保存、cycle 処理が定義されるまでは、deep copy できそうという
理由だけで mutable `Array` / `Bytes` を `Send` にしない。

## Algebraic effects との関係

並行性そのものを巨大な `Async` atom にまとめず、ADR-0071 に従って operation 単位
で追跡する。

- `Spawn[r]::spawn` / `Spawn[r]::cancel` は child lifecycle を変更する権限。
  `nursery` が handler を設置・放電する。
- `Async::suspend` は現在の task を suspend する権限。`join` と blocking channel
  operation が要求する。
- channel の送受信権限は effect row ではなく `Sender` / `Receiver` の値が持つ。
  これにより channel instance と方向が型に残る。
- `effectset Concurrent[r]` は便利な透明 alias にすぎず、独自 handler や runtime
  identity を持たない。

handler stack と continuation は task-affine とする。`perform` が捕捉した continuation
は同じ task で一度だけ resume でき、channel message、spawn capture、global state に
保存できない。別 task から resume することは禁止する。

child は親の dynamic handler stack を暗黙に複製しない。spawn boundary では child
closure の閉じた effect row を明示し、その operation の evidence が fork 可能かを
検査する。v0.4.0 では `Async` / `Spawn` runtime evidence と、package contract で
fork-safe と定めた built-in host capability だけを fork できる。user-defined handler
は既定で task-local とし、user が fork-safe を宣言する surface は後続 ADR にする。

### Executable authority contract

ADR-0075 に従い、task/process が持つ authority は host と parent の部分集合とする。

```text
Root.authority  = VibexEntry.requires
Child.authority = Child.transitiveRequirements

Child.authority ⊆ Parent.authority ⊆ ComposedHost.provides
Child.authority ⊆ ComposedHost.forkable
```

physical thread / Worker / worker slot は独自の ambient authority を持たない。実行中の
task authority を一時的に借りるだけであり、task migration、worker pool reuse、worker
数の変更で authority が増減してはならない。

spawn closure の latent effect を root executable contract から落としてはならない。

```text
Req(spawn f)     = { Spawn[r]::spawn } ∪ Req(f)
ForkReq(spawn f) = Req(f) ∪ ForkReq(f)
```

したがって child だけが `S3[Posts]::get_object` を行う場合も `.vibex` entry はその
resource-qualified operation を要求する。provider/host が operation を提供するだけでなく
fork-safe evidence として委譲可能でなければ spawn contract は満たされない。host が
より強い operation を持っていても parent authority に無い operation を child へ渡す
ことは禁止する。

authority は v0.4.0 では immutable とし、動的 grant/revoke は導入しない。将来の
`Process[Msg]` も同じ principal hierarchy を使い、親より長生きする場合は supervisor
への ownership 移管を明示する。詳細、resource/provider contract、Lean Oracle は
[vibex-runtime-contract.md](vibex-runtime-contract.md) を参照する。

## Memory and runtime context

各 task は論理的に独立した heap / arena と `TaskContext` を持つ。単一 linear memory
内で実装しても、別 task の arena を指す user-visible reference を作ってはならない。

`TaskContext` には少なくとも次を集約する。

- task id、nursery id、lifecycle / cancel state
- allocator / heap arena と message copy context
- evidence vector / handler stack と suspend continuation
- channel / task waiter registration と scheduler state
- finalizer stack、top-level thunk memo、runtime bookkeeping

既存の bump heap pointer、effect 固定 region、operation index、lazy thunk memo 等の
mutable global は task-local / nursery-local context へ移すか、spawn 前に初期化して
immutable に freeze する。言語から観測できる unsynchronized mutable global を追加
しない。

message の move 最適化を許すのは、compiler が sender 側の last use と、到達可能な
全 allocation が一つの transferable arena に閉じていることを証明できる場合だけ
である。root object の `refcount == 1` だけでは内部 alias や別 arena 参照を排除できず、
move の根拠にしてはならない。

言語の memory model は data-race-free とし、shared mutable reference、atomic、lock、
weak-memory ordering を公開しない。shared-everything backend もこの制約を破らない。

## Scheduler observability

schedule は非決定的である。プログラムが依存してよい同期点は spawn、suspend、
task completion、channel linearization、nursery close だけとする。複数 child の
Stdout 等、外部 effect の順序が重要なら channel で一つの owner task へ直列化する。

cooperative backend は suspend point でのみ task を切り替えてよい。parallel backend
は任意の時点で別 task を進められるが、task-local state しか共有しないため、観測差は
許された message / external-effect order に限られる。テスト用 scheduler は seed と
trace を受け取り、同じ backend・seed で再現可能にする。

## Compiler self-parallelization

compiler を ADR-0068 の reference workload とする。最初の並列単位は import
DAG 上で依存が terminal になった module の parse/typecheck であり、現在の mutable
`TypeDb` を複数 task から共有しない。driver が source snapshot、DAG、result store、
cache publish を所有し、worker は immutable な source + dependency interface から
成功 artifact または diagnostics の値を返す。

通常の parse/type error は `TaskError` にせず recoverable な `ModuleOutcome` として
返す。compiler は outcome を module path / source span の canonical order で確定し、
nursery が最初に観測した failure や task completion order を診断・Wasm index・cache
key に混ぜない。trap や compiler invariant 違反だけを task failure として sibling
cancel へ流す。

最終 codegen は、function/type/constructor/string/effect index と per-function id range
を serial planning pass で freeze した後に限り function body 単位で並列化する。link と
cache publication は canonical coordinator operation とする。詳細な worker contract、
cache atomicity、TDD gate、Lean model の対応は
[compiler-parallelism.md](compiler-parallelism.md) を source of truth とする。

## Backend mapping

| Backend | suspend | isolation / message | parallelism | 位置づけ |
| --- | --- | --- | --- | --- |
| core wasm cooperative | 明示 suspend IR + evidence/yield | 同一 memory 内の task arena + deep copy | なし | 基準実装、決定的テスト |
| browser JSPI | `WebAssembly.Suspending` / `promising` | Worker ごとの instance/heap + `postMessage` 相当 | Worker 数まで | JSPI は stack suspension のみ。task pinning を許す |
| WASI Component Model | async lift/lower、waitable、task built-in | component/resource 境界 | host 実装次第 | vibe nursery が host より強い lifetime/fail-fast 規則を追加 |
| shared-everything threads | thread intrinsic + shared store | task arena を論理分離。message API は不変 | host thread 数まで | #488 の opt-in 実験。zero-copy は証明時のみ |

### Native/WASI backend implementation policy

production の native/WASI multi-worker 実装は、guest が `wasi::thread-spawn` を直接
呼ぶ形ではなく、Wasmtime embedding host が worker pool を所有する形を採る。
`Engine` と compile 済み `Module` は host 内で共有できるが、各 worker は別々の OS
thread、`Store`、`Instance`、linear memory、effect evidence table を持つ。worker 間で
渡せるのは `Send` を満たす immutable snapshot/message だけであり、結果 publish と
canonical commit は coordinator に限定する。

この選択は backend 実装の決定であり、公開 `Task` API に thread id、Wasmtime flag、
`Store`、shared memory を露出しない。Wasmtime Component Model threading が安定した
場合も、同じ lifecycle trace、task-local heap/evidence、message-copy 契約を満たす
adapter として置換する。

移行までの executable prototype は Node.js `worker_threads` を scheduler/ownership
境界に使い、実 selfhost check は各 worker が所有する永続 stage2 daemon で実行する。
これは process-shaped な現行 JavaScript host runner を再利用する暫定 transport で
あり、論理 `ModuleJob -> ModuleOutcome`、ready rule、failure classification、canonical
commit は production backend と同じに保つ。transport の差は Lean oracle の状態や
event 語彙へ入れない。

Core Wasm Threads の shared memory/atomic と WASI Threads の guest-side spawn は、
shared-nothing 基準意味論を実装するための必須機能ではない。これらを使う経路は
#488 と同様に opt-in 実験とし、通常 backend へ昇格するには task-local isolation と
同一 conformance trace を別途示さなければならない。

JSPI は WebAssembly proposal registry で Phase 4、Safari 27 beta でも実装が告知され、
Firefox も実装を追跡中である。browser version matrix は backend 選択の入力であって、
公開意味論の blocker ではない。JSPI が無い環境は cooperative/state-machine lowering
へ fallback できる。

Component Model の concurrency は host task と thread の primitive を提供するが、
vibe の「nursery close 前に全 child が terminal」という強い規則は language runtime
側で維持する。host primitive の最小保証へ意味論を弱めない。

## #488: shared-everything 実験の境界

#488 の成果は backend feasibility と flag/probe の検証に限定し、次を公開 API に
しない。

- `thread.spawn-ref` 等の proposal intrinsic
- Wasmtime 固有 flag、thread id、available parallelism
- shared reference、shared function、atomic、lock
- raw Int channel id や String 専用 message

shared-everything-threads proposal 自体も WebAssembly registry では Phase 1 の
draft である。2026-07-16 時点の #488 では、local patch 上の shared `i31`
subset と既存 Component Model `canon thread.new-indirect` 系は確認できる一方、
`thread.spawn-ref`、
`thread.spawn-indirect`、`thread.available-parallelism` は Wasmtime の unsupported
intrinsic path に入り、proposal test と parser/runtime の名前にも差がある。このため
shared-everything path は feature detection と probe に合格した build だけで有効化し、
通常 CI / release gate にはしない。

#488 を production lowering 候補へ昇格できる条件は次のすべてである。

1. proposal grammar と Wasmtime intrinsic 名が一致し、upstream regression test が通る。
2. shared heap type、function/table/composite type、必要な component intrinsic が実装済み。
3. task-local evidence、cancel、finalizer、arena isolation を壊さない。
4. cooperative backend と同じ conformance trace 集合を満たす。
5. patched local Wasmtime でなく、version 固定できる upstream release で再現する。

## Conformance locks

実装は次を Red から固定する。

Static rejection:

- `Task[r, T]` / endpoint / nursery token の region escape
- mutable cell、non-`Send` value、task-local evidence の spawn capture
- non-`Send` message と別 task からの continuation resume
- nursery close 中の spawn、負 capacity

Lifecycle and failure:

- suspend する child に対し `spawn` が completion を待たない
- nursery 正常終了時に orphan task が残らない
- child failure が sibling cancel と全 child の収束を引き起こす
- cancel / join の idempotence、finalizer exactly-once
- replay による pre-perform side effect の重複がない

Channel:

- capacity 0 rendezvous、bounded backpressure、sender 内 FIFO
- sender 間の許された順序違い、last-sender close、buffer drain 後 `None`
- closed send の `Err(Closed)`
- send / recv と cancel の競合で duplicate / loss が起きない
- send 後の sender 側変更が receiver snapshot に見えない

Backend differential:

- cooperative を oracle とし、JSPI/Worker、WASI、shared-everything の trace を
  許容された非決定順序へ正規化して比較する
- scheduler seed と event trace から failure を再現できる
- #488 probe は opt-in 環境だけで走り、不在を通常 CI failure にしない

## 実装順

ADR-0075 の `.vibex` entry、semantic contract emission、local provider preflight は
下記 runtime 実装と独立に先行できる。ただし child へ operation/resource 単位の
evidence を実際に委譲する段階は、ADR-0076 (#817) の evidence passing と
`TaskContext` 分離後に行う。

1. 本仕様と negative/type fixtures を固定する。
2. ADR-0076 (#817): replay handler を evidence passing + yield bubbling へ置換し、
   共通の `Suspend` IR (ADR-0076 の `EPerform`/`EHandle`) と finalizer unwind を
   作る。ADR-0076 のロールアウトは Phase 1〜3 相当 (M2 回帰 pin → tail-resumptive
   hybrid → yield bubbling で replay 全廃) に分かれ、本項目が「compliant」と
   見なせるのは ADR-0076 Phase 3 完了後。
3. mutable global を `TaskContext` へ集約し、単一 thread の deterministic scheduler
   と nursery state machine を実装する。
4. region escape、`Send`、`Spawnable[r]`、fork-safe evidence の checker を実装する。
5. deep-copy channel、cancel atomicity、failure propagation を実装する。
6. compiler を `--jobs 1` の順序ランダム化 scheduler へ移し、module
   outcome と Wasm bytes の決定性を固定してから module DAG を dogfood する。
7. JSPI / Worker と WASI Component Model lowering を conformance suite に接続する。
8. multi-worker を有効化し、最後に #488 shared-everything lowering と証明可能な
   move/zero-copy を opt-in で追加する。

### 実装ノート (2026-07-24): cooperative run-to-completion slice

`lib/@vibex/concurrent/` に本仕様の最初の runtime slice を追加した。単一
thread の決定的 FIFO scheduler で、`spawn` は deferred(eager prototype は
契約外のまま)、blocking 操作 (join / send / recv / nursery close) が ready
queue を呼び出しスタック上で駆動する run-to-completion 方式。継続を使わない
ため ADR-0076 Phase 3 の suspend IR を待たずに次を conformance lock として
テストで固定した: join 冪等・terminal 安定、dispatch 前 cancel と cancel
冪等、fail-fast sibling cancel + first-observed failure、child の
`Error::Throw` → `Failed` 変換、`Err` 値は task failure ではない、bounded
MPMC channel (capacity 0 rendezvous / `NegativeCapacity` / per-sender FIFO /
last-sender release close / drain-then-`None` / closed send `Err(Closed)`)、
nursery close の endpoint close。

未実装(本 slice の scope 外、実装順の後続 step): region 生成性と escape
check、`Send` / `Spawnable` 判定、blocking API の `Async::suspend` row、
mid-run cancel 観測、deep-copy snapshot(単一 heap のため immutable 値の
送信を前提)、`Task::yield`。双方が body 途中で block し合う 2 task
(容量超過 producer + 貪欲 drain consumer の相互 block)は本方式では表現
できず deadlock trap になる — suspend IR 着地後に内部を差し替える。

命名: 本書の概念名 nursery (Trio 系譜) は spec 用語として維持し、
library の型/APIは `TaskGroup` (asyncio / Swift 系譜) とした —
LLM/読者にとって最も広く学習・認知されている綴りを採る判断
(2026-07-24)。将来の構文糖衣も `taskgroup { g => ... }` を予定。

実装中に #1070 の一般ケースが **pure closure でも再現する**ことを特定した
(capturing closure を by-value 引数で callee に渡して store すると 3 個目
から破損。effect/evidence 非依存)。`TaskGroup::spawn` は store を inline 化
する workaround で回避している。最小 repro は #1070 のコメント参照
(store サブケースは #1085 へ切り出し済み)。

### 実装ノート (2026-07-24 追記): `Send` marker (実装順 step 4 の第一片)

checker に compiler 判定の structural `Send` を実装した。`Send` は
`register_builtin_traits` で trait def として seed され(primitive は
nominal impl も併記)、`[T: Send]` bound の enforcement は
`check_program_bounds` から `type_send_ok`
(`checker/checker_trait.vibe`) に dispatch する。判定は本書の
allowlist どおり: primitives / tuple / Option / Result / mut field を
持たない struct / enum(generic instantiation・再帰型は coinductive)
が Send、`Array` / `Bytes` / closure / mut-field struct / 未解決型は
非 Send。`impl Send for X` は「compiler-judged marker」として reject。
generic enum は TDEnum が payload を宣言時 fresh `CtVar` で保存する
ため、ctor の `CtForAll` binder から var id を回収して positional に
置換する(struct は名前ベースの `subst_type_params` で足りる)。

fixtures: `send_bound_structural.vibe`(positive, 実行 42)+
`err_type_send_{array_bound,mut_struct_bound,closure_bound,user_impl}`、
compiler gate 47/47。`@vibex/concurrent` の `TaskGroup::spawn` /
`Channel::bounded` / `Parallel::map` に `[T: Send]` bound を配線済み。
未着手: spawn closure の capture 検査(`Spawnable`)、`Sender[r,T]` の
同一 nursery 特例、region 生成性。

### 実装ノート (2026-07-25 追記): suspend 継続の第一級化 (ADR-0076 Phase 3a)

実装順 step 2 の入口が着地: handler arm が `resume` を第一級 one-shot 値
として保存し、後から別の dynamic extent で呼べるようになった (linear
backend、depth-0 — perform が handle body 直下にある場合のみ)。これは
本 ADR の `Async::suspend` が要求する「scheduler が継続を受け取る」形
そのもので、`fixtures/effect_resume_store_scheduler.vibe` が
suspend → 外部から resume → 次の suspend → 完走のサイクルを pin する。
次の一手 (3c) は `TaskCell` に継続 slot を足して cooperative scheduler
の run-to-completion 制約 (mid-body の相互 blocking 不可) を解除する
こと。詳細は [effect-evidence-passing.md](effect-evidence-passing.md)
追記27/28。

### 実装ノート (2026-07-25 追記2): 3c — suspendable task
(`@vibex/concurrent` への接続、run-to-completion 制約の部分解除)

Phase 3b (yield bubbling、追記29) を受けて、`@vibex/concurrent` に
suspendable task の第一スライスを実装した:

- `TaskCell` に**継続 slot** (`mut cont: Option[(Int) -> Unit]`) と
  parked 状態 (status 5) を追加。`TaskGroup` は adopted list +
  round-robin の pump カーソルを持つ。
- 新 API: `TaskGroup::adopt` / `TaskHandle::settle` / `TaskHandle::park`
  (arm の第一級 `resume` を T 消去 wrapper で slot へ保存) /
  `TaskHandle::wake(v)` (wake 値を届けて再開) / `TaskGroup::pump` /
  `pump_all` (yield された task を round-robin で駆動)。
  `effect Async { Suspend(Int) -> Int }` は package contract の透明
  宣言 (#752)。
- task body の handle site は 2 通り: adoption site (`adopt`/`settle` の
  canonical shape、concurrent.vibe の Suspendable tasks 節) と、
  **`TaskGroup::spawn_suspend(g, f)`** — closure-CPS ABI (ADR-0076
  追記31 Vertical B) の着地で handle site が library 内部へ移り、caller
  は `() -> T with { Async } { ... }` の plain closure を渡すだけに
  なった (suspend する literal には明示 row 注釈が必要、#761)。
- **channel の mid-body blocking も着地**: `Sender::send_wait` /
  `Receiver::recv_wait` (`with { Async }`)。バッファ満杯の send は
  deposit → suspend → 消費 (pend_consumed) を自己再帰で待ち、空の recv
  は suspend → 再検査 (loop spine 非対応のためリトライは再帰 — 3b の
  再帰 clone がそのまま処理する)。capacity-0 rendezvous も同経路。
  producer が capacity-1 を溢れさせ consumer が drain する相互 blocking
  (run-to-completion では不可能と header が明記していた形) が
  suspend_test.vibe で conformance lock 済み。`TaskGroup.progress`
  カウンタ + `pump_all` の全周無進捗検出で、詰まった channel 待ちは
  livelock ではなく deadlock trap になる (drive_one の規則と同型)。
  stack-driving の `Sender::send` / `Receiver::recv` は `send_wait`/
  `recv_wait` と同じ linearization (buf/pend/pend_seq/pend_consumed) を
  共有する。**#1181 追記**: `TaskGroup`/`Channel`/`Sender`/`Receiver` が
  `e` について row-polymorphic 化されたことに伴い、`Sender::send`/
  `Receiver::recv`/`TaskHandle::join` の宣言 row は row-free から
  `with { e }`(row 変数)へ変わった。ADR-0076 の suspend/CPS lowering
  (`inline_direct_perform.vibe` の `scps_calls_ok`/`scps_row_has_var`) は
  row 変数を持つ callee を常に保守的に拒否するため、`Async` を持つ
  `spawn_suspend` closure literal の**内側**から呼ぶ場合は引き続き
  row-free ではなく具体的な `with { Async }` row を持つ `send_wait`/
  `recv_wait` を使う必要がある(この2関数の呼び出し側は変わっていない)。
  **Suspend payload 規約**: `0` = cooperative yield / `1` = poll wait。
  adoption-site の arm は理由を伝播する
  `TaskHandle::park_poll(h, resume, r == 1)` を canonical とする —
  plain `park` は yield 扱いなので、channel 待ちを plain park で park
  すると deadlock trap に見えず livelock になる (#1111 Codex review)。
  yield は deadlock の証拠に数えない (resume は常に body を前進させる;
  無限 yield は通常の無限ループ)。
- **fail-fast × suspendable の統合も着地**: `spawn_suspend` の body row は
  `{ Async, Error }` になり、escape した `Error::Throw` は Failed へ変換
  される。settle leg は spawn_suspend 内の外側 Error handle (Async handle
  は CPS 化済みなので handler 越え resume は存在せず #543 の罠は当たら
  ない)、resume 後の leg は park wrapper の per-leg Error boundary が
  受ける (pump の stack 上で走るため)。失敗は group の first-observed
  failure を記録し、**parked sibling を自動 cancel** (継続 drop = RC 解放)
  して pump_all を自然終了させる。run は Err(Failed(first)) を返す。
- conformance lock (`suspend_test.vibe`): **2 task の mid-body 相互
  interleave** (run-to-completion では不可能だった形 — log が厳密交互)、
  wake 値の suspension point への配達、parked task の cancel (継続 drop
  = RC 解放、ADR-0076 の保証)、suspend しない body の同期 settle。
  parked のまま group close → deadlock trap (join と同じ規則)。

cancel は parked 状態でも観測されるようになった (mid-run cancel 観測の
第一歩)。fail-fast と adopted task の統合 (parked sibling の自動
cancel) は次スライス。#1097 (suspend 継続の local capture × 複数 site の RC trap) は根治済み — 当初の `md_capturing_fn_count` 補償は owned-captures closure ABI (ADR-0076 追記31 Vertical A: closure env が heap capture を creation dup で所有し class-7 drop が再帰解放) に置き換わり、補償テーブルは撤去された。suspend_test がローカル capture 形のままregression lock。

### 実装ノート (2026-07-27 追記): region 生成性 (実装順 step 4、#1081 step 3)

`TaskGroup::run` が呼び出しごとに新しい生成的 region を発行するようになった。
checker に一般化された rank-2 多相や `Region` bound の仕組みは存在しない
(確認済み — `CtForAll` は `let`/`letrec` の通常多相のみ、呼び出し側が
choose する fresh var を返す `instantiate` しかなく、型に scope タグを
付けて escape を検査する既存機構もゼロだった)。そのため `TaskGroup::run`
という qualified name を `resume` と同様に checker が直書きで特殊扱いする
(`checker/checker.vibe` の `ECall(EIdent(name),...)` 分岐、`name ==
"TaskGroup::run"` の枝)。

- **region の表現**: `CtNamed("#region_" + gensym, [])`。`#` を含む名前は
  lexer が識別子として受理しないため、パースされたソースは絶対にこの名前を
  偽造できない。`TaskGroup::run` の呼び出しごとに、通常なら fresh `CtVar`
  になるはずの `r` 型パラメータをこの rigid skolem へ直接 bind してから
  body を検査する。
- **struct へ `r` を追加する際の罠**: `TaskGroup[r]`/`TaskHandle[r,T]`/
  `Channel[r,T]`/`Sender[r,T]`/`Receiver[r,T]` の型引数は、構築時
  `struct_fields_ground` (checker.vibe) が「宣言済みフィールド型がすべて
  ground なら型引数を丸ごと捨てて `CtStruct` に潰す」ため、`r` を使う
  フィールドが一つも無い構造体 (`TaskGroup` は元々どの型パラメータも
  使っていなかった) では型引数が構築のたびに消えて追跡できない。
  `TaskGroup` に `_region_witness: (r) -> r`(恒等関数、実行時には一度も
  呼ばれない)という phantom field を足すだけで `type_is_ground` が
  `CtFn` の中の `r` 参照を検出し非 ground 判定になる — unsafe cast も
  新しい checker 機構も要らない。`TaskHandle`/`Channel`/`Sender`/
  `Receiver` は元々 `group`/`ch` フィールド経由で `r` を含む型
  (`TaskGroup[r]`/`Channel[r,T]`) を参照するため witness 不要。
- **escape check の実装**: `TaskGroup::run` の呼び出しを検査し終えた
  「その場」で 2 種類のチェックを行う(`Send` の `check_program_bounds_impl`
  のような遅延・全体パスではない — この呼び出し固有の skolem が対象なので
  即座に判定できる):
  1. **戻り値位置**: body の戻り値型(`T`)を最終 subst で zonk し、
     skolem 名を含んでいれば reject。
  2. **外側 capture**: 呼び出し時点の `env` に見えているすべての
     binding を(`env_cache` と同じ cons chain 走査で)集め、最終 subst
     で zonk して skolem 名を含むものが無いか調べる。呼び出し前に存在した
     bindings だけを見るので、body 内で新しく `let` された名前は対象外。
- **既知のギャップ (未解決、正直に記録)**: 外側 capture check は
  **generalize された `let`/`let mut` local へのリークを検出できない**。
  実測: `let mut arr = [None]` に対して型の異なる 2 回の `Array::set`
  (`Some(1)` → `Some("str")`) がどちらも通ることを確認済み — この
  checker は `let`/`let mut` binding を(mutable でも)generalize する
  ため、body 内で `arr` を参照するたびに独立した fresh instantiation が
  返り、env に保存された scheme 自体は一切変化しない。したがって
  `let mut leaked = [None]; TaskGroup::run((n) => { ...; Array::set(leaked,
  0, Some(rx)) })` のような、旧 `concurrent_test.vibe` が実際に使っていた
  leak パターンは **現状のこの slice では検出できない**。戻り値位置の
  escape (`fixtures/err_region_escape_return.vibe`) だけがこの slice の
  確定した保証であり、`fixtures/err_region_escape_outer_mut.vibe` のような
  「必ず reject される」fixture は追加していない(誤って通ってしまう
  fixture を追加するのは不正直なので)。閉じるには generalize を
  region-checking 中だけ抑制するか、型に依存しない AST ベースの escape
  追跡が必要 — 次スライスの課題として残す。
- **fixtures/compiler_gate.sh 59/59**: `region_ok_basic.vibe` (非 escape、
  spawn+join、42 で正常終了)、`err_region_escape_return.vibe` (戻り値
  escape、reject)。両方とも `Send` marker (48/48) と同じ
  `send_check_reject` 型のヘルパーパターンで gate に配線。
- **既知のギャップ 2 (PR #1135 Codex review P1、試みて撤回)**: 特殊扱いは
  callee の**リテラルな綴り** `"TaskGroup::run"` に対する文字列一致であり、
  `let run = TaskGroup::run; run((n) => ...)` のような first-class alias、
  import rename、higher-order wrapper はこの一致をすり抜けて `r` が
  普通の unifiable `CtVar` になる(escape 検査が一切走らない)。一度、
  文字列一致の代わりに callee の**構造的な形**(`(body: (TaskGroup[r]) ->
  T with {e}) -> Result[T, TaskError] with {e}`)で一致させる修正を試みたが、
  コンパイラ自身のソース中の無関係な 1 引数呼び出しに誤爆し unit battery
  20 ファイルが実行時 trap で regress した(`TaskError` が実際には
  `CtEnum("TaskError")` に解決される — `CtNamed` だと決め打っていた
  一箇所のバグで露呈)ため撤回し、リテラル一致に戻した。alias/rename/
  wrapper 経由のすり抜けは this slice の既知のギャップとして
  `lib/@vibex/concurrent/index.vpkg` の `r` コメントに明記した。
### 実装ノート (2026-07-27 追記2): `Spawnable[r]` capture check (#1081 step 3 後半)

上の「未着手のまま」で懸念していた不健全さ(`n` の region が spawn 呼び出し
時点ではまだ skolem へ unify されていない)は実際に起こるが、**inline での
判定自体は健全であることが判明した** — deferred な第二パスは不要だった。
理由: `TaskGroup::spawn(n, f)` を検査する時点で `n` の region はまだ
skolem ではなく、この nursery body の `EFn` パラメータ検査(checker.vibe
の `EFn` 分岐、無注釈パラメータに `fresh_var` を新規発行する箇所)で
割り当てられた、その場限りの `CtVar` のままである。しかし **異なる
`TaskGroup::run` 呼び出しは必ず異なる `EFn` パラメータ検査を経る**ため、
必ず異なる(プログラム全体を貫くモノトニックなカウンタから発行された)
`CtVar` id を得る。したがって「capture の region の zonk 結果」と
「`n` 自身の region の zonk 結果」を比較する際、**両者が構造的に
`CtNamed(skolem_name, [])` なら name で比較、まだ未解決な `CtVar` 同士
なら var id の一致で比較**すれば、後者の場合でも誤って許可することは
ない(同じ nursery 由来の capture だけが同じ var id を共有し、別の
nursery の capture は必ず異なる var id を持つ)。実装は
`checker/checker_spawnable.vibe` の `sp_same_region`。

- **checker 側の配線**: `TaskGroup::run` と同じ場所(`checker.vibe` の
  `ECall(EIdent(name),...)` 分岐)に `"TaskGroup::spawn"` /
  `"TaskGroup::spawn_suspend"` の枝を追加。通常の呼び出しチェック
  (instantiate → 両引数を `check_expr` → `unify_call_args`)をそのまま
  行った**上で**、`n` (第一引数)の zonk 済み region 型引数を
  `check_spawnable_captures`(`checker_spawnable.vibe`)に渡す。
- **capture 収集**: `checker_capture.vibe`(root package `@vibe/compiler`)
  の `collect_free_vars` は checker package から import できない
  (checker package は root package の依存元であり、逆方向 import は
  循環になる)。codegen 側にも別実装(`codegen/common_analysis/
  common_analysis.vibe` の `collect_free_vars_expr`)がすでに存在し、
  この codebase では「解析目的ごとに package 内で複製する」のが既定の
  パターンなので、`checker_spawnable.vibe` 内に自前の走査を複製した。
  **`ECall` の callee 位置にある裸の識別子は capture として数えない**
  (builtin/トップレベル関数/コンストラクタはランタイムの capture を
  要しない一方、`let cb = ...; TaskGroup::spawn(n, () -> { cb() })`
  のように capture された**ローカルの closure 値**を間接呼び出しする
  ケースはこの slice では検出できない — 未対応、既知のギャップとして
  記録)。
- **判定**: `sp_spawnable_ok`(`checker_spawnable.vibe`)— `type_send_ok`
  を満たすか、または `TaskGroup[r]`/`TaskHandle[r,_]`/`Sender[r,_]`/
  `Receiver[r,_]` で `r` が spawn 呼び出し自身の region と一致する場合に
  legal。
- **副産物のバグ修正 (checker 全体に影響、Phase B 固有ではない)**:
  検証中に `check_pattern`(`checker_pattern.vibe` の `PCtor` 分岐)の
  ジェネリック enum ペイロード置換が **常に無効化されていた**ことが
  判明した — `defs`(`TDEnum`)に保存されるペイロード型は
  `checker_stmt.vibe` の `SEnum` 処理時点で既に宣言時の固定 `CtVar` id
  へ置換済みなのに、`check_pattern` 側は名前ベースの `subst_type_params`
  で(存在しない)`CtNamed(paramname, [])` を探そうとしていたため、
  一致せず静かに no-op していた。プレーンな `Result[Int, String]` の
  `Ok(a)` だけで再現する(region も Sender も無関係)一般バグで、
  `CtUnknown` 相当の緩い型がどこでも許容されるために誰も気付いていな
  かった。`checker_trait.vibe` の `send_ok_named`/`send_subst_vars`
  (`Send` 判定がジェネリック enum に対してすでに正しく行っている、
  ctor の `env` 束縛スキーム `CtForAll(param_var_ids, _, ...)` から
  実際の var id を復元して置換する手法)を `check_pattern` にも適用して
  修正。`Foo[r]` のような一般ケースでも `Ok(a)` の `a` が正しく型付け
  されるようになった、副作用として広い範囲の改善。
- **副産物のバグ修正 2**: 地域タグ付き endpoint (`TaskGroup`/
  `TaskHandle`/`Sender`/`Receiver`) を `let` で束縛すると通常の
  Hindley-Milner let 多相と同様に generalize され、以後の各参照が独立
  した fresh instantiation を得てしまい、region の同一性が失われる
  ("同じ nursery 由来" を正しく判定できなくなる)。`ArrayBuilder` の
  既存の value-restriction 特例(`is_array_builder_ty`)と全く同じ理由
  で `is_region_tagged_ty` を追加し、同じ扱いにした。
- **fixtures/compiler_gate.sh 60/60**: `region_ok_spawnable_capture.vibe`
  (同一 nursery の `Sender` capture、42 で正常終了)、
  `err_spawnable_capture_array.vibe`(非 Send な outer `Array` capture、
  reject)、`err_spawnable_capture_cross_region.vibe`(別 nursery の
  `Sender` capture、reject)。
- **既知のギャップ**: `TaskGroup::run` と同じ alias/rename/wrapper すり
  抜け(リテラル名一致のみ)。間接呼び出しされるローカル closure 値の
  capture は検出しない(上記)。adoption レーン(`TaskGroup::adopt` +
  `TaskHandle::settle`)は `TaskGroup::spawn`/`spawn_suspend` の呼び出し
  形をしていないため、この check の対象外のまま(`suspend_test.vibe`
  の adoption-site テストが `log: Array[Int]` を無検査で capture できる
  のはこのため — 意図した既存の適用範囲どおり)。

### 実装ノート (2026-07-27 追記3): `taskgroup { g => body }` 構文糖衣 (#1081 step 4 の一部)

実装順 step 4「表面仕上げ」のうち、構文糖衣の部分を実装した。もう一方
(blocking API への `Async::suspend` row 付与) はすでに
`Sender::send_wait`/`Receiver::recv_wait`/`TaskGroup::spawn_suspend` の
既存シグネチャで満たされていたため、追加作業は不要だった。

- 命名は 2026-07-24 の実装ノートにある「library の型/API は `TaskGroup`」
  という決定に従う。本書冒頭の illustrative セクション (`nursery { n =>
  body }`、`Task::spawn`、`Spawn[r]` capability effect)
  は初期の aspirational 設計であり、実装は別の(より単純な、effect を使わ
  ない region ベースの)形になっているため、構文糖衣も `nursery` ではなく
  `taskgroup` を採用する。
- `taskgroup { g => body }` は `TaskGroup::run((g) -> { body })` への
  純粋な parse-time 書き換えであり、専用の AST variant も desugar pass も
  checker 側の特別扱いも追加していない — parser が今日の手書き
  `TaskGroup::run(...)` 呼び出しと全く同じ `ECall`/`EFn` 形を直接構築する
  だけなので、region escape check・`Spawnable[r]` capture check は無変更
  のまま sugar 越しにも適用される(`err_taskgroup_sugar_region_escape.vibe`
  で確認)。
- 実装: `lib/@vibe/parser/lexer.vibe`(`taskgroup` キーワード追加、識別子
  長 9 の分岐)、`token.vibe`(`TTaskGroup` variant)、
  `parser_expr_primary.vibe`(`parse_control_primary` から mode 26 へ
  ディスパッチ)、`parser_expr_dispatch.vibe`(mode 26: `{` → 束縛識別子
  → `=>` → body(mode 0、match arm の body と同じ規約 — 複文は
  `{ ... }` で自分から囲む必要がある)→ `}`)。
- 現状は今日の手書き呼び出しと同様、呼び出し側が
  `import @vibex/concurrent { TaskGroup }` を書く必要がある — この
  sugar 自体は import を暗黙に注入しない(そうする既存の仕組みがこの
  コンパイラに存在しないため、範囲外とした)。
- fixtures/compiler_gate.sh 62/62: `region_ok_taskgroup_sugar.vibe`
  (sugar 経由の spawn+join、42 で正常終了)、
  `err_taskgroup_sugar_region_escape.vibe`(sugar body から漏れた
  `TaskHandle`、reject)。

### 実装ノート (2026-08-03 追記): `Result` → 型付き `Exception[E]` (#1324 slice 1)

ADR-0085 の型付き `Exception[E]` (#1344) を受けて、`@vibex/concurrent` の
公開 API のうち **suspend lane にないもの**を throw ベースへ移した。
`Result` の二重ラップ (`Result[Result[T, TaskError], TaskError]`) が消え、
成功パスが値そのものになる。

移行済み (5 本):

| API | 旧 | 新 |
| --- | --- | --- |
| `TaskGroup::run` | `-> Result[T, TaskError] with { e }` | `-> T with { Exception[TaskError], e }` |
| `TaskHandle::join` | `-> Result[T, TaskError] with { e }` | `-> T with { Exception[TaskError], e }` |
| `Channel::bounded` | `-> Result[(Sender, Receiver), ChannelConfigError]` | `-> (Sender, Receiver) with { Exception[ChannelConfigError] }` |
| `Sender::send` | `-> Result[Unit, SendError] with { e }` | `-> Unit with { Exception[SendError], e }` |
| `Parallel::map` | `-> Result[Array[U], TaskError] with { e }` | `-> Array[U] with { Exception[TaskError], e }` |

失敗を観測したい呼び出し側は
`handle { .. } with Exception[TaskError] { Throw(e) => .. }` を書く。
`TaskGroup::run` の row は effect 変数 `e` を含むため、その `handle` は
**呼び出し地点に直接**置く — generic helper で包むと nursery token が型変数
経由で escape し (#1081 step 3)、closure literal で包むと ADR-0076 の
suspend lowering が row 変数 callee を拒否する (`scps_calls_ok`)。

**移行しなかったもの (suspend lane、意図的)**:
`Sender::send_wait` / `conc_send_wait_consumed` / `TaskHandle::result_wait`
は `Result` のまま。ADR-0076 の suspend lowering は **CPS 分割された callee
の中で実行された `throw` を正しく伝播しない** — task を abort せず、呼び出し
元に garbage 値を返す。`main` 上で計測して確認した (この #1324 の変更前):
`fn pw(x) -> Int with { Error, Async } { perform Async::Suspend(0);
throw(Failed("boom")) }` を `spawn_suspend` の body から呼ぶと、group は
成功終了し `join` は 699 を返した。この3本を throw 化すると「閉じた
channel」「cancel された sibling」が観測可能な結果から静かな破損に変わる
ため、lowering 側が直るまで据え置く。

`Result` を返す `TaskHandle::join` に依存していた fixture 群
(`region_ok_*.vibe`、`err_spawnable_capture_*.vibe` ほか) は throw 版へ
更新済み。エントリが throw を素通しするため `with { Error }` の row 付与が
必要になった点に注意。

**同時に踏んだ checker のバグ (修正済み)**: `unify` の `CtUnknown` 節が
`CtVar` 節より下にあったため、`unify(CtVar(T), CtUnknown)` が
`T := CtUnknown` を束縛して T を恒久的に消していた。`throw` の結果型は
`CtUnknown` (builtins_misc.vibe `lookup_throw`) なので、`-> T` を宣言した
関数が T の位置で `throw` すると (= 移行後の `TaskGroup::run` /
`TaskHandle::join` そのもの) 一般化された scheme が `T` の代わりに
`CtUnknown` を持つ。その結果 #1081 の region-escape 検査
(`TaskGroup::run` の body 戻り値が rigid skolem を含むか) が常に false と
なり、**`fixtures/err_region_escape_return.vibe` が clean に通ってしまう**
状態になっていた。`CtUnknown` 節を `CtVar` 節より上へ移し、型変数を
`CtUnknown` に束縛しないようにして修正 (`core/types.vibe`)。同 fixture が
そのまま regression lock になっている。

**失敗メッセージの表現 (#1374)**: `TaskGroup::spawn` の runner と suspend
lane の2つの Error boundary は、どれも payload を `fail_msg: String` に
流し込む。ADR-0085 の runtime は kind を出さないので、これらの **erased な
`with Error` arm は typed な `Exception[E]` の throw も捕まえ**、enum
ポインタが String として保存されていた (計測: `String::length` が 2129)。
#1374 の kind side channel が入ったので、3箇所とも `conc_exn_message` を
通す:

| payload の kind | `fail_msg` |
| --- | --- |
| `String` / `Int` / 解決不能 | `__to_string` の結果 (従来どおり) |
| その他 | `<Kind>` (例: `Failed("<SendError>")`) |

つまり **String を throw する既存コードの見え方は変わらない**。非 String
payload の値そのものはまだ出せない (kind ごとの formatting が要る)。

## v0.4.0 に含めないもの

- raw OS thread / Worker API、thread affinity、priority、CPU count の安定公開
- shared mutable memory、atomics、mutex、weak-memory model
- arbitrary continuation migration
- user-defined fork-safe handler 宣言
- actor supervision / location transparency を持つ `Process[Msg]`
- cown 的な複数 resource atomic acquisition、work stealing の性能保証

これらは core semantics を変えずに追加できる場合だけ後続 ADR で扱う。

## References

- [WebAssembly proposal registry](https://github.com/WebAssembly/proposals)
- [JavaScript Promise Integration](https://github.com/WebAssembly/js-promise-integration)
- [WebKit: JSPI in Safari 27 beta](https://webkit.org/blog/17967/news-from-wwdc26-webkit-in-safari-27-beta/)
- [Mozilla JSPI tracking bug](https://bugzilla.mozilla.org/show_bug.cgi?id=1897981)
- [Component Model concurrency design](https://github.com/WebAssembly/component-model/blob/main/design/mvp/Concurrency.md)
- [Shared-everything threads draft](https://github.com/WebAssembly/shared-everything-threads)
- [Generalized Evidence Passing for Effect Handlers](https://www.microsoft.com/en-us/research/publication/generalized-evidence-passing-for-effect-handlers/)
