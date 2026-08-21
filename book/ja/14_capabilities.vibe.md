# 14 — ケーパビリティ

前: [エフェクト (vibe の核)](13_effects.vibe.md)

English version: [14_capabilities.vibe.md](../en/14_capabilities.vibe.md)

前章のエフェクトは、ハンドラで自分が実装するものでした。ファイルを読むのは
そうではありません。やり方はホストが既に知っていて、問題は「あなたの
プログラムにそれが**許されているか**」です。

それがケーパビリティです。同じ row に乗りますが、row が記録しているのは
権限で、その権限はビルド時に決まります — 呼び出しのたびに確認されるので
はありません。呼び出し自体は普通の関数呼び出しのままです。

Deno のパーミッションフラグと Koka の effect system を合成したもの、と
考えてください。

## 権限はシグネチャの一部

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

`greet` は端末に書くので `with Console` と宣言します。`main` は `greet` を
呼ぶので `main` も宣言します。ケーパビリティが `main` に勝手に現れることは
なく、呼び出しから推論された上で、あなたが書いたものと突き合わされます。
シグネチャに書き忘れた関数はコンパイルされません。

`Console` が端末のケーパビリティです。`Stdin` / `Stdout` / `Stderr` はその
一部を指す古いラベルで、まだ受け付けられます。`with Console` はこれらを
覆いますが、逆は成り立ちません。狭い方を求めれば狭い方が来ます。

```vibe skip
// skip: `with Stdout` は `Console::` の操作に届かない
fn main with Stdout {
  Console::write_stream("x")
}
```

```
effect row mismatch for 'main': missing { Console::write_stream }
(declared { Stdout }, requires { Console::write_stream, Stdout })
hint: add 'with Console::write_stream + Stdout' to 'main'
```

## `with` と `allows` は別の節

シグネチャは「何を発行するか」と「何を認可されているか」に分けられます。

```vibe run
fn main with () allows Console {
  println("authority is a separate clause")
}
```

```output
authority is a separate clause
```

`with ()` は空の row で、代数的なものは何もありません。`allows Console` が
権限です。1章の裸の `fn main with Console` は、同じものの短い書き方です。

分割形を書いたら、ケーパビリティは `allows` に置く必要があります。`with` に
置くと、どちらの節に属するかを教えられます。

```vibe skip
// skip: 分割シグネチャの `with` にケーパビリティを置いた例
fn main() -> Int with Console allows Fs::read_file? {
  0
}
```

```
`Console` is a capability effect and must appear in the `allows` clause,
not `with` (ADR-0088, #1345)
```

権限は操作ごとのままです。`allows Console::write_stream` は
`Console::read_stream` を許可しません — 表示してよいプログラムが、それに
よって端末を読む権利まで得ることはありません。

## 省略可能なケーパビリティ: `perform?`

`allows` の項目に付く `?` は「省略可能」を表します。ホストがそれを許可した
かどうかに関わらず、プログラムは走れます。対応する
`perform? Fs::read_file("p")` は `Attempt` を返します —
`Granted` / `NotGranted` / `Errored`。

型検査は今日これを受け付けます。**コード生成は受け付けないので、
コンパイラが拒否します** — 走らないものを作るよりは、という判断です。

```vibe skip
// skip: 拒否される。codegen が `perform?` をまだ lower しない (#2145)
fn main() -> Int with () allows Console + Fs::read_file? {
  let a = perform? Fs::read_file("config.json")
  match a {
    NotGranted => 0,
    Errored(_) => 1,
    Granted(_) => 2
  }
}
```

```
line 2:11: drop the `?` from `allows Fs::read_file?` and call
`Fs::read_file(..)` directly -- a capability is an ordinary call, not a
`perform` -- then handle the failure with `try`/`handle` instead of matching
`Attempt`. `perform?` is not lowered yet: the checker types it as
`Attempt[T, String]`, but code generation cannot emit it (#2145).
```

`vibe check` も同じことを言うので、ビルドする前に分かります。着地するまでは
ケーパビリティを必須にして、普通の呼び出しで使ってください。

## 2種類の見分け方

どちらも row に乗り、綴りがどちらかを示します。

| | 例 | 書き方 | 実装するのは |
|---|---|---|---|
| 代数的エフェクト | `Ask::Value` | `perform` と `handle` | あなた |
| ケーパビリティ | `Fs::read_file` | 普通の呼び出し | ホスト |

`Effect::CamelCase` は perform する操作、`Effect::snake_case` は呼ぶ関数。
これが規則で、`Fs::read_file(p)` が権限を要するのに普通の呼び出しに見える
理由でもあります。

## 拒否すると実際に何が起きるか

`--allow-*` がビルド時に grant セットを決め、拒否されたケーパビリティは
**const-fold と DCE で成果物から消えます** — それを必要としたコードは、
到達不能になるのではなく wasm に入りません。`Http` を一度も得ないプログラム
はネットワークのコードを配布せず、ネットワーク可能なランタイムも要求しません
([feature levels](../../docs/wasm/feature-levels.md))。

起動時、ホストが許可しなかった必須ケーパビリティがあれば `main` の前に
中断し、許可するはずだったフラグの名前を告げます。

次: [ジェネリクス・trait・derive](15_generics.vibe.md)。
