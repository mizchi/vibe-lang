# vibe チュートリアルは The Vibe Book に移りました

正本は英語の [The Vibe Book](../../book/README.md) (`book/en/`)。
日本語の章は [book/ja/](../../book/ja/) にあります。各章はこれまで通り
`*.vibe.md` で、`scripts/vibe_md.sh` が `` ```vibe run `` を実行し
`` ```output `` と照合します。

旧 `docs/tutorial/` のパスからの対応表は [README.md](README.md) にあります。
`-ja` 版 (`01_values_functions-ja.vibe.md` など) は、その表の**英語側の行き先と
同じ名前**の [book/ja/](../../book/ja/) のファイルに対応します — つまり
`01_values_functions-ja.vibe.md` は `book/ja/03_values_functions.vibe.md` で
あって `book/ja/01_*` ではありません。番号は2言語で共通で、`-ja` 接尾辞だけが
無くなりました。本は7章から20章に増えているので、対応の無い章もあります。

English: [README.md](README.md)

```bash
bash scripts/vibe_md.sh check book/en/*.vibe.md book/ja/*.vibe.md
pkf run vibe-md-tutorial
```
