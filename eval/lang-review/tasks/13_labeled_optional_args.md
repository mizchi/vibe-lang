# 13 labeled_optional_args — labeled / optional 引数

必須 labeled 引数と optional 引数を持つ関数を定義し、次を書く:

- optional を**渡した**呼び出し
- optional を**省略した**呼び出し
- body 内で optional の有無を分岐する

期待出力例: `with=15 without=10`

> r3 所見 (2026-08-06, #1500): `x?` はパーサが受理するだけで semantics が
> 無く、省略は `arity mismatch`、body 内では `T` に束縛されると測定した。
>
> 2026-09-24: cheatsheet は、top-level 関数への直接呼び出しでは `x?` が
> 着地済みで、body 内は `Option[T]`、省略は `None`、渡すと `Some` だと
> 書いている。local lambda と alias 経由は今も対象外、と同じ節が書いている。
> このタスクは top-level の形なので、r3 の「解けない」は現行の主張として
> 使えない。golden は、その cheatsheet の文を compile して確認してから足す。
