# 付録 — 次に読むもの

この本は物語の側です。ほかの資料を、役に立つことが多い順に並べます。

## このリポジトリの中

- [docs/cheatsheet.md](../../docs/cheatsheet.md) — 1ページの言語
  リファレンス。本と cheatsheet が食い違ったら、`.vibe.md` の
  ブロックを実行してコンパイラを信じること。
- [docs/install.md](../../docs/install.md) — インストーラ、`VIBE_HOME`、
  ディスパッチャ。
- [docs/cli-commands.md](../../docs/cli-commands.md) — すべての `vibe`
  動詞。
- [docs/editor-and-debugging.md](../../docs/editor-and-debugging.md) —
  LSP、DAP、`type-at` / `binding-at` / `symbols`。
- [docs/adding-modules.md](../../docs/adding-modules.md) — 新しい
  パッケージの置き場所 (`@vibe` / `@vibex` / ユーザースコープ)。
- [docs/wasm/feature-levels.md](../../docs/wasm/feature-levels.md) —
  生成モジュールが使ってよい wasm proposal。
- [docs/concurrency.md](../../docs/concurrency.md) — `Send`、リージョン、
  `TaskGroup`。
- [docs/adr.md](../../docs/adr.md) — この本が番号で引いている決定。

## 本が前提にしているコマンド

```bash
vibe check file.vibe                 # 空出力 = コンパイルが通る
vibe test file_test.vibe
vibe run hello.vibex
bash scripts/vibe_md.sh check book/en/*.vibe.md
bash scripts/vibe_book.sh            # _build/book/index.html
pkf run book
pkf run vibe-md-tutorial
```

## 日本語訳

この本の全章に [book/ja/](../ja/) の日本語訳があります。英語版が
正典です。`pkf run check-tutorial-translation-parity` が、各ペアが
同じプログラムを実行していることを検査します。

## この本がやらないこと

仕様書 ([docs/spec/syntax.md](../../docs/spec/syntax.md)) ではなく、
effect taxonomy でもなく、コンパイラを読むことの代わりでもありません。
Rust や TypeScript を書いてきた人に、vibe の実際の規則を、コンパイラが
実行してくれる例と一緒に手渡すための文書です。
