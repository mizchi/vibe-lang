#!/bin/bash

# UCM風シェルのテストスクリプト

echo "Testing UCM-style shell commands..."

# プロジェクトディレクトリから実行
cd "$(dirname "$0")"

# 一時ディレクトリを作成してコードベースの場所を設定
export XS_CODEBASE_DIR="$(mktemp -d)"
echo "Using codebase directory: $XS_CODEBASE_DIR"

# テストコマンドを実行
cargo run --package shell --bin xs-shell <<EOF
help
add double = (fn (x) (* x 2))
ls
view double
find double
type-of (double 21)
update
exit
EOF

echo "Test completed. Codebase was at: $XS_CODEBASE_DIR"