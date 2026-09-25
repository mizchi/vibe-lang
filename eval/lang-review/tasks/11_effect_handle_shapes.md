# 11 effect_handle_shapes — handle の位置と handled body の形

`Ask` effect (op: `Question(Int) -> Int`) を定義し、`perform` する関数を1つ
用意する。その上で、**意味が同じで書き方だけ違う3つの形**をすべて動かす:

- A: handled body が performing 関数の**素の呼び出し** — `handle { ask() }`
- B: handled body で performing 関数の呼び出しを**別の関数の引数に置く** —
  `handle { add(1, ask()) }`
- C: B と同じ body を、**関数の中**に置いた handle で書く

3つとも compile して同じ値を出すこと。**`vibe check` だけでなく実際に
compile+run して確認する** — この帯域には型検査を通り抜ける失敗がある。

期待出力例: `a=42 b=43 c=43`

> r3 所見 (2026-08-06, #1511): B は
> `handle of effect 'Ask' cannot be compiled here. ...` で落ちた。
> A と C は通った。2026-09-24 時点でこの 3 形は再測定していない。
> book の pitfalls は、row を持たない外側の closure が今も拒否されると
> 書いており、その診断は編集を名指しする。B が今も落ちるかは別の質問である。
> 再測定してから golden を作る。
