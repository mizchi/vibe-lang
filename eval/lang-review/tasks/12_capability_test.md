# 12 capability_test — capability を要求する test を書く

`Http::request` を実際に呼ぶ `test` ブロックを書く。mock やハンドラで
置き換えるのではなく、**本物の呼び出しが test から到達できる**こと。

`Fs` を使う test も併せて書き、両者で必要な宣言がどう違うかを記録する。

期待: test が compile し、capability の要求が source 上で読み取れること。

> r3 所見 (#1508): `Http` / `Socket` / `Llm` は test/bench の ambient row に
> 無く、row を足す構文も無い (`test "n" with Http { .. }` は
> `expected { but got with`)。`handle .. with Http { .. }` は通るが effect を
> **放電**するので mock にしかならない。`Fs` は ambient に入っているので
> 通る — この非対称が所見。解けるようになったら golden を作る。
