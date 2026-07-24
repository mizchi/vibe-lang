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

現行の `Task[T]` codegen は `spawn` が thunk を即時実行する synchronous eager
prototype であり、本仕様を実装したものではない。撤去済みの `Threads::*` probe
と Int channel id API も公開契約ではない。

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
現在の eager `Task::race` / `Task::timeout` の挙動は契約に含めない。task handle の
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

実装中に #1070 の一般ケースが **pure closure でも再現する**ことを特定した
(capturing closure を by-value 引数で callee に渡して store すると 3 個目
から破損。effect/evidence 非依存)。`Nursery::spawn` は store を inline 化
する workaround で回避している。最小 repro は #1070 のコメント参照。

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
compiler gate 47/47。`@vibex/concurrent` の `Nursery::spawn` /
`Channel::bounded` / `Parallel::map` に `[T: Send]` bound を配線済み。
未着手: spawn closure の capture 検査(`Spawnable`)、`Sender[r,T]` の
同一 nursery 特例、region 生成性。

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
