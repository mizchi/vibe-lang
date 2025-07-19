#!/bin/bash

# Advanced XS Shell test - building a small library
echo "Building a small library in XS Shell..."

# Create a test script
cat << 'EOF' > test_advanced.txt
# まず基本的な関数を定義
(let inc (lambda (x) (+ x 1)))
(let dec (lambda (x) (- x 1)))

# リスト操作関数を定義
(let length (rec length (xs)
  (match xs
    ((list) 0)
    ((list h t) (+ 1 (length t))))))

(let map (rec map (f xs)
  (match xs
    ((list) (list))
    ((list h t) (cons (f h) (map f t))))))

(let filter (rec filter (p xs)
  (match xs
    ((list) (list))
    ((list h t) 
      (if (p h)
          (cons h (filter p t))
          (filter p t))))))

# 関数をテスト
(length (list 1 2 3 4 5))
(map inc (list 1 2 3))
(filter (lambda (x) (> x 2)) (list 1 2 3 4))

# 履歴を確認
history 10

# 重要な関数に名前を付ける
name bac2c inc_fn
name 39d19 dec_fn
name 7f8e2 length_fn
name 3a4b5 map_fn
name 9c7d1 filter_fn

# 名前付き関数を確認
ls

# コードベースに保存
update

# 新しいセッションで名前付き関数を使う
(map_fn inc_fn (list 10 20 30))
(length_fn (list 1 2 3 4 5 6))

exit
EOF

# Run the shell with test input
cargo run -p shell --bin xs-shell < test_advanced.txt 2>&1 | grep -v "warning:"

# Clean up
rm test_advanced.txt