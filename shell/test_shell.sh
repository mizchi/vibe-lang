#!/bin/bash

# XS Shell test script
echo "Testing XS Shell..."

# Create a test script
cat << 'EOF' > test_input.txt
42
(+ 1 2)
(* 3 4)
(let x 10)
(let double (lambda (x) (* x 2)))
(double 21)
history 5
ls
name 
help
exit
EOF

# Run the shell with test input
cargo run -p shell --bin xs-shell < test_input.txt

# Clean up
rm test_input.txt