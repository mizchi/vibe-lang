(module
  (memory (export "memory") 10)  ;; 640KB

  ;; === SIMD whitespace skip ===
  ;; Skip ' ', '\t', '\n', '\r' using 16-byte parallel comparison
  ;; Returns new position after whitespace
  (func $skip_ws_simd (export "skip_ws_simd") (param $ptr i32) (param $len i32) (result i32)
    (local $pos i32)
    (local $end i32)
    (local $chunk v128)
    (local $mask i32)
    (local $c i32)

    (local.set $pos (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (local.get $len)))

    ;; SIMD fast path: process 16 bytes at a time
    (block $simd_done
      (loop $simd_loop
        ;; Need at least 16 bytes remaining
        (br_if $simd_done (i32.gt_u (i32.add (local.get $pos) (i32.const 16)) (local.get $end)))

        ;; Load 16 bytes
        (local.set $chunk (v128.load (local.get $pos)))

        ;; Check each whitespace char: space(32), tab(9), newline(10), cr(13)
        ;; mask = (chunk == ' ') | (chunk == '\t') | (chunk == '\n') | (chunk == '\r')
        (local.set $mask
          (i8x16.bitmask
            (v128.or
              (v128.or
                (i8x16.eq (local.get $chunk) (v128.const i8x16 32 32 32 32 32 32 32 32 32 32 32 32 32 32 32 32))
                (i8x16.eq (local.get $chunk) (v128.const i8x16 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9)))
              (v128.or
                (i8x16.eq (local.get $chunk) (v128.const i8x16 10 10 10 10 10 10 10 10 10 10 10 10 10 10 10 10))
                (i8x16.eq (local.get $chunk) (v128.const i8x16 13 13 13 13 13 13 13 13 13 13 13 13 13 13 13 13))))))

        ;; If all 16 bytes are whitespace (mask == 0xFFFF), skip all
        (if (i32.eq (local.get $mask) (i32.const 0xFFFF))
          (then
            (local.set $pos (i32.add (local.get $pos) (i32.const 16)))
            (br $simd_loop))
          (else
            ;; Find first non-whitespace: count trailing ones in mask
            ;; ctz of ~mask gives number of leading whitespace bytes
            (if (i32.eq (local.get $mask) (i32.const 0))
              (then
                ;; No whitespace at all, return current pos
                (return (local.get $pos)))
              (else
                ;; Find first zero bit (first non-ws byte)
                (local.set $pos (i32.add (local.get $pos)
                  (i32.ctz (i32.xor (local.get $mask) (i32.const 0xFFFF)))))
                (return (local.get $pos))))))))

    ;; Scalar fallback for remaining < 16 bytes
    (block $scalar_done
      (loop $scalar_loop
        (br_if $scalar_done (i32.ge_u (local.get $pos) (local.get $end)))
        (local.set $c (i32.load8_u (local.get $pos)))
        (if (i32.or
              (i32.or (i32.eq (local.get $c) (i32.const 32)) (i32.eq (local.get $c) (i32.const 9)))
              (i32.or (i32.eq (local.get $c) (i32.const 10)) (i32.eq (local.get $c) (i32.const 13))))
          (then
            (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
            (br $scalar_loop)))))

    (local.get $pos)
  )

  ;; === Scalar whitespace skip (for comparison) ===
  (func $skip_ws_scalar (export "skip_ws_scalar") (param $ptr i32) (param $len i32) (result i32)
    (local $pos i32)
    (local $end i32)
    (local $c i32)

    (local.set $pos (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (local.get $len)))

    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $pos) (local.get $end)))
        (local.set $c (i32.load8_u (local.get $pos)))
        (if (i32.or
              (i32.or (i32.eq (local.get $c) (i32.const 32)) (i32.eq (local.get $c) (i32.const 9)))
              (i32.or (i32.eq (local.get $c) (i32.const 10)) (i32.eq (local.get $c) (i32.const 13))))
          (then
            (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
            (br $loop)))))

    (local.get $pos)
  )

  ;; === SIMD identifier scan ===
  ;; Scan [a-zA-Z0-9_] bytes. Returns end position.
  (func $scan_alnum_simd (export "scan_alnum_simd") (param $ptr i32) (param $len i32) (result i32)
    (local $pos i32)
    (local $end i32)
    (local $chunk v128)
    (local $is_lower v128) (local $is_upper v128) (local $is_digit v128) (local $is_under v128)
    (local $is_alnum v128)
    (local $mask i32)
    (local $c i32)

    (local.set $pos (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (local.get $len)))

    ;; SIMD fast path
    (block $simd_done
      (loop $simd_loop
        (br_if $simd_done (i32.gt_u (i32.add (local.get $pos) (i32.const 16)) (local.get $end)))

        (local.set $chunk (v128.load (local.get $pos)))

        ;; a-z: chunk >= 'a' && chunk <= 'z'
        (local.set $is_lower
          (v128.and
            (i8x16.ge_u (local.get $chunk) (v128.const i8x16 97 97 97 97 97 97 97 97 97 97 97 97 97 97 97 97))
            (i8x16.le_u (local.get $chunk) (v128.const i8x16 122 122 122 122 122 122 122 122 122 122 122 122 122 122 122 122))))
        ;; A-Z
        (local.set $is_upper
          (v128.and
            (i8x16.ge_u (local.get $chunk) (v128.const i8x16 65 65 65 65 65 65 65 65 65 65 65 65 65 65 65 65))
            (i8x16.le_u (local.get $chunk) (v128.const i8x16 90 90 90 90 90 90 90 90 90 90 90 90 90 90 90 90))))
        ;; 0-9
        (local.set $is_digit
          (v128.and
            (i8x16.ge_u (local.get $chunk) (v128.const i8x16 48 48 48 48 48 48 48 48 48 48 48 48 48 48 48 48))
            (i8x16.le_u (local.get $chunk) (v128.const i8x16 57 57 57 57 57 57 57 57 57 57 57 57 57 57 57 57))))
        ;; _
        (local.set $is_under
          (i8x16.eq (local.get $chunk) (v128.const i8x16 95 95 95 95 95 95 95 95 95 95 95 95 95 95 95 95)))

        ;; Combine: is_alnum = lower | upper | digit | underscore
        (local.set $is_alnum
          (v128.or (v128.or (local.get $is_lower) (local.get $is_upper))
                   (v128.or (local.get $is_digit) (local.get $is_under))))

        (local.set $mask (i8x16.bitmask (local.get $is_alnum)))

        ;; If all 16 are alnum, advance
        (if (i32.eq (local.get $mask) (i32.const 0xFFFF))
          (then
            (local.set $pos (i32.add (local.get $pos) (i32.const 16)))
            (br $simd_loop))
          (else
            ;; Find first non-alnum
            (if (i32.eq (local.get $mask) (i32.const 0))
              (then (return (local.get $pos)))
              (else
                (local.set $pos (i32.add (local.get $pos)
                  (i32.ctz (i32.xor (local.get $mask) (i32.const 0xFFFF)))))
                (return (local.get $pos))))))))

    ;; Scalar fallback
    (block $scalar_done
      (loop $scalar_loop
        (br_if $scalar_done (i32.ge_u (local.get $pos) (local.get $end)))
        (local.set $c (i32.load8_u (local.get $pos)))
        (if (i32.or
              (i32.or
                (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))
                (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90))))
              (i32.or
                (i32.and (i32.ge_u (local.get $c) (i32.const 48)) (i32.le_u (local.get $c) (i32.const 57)))
                (i32.eq (local.get $c) (i32.const 95))))
          (then
            (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
            (br $scalar_loop)))))

    (local.get $pos)
  )

  ;; === Scalar identifier scan (for comparison) ===
  (func $scan_alnum_scalar (export "scan_alnum_scalar") (param $ptr i32) (param $len i32) (result i32)
    (local $pos i32)
    (local $end i32)
    (local $c i32)

    (local.set $pos (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (local.get $len)))

    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $pos) (local.get $end)))
        (local.set $c (i32.load8_u (local.get $pos)))
        (if (i32.or
              (i32.or
                (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))
                (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90))))
              (i32.or
                (i32.and (i32.ge_u (local.get $c) (i32.const 48)) (i32.le_u (local.get $c) (i32.const 57)))
                (i32.eq (local.get $c) (i32.const 95))))
          (then
            (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
            (br $loop)))))

    (local.get $pos)
  )

  ;; === Benchmark helpers ===

  ;; Fill memory at ptr with pattern for benchmarking
  (func $fill_ws (param $ptr i32) (param $len i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        ;; Pattern: spaces with occasional newlines
        (if (i32.eq (i32.rem_u (local.get $i) (i32.const 40)) (i32.const 39))
          (then (i32.store8 (i32.add (local.get $ptr) (local.get $i)) (i32.const 10)))
          (else (i32.store8 (i32.add (local.get $ptr) (local.get $i)) (i32.const 32))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    ;; Non-ws terminator
    (i32.store8 (i32.add (local.get $ptr) (local.get $len)) (i32.const 65))
  )

  (func $fill_ident (param $ptr i32) (param $len i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        ;; Pattern: lowercase letters
        (i32.store8 (i32.add (local.get $ptr) (local.get $i))
          (i32.add (i32.const 97) (i32.rem_u (local.get $i) (i32.const 26))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    ;; Non-alnum terminator
    (i32.store8 (i32.add (local.get $ptr) (local.get $len)) (i32.const 32))
  )

  ;; Bench: skip 4KB of whitespace, 100K iterations
  (func (export "bench_ws_simd") (result i32)
    (local $i i32)
    (local $result i32)
    (call $fill_ws (i32.const 0) (i32.const 4096))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (i32.const 100000)))
        (local.set $result (call $skip_ws_simd (i32.const 0) (i32.const 4096)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.get $result)
  )

  (func (export "bench_ws_scalar") (result i32)
    (local $i i32)
    (local $result i32)
    (call $fill_ws (i32.const 0) (i32.const 4096))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (i32.const 100000)))
        (local.set $result (call $skip_ws_scalar (i32.const 0) (i32.const 4096)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.get $result)
  )

  ;; Bench: scan 4KB identifier, 100K iterations
  (func (export "bench_ident_simd") (result i32)
    (local $i i32)
    (local $result i32)
    (call $fill_ident (i32.const 0) (i32.const 4096))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (i32.const 100000)))
        (local.set $result (call $scan_alnum_simd (i32.const 0) (i32.const 4096)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.get $result)
  )

  (func (export "bench_ident_scalar") (result i32)
    (local $i i32)
    (local $result i32)
    (call $fill_ident (i32.const 0) (i32.const 4096))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (i32.const 100000)))
        (local.set $result (call $scan_alnum_scalar (i32.const 0) (i32.const 4096)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.get $result)
  )

  ;; === SIMD find_byte: find first occurrence of a byte ===
  ;; Returns offset from ptr, or len if not found
  (func $find_byte_simd (export "find_byte_simd") (param $ptr i32) (param $len i32) (param $byte i32) (result i32)
    (local $pos i32)
    (local $end i32)
    (local $needle v128)
    (local $mask i32)
    (local $c i32)

    (local.set $pos (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (local.get $len)))
    ;; Splat byte to all 16 lanes
    (local.set $needle (i8x16.splat (local.get $byte)))

    (block $simd_done
      (loop $simd_loop
        (br_if $simd_done (i32.gt_u (i32.add (local.get $pos) (i32.const 16)) (local.get $end)))
        (local.set $mask (i8x16.bitmask (i8x16.eq (v128.load (local.get $pos)) (local.get $needle))))
        (if (i32.ne (local.get $mask) (i32.const 0))
          (then (return (i32.sub (i32.add (local.get $pos) (i32.ctz (local.get $mask))) (local.get $ptr)))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 16)))
        (br $simd_loop)))

    ;; Scalar fallback
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $pos) (local.get $end)))
        (if (i32.eq (i32.load8_u (local.get $pos)) (local.get $byte))
          (then (return (i32.sub (local.get $pos) (local.get $ptr)))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (br $loop)))
    (local.get $len)
  )

  (func $find_byte_scalar (export "find_byte_scalar") (param $ptr i32) (param $len i32) (param $byte i32) (result i32)
    (local $pos i32)
    (local $end i32)
    (local.set $pos (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (local.get $len)))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $pos) (local.get $end)))
        (if (i32.eq (i32.load8_u (local.get $pos)) (local.get $byte))
          (then (return (i32.sub (local.get $pos) (local.get $ptr)))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (br $loop)))
    (local.get $len)
  )

  ;; === SIMD find_byte2: find first of two bytes (e.g. '"' or '\') ===
  (func $find_byte2_simd (export "find_byte2_simd")
    (param $ptr i32) (param $len i32) (param $b1 i32) (param $b2 i32) (result i32)
    (local $pos i32)
    (local $end i32)
    (local $n1 v128) (local $n2 v128)
    (local $mask i32)

    (local.set $pos (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (local.get $len)))
    (local.set $n1 (i8x16.splat (local.get $b1)))
    (local.set $n2 (i8x16.splat (local.get $b2)))

    (block $simd_done
      (loop $simd_loop
        (br_if $simd_done (i32.gt_u (i32.add (local.get $pos) (i32.const 16)) (local.get $end)))
        (local.set $mask (i8x16.bitmask
          (v128.or
            (i8x16.eq (v128.load (local.get $pos)) (local.get $n1))
            (i8x16.eq (v128.load (local.get $pos)) (local.get $n2)))))
        (if (i32.ne (local.get $mask) (i32.const 0))
          (then (return (i32.sub (i32.add (local.get $pos) (i32.ctz (local.get $mask))) (local.get $ptr)))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 16)))
        (br $simd_loop)))

    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $pos) (local.get $end)))
        (if (i32.or
              (i32.eq (i32.load8_u (local.get $pos)) (local.get $b1))
              (i32.eq (i32.load8_u (local.get $pos)) (local.get $b2)))
          (then (return (i32.sub (local.get $pos) (local.get $ptr)))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (br $loop)))
    (local.get $len)
  )

  (func $find_byte2_scalar (export "find_byte2_scalar")
    (param $ptr i32) (param $len i32) (param $b1 i32) (param $b2 i32) (result i32)
    (local $pos i32)
    (local $end i32)
    (local.set $pos (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (local.get $len)))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $pos) (local.get $end)))
        (if (i32.or
              (i32.eq (i32.load8_u (local.get $pos)) (local.get $b1))
              (i32.eq (i32.load8_u (local.get $pos)) (local.get $b2)))
          (then (return (i32.sub (local.get $pos) (local.get $ptr)))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (br $loop)))
    (local.get $len)
  )

  ;; === SIMD scan_digits: scan [0-9] ===
  (func $scan_digits_simd (export "scan_digits_simd") (param $ptr i32) (param $len i32) (result i32)
    (local $pos i32)
    (local $end i32)
    (local $chunk v128)
    (local $mask i32)

    (local.set $pos (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (local.get $len)))

    (block $simd_done
      (loop $simd_loop
        (br_if $simd_done (i32.gt_u (i32.add (local.get $pos) (i32.const 16)) (local.get $end)))
        (local.set $chunk (v128.load (local.get $pos)))
        (local.set $mask (i8x16.bitmask
          (v128.and
            (i8x16.ge_u (local.get $chunk) (v128.const i8x16 48 48 48 48 48 48 48 48 48 48 48 48 48 48 48 48))
            (i8x16.le_u (local.get $chunk) (v128.const i8x16 57 57 57 57 57 57 57 57 57 57 57 57 57 57 57 57)))))
        (if (i32.eq (local.get $mask) (i32.const 0xFFFF))
          (then (local.set $pos (i32.add (local.get $pos) (i32.const 16))) (br $simd_loop))
          (else
            (if (i32.eq (local.get $mask) (i32.const 0))
              (then (return (local.get $pos)))
              (else (return (i32.add (local.get $pos)
                (i32.ctz (i32.xor (local.get $mask) (i32.const 0xFFFF)))))))))))

    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $pos) (local.get $end)))
        (if (i32.and
              (i32.ge_u (i32.load8_u (local.get $pos)) (i32.const 48))
              (i32.le_u (i32.load8_u (local.get $pos)) (i32.const 57)))
          (then (local.set $pos (i32.add (local.get $pos) (i32.const 1))) (br $loop)))))
    (local.get $pos)
  )

  (func $scan_digits_scalar (export "scan_digits_scalar") (param $ptr i32) (param $len i32) (result i32)
    (local $pos i32)
    (local $end i32)
    (local.set $pos (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (local.get $len)))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $pos) (local.get $end)))
        (if (i32.and
              (i32.ge_u (i32.load8_u (local.get $pos)) (i32.const 48))
              (i32.le_u (i32.load8_u (local.get $pos)) (i32.const 57)))
          (then (local.set $pos (i32.add (local.get $pos) (i32.const 1))) (br $loop)))))
    (local.get $pos)
  )

  ;; === SIMD count_newlines: count '\n' in buffer ===
  (func $count_newlines_simd (export "count_newlines_simd") (param $ptr i32) (param $len i32) (result i32)
    (local $pos i32)
    (local $end i32)
    (local $count i32)
    (local $nl v128)
    (local $matches v128)
    (local $mask i32)

    (local.set $pos (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (local.get $len)))
    (local.set $count (i32.const 0))
    (local.set $nl (v128.const i8x16 10 10 10 10 10 10 10 10 10 10 10 10 10 10 10 10))

    (block $simd_done
      (loop $simd_loop
        (br_if $simd_done (i32.gt_u (i32.add (local.get $pos) (i32.const 16)) (local.get $end)))
        (local.set $mask (i8x16.bitmask (i8x16.eq (v128.load (local.get $pos)) (local.get $nl))))
        (local.set $count (i32.add (local.get $count) (i32.popcnt (local.get $mask))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 16)))
        (br $simd_loop)))

    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $pos) (local.get $end)))
        (if (i32.eq (i32.load8_u (local.get $pos)) (i32.const 10))
          (then (local.set $count (i32.add (local.get $count) (i32.const 1)))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (br $loop)))
    (local.get $count)
  )

  (func $count_newlines_scalar (export "count_newlines_scalar") (param $ptr i32) (param $len i32) (result i32)
    (local $pos i32)
    (local $end i32)
    (local $count i32)
    (local.set $pos (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (local.get $len)))
    (local.set $count (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $pos) (local.get $end)))
        (if (i32.eq (i32.load8_u (local.get $pos)) (i32.const 10))
          (then (local.set $count (i32.add (local.get $count) (i32.const 1)))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (br $loop)))
    (local.get $count)
  )

  ;; === SIMD memcmp: compare two byte buffers ===
  ;; Returns 1 if equal, 0 if different
  (func $memcmp_simd (export "memcmp_simd") (param $a i32) (param $b i32) (param $len i32) (result i32)
    (local $pos i32)
    (local $end i32)
    (local.set $pos (i32.const 0))
    (local.set $end (local.get $len))

    (block $simd_done
      (loop $simd_loop
        (br_if $simd_done (i32.gt_u (i32.add (local.get $pos) (i32.const 16)) (local.get $end)))
        ;; XOR both chunks; if equal, result is all zeros
        (if (v128.any_true
              (v128.xor
                (v128.load (i32.add (local.get $a) (local.get $pos)))
                (v128.load (i32.add (local.get $b) (local.get $pos)))))
          (then (return (i32.const 0))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 16)))
        (br $simd_loop)))

    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $pos) (local.get $end)))
        (if (i32.ne
              (i32.load8_u (i32.add (local.get $a) (local.get $pos)))
              (i32.load8_u (i32.add (local.get $b) (local.get $pos))))
          (then (return (i32.const 0))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (br $loop)))
    (i32.const 1)
  )

  (func $memcmp_scalar (export "memcmp_scalar") (param $a i32) (param $b i32) (param $len i32) (result i32)
    (local $pos i32)
    (local.set $pos (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $pos) (local.get $len)))
        (if (i32.ne
              (i32.load8_u (i32.add (local.get $a) (local.get $pos)))
              (i32.load8_u (i32.add (local.get $b) (local.get $pos))))
          (then (return (i32.const 0))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (br $loop)))
    (i32.const 1)
  )

  ;; === Benchmark: find_byte (needle at end of 4KB) ===
  (func $fill_find_byte (param $ptr i32) (param $len i32) (param $byte i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
      (i32.store8 (i32.add (local.get $ptr) (local.get $i)) (i32.const 65))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    ;; Put needle at end
    (i32.store8 (i32.add (local.get $ptr) (i32.sub (local.get $len) (i32.const 1))) (local.get $byte))
  )

  (func (export "bench_find_byte_simd") (result i32)
    (local $i i32) (local $r i32)
    (call $fill_find_byte (i32.const 0) (i32.const 4096) (i32.const 10))
    (local.set $i (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (i32.const 100000)))
      (local.set $r (call $find_byte_simd (i32.const 0) (i32.const 4096) (i32.const 10)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    (local.get $r))

  (func (export "bench_find_byte_scalar") (result i32)
    (local $i i32) (local $r i32)
    (call $fill_find_byte (i32.const 0) (i32.const 4096) (i32.const 10))
    (local.set $i (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (i32.const 100000)))
      (local.set $r (call $find_byte_scalar (i32.const 0) (i32.const 4096) (i32.const 10)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    (local.get $r))

  ;; === Benchmark: count_newlines (1 newline per 40 chars in 4KB) ===
  (func (export "bench_newlines_simd") (result i32)
    (local $i i32) (local $r i32)
    (call $fill_ws (i32.const 0) (i32.const 4096))
    (local.set $i (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (i32.const 100000)))
      (local.set $r (call $count_newlines_simd (i32.const 0) (i32.const 4096)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    (local.get $r))

  (func (export "bench_newlines_scalar") (result i32)
    (local $i i32) (local $r i32)
    (call $fill_ws (i32.const 0) (i32.const 4096))
    (local.set $i (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (i32.const 100000)))
      (local.set $r (call $count_newlines_scalar (i32.const 0) (i32.const 4096)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    (local.get $r))

  ;; === Benchmark: memcmp (4KB equal buffers) ===
  (func $fill_equal_bufs (param $a i32) (param $b i32) (param $len i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
      (i32.store8 (i32.add (local.get $a) (local.get $i))
        (i32.rem_u (local.get $i) (i32.const 256)))
      (i32.store8 (i32.add (local.get $b) (local.get $i))
        (i32.rem_u (local.get $i) (i32.const 256)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop))))

  (func (export "bench_memcmp_simd") (result i32)
    (local $i i32) (local $r i32)
    (call $fill_equal_bufs (i32.const 0) (i32.const 8192) (i32.const 4096))
    (local.set $i (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (i32.const 100000)))
      (local.set $r (call $memcmp_simd (i32.const 0) (i32.const 8192) (i32.const 4096)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    (local.get $r))

  (func (export "bench_memcmp_scalar") (result i32)
    (local $i i32) (local $r i32)
    (call $fill_equal_bufs (i32.const 0) (i32.const 8192) (i32.const 4096))
    (local.set $i (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (i32.const 100000)))
      (local.set $r (call $memcmp_scalar (i32.const 0) (i32.const 8192) (i32.const 4096)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    (local.get $r))

  ;; === Benchmark: scan_digits (4KB of digits) ===
  (func $fill_digits (param $ptr i32) (param $len i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
      (i32.store8 (i32.add (local.get $ptr) (local.get $i))
        (i32.add (i32.const 48) (i32.rem_u (local.get $i) (i32.const 10))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    (i32.store8 (i32.add (local.get $ptr) (local.get $len)) (i32.const 32)))

  (func (export "bench_digits_simd") (result i32)
    (local $i i32) (local $r i32)
    (call $fill_digits (i32.const 0) (i32.const 4096))
    (local.set $i (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (i32.const 100000)))
      (local.set $r (call $scan_digits_simd (i32.const 0) (i32.const 4096)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    (local.get $r))

  (func (export "bench_digits_scalar") (result i32)
    (local $i i32) (local $r i32)
    (call $fill_digits (i32.const 0) (i32.const 4096))
    (local.set $i (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (i32.const 100000)))
      (local.set $r (call $scan_digits_scalar (i32.const 0) (i32.const 4096)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    (local.get $r))

  ;; Correctness test
  (func (export "test_ws") (result i32)
    ;; Write "   \n  abc" at offset 8192
    (i32.store8 (i32.const 8192) (i32.const 32))
    (i32.store8 (i32.const 8193) (i32.const 32))
    (i32.store8 (i32.const 8194) (i32.const 32))
    (i32.store8 (i32.const 8195) (i32.const 10))
    (i32.store8 (i32.const 8196) (i32.const 32))
    (i32.store8 (i32.const 8197) (i32.const 32))
    (i32.store8 (i32.const 8198) (i32.const 97))  ;; 'a'
    ;; Should return 8198 (offset of 'a')
    (call $skip_ws_simd (i32.const 8192) (i32.const 7))
  )
)
