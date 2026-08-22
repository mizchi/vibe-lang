# 18 — CLI を IDE として使う

前: [並行処理](17_concurrency.vibe.md)

English version: [18_cli.vibe.md](../en/18_cli.vibe.md) (canonical)

エディタが言語サーバから得ているものは、すべてシェルからも訊けます。答えは
パイプに流せる形をしています — 1件1行、フィールド順は固定、そして
**空の出力は「問題なし」**です。

最後のものは覚えておく価値があります。`vibe check` が何も表示しないのが
成功した状態です。

## 訊けること

```bash
vibe check file.vibe                # empty = this file compiles (imports resolved)
vibe check --single-file file.vibe  # buffer-only; imports are not followed
vibe symbols file.vibe              # outline: NAME KIND START END [DOC]
vibe type-at file.vibe 12 4         # hover at 1-based line,col
vibe binding-at file.vibe 12 4      # rename / refs
vibe escapes file.vibe              # which let mut is boxed
vibe deps file.vibe                 # resolved import closure
vibe deps --direct file.vibe        # one hop; cache-friendly
vibe grep --pattern 'f($(x:exp))' --where '$x : Array[_]' lib
```

`vibe lsp` は stdin/stdout で LSP を話すので、サーバを求めるエディタは
これを向ければよい。

`--single-file` は `check` の劣化版ではない。**未保存バッファ用の道具**で
ある。プロジェクト全体としては正しくても、import 由来のコンストラクタに
`unknown name` を報告する。ファイルがコンパイルを通るか知りたいなら
フラグを外すこと。

`vibe grep` はテキストではなく AST パターンにマッチする。フィルタは
checker に問い合わせられる (`--where '$x : Array[_]'`、
`--where-row '$f with Async'`、`--only-ill-typed`)。これらのフィルタは
`vibe check` と同じ import 解決レーンに乗る。

## クエリから見えるプログラム

```vibe run
fn add(x: Int, y: Int) -> Int {
  x + y
}

fn main with Console {
  println("\{add(2, 40)}")
}
```

```output
42
```

この `add` を含むファイルに対して:

```bash
vibe symbols hello.vibe          # add 12 3 6 / main 12 46 50
vibe type-at hello.vibe 1 4      # (Int, Int) -> Int  (`add` の名前の上)
vibe type-at hello.vibe 5 4      # () -> () with Console  (`main` の上)
vibe check hello.vibe            # empty
```

symbols 行の `12` は関数の LSP SymbolKind で、その後の2つの数値は名前の
byte offset です — kind の表は `vibe symbols --legend` が出します。
`type-at` は 1-based の行と byte 列を受け取り、その位置の識別子について
答えます。識別子の無い位置では何も出力せず exit 0 — ほかと同じ
「空出力 = clean」の規約です。

`vibe test file.vibe` は `test { }` / `test "name" { }` ブロックを全部
コンパイルする。`inspect(value, "expected")` がスナップショット形式で、
`vibe test --update` がリテラルを書き換える。`inspect` に import は要らない
— コンパイラが型検査の前に脱糖する。

言語レベルの説明は [テスト](12_tests.vibe.md) を参照。

次: [wasm をターゲットにする](19_wasm.vibe.md)。
