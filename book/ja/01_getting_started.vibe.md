# 01 — インストールと Hello, vibe

English version: [01_getting_started.vibe.md](../en/01_getting_started.vibe.md)

## インストール

```bash
curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/install/install.sh | bash
. "$HOME/.vibe/env"
vibe version
```

このリポジトリのチェックアウトからなら `bash install/install.sh` で同じことが
できます。`vibe` コマンド、`viberun` ホスト、標準ライブラリが入ります。
コンパイラ自体が wasm モジュールです。

## Hello

`hello.vibex` に置きます:

```vibe run
fn main with Console {
  println("hello, vibe")
}
```

```output
hello, vibe
```

```bash
vibe run hello.vibex
```

`println` は組み込みなので import は要りません。

面白いのは `with Console` の方です。これは端末に書き込むための、この
プログラムの許可であり、必須です — 消せばコンパイルが通りません。
この言語の一番大きな考えが、一番小さなプログラムに既に現れています。
関数は自分に許されたことを宣言し、コンパイラはそれを守らせます。

同じ形は失敗 (`with Exception`) にも、ファイル読み込み
(`allows Fs::read_file`) にも出てきます。決着は
[ケーパビリティ](14_capabilities.vibe.md)で付けます。

## コンパイラに質問する

vibe の CLI は実行するだけでなく、問い合わせるために作られています。
全体を通じた約束は「**出力が空なら問題なし**」です。

```bash
vibe check hello.vibex     # 型検査。通れば何も出力しない
vibe run   hello.vibex     # コンパイルして実行
vibe test  hello_test.vibe # test { } ブロックを実行
```

書いている最中に使うのは `vibe check` です。「これはコンパイルが通るか」に
単体で答え、診断は1件1行、言うことがあれば非ゼロで終了します。

この種のコマンドは他にもあり (`vibe symbols`, `vibe type-at`, `vibe deps`)、
エディタや自分やスクリプトがコンパイラの知っていることを訊けるように
用意されています。[CLI を IDE として使う](18_cli.vibe.md)で扱います。

## プロジェクトが要るとき

```bash
vibe new myapp
cd myapp
vibe run main.vibex
```

`vibe new` はパッケージの雛形を作ります — エントリポイント、契約ファイル、
依存を置く場所。1ファイルなら必要ないので、この章はそこから始めません
でした。[モジュールとパッケージ](09_modules_packages.vibe.md)で扱います。

次: [小さなプログラム](02_a_small_program.vibe.md)
