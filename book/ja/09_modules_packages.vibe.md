# 09 — モジュールとパッケージ

前: [Option とレールウェイ](08_option.vibe.md)

English version: [09_modules_packages.vibe.md](../en/09_modules_packages.vibe.md)

1ファイルが1モジュールです。`export` と書かない限り他のファイルからは何も
見えず、`import` と書かない限り自分のファイルには何も入ってきません。
必要なことのほとんどはこの2語です。

## 2つのファイル

実物です。[support/mathx.vibe](support/mathx.vibe) に export された関数が
あります:

```vibe
export fn triple(x: Int) -> Int {
  x * 3
}
```

この章は相対パスで、欲しい名前を指定して import します:

```vibe run
import ./support/mathx.vibe {
  triple
}

fn main with Console {
  println("triple(14) = \{triple(14)}")
}
```

```output
triple(14) = 42
```

import 行のバリエーションが2つ:

- `import ./lib.vibe { f as renamed }` は取り込むときに改名します。
  2つのモジュールが良い名前について意見を異にするときのためのものです。
- `import ./subdir { helper }` は**ディレクトリ**を import し、その
  `index.vibe` に解決されます。

import はエントリファイルのディレクトリツリーの外に出られません。これは
作法ではなくサンドボックスの規則です — プログラムは、あなたが中に置かな
かったコードには到達できません。

## 名前で指すパッケージ

`@` で始まる import はパスではなくパッケージを指します:

```vibe run
import @vibe/core {
  hex_encode, sha1
}

fn main with Console {
  println("length(sha1(\"vibe\")) = \{String::length(sha1("vibe"))}")
  println("hex_encode(\"hi\") = \{hex_encode("hi")}")
}
```

```output
length(sha1("vibe")) = 40
hex_encode("hi") = 6869
```

名前は3箇所を順に探します: プロジェクトの pin 済みストア、ワークスペース
自身の `lib/`、インストール済みの標準ライブラリ。最初に見つかったものが
勝つので、作業中はローカルのコピーがインストール済みのものを覆い隠します。

## 契約ファイル

パッケージは、たまたま export されているものを外に出すわけではありません。
公開 API を `index.vpkg` — 本体のない宣言の**契約** — として宣言し、
コンパイラが実装をそれと突き合わせます。食い違えばコンパイルエラーであり、
利用者にとっての驚きにはなりません。

```text
name = @you/counter
version = 1.0.0
description =
  #|A tiny counter contract
deps = {}

generated_hash =

type Counter
fn add(x: Int, y: Int) -> Int
```

定義のない `type Counter` は、利用者に名前だけを与えて表現は与えない、
という意味です。後から変えられます。宣言の上のヘッダは vibe の構文では
なくパッケージのメタデータで、
[docs/adding-modules.md](../../docs/adding-modules.md) が参照先です。

実務上の帰結、そして人が驚くところ: **同じパッケージの**2ファイル間で
ヘルパーを共有したいとき、export だけでは足りません。契約にも宣言し、
使う側のファイルが明示的に import する必要があります。既定は
パッケージ内非公開です。

## 再現可能なビルド

他人のパッケージに依存するとき、検証されるのはバージョン番号ではなく
**内容ハッシュ**です:

```text
require @vibe/core 0.2.0 = #pkg:sha1:<40hex>
```

ビルドのたびにそのハッシュをオフラインで再検査するので、ビルドとビルドの
間、レジストリもネットワークも信頼する必要がありません。値は `vibe hash`
が計算します。`VIBE_REQUIRE_PINS=1` を設定すると pin の無い依存はエラーに
なります。リリースビルドはそうあるべきです。

## 公開する

誰かに渡す準備ができたら:

```bash
vibe pkg publish lib/@you/pkg     # バージョン検査の後、ログに追記
vibe pkg install @you/pkg@1.0.0   # 取得してログと照合
vibe pkg add github:owner/repo/dir@ref
vibe pkg yank @you/pkg@1.0.0      # バージョンを取り下げる
vibe pkg update @you/pkg          # 最新へ移動し、契約の差分を表示
```

publish と yank は透明性ログに追記され、install はその証明を検証します —
なので、後からバージョンを差し替えられることはありません。設計は
[docs/registry-design.md](../../docs/registry-design.md) にあります。

次: [テストを書く](10_tests.vibe.md)
