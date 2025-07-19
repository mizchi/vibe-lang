#!/bin/bash

# XS Shell demo - Building a list library
echo "Building a list library using XS Shell..."
echo "This demonstrates content-addressed code storage"
echo

# Create a test script
cat << 'EOF' > demo_list.txt
(let length (rec length (xs) (match xs ((list) 0) ((list h t) (+ 1 (length t))))))
(length (list 1 2 3 4 5))
name da2c length_fn
(let map (rec map (f xs) (match xs ((list) (list)) ((list h t) (cons (f h) (map f t))))))
(map (lambda (x) (* x 2)) (list 1 2 3))
name a890 map_fn
(let sum (rec sum (xs) (match xs ((list) 0) ((list h t) (+ h (sum t))))))
(sum (list 1 2 3 4 5))
name b456 sum_fn
(let reverse (rec reverse (xs) ((rec rev-helper (xs acc) (match xs ((list) acc) ((list h t) (rev-helper t (cons h acc))))) xs (list))))
(reverse (list 1 2 3 4))
name c789 reverse_fn
ls
update
history 10
exit
EOF

# Run the shell
echo "Starting XS Shell..."
cargo run -p shell --bin xs-shell < demo_list.txt 2>&1 | grep -E -v "warning:|Compiling|Finished|Running"

# Clean up
rm demo_list.txt