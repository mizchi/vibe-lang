#!/bin/bash

# UCM風シェルのデバッグテストスクリプト

echo "Testing UCM-style shell commands (debug mode)..."

# プロジェクトディレクトリから実行
cd "$(dirname "$0")"

# テストコマンドを実行（一つずつ確認）
cargo run --package shell --bin xs-shell <<EOF
add double = (fn (x) (* x 2))
ls
view double
find double
update
ls
view double
exit
EOF