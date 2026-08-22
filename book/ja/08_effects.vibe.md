# 08 — エフェクト (vibe の核)

前: [構造体・列挙・match](07_data.vibe.md)

English version: [08_effects.vibe.md](../en/08_effects.vibe.md)

vibe の関数は、型がそう言わない限り純粋です。計算以外にできること —
失敗する、表示する、ファイルを読む — はシグネチャの `with` 節に名前が
書かれ、その節は誰かが handle するまで呼び出し側へ伝播します。

仕組みはこれで全部。この章はそれがどう見えるかです。

## 失敗しうることを宣言する

失敗のためのエフェクトが `Exception`。throw しうる関数はそう宣言し、
呼び出し側はその義務を引き継ぎます。

```vibe run
fn risky(x: Int) -> Int with Exception {
  if x == 0 {
    perform Exception::Throw("division by zero")
  }
  100 / x
}

fn main with Console {
  let safe = handle {
    risky(0)
  } with Exception {
    Throw(message) => {
      println("exception: \{message}")
      0 - 1
    }
  }
  let fine = handle {
    risky(4)
  } with Exception {
    Throw(_) => 0 - 1
  }
  println("safe = \{safe}")
  println("fine = \{fine}")
}
```

```output
exception: division by zero
safe = -1
fine = 25
```

`handle { body } with Exception { ... }` が境界です。その内側では `risky`
は throw してよく、外側の `main` の row に `Exception` は現れません。義務が
そこで果たされたからです。

`Exception` は**中断的** (abortive) — throw は戻ってきません。ハンドラ腕の
値が `handle` 全体の値になり、だから `safe` は `-1`、`fine` は `25` に
なります。`Exception` の腕に `resume` はありません。

型引数なしの `Exception` は消去された形で、どの `Exception[E]` も受け取り、
payload は文字列として届きます。エラー型を保ちたいときは `Exception[E]` と
書きます — [exception effect](../../docs/exception-effect.md) を参照。

## 自分のエフェクトを宣言する

エフェクト宣言は、実装を持たない操作の一覧です。実装はハンドラとして
呼び出し側が与えます。`Exception` はこの特別な場合にあたります。

```vibe run
effect Ask {
  Value(String) -> Int
}

fn answer_of(q: String) -> Int with Ask {
  perform Ask::Value(q) + 1
}

fn main with Console {
  let v = handle {
    answer_of("life")
  } with Ask {
    Value(_q) => resume(41)
  }
  println("v = \{v}")
}
```

```output
v = 42
```

`answer_of` はその数がどこから来るかを知りません。`Ask::Value` を perform
し、ハンドラが resume した値で続きを実行します — ここでは `41` なので
`answer_of` は `42` を返します。`Exception` と違い `Ask` は**再開可能**で、
`resume(v)` が `v` を perform の位置へ返し、関数はそこから続きます。

再開は one-shot かつ末尾再開 — ハンドラの腕は最後の動作として高々一度だけ
resume します。

自分のエフェクトを持ち出すのは、呼び出し側が本当に実装を差し替える必要が
あるときです — テストでの時計、値の別の供給元など。普通の失敗には
`Exception` を、ローカルな状態にはまず `let mut` を試すこと。判断基準は
[Effects vs let mut](../../docs/guide/when-to-use-effects.md) にあります。

## row は変数にできる

高階関数が「渡された関数がどのエフェクトを performするか」を知る必要は
ありません。row を変数として書けば、来たものをそのまま運びます。

```vibe run
fn apply_twice(f~: (Int) -> Int with e, x~: Int) -> Int with e {
  f(f(x))
}

fn main with Console {
  println("apply_twice = \{apply_twice(f=(n) -> n * 2, x=10)}")
}
```

```output
apply_twice = 40
```

`apply_twice` は `f` が純粋なら純粋、`f` が throw するなら `Exception` を
運びます。定義は一つ、両方の場合が検査されます。

## `handle` についての唯一の規則

`handle` は、自分が覆うすべての `perform` を見えている必要があります。
handle された本体の各呼び出しについて、コンパイラはその呼び出しが何を
perform するか分かる必要があります。

ほとんどの呼び出しは見えます — トップレベルの `fn`、組み込み、束縛や引数が
effect row を持つクロージャ、そして handle された本体の中に書かれた
クロージャ。見えないのは、**row を持たず本体の外で束縛された**クロージャ
です。見に行く定義も、読む row もありません。型検査は通り、それでも
拒否されます。

```vibe skip
// skip: 拒否される形。出る診断を見せるための例
effect Ask {
  Once() -> Int
}

fn ask_once() -> Int with Ask {
  perform Ask::Once()
}

fn main() -> Int {
  let bump = (x: Int) -> Int { x + 1 }
  handle { bump(ask_once()) } with Ask {
    Once() => resume(41)
  }
}
```

```
handle of effect 'Ask' cannot be compiled here: this handle cannot see what
one call in its body performs (here: the call to 'bump'). Make that call
visible -- declare 'bump' as a top-level `fn`, give the binding or parameter
it arrives through an effect row (`with Ask`), or move its `let` inside the
handled body. Moving the `handle` into the function that performs works too.
(ADR-0076 evidence-passing migration.)
```

メッセージは4つの直し方を挙げ、どれか一つで直ります。ここで一番小さいのは
`bump` をトップレベルの `fn` にすること。末尾の ADR 参照はメンテナ向けの
注記で、読者に宛てられているのは4つの直し方の部分です。

## handle しないエフェクト: ケーパビリティ

`Fs`・`Env`・`Http`・`Console` も同じ row に乗りますが、これらにハンドラを
書くことはありません。実装はホストが持っていて、宣言するのは「使ってよい」
という権限です。それが次の章です。

次: [ケーパビリティ](09_capabilities.vibe.md)。
