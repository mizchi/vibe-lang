#!/bin/bash

# Salsa統合のテストスクリプト

echo "Testing Salsa integration in XS shell..."

# プロジェクトディレクトリから実行
cd "$(dirname "$0")"

# テストコマンドを実行
cargo run --package shell --bin xs-shell <<EOF
add f = (fn (x) (* x 2))
add g = (fn (x) (f (+ x 1)))
update
ls
dependencies g
dependents f
type-of (g 10)
exit
EOF

echo "Salsa integration test completed."