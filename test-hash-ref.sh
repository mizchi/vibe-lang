#!/bin/bash

# Test hash reference feature in XS shell

echo "Testing hash reference feature..."

# Create a test script that defines some values and then references them by hash
cat << 'EOF' > test-hash-interactive.xs
-- First, define some values
let x = 42
print x

let double = fn n -> n * 2
print (double 10)

-- The shell should show hashes for these expressions
-- We'll manually note the hashes and create references to test
EOF

echo "Run the following commands in the shell to test hash references:"
echo "1. let x = 42"
echo "2. Note the hash (e.g., [abc123...])"
echo "3. Reference it with: #abc123"
echo ""
echo "Starting shell..."

cargo run -p xsh --bin xsh