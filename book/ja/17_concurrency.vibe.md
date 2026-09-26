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
`recv_wait`) は `@vibe/concurrent/experimental` にあり、このパッケージの
import は `VIBE_UNSTABLE=1` を付けてビルドしないと拒否されます。SemVer の
約束の外側にあり、Minor リリースの中で変わりえます
([stable surface](../../docs/user/reference/stable-surface.md) §6)。

`Async` effect 自体も stable です。ADR-0012 は accepted で、row 上の
`with Async` は他の effect と同じだけ安定しています — `StdinStream::next` の
ように出荷済み builtin の署名にも現れます。

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

`TaskGroup::run` は本体にグループ `n` を渡します。`spawn` はその中で仕事を
始めてハンドルを返し、`join` が値を待ちます。`run` が返った時点でグループは
終わっていて、後片付けを覚えておくべき動作中のものは残りません。

`main` の `+ Exception` は飾りではありません: spawn されたタスクは失敗し
得て、`join` はその失敗を `TaskError` として投げ直すので、`join` 自身の
row が `Exception[TaskError]` を運びます。`main` から外すとコンパイラが
直すべき編集をそのまま教えます — `` hint: add 'allows Console +
Exception[TaskError]' to 'main' `` (上で書いた素の `Exception` はこれを
カバーします)。

## spawn を越えられるもの

spawn された仕事は自分の制御下にない場所で走るので、何を捕獲するかは移動して
安全なものに限られます。それが `Send` の判定で、コンパイラが構造的に行います
— `impl Send` を書くことはありません。

| 越えられる | 越えられない |
|---|---|
| スカラー、タプル | クロージャ |
| `Send` な部品の `Option` | `Array`、`Bytes` |
| `Send` な部品でできた struct と enum (`mut` フィールド無し) | `mut` フィールドを持つもの |

`spawn` に渡す本体はそれ自体クロージャですが、それは問題ありません —
この表が言っているのは本体が**捕獲する**ものとタスク間で送るものの話で、
本体そのものの話ではありません。

`FrozenArray[T]` はまさにこのために在ります — 送れる配列です。永続的な `Map`
は自動的に `Send` にはなりません。

## グループは外へ出られない

`TaskGroup::run` はリージョンを開き、そこに属するもの — グループ、ハンドル、
Sender、Receiver — は本体が返す値に含められません。ハンドルを返すことは、
既に終わったグループに属する何かを受け取ることになるので、コンパイラが
拒否します。

どちらの検査も綴りではなく関数そのものを追います: ローカルな別名
(`let spawn = TaskGroup::spawn`) や改名した import も直接呼び出しと同じく
検査され、`TaskGroup::run` も同様です。どちらかを値として渡すこと —
引数・フィールド・戻り値 — は拒否されます。後で適用される closure を検査が
見られないからです。

spawn の検査は closure が何を capture したかを見る必要があります。呼び出しに
書かれた closure、ローカルな `let work = () -> ...` に束縛した closure、名前で
渡したトップレベル関数はいずれも検査でき、本体が呼ぶローカル closure も
capture として数えます。中身を見られない closure — たとえば自作ヘルパーの
引数 — は拒否されます。例外は `spawn` と同じ形のヘルパー (先頭が
`TaskGroup`、末尾が closure。`Parallel::map` がこの形) で、呼び出し側の
closure が検査されるので、その中では引数をそのまま spawn できます。

## 中断とブロック

上のブロックする操作は、終わるまで呼び出したタスクをスタックに載せたままに
します。experimental パッケージは待つ操作それぞれにもう1種類を足し、違いは
「兄弟タスクが走れるか」です。

| インスタンスをブロックする | タスクを中断する |
|---|---|
| `sleep` | `sleep_wait` |
| `send` / `recv` | `send_wait` / `recv_wait` |

`_wait` の形は `TaskGroup::spawn_suspend` で始めたタスクの中で使い、どれも
`@vibe/concurrent/experimental` から import します (なのでビルドには
`VIBE_UNSTABLE=1` が要ります)。ブロックする方は呼び出し元だけでなく全体を
止めます。

中断はそのパッケージの `Async` エフェクトが運び、`Suspend(Int) -> Int` と
宣言されています。他と同じライブラリのエフェクトであってキーワードではなく、
row にも同じように現れます。

## shared-nothing

メッセージは値で、意図されている意味論はタスク間のディープコピーです。今日は
まだ全タスクが一つのヒープを共有しているので、不変なデータを送れば両者は
一致します。本物のスレッドが載っても模型は shared-nothing のままです —
`TaskGroup` と `Send`・リージョン検査が既にその形を述べていて、だから今から
強制されています。

次: [IDE としての CLI](18_cli.vibe.md)。
