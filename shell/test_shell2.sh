#!/bin/bash

# XS Shell test script with more examples
echo "Testing XS Shell with content-addressed expressions..."

# Create a test script
cat << 'EOF' > test_input2.txt
42
(+ 1 2)
(* 3 4)
history 3
(let x 10)
x
(let double (lambda (x) (* x 2)))
(double x)
history
ls
name 39d1 x_value
name bac2 double_fn
ls
update
exit
EOF

# Run the shell with test input
cargo run -p shell --bin xs-shell < test_input2.txt

# Clean up
rm test_input2.txt