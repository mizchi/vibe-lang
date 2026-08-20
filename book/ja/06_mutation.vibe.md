# 09 — ミューテーション・region・エスケープ

English version: [06_mutation.vibe.md](../en/06_mutation.vibe.md) (canonical)

vibe は既定で純粋。ミューテーションは存在するが、局所的であり、関数の
公開 effect row には現れない。組み込みの `Mut` effect も `Ref[T]` も無い。

## 収まる範囲で最小のミューテーションを選ぶ

- 局所的なカウンタや累積器: `let mut x = ...`。ブロックスコープ。
  `async` / `spawn` を通って関数の外へ逃げることはできない。
- 伸ばせるバイト列やテキスト: `Bytes` / `StringBuilder`。
- 伸ばせる配列: `ArrayBuilder` して `freeze`、あるいは既に持っている配列への
  `Array::push`。
- ヒープ値の上の可変カーソル: `struct S { mut field: T }` (ADR-0052)。
- 呼び出しをまたぐ状態やハンドラ経由の状態: effect を宣言して `handle`
  する。ハンドラ本体の**直下**にある `perform` はインライン除去される。

## `let mut` はブロックに留まる

`let mut` の束縛はブロックが終わるまで書き込める。ブロック自体は式なので、
値を produce する。

```vibe run
fn main with Console {
  let y = {
    let mut v = 0
    v += 1
    v + 1
  }
  println("y = \{y}")
}
```

```output
y = 2
```

これが普通のケース。codegen はこの束縛を wasm local のまま保つ。

`Array::push` はもう 1 つの普通のケース。**束縛**は immutable で、
**内部**が伸び、すべての別名がそれを見る。

```vibe run
fn grow(xs: Array[Int]) -> Unit {
  Array::push(xs, 9)
}

fn main with Console {
  let xs = [
    1
  ]
  grow(xs)
  println("length = \{Array::length(xs)}, last = \{Array::get(xs, 1)}")
}
```

```output
length = 2, last = 9
```

## エスケープとは capture のこと

`let mut` が、その束縛より長生きしうるクロージャに捕獲されると、それは
もう local ではない。コンパイラはそれを box する。`vibe escapes file.vibe`
がその名前を列挙する。空出力なら、そのファイルの `let mut` はすべて
ただの local。

`--strict` は別の質問に答える — 「そのクロージャは本当にその束縛に届くか」。
既定は lowering の答え (迷ったら box する)。`--strict` は enforcement の
答え (shadowing を引く)。コストを気にするなら既定を、権限を気にするなら
`--strict` を使うこと。

```bash
vibe escapes file.vibe
vibe escapes --strict file.vibe
```

## region と `TaskGroup`

structured concurrency は生成的な region タグを使う。`TaskGroup::run` は
新しい region を発行し、nursery の値が body の**返り値**を通って逃げるのを
拒否する。今日実際に検査されている保証はこれ。
[並行処理](17_concurrency.vibe.md) を参照。

## `mut` struct フィールド

`mut` と宣言された struct フィールドは、書き込めるヒープセルである
(ADR-0052)。書き込みはすべての別名から見える。書き込み前に作った別名でも、
関数経由で届いた場合でも同じ:

    struct Counter { mut n: Int }
    fn bump(c: Counter) -> Unit { c.n = c.n + 1 }
    // 10 から 2 回 bump すると、c も別名も 12 を読む

ADR-0052 は wasm-gc バックエンドについて書かれているが、この機能は gc 限定
ではない — 両レーンとも同じ答えを返す (2026-08-19 実測)。とはいえ local が
欲しいだけなら `let mut` の local を選ぶこと。すべての別名が書き込める
ヒープセルは、カウンタよりずっと強い主張になる。

次章: [ジェネリクス](15_generics.vibe.md)。
