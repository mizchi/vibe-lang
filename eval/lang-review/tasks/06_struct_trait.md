# 06 struct_trait — struct・derive(Eq)・trait

`Point { x: Int, y: Int }` を定義し、(a) 2 つの同値 Point の `==` が true に
なること、(b) trait (例: `Show` 的な `to_string(Self) -> String`) を定義して
Point に impl し、`(1, 2)` 形式で出力すること。
