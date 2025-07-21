#!/bin/bash

# API mode test script

echo "Testing XS API mode..."

# プロジェクトディレクトリから実行
cd "$(dirname "$0")"

# Test 1: Add a definition
echo "Test 1: Add definition"
echo '{"command":"add","name":"square","expr":"(fn (x) (* x x))"}' | cargo run --package shell --bin xs-api --quiet

echo -e "\nTest 2: List definitions"
echo '{"command":"list"}' | cargo run --package shell --bin xs-api --quiet

echo -e "\nTest 3: Get type of expression"
echo '{"command":"type_of","expr":"(square 5)"}' | cargo run --package shell --bin xs-api --quiet

echo -e "\nTest 4: View definition"
echo '{"command":"view","name":"square"}' | cargo run --package shell --bin xs-api --quiet

echo -e "\nTest 5: Get status"
echo '{"command":"status"}' | cargo run --package shell --bin xs-api --quiet

echo -e "\n\nAPI test completed."