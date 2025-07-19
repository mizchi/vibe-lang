#!/bin/bash

# Simple XS Shell test
echo "Simple XS Shell test..."

# Create a test script
cat << 'EOF' > test_simple.txt
(let inc (lambda (x) (+ x 1)))
(let dec (lambda (x) (- x 1)))
(inc 10)
(dec 10)
history 4
name da2c inc_fn
name a890 dec_fn
ls
update
exit
EOF

# Run the shell with test input
cargo run -p shell --bin xs-shell < test_simple.txt 2>&1 | grep -v "warning:"

# Clean up
rm test_simple.txt