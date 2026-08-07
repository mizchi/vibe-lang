# 13 labeled_optional_args — labeled / optional 引数

必須 labeled 引数と optional 引数を持つ関数を定義し、次を書く:

- optional を**渡した**呼び出し
- optional を**省略した**呼び出し
- body 内で optional の有無を分岐する

期待出力例: `with=15 without=10`

> r3 所見 (#1500): `x?` はパーサが受理するだけで semantics が無い。省略すると
> `arity mismatch`、body 内では `Option[T]` ではなく `T` に束縛される。
> 必須 labeled (`x~`) + 全 labeled 呼び出しは動く。positional と labeled の
> 混在は拒否される。解けるようになったら golden を作る。
