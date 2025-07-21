#!/bin/bash

# LSP相当機能のテストスクリプト

echo "Testing LSP-like features in XS shell..."

# プロジェクトディレクトリから実行
cd "$(dirname "$0")"

# テストコマンドを実行
cargo run --package shell --bin xs-shell <<EOF
add double = (fn (x) (* x 2))
add triple = (fn (x) (* x 3))
add compute = (fn (x) (+ (double x) (triple x)))
update
ls
hover double
hover (double 5)
definition double
references double
type-of compute
exit
EOF

echo "LSP features test completed."