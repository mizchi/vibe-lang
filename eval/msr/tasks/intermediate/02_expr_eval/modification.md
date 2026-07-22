# intermediate/02_expr_eval — 変更

`Div(Expr, Expr)` variant を追加する。ゼロ除算はエラーとして扱いたいので、
`eval` の戻り値型を `Int` から `Option[Int]` に変更する
(`Div` 以外の演算がゼロ除算するわけではないが、シグネチャ全体を
`Option[Int]` に統一すること — 既存の `Num`/`Add`/`Sub`/`Mul` の分岐も
`Some(...)` を返す形に書き換えが必要になる)。ネストした式の途中で
`None` が出た場合は全体が `None` になること。

既存の test は `eval` の戻り値が `Option[Int]` になったことに合わせて
`Some(...)` との比較に書き換える (中身の期待値は変えない)。`Div` の
正常ケースと、ゼロ除算で `None` になるケースを最低2つ追加すること。
