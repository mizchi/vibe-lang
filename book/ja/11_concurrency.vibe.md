# 11 — 並行処理

English version: [11_concurrency.vibe.md](../en/11_concurrency.vibe.md) (canonical)

vibe の公開並行モデルは **shared-nothing structured concurrency**
(ADR-0068)。OS スレッドを spawn することはない。`TaskGroup` を走らせ、
そこへ仕事を spawn し、join する。

パッケージは `@vibe/concurrent`。

## 何が検査されるか

`TaskGroup::run` は新しい region を作る。body の**返り値**がその region の
`TaskGroup` / `TaskHandle` / `Sender` / `Receiver` を持ち出す場合、
コンパイラはそのプログラムを拒否する。

`TaskGroup::spawn` / `::spawn_suspend` は `Spawnable` — 同一 region または
`Send` な capture — を強制する。ただし呼び先が**リテラルに綴られている**
ときに限る。import で rename したり `let spawn = TaskGroup::spawn` と
束縛したりすると、この検査は素通りする。`adopt` / `settle` は現時点で
対象外。

```vibe skip
// skip: 契約のスケッチ — lib/@vibe/concurrent と fixtures/region_ok_basic.vibe を参照
import @vibe/concurrent {
  TaskGroup, TaskHandle
}

fn main with Exception {
  let answer = TaskGroup::run((n) -> {
    let h = TaskGroup::spawn(n, () -> {
      21 * 2
    })
    TaskHandle::join(h)
  })
  // answer == 42
}
```

`Send` は構造的に判定される。スカラー、タプル、Send な要素の `Option`、
`mut` フィールドを持たず Send な要素だけからなる struct / enum は spawn を
越えられる。`Array` / `Bytes`、クロージャ、`mut` フィールドを持つ struct は
越えられない。`FrozenArray[T]` は Send 可能な配列としてまさにこのために
存在する。永続 `Map` は**自動的には** `Send` にならない。

## suspend とブロッキング

`sleep` はインスタンス全体をブロックする。`sleep_wait` はタスクを park
するので兄弟タスクが走れる。stack 駆動 API のチャネル `send` / `recv` は
スケジューラの制御フローをブロックし、`send_wait` / `recv_wait` は
suspend する。

このパッケージの `Async` effect は `Suspend(Int) -> Int`。これは
ライブラリの effect であって言語のキーワードではない。

## shared-nothing

メッセージは値である。長期的な意味論はタスク間の deep-copy スナップショット。
現状はまだ全体が 1 つのヒープを共有しているので、送るのは immutable な
データにすること。マルチスレッド化が来ても shared-nothing のままとする
(`TaskGroup` + `Send` / region 検査が既にその形を表している)。

次章: [CLI を IDE として使う](12_cli.vibe.md)。
