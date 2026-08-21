# 10 — テストを書く

前: [モジュールとパッケージ](09_modules_packages.vibe.md)

English version: [10_tests.vibe.md](../en/10_tests.vibe.md)

テストは、普通のソースファイルに書く `test "name" { ... }` ブロックです。
入れるフレームワークも、import するものもありません。

```vibe
fn double(n: Int) -> Int {
  n * 2
}

test "double works" {
  assert_eq(double(21), 42)
  assert(double(0) == 0)
}
```

慣習として `_test.vibe` で終わるファイルに置きます。そうするとビルドが
配布パッケージから除外できます。

```bash
vibe test demo_test.vibe             # 1ファイル
vibe test a_test.vibe b_test.vibe    # 複数
vibe test tests/                     # 配下のすべての *_test.vibe
```

通ったファイルは1行で報告されます:

```console
$ vibe test demo_test.vibe
ok:   demo_test.vibe
```

## 失敗したとき

期待値を 43 に変えると、レポートはテスト名を挙げ、両側を見せて止まります:

```console
$ vibe test demo_test.vibe
assert_eq failed
  expected: 43
  actual:   42

FAIL: demo_test.vibe
  failing test: double works
```

`assert_eq(actual, expected)` は比較可能な任意の型で使え、文字列は内容で
比較します — なので連結の結果や関数の戻り値に対して、何も変換せずそのまま
表明できます。素の `Bool` には `assert(cond)` を使います。

## `inspect` — 期待値をツールに書かせる

値が**どう見えるべきか**は分かっているが打ち込みたくない、まして書式が
正当に変わるたびに打ち直したくない、ということはよくあります。`inspect` は
期待される描画結果をソース中に置き、その保守をツールがやります:

```vibe
fn double(n: Int) -> Int {
  n * 2
}

test "inspect records the value" {
  inspect(double(3), "6")
}
```

`--update` を付けて実行すると、古くなった期待値がコードの実際の出力に
書き換えられます:

```bash
vibe test --update demo_test.vibe
```

そして差分を読みます。それがワークフローです — ツールが提案し、人が
レビューする。文字列を手で保守するよりずっと良く、差分を読まなかった場合は
`assert_eq` よりずっと悪い。見ずに受け入れたスナップショットは、何も表明して
いないテストです。

答えが分かっていて、それが重要なら `assert_eq` を。手で書き出すことだけが
テストを書かない理由になっているような、大きめの構造の形には `inspect` を
使ってください。

## 直接呼べないものをテストする

テストはパッケージの内側にあるので、その内部に手が届きます — テストファイルは
利用者には使えないモジュールを使えます。テストのためだけに export しなくても
ヘルパーをテストできるのはこのためです。テストをコードの隣に置く理由が
これです。

次: [コレクション](11_collections.vibe.md)。
