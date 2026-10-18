# 17 — 並行性

前: [等価性](16_equality.vibe.md)

English version: [17_concurrency.vibe.md](../en/17_concurrency.vibe.md)

vibe でスレッドを spawn することはありません。`TaskGroup` を開き、そこへ
仕事を spawn し、結果を join します。そしてグループは、それを開いた呼び出し
より長生きしません。すべてがスコープに収まっていて、それが残りを検査可能に
しています。

パッケージは `@vibe/concurrent` で、stable です: タスクグループ、タスク
ハンドル、容量付きチャネル、`Parallel::map`、そしてコンパイラの `Send` と
リージョンの検査は opt-in なしで使えます。裏のスケジューラは協調的かつ決定的
(タスクは待つまで走る) ですが、モデルはそれとは独立に決まっています —
同じプログラムを後で並列 backend に載せても意味は変わりません。

一部はまだ experimental です: 中断可能なタスクのレーン
(`TaskGroup::spawn_suspend`、`pump_all`、`sleep_wait`、`send_wait` /
`recv_wait`、`result_wait`) は `@vibe/concurrent/experimental` にあり、この
パッケージの import は `VIBE_UNSTABLE=1` を付けてビルドしないと拒否されます。
SemVer の約束の外側にあり、Minor リリースの中で変わりえます
([stable surface](../../docs/user/reference/stable-surface.md) §6)。

ブロックせずに待つことは `Async` effect が表し、これは stable です。`Async`
ラベルは言語に組み込まれた一つだけで、operation も一つ (`Async::Suspend`)
です。待ちうる builtin — `sleep`、`await`、`StdinStream::next` — がこれを
持ち、それを呼ぶ関数も他の effect と同じように持ちます。`main` なら
`allows Async` と書きます。experimental パッケージの
`effect Async { Suspend(Int) -> Int }` は二つ目の effect ではありません:
パッケージがそれを handle できるよう、同じ builtin ラベルを書き下したもの
です。

## spawn して join する

```vibe run
import @vibe/concurrent {
  TaskGroup, TaskHandle
}

fn main allows Console + Exception {
  let answer = TaskGroup::run((n) -> {
    let h = TaskGroup::spawn(n, () -> {
      21 * 2
    })
    TaskHandle::join(h)
  })
  println("answer = \{answer}")
}
```

```output
answer = 42
```

`TaskGroup::run` は本体にグループ `n` を渡します。`spawn` はそこへ仕事を
キューに積んでハンドルを返し、`join` は値を待ちます。`run` が返った時点で
グループは終わっています — 後片付けを覚えておくべきものは何も走っていません。

`taskgroup { n => { .. } }` は同じ呼び出しのキーワード綴りで、そのまま
`TaskGroup::run((n) -> { .. })` として parse されます。

`main` の `+ Exception` は飾りではありません: spawn したタスクは失敗しうる
ので、`join` はその失敗を `TaskError` として投げ直し、`join` 自身の row は
`Exception[TaskError]` を持ちます。`main` から外すと、コンパイラが正確な
修正を示します — `` hint: add 'allows Console +
Exception[TaskError]' to 'main' `` (上で書いた素の `Exception` がそれを
覆います)。

## タスクはいつ走るか

`spawn` は何も走らせません。タスクをグループの ready キューの末尾に置いて
すぐに返ります。キューのタスクは、spawn した側が待つとき — `join`、チャネル
の `send` や `recv`、あるいは `run` 本体の終わり (グループを閉じる前に
残りを全部走らせる) — に、先入れ先出しで走ります。走り始めたタスクは最後
まで走ります。

```vibe run
import @vibe/concurrent {
  TaskGroup, TaskHandle
}

fn main allows Console + Exception {
  let total = TaskGroup::run((g) -> {
    let a = TaskGroup::spawn(g, () -> {
      println("task a")
      1
    })
    let b = TaskGroup::spawn(g, () -> {
      println("task b")
      2
    })
    println("after spawn")
    let vb = TaskHandle::join(b)
    println("joined b = \{vb}")
    let va = TaskHandle::join(a)
    println("joined a = \{va}")
    va + vb
  })
  println("total = \{total}")
}
```

```output
after spawn
task a
task b
joined b = 2
joined a = 1
total = 3
```

先に `b` を join しても、走るのは `a` が先です: `join` は待っているタスクが
終わるまでキューを順に消化します。順序は毎回同じです。

## 失敗とキャンセル

タスクが throw すると、そのタスクは失敗し、グループも失敗します: キューに
残った兄弟はキャンセルされ、失敗したタスクへの `join` — あるいはグループの
close — が `TaskError::Failed(message)` を投げます。message にはタスクの
エラーが描画されています。観測するには `run` の周りで
`Exception[TaskError]` を handle します:

```vibe run
import @vibe/concurrent {
  TaskGroup, TaskHandle, TaskError
}

fn main allows Console + Exception {
  let r = handle {
    TaskGroup::run((g) -> {
      let a = TaskGroup::spawn(g, () -> {
        throw("boom")
        1
      })
      TaskHandle::join(a)
    })
  } with Exception[TaskError] {
    Throw(e) => {
      println("caught \{e}")
      0
    }
  }
  println("r = \{r}")
}
```

```output
caught Failed(boom)
r = 0
```

`TaskHandle::cancel(h)` はタスクに停止を求めます。まだ始まっていない
タスクは始まらず、それを join すると `TaskError::Cancelled` が投げられます。
すでに終わったタスクへの `cancel` は何もしません。すでに走っているタスクは
中断されず最後まで走ります: 止まるのは、まだ始まっていないタスクと、待ちで
park している中断可能なタスクだけです。一つのタスクのキャンセルはグループを
失敗させません: 兄弟は走り続けます。

## チャネル

`Channel::bounded(g, capacity)` はグループ `g` の中にチャネルを作り、その
両端 `Sender` と `Receiver` を返します。容量 `0` はランデブーで、どの send
も受け手を待ちます。負の容量は `ChannelConfigError::NegativeCapacity` を
投げます。

```vibe run
import @vibe/concurrent {
  TaskGroup, TaskHandle, Channel, Sender, Receiver
}

fn main allows Console + Exception {
  let sum = TaskGroup::run((g) -> {
    let (tx, rx) = Channel::bounded(g, 1)
    let producer = TaskGroup::spawn(g, () -> {
      for i in [1, 2, 3] {
        Sender::send(tx, i)
      }
      Sender::release(tx)
    })
    let mut total = 0
    let mut done = false
    while !done {
      match Receiver::recv(rx) {
        Some(v) => {
          total = total + v
        }
        None => {
          done = true
        }
      }
    }
    TaskHandle::join(producer)
    total
  })
  println("sum = \{sum}")
}
```

```output
sum = 6
```

- `Sender::send` はメッセージがバッファされるか、スタックの下ですでに待って
  いる受け手に渡された時点で返ります — なので送り手は、その受け手が再開する
  前に先へ進めます。空きも待っている受け手も無ければ、受け手が受け取るまで
  グループのキューのタスクを走らせます。
- `Receiver::recv` は `Some(v)` を返し、チャネルが閉じて**かつ**空になると
  `None` を返します: すでにバッファされたメッセージは届きます。
- チャネルは最後の sender が release されると閉じます。`Sender::clone` は
  sender を増やし、それぞれ `Sender::release` で release する必要があります。
  閉じたチャネルへの send は `SendError::Closed` を投げます。
- 走らせるものが何も残っていないのに待つのはデッドロックで、ハングせずに
  メッセージ付きで trap します。run-to-completion のタスクが `send` で
  ブロックすると、自分が走らせたタスクの*下*で待つことになるので、互いの次の
  一歩を必要とする二つのタスクはデッドロックします。上の例のように `run`
  本体で受け取るか、中断可能なタスクを使います。

## `Parallel::map`

`Parallel::map(g, xs, f)` は各要素に対して `f` を `g` のタスクとして走らせ、
結果を `xs` の順に返します:

```vibe run
import @vibe/concurrent {
  TaskGroup, Parallel
}

fn main allows Console + Exception {
  let ys: Array[Int] = TaskGroup::run((g) -> {
    Parallel::map(g, [3, 1, 2], (x) -> x * 10)
  })
  println("\{ys}")
}
```

```output
[30, 10, 20]
```

結果はタスクがどの順で終わっても添字順なので、プログラムはそこから完了順を
観測できません。要素と結果はタスク境界を越えるので、どちらも `Send` で
なければなりません。

## spawn を越えてよいもの

spawn した仕事は自分の制御の外で走るので、それが捕獲するものと返すものは
移動して安全でなければなりません。それが `Send` の判定で、コンパイラは型の
構造から判定します — `impl Send` を書くことはなく、書いても拒否されます:

| `Send` | `Send` でない |
|---|---|
| `Int`、`Double`、`Bool`、`Char`、`String`、`Unit` | `Array`、`Bytes` |
| `Send` な部品のタプルと `Option` | `mut` フィールドを持つもの |
| `Send` な部品でできた struct と enum | `Map`、host リソース、opaque なハンドル |
| `Send` な `T` の `FrozenArray[T]` | 関数値 |

`Send` は値がタスク間を移動するところで検査されます: タスクの結果、チャネル
の要素型、`Parallel::map` の入力と出力です。関数や `Option[Array[Int]]` を
返すタスクは `spawn` の時点で拒否されます。`FrozenArray[T]` はまさにその
ためにあります: 送れる配列です。`Map` は決して `Send` になりません。
エントリを送ってください。

タスクが*捕獲する*ものも、捕獲ごとに同じ判定を受けます。`spawn` に渡す
本体自体はクロージャですが、それは問題ありません。本体が呼ぶクロージャも、
そのクロージャ自身の捕獲が問題なければ問題ありません —
`let inc = (x: Int) -> x + 1` の捕獲は受理され、同じクロージャが `Array` を
捕獲していれば拒否されます。タスクは自分のグループのハンドル・sender・
receiver も捕獲できます。`let mut` は決して捕獲できません: 一つの可変セルを
タスク間で共有してしまうからです。

## グループは逃げられない

`TaskGroup::run` はリージョンを開き、そこに属するもの — グループ、ハンドル、
sender、receiver — は本体が返す値に含められません。ハンドルを返すと、
グループがすでに終わったものを渡すことになるので、コンパイラは代わりに
拒否します。

どちらの検査も綴りではなく関数を追います: ローカルの別名
(`let spawn = TaskGroup::spawn`) や名前を変えた import も直接呼び出しと同じ
ように検査され、`TaskGroup::run` も同じです。どちらかを値として渡す —
引数、フィールド、戻り値 — のは拒否されます。後で適用されるクロージャを
検査が見られないからです。

spawn の検査は、クロージャが何を捕獲したかを見る必要があります。呼び出しに
書かれたクロージャ、ローカルの `let work = () -> ...` で束縛したクロージャ、
名前で渡したトップレベル関数はどれも該当し、本体が呼ぶローカルクロージャは
捕獲として数えられます。検査が中を見られないクロージャ — 例えば自分の
ヘルパーの引数 — は拒否されます。例外は `spawn` と同じ形のヘルパー
(`Parallel::map` のように、最初が `TaskGroup` で最後がクロージャ) で、その
呼び出し側のクロージャが検査されるので、中ではその引数を spawn できます。

## 中断とブロック

待ち方は三通りあり、その間に他の何が走れるかが違います:

| 待ち方 | 兄弟 | 操作 |
|---|---|---|
| インスタンスをブロック | 何も走らない | `sleep_blocking` |
| 呼び出し側のスタック上で駆動 | キューの兄弟が最後まで走る | `join`、`send` / `recv` |
| タスクを中断 | 兄弟と交互に走る | `sleep`、`await`、中断可能なタスクでは `sleep_wait`、`send_wait` / `recv_wait`、`result_wait` |

`join`、`send`、`recv` はブロックしません: 呼び出し側が待つ間、必要な値・
空き・メッセージが揃うまで、グループのキューのタスクをそのスタック上で
走らせます。できないのは、呼び出し側を本体の途中で止めて後でそこへ戻る
ことで、途中で兄弟を待ち、その兄弟もこちらを待つ、というタスクはこの方法
では書けません。`sleep_blocking(ms)` はすべてを止めます。

中断は `Async` を持ち、中断して戻る先を必要とします。`Async` を allows する
エントリはその一つです: `main` から、あるいは row に `Async` を持つ関数から
呼んだ `sleep` と `await` はそこで中断します。`TaskGroup::spawn` で始めた
タスクはそうではありません: 最後まで走るので、`Async` を使うタスク —
`sleep`、`_wait` 操作、row に `Async` を持つ関数 — は拒否され、
`TaskGroup::spawn_suspend` で始めるよう修正が示されます。`run` 本体自体も
同じです: 待ちを本体の外へ出すか、中断可能なタスクの中へ移します。

## 中断可能なタスク

`@vibe/concurrent/experimental` の `TaskGroup::spawn_suspend` (なので
ビルドには `VIBE_UNSTABLE=1` が必要) は、中断できるタスクを始めます。その
中では `sleep` と `sleep_wait` がタスクを park して兄弟を走らせ、
`TaskHandle::result_wait` は中断する `join`、`send_wait` / `recv_wait` は
中断するチャネル操作です。`TaskGroup::pump_all(g)` は park したタスクが
無くなるまで走らせます。park したタスクへの `join` も、そのタスクについて
同じことをします。

```vibe run
import @vibe/concurrent/experimental {
  TaskGroup, TaskHandle, sleep_wait
}

fn main allows Console + Exception + Async {
  let total = TaskGroup::run((g) -> {
    let a = TaskGroup::spawn_suspend(g, () -> {
      println("a1")
      sleep_wait(10)
      println("a2")
      1
    })
    let b = TaskGroup::spawn_suspend(g, () -> {
      println("b1")
      let va = TaskHandle::result_wait(a)
      println("b2 saw a = \{va}")
      va + 1
    })
    TaskGroup::pump_all(g)
    TaskHandle::join(a) + TaskHandle::join(b)
  })
  println("total = \{total}")
}
```

```output
a1
b1
a2
b2 saw a = 1
total = 3
```

`a` は sleep で中断し、`b` は `a` を待つところまで走ります。その後 `a` が
終わって `b` を起こします。中断可能なタスクのクロージャに自前の row は
要りません: `spawn_suspend` は `Async` のクロージャを期待しており、タスクは
エントリの capability (ここでは `Console`) を使えます。sleep は足し算では
なく重なり、壁時計は読みません。

## Future と非同期イテレーション

ここまでの待ちはタスクに属するものでした。待ちを値として運ぶ builtin の型が
二つあります。

`Future[T]` はまだ存在しないかもしれない値へのハンドルです。
`Future::pending()` は未解決のものを作り、`Future::resolve(f, v)` がそれを
満たし、`Future::ready(v)` は最初から満たされていて、`await(f)` は値が揃う
まで中断します。

非同期イテレータは、`next` が `Future[Option[(T, Self)]]` を返す値です: 次の
要素と残り、あるいは終わりなら `None`。そういう値に対する `for x in it` は
各ステップを await するので、`Async` を持ちます。`for` が eager な配列ループ
か await ループかは iterand の型だけで決まり、`for await` はありません。

`AsyncIter` は同じ pull モデルのライブラリ版で、`Array::iter` で明示的に
入ります。`map`、`filter`、`take`、`take_while` は遅延し、`collect`、
`fold`、`count` などは pull して `Async` を持ちます。

```vibe run
import @vibe/builtin {
  Array::iter,
  AsyncIter::collect,
  AsyncIter::map
}

struct Countdown {
  n: Int
}

fn Countdown::next(c: Countdown) -> Future[Option[(Int, Countdown)]] {
  if c.n <= 0 {
    Future::ready(None)
  } else {
    Future::ready(Some((c.n, Countdown::{ n: c.n - 1 })))
  }
}

fn sum_down(n: Int) -> Int with Async {
  let mut acc = 0
  for x in Countdown::{ n: n } {
    acc = acc + x
  }
  acc
}

fn tens() -> Array[Int] with Async {
  [1, 2, 3]
    |> Array::iter
    |> AsyncIter::map((x) -> { x * 10 })
    |> AsyncIter::collect
}

fn main allows Console + Async {
  let f = Future::pending()
  Future::resolve(f, 41)
  let v = await(f)
  println("v = \{v + 1}")
  println("sum = \{sum_down(4)}")
  let ys = tens()
  println("tens = \{ys}")
}
```

```output
v = 42
sum = 10
tens = [10, 20, 30]
```

HTTP レスポンスの body のような host が持つストリームは `HostStream` で、
その `next` も `Async` を持つので、それに対する `for` も同じように各バイトを
await します。`Future`、`HostStream`、`ByteStream` が WASI 0.3 の future と
stream にどう対応するかは
[wasi-p3-async.md](../../docs/internal/design/wasi-p3-async.md) にあります。

## shared-nothing

メッセージは値で、意図された意味論はタスク間の deep copy です。今は全タスク
がまだ一つのヒープを共有しているので、不変なデータを送れば両者は一致します。
本物のスレッドが入っても、モデルは shared-nothing のままです — `TaskGroup`
と `Send`・リージョンの検査はすでにその形を記述しており、だから今から
強制されています。

次: [IDE としての CLI](18_cli.vibe.md)。
