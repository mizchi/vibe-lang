# 09 — ケーパビリティ

前: [エフェクト (vibe の核)](08_effects.vibe.md)

English version: [09_capabilities.vibe.md](../en/09_capabilities.vibe.md)

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

fn main allows Console {
  greet("vibe")
}
```

```output
hi vibe
```

`greet` は端末に書くので `with Console` と宣言します。呼び出す側に対して
ケーパビリティを**要求**しているのです。`main` は `greet` を呼びますが、
`main` を呼ぶものは誰もいません。プログラムの起点なので、ケーパビリティを
**付与**します: `allows Console`。ケーパビリティが `main` に勝手に現れる
ことはなく、呼び出しから推論された上で、あなたが書いたものと突き合わされ
ます。シグネチャに書き忘れた関数はコンパイルされません。

`Console` が端末のケーパビリティです。`Stdin` / `Stdout` / `Stderr` はその
一部を指す古いラベルで、まだ受け付けられます。`allows Console` はこれらを
覆いますが、逆は成り立ちません。狭い方を求めれば狭い方が来ます。

```vibe skip
// skip: `allows Stdout` は `Console::` の操作に届かない
fn main allows Stdout {
  Console::write_stream("x")
}
```

```
effect row mismatch for 'main': missing { Console::write_stream }
(declared { Stdout }, requires { Console::write_stream, Stdout })
hint: add 'allows Console::write_stream + Stdout' to 'main'
```

## `with` は要求、`allows` は付与

キーワードは 2 つ、row は 1 つです。呼ばれる関数には呼び出し元があり、row
は呼び出し元に求めるもの — `with`。エントリポイントには呼び出し元がなく、
権限は実行が持ち込みます。row は実行が付与するもの — `allows`。
エントリポイントは `fn main`、`fn _start`、そして
[12章](12_tests.vibe.md) の `test` / `bench` / `example` ブロックです。

つまり `allows` はエントリポイントにだけ書きます。呼ばれる関数に書くと、
コンパイラが直し方を教えます。

```vibe skip
// skip: 呼ばれる関数に `allows` を書いた例
fn greet(name: String) -> Unit allows Console {
  println("hi \{name}")
}
```

```
`allows` grants authority and is written on an entry point only (`fn main`,
`fn _start`, `test`, `example`, `bench`); `greet` requires its effects from
the caller -- write `with` here and grant the effect at the entry
```

逆向きも拒否されます。`main` には要求する相手 (呼び出し元) がいないので、
そのヘッドの `with` は parse error になり、メッセージは読み取った row ごと
修正後の綴りを示します:

```vibe skip
// skip: `with` on an entry point
fn main with Console {
  println("hi")
}
```

```
`fn main` is an entry point and grants its row, so the keyword is `allows`:
write `fn main allows Console`
```

権限は操作ごとのままです。`allows Console::write_stream` は
`Console::read_stream` を許可しません — 表示してよいプログラムが、それに
よって端末を読む権利まで得ることはありません。

## ケーパビリティの束に名前を付ける

複数のエントリポイントで同じ集合を付与するプログラムは、一度だけ名前を
付けられます。`effectset` は row 項目の集合で、エントリは他の項目と同じ
ように付与します。

```vibe run
effectset AppCaps = { Console, Fs::read_file }

fn main allows AppCaps {
  println("bundled")
}
```

```output
bundled
```

集合は検査の前に展開されるので、`allows AppCaps` は
`allows Console + Fs::read_file` と厳密に同じです — それ以上でも以下でも
ありません。

## 省略可能なケーパビリティ: `perform?`

`allows` の項目に付く `?` は「省略可能」を表します。ホストがそれを許可した
かどうかに関わらず、プログラムは走れます。対応する
`perform? Fs::read_file("p")` は `Attempt` を返します —
`Granted` / `NotGranted` / `Errored`。

非対話コンパイラには build/apply の grant 情報がないため、未解決の optional
capability は codegen 前に `NotGranted` へ固定されます。operation とその引数は
評価されません。

```vibe run
fn main() -> Int allows Console + Fs::read_file? {
  let a = perform? Fs::read_file("config.json")
  match a {
    NotGranted => 0,
    Errored(_) => 1,
    Granted(_) => 2
  }
}
```

```output
0
```

省略可能な付与が必須の呼び出しの代わりになることはありません。
`allows Fs::read_file?` のもとで `Fs::read_file("p")` と書くと拒否され、
メッセージが 2 つの直し方を示します — `perform?` で呼ぶか、`?` なしで
付与するか。

呼ばれる関数も同じ形で省略可能な等級を**要求**でき、そのとき `perform?` は
フォールバックのロジックがある場所に置けます。呼び出し側は
`with Fs::read_file?` を付与のどちらの等級でも満たせます —
`allows Fs::read_file` でも `allows Fs::read_file?` でも。必須の付与の方が
強いからです。

```vibe run
import @vibe/core { Attempt }

fn cached() -> Attempt[String, String] with Fs::read_file? {
  perform? Fs::read_file("cache.json")
}

fn main allows Console + Fs::read_file? {
  match cached() {
    NotGranted => println("no cache"),
    Errored(_) => println("cache failed"),
    Granted(_) => println("cache hit")
  }
}
```

```output
no cache
```

`?` はホストのケーパビリティにだけ付きます。自分で宣言したエフェクトへの
`with Ask::Get?` や、`allows Exception?` は拒否されます — プログラムの外に
それを差し止められる者がいないので、その等級は何についての主張でもない
からです。

固定済み解決表からの lowering は linear / wasm-gc の両 backend で共通です。
`--allow-*`、BindingLock、対話 preflight を production に接続する作業は #2332 に残り、
それまでは production compile が `Granted` / `Errored` を選ぶことはありません。

## 2種類の見分け方

どちらも row に乗り、綴りがどちらかを示します。

| | 例 | 書き方 | 実装するのは |
|---|---|---|---|
| 代数的エフェクト | `Ask::Value` | `perform` と `handle` | あなた |
| ケーパビリティ | `Fs::read_file` | 普通の呼び出し | ホスト |

`Effect::CamelCase` は perform する操作、`Effect::snake_case` は呼ぶ関数。
これが規則で、`Fs::read_file(p)` が権限を要するのに普通の呼び出しに見える
理由でもあります。

エントリが付与できるのは実行が持ち込めるものだけです: ホストの
ケーパビリティ、`Exception` (ランタイム境界が報告する失敗)、そして `Async`。
自分で宣言したエフェクトには背後にホストがいないので付与できません —
エントリに届く前に `handle` で処理します。

## 拒否すると実際に何が起きるか

`--allow-*` がビルド時に grant セットを決め、拒否されたケーパビリティは
**const-fold と DCE で成果物から消えます** — それを必要としたコードは、
到達不能になるのではなく wasm に入りません。`Http` を一度も得ないプログラム
はネットワークのコードを配布せず、ネットワーク可能なランタイムも要求しません
([feature levels](../../docs/wasm/feature-levels.md))。

起動時、ホストが許可しなかった必須ケーパビリティがあれば `main` の前に
中断し、許可するはずだったフラグの名前を告げます。

次: [Option とレールウェイ](10_option.vibe.md)。
