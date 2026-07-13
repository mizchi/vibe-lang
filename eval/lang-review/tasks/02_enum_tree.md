# 02 enum_tree — 再帰 enum・パターンマッチ

二分木 `Tree` (Leaf(Int) / Node(Tree, Tree)) を enum で定義し、全 Leaf の
合計を返す再帰関数 `sum` を書く。`Node(Node(Leaf(1), Leaf(2)), Leaf(3))`
の合計 6 を出力する。
