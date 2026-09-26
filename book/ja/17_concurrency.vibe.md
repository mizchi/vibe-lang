# 17 — 並行性

前: [等価性](16_equality.vibe.md)

English version: [17_concurrency.vibe.md](../en/17_concurrency.vibe.md)

vibe でスレッドを spawn することはありません。`TaskGroup` を開き、そこへ
仕事を spawn し、結果を join します。そしてグループは、それを開いた呼び出し
より長生きしません。すべてがスコープに収まっていて、それが残りを検査可能に
しています。

パッケージは `@vibe/concurrent`。import は `VIBE_UNSTABLE=1` を付けて
ビルドしないと拒否され、メッセージはそのフラグを名指しします。下の例は
そのフラグを付けて実行したものです。

**この章は本書で唯一の unstable な面です。** ここに出てくるものはすべて
ADR-0068 で、状態はまだ `proposed` です — `Nursery`、`Task`、
`Sender`/`Receiver`、`TaskGroup::run` / `spawn` / `spawn_suspend`、および
コンパイラの `Send` 判定。SemVer の約束の外側にあり、Minor リリースの中で
変わりえます ([stable surface](../../docs/user/reference/stable-surface.md) §6)。決めて
あることは組み立てるに足りますが、決まっていないのは `Send`/region の検査と、
どの backend が動かすかです (現行のスケジューラは cooperative
run-to-completion のプロトタイプ)。

`Async` effect 自体はこのバケツに入りません。ADR-0012 は accepted で、row 上の
`with Async` は他の effect と同じだけ安定しています — `StdinStream::next` の
ように出荷済み builtin の署名にも現れます。不安定なのはその上に建つ並行
モデルであって、語彙ではありません。

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
カバーします)。この hint が出るのは `VIBE_UNSTABLE=1` のあとです。
フラグが無いとその手前で止まります。

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

spawn の検査は綴りではなく関数そのものを追います: ローカルな別名
(`let spawn = TaskGroup::spawn`) や改名した import も、直接呼び出しと同じく
検査されます。`TaskGroup::spawn` を値として渡すこと — 引数・フィールド・
戻り値 — は拒否されます。後で適用される closure を検査が見られないからです。
残る穴が一つ: 検査は呼び出しに書かれた closure を読むので、先に名前へ束縛した
closure (`let work = () -> ...` の後に `TaskGroup::spawn(n, work)`) は検査
されません。

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
