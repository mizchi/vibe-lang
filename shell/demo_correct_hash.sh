#!/bin/bash

# XS Shell demo with correct hash prefixes
echo "XS Shell Demo: Content-Addressed Code Storage"
echo "============================================="
echo

# Create a test script
cat << 'EOF' > demo_correct.txt
(let length (rec length (xs) (match xs ((list) 0) ((list h t) (+ 1 (length t))))))
(let map (rec map (f xs) (match xs ((list) (list)) ((list h t) (cons (f h) (map f t))))))
(let sum (rec sum (xs) (match xs ((list) 0) ((list h t) (+ h (sum t))))))
(let reverse (rec reverse (xs) ((rec rev-helper (xs acc) (match xs ((list) acc) ((list h t) (rev-helper t (cons h acc))))) xs (list))))
history
name 2c8d length_fn
name 9e41 map_fn
name fbfa sum_fn
name b5cc reverse_fn
ls
(length_fn (list 1 2 3 4 5 6 7))
(sum_fn (list 10 20 30 40))
(map_fn (lambda (x) (+ x 100)) (list 1 2 3))
(reverse_fn (list "a" "b" "c"))
update
exit
EOF

# Run the shell
echo "Starting XS Shell session..."
echo
cargo run -p shell --bin xs-shell < demo_correct.txt 2>&1 | grep -E -v "warning:|Compiling|Finished|Running"

# Clean up
rm demo_correct.txt