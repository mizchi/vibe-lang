#!/bin/bash

# Test improved error messages in XS Shell
echo "Testing improved AI-friendly error messages..."
echo

# Create test files with various errors
cat << 'EOF' > test_type_error.xs
(let x 42)
(let y "hello")
(+ x y)
EOF

cat << 'EOF' > test_undefined.xs
(let result (mpa double (list 1 2 3)))
EOF

cat << 'EOF' > test_pattern_error.xs
(match (list 1 2 3)
  ((Cons h t) h)
  ((Nil) 0))
EOF

# Test type error
echo "=== Type Error Test ==="
cargo run -p cli --bin xsc -- check test_type_error.xs 2>&1 | grep -A5 "error"

echo
echo "=== Undefined Variable Test ==="
cargo run -p cli --bin xsc -- check test_undefined.xs 2>&1 | grep -A5 "error"

echo
echo "=== Pattern Error Test ==="
cargo run -p cli --bin xsc -- check test_pattern_error.xs 2>&1 | grep -A5 "error"

# Clean up
rm test_*.xs