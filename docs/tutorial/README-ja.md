# vibe チュートリアルは The Vibe Book に移りました

正本は英語の [The Vibe Book](../../book/README.md) (`book/en/`)。
日本語の章は [book/ja/](../../book/ja/) にあります。各章はこれまで通り
`*.vibe.md` で、`scripts/vibe_md.sh` が `` ```vibe run `` を実行し
`` ```output `` と照合します。

旧 `docs/tutorial/` のパスからの対応表は [README.md](README.md) にあります
(`-ja` 版は同じ番号の `book/ja/` の章に対応します)。本は7章から20章に
増えているので、対応の無い章もあります。

English: [README.md](README.md)

```bash
bash scripts/vibe_md.sh check book/en/*.vibe.md book/ja/*.vibe.md
pkf run vibe-md-tutorial
```
