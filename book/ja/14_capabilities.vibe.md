# 10 — ケーパビリティ

English version: [14_capabilities.vibe.md](../en/14_capabilities.vibe.md) (canonical)

effect row は「失敗しうる」だけを表すものではない。ホスト I/O は
**capability** である。関数の型がどの権限を必要とするかを述べ、呼び出し側の
式は普通の呼び出しのまま、そして認可は build / apply / instantiate で
一度だけ決まり、その後は run 中ずっと不変になる (ADR-0075 / 0084 / 0088)。

これは Deno のパーミッションフラグと Koka の effect system を合成したもの。
書く式は変わらず `Fs::read_file(path)` で、row はその許可がどう届いたかを
表している。

## ラッパではなく row

```vibe skip
// skip: signatures only — not a complete program
fn greet(name: String) -> Unit with Console
fn slurp(path: String) -> String with Exception + Fs
fn read_var(name: String) -> String with Exception + Env
```

言語の prelude に `Result` は無い。プログラムの意味の一部としての失敗は
`Exception[E]` と `throw` / `handle` で表す。`result<T, E>` の形が投影される
唯一の場所が WIT 境界 (`@vibe/wit_runtime`)。

空の row の綴りは 1 つ、`with ()`。古い波括弧形式の `with { A, B }` は
名前付きの parse error で、`vibe fmt` が `with A + B` に書き換える。

## 型が既に述べていたこと

hello-world の `Stdout` は `Fs` や `Env` と同じ仕組み。違いは、生成された
wasm がどのホスト import に言及してよいか。`--allow-*` フラグは不許可の
capability を const-fold + DCE で落とすので、それを必要としたコードは
成果物に入らない。

```vibe run
fn greet(name: String) -> Unit with Console {
  println("hi \{name}")
}

fn main with Console {
  greet("vibe")
}
```

```output
hi vibe
```

`greet` を呼ぶだけの関数も、自分で `Console` に言及しなければならない。
capability が `main` に魔法で現れることはない — 呼び出しから推論され、
書かれたものと照合される。

`println` / `print` の builtin は内部的にはまだ**レガシー**の `Stdout`
ラベルを持っている。現行の tty capability は `Console` — 権限プロンプトが
表示すべき名前はこちら — で、これを宣言するとレガシーの 3 つを認可する。
上の row が `with Console` なのはそのため (#2102)。

包含は**一方向**で、それは意図的。`Console` は 6 つの操作を持ち `Stdout` は
そのうち 2 つを持つので、`Stdout` だけを宣言した row から
`Console::read_stream` へは届かない。書き込み専用のプログラムが移行用の
別名を経由して読み取り権限を獲得することはない。

## 現行の tty の名前は `Console`

1 つの effect に 6 つの操作:

| 操作 | レガシーのラベル | ホスト import |
|---|---|---|
| `Console::write_stream` | `Stdout::write_stream` | `vibe.stdout_write_stream` |
| `Console::write_char` | `Stdout::write_char` | `vibe.stdout_write_char` |
| `Console::write_err_stream` | `Stderr::write_stream` | `vibe.stderr_write_stream` |
| `Console::write_err_char` | `Stderr::write_char` | `vibe.stderr_write_char` |
| `Console::read_stream` | `Stdin::read_stream` | `vibe.stdin_read_stream` |
| `Console::read_char` | `Stdin::read_char` | `vibe.stdin_read_char` |

`Stdin` / `Stdout` / `Stderr` は seed bump で退役するまで受理され続け、
`with Console` が 3 つとも覆う。逆は成り立たない —
`with Stdout { Console::write_stream(...) }` は row の不一致になる。

`with Console` が覆うのは **row** の中の 6 操作。instantiate の grant は
操作ごとのまま: `allows Console::write_stream` は
`Console::read_stream` を許可しない (#1496)。この統合を「読み + 書き +
stderr がひとつの権限になった」と読まないこと。

```vibe run
fn main with Console {
  Console::write_stream("hello, console\n")
}
```

```output
hello, console
```

```vibe skip
// skip: legacy Stdout does not authorize Console::* (distinct labels)
fn main with Console {
  Console::write_stream("no")
}
```

## `with` と `allows`

`with` は**発行される操作**の row (代数的 / コアの ambient)。`allows` は
**提供側の権限**。同じ集合の 2 通りの綴りではない。`with Ask::Get allows Fs`
は未処理の `Ask::Get` を認可**しない** — `handle` が要るか、その操作を
`allows` に足す (そうすると capability になるが、`Ask::Get` はそうではない)。

パーサはこの分割を、発行 row と `#allows` マーカーとして保持する。
`with A + C` としてではない。

```vibe run
fn main with () allows Console {
  println("authority is a separate clause")
}
```

```output
authority is a separate clause
```

**分割された**シグネチャの中の `Stdout` は `allows` に属する。
`fn main() -> Int with Console allows Fs::read_file?` は拒否され、
「`Stdout` は capability effect なので `with` ではなく `allows` 句に
書くこと」と言われる。hello-world の `fn main with Console` は**裸の**形で
あり、合法なまま。

## optional な capability と `perform?`

`allows` の項目に付く末尾の `?` が optional グレード。必須の
`Fs::read_file("p")` は `allows Fs::read_file?` では認可されない。
`perform? Fs::read_file("p")` が optional な perform で、checker はこれを
`Attempt[T, String]` (`NotGranted` / `Errored` / `Granted`) として型付けし、
optional な `allows` の下でのみ受理する。

codegen はまだ `perform?` を lowering **しない**ので、**コンパイラはこれを
拒否する** (#2145):

> \`perform?\` is not lowered yet (#2145): the checker types it as
> \`Attempt[T, String]\`, but code generation cannot emit it. Use a REQUIRED
> capability and plain \`perform\` — drop the \`?\` from both the \`allows\` item
> and the \`perform\` — and handle the failure with \`try\`/\`handle\` instead of
> matching \`Attempt\`.

`vibe check` も同じことを言うので、ビルドする前に分かる。かつては型検査を
通ってから codegen で「this is a bug in the compiler and not in your program」
と落ちていたが、それはこの章の読者が対処できる文言ではない。

```vibe skip
// skip: rejected by the checker -- codegen does not lower perform? (#2145)
fn main() -> Int with () allows Console + Fs::read_file? {
  let a = perform? Fs::read_file("config.json")
  match a {
    NotGranted => 0,
    Errored(_) => 1,
    Granted(_) => 2
  }
}
```

非 TTY の instantiate は `preflight_instantiate` を使う。ホストの grant 集合に
必須 capability が無ければ `main` の前に中断し、`--allow-fs` フラグを名指し
する。TTY の grant プロンプトはまだ runner 側の作業。

## 代数的 effect と capability

`perform` して `handle` する `effect Ask { Get -> Int }` は代数的 effect で、
操作はコンストラクタにあたる。capability の builtin (`Fs::read_file`、
`Env::get`) は関数。どちらも row に乗る。綴りがどちらかを教えてくれる:
`Effect::CamelCase` は perform され、`Effect::snake_case` は呼ばれる。
cheatsheet の "Effect classes" の表と [エフェクト](13_effects.vibe.md) を
参照。

## プログレッシブな wasm

生成されるモジュールは、実際に必要とする wasm feature level を宣言する
([docs/wasm/feature-levels.md](../../docs/wasm/feature-levels.md))。不許可の
capability が、残りのコードが使う以上に高い feature level を強制すべきでは
ない。`Http` に到達しないプログラムがネットワーク対応ランタイムを要求すべき
ではない。

次章: [並行処理](17_concurrency.vibe.md)。
