# 17 — 並行性

前: [等価性](16_equality.vibe.md)

English version: [17_concurrency.vibe.md](../en/17_concurrency.vibe.md)

vibe でスレッドを spawn することはありません。`TaskGroup` を開き、そこへ
仕事を spawn し、結果を join します。そしてグループは、それを開いた呼び出し
より長生きしません。すべてがスコープに収まっていて、それが残りを検査可能に
しています。

パッケージは `@vibe/concurrent`。

## spawn して join する

```vibe run
import @vibe/concurrent {
  TaskGroup, TaskHandle
}

fn main with Console + Exception {
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

知っておく価値のある穴が一つ: spawn の検査は `TaskGroup::spawn` が字面通りに
書かれたときに働きます。改名を経由すると (`let spawn = TaskGroup::spawn`)
検査を素通りします。

## 中断とブロック

待つ操作にはそれぞれ2種類あり、違いは「兄弟タスクが走れるか」です。

| インスタンスをブロックする | タスクを中断する |
|---|---|
| `sleep` | `sleep_wait` |
| `send` / `recv` | `send_wait` / `recv_wait` |

`TaskGroup` の中では `_wait` の形を選ぶこと。ブロックする方は呼び出し元だけ
でなく全体を止めます。

中断はこのパッケージの `Async` エフェクトが運び、`Suspend(Int) -> Int` と
宣言されています。他と同じライブラリのエフェクトであってキーワードではなく、
row にも同じように現れます。

## shared-nothing

メッセージは値で、意図されている意味論はタスク間のディープコピーです。今日は
まだ全タスクが一つのヒープを共有しているので、不変なデータを送れば両者は
一致します。本物のスレッドが載っても模型は shared-nothing のままです —
`TaskGroup` と `Send`・リージョン検査が既にその形を述べていて、だから今から
強制されています。

次: [IDE としての CLI](18_cli.vibe.md)。
