# 12 capability_test — capability を要求する test を書く

`Http::request` を実際に呼ぶ `test` ブロックを書く。mock やハンドラで
置き換えるのではなく、**本物の呼び出しが test から到達できる**こと。

`Fs` を使う test も併せて書き、両者で必要な宣言がどう違うかを記録する。

期待: test が compile し、capability の要求が source 上で読み取れること。

> r3 所見 (2026-08-06, #1508): `Http` / `Socket` / `Llm` は test/bench の
> ambient row に無く、`test "n" with Http { .. }` は parse error だった。
> `Fs` は ambient に入っていた。
>
> 2026-09-24: cheatsheet は、クライアント builtin (`Http::request` ほか) が
> bare file でも host import に落ち、#1508 の第二の壁は外れたと書いている。
> ambient row に network が無い、という設計は同じ文が「変わっていない」と
> も書いている。test ブロックに `Http` を宣言できるかは再測定していない。
> golden は、compile できることを確認してから足す。
