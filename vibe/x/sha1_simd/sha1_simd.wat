(module
  (memory (export "memory") 1)

  ;; SHA1 constants
  (global $k0 i32 (i32.const 0x5A827999))
  (global $k1 i32 (i32.const 0x6ED9EBA1))
  (global $k2 i32 (i32.const 0x8F1BBCDC))
  (global $k3 i32 (i32.const 0xCA62C1D6))

  ;; SHA1 initial hash values
  (global $h0_init i32 (i32.const 0x67452301))
  (global $h1_init i32 (i32.const 0xEFCDAB89))
  (global $h2_init i32 (i32.const 0x98BADCFE))
  (global $h3_init i32 (i32.const 0x10325476))
  (global $h4_init i32 (i32.const 0xC3D2E1F0))

  ;; Working state (mutable)
  (global $h0 (mut i32) (i32.const 0))
  (global $h1 (mut i32) (i32.const 0))
  (global $h2 (mut i32) (i32.const 0))
  (global $h3 (mut i32) (i32.const 0))
  (global $h4 (mut i32) (i32.const 0))

  ;; Memory layout:
  ;;   0-63:    input block (64 bytes)
  ;;   64-383:  W schedule (80 * 4 = 320 bytes)
  ;;   384-403: hash output (20 bytes)
  ;;   404-443: hex output (40 bytes)

  ;; Byte swap for big-endian: SIMD shuffle mask at offset 448
  (data (i32.const 448) "\03\02\01\00\07\06\05\04\0b\0a\09\08\0f\0e\0d\0c")

  ;; Test data: "abc" at offset 1024
  (data (i32.const 1024) "abc")

  ;; Hex table at offset 512
  (data (i32.const 512) "0123456789abcdef")

  ;; Scalar byte-swap version of schedule building (for comparison)
  (func $build_schedule_scalar (param $block_ptr i32)
    (local $i i32)
    (local $offset i32)
    (local $b0 i32) (local $b1 i32) (local $b2 i32) (local $b3 i32)

    ;; W[0..15]: manual big-endian byte load
    (local.set $i (i32.const 0))
    (block $init_done
      (loop $init_loop
        (br_if $init_done (i32.ge_u (local.get $i) (i32.const 16)))
        (local.set $offset (i32.add (local.get $block_ptr) (i32.mul (local.get $i) (i32.const 4))))
        (local.set $b0 (i32.load8_u (local.get $offset)))
        (local.set $b1 (i32.load8_u (i32.add (local.get $offset) (i32.const 1))))
        (local.set $b2 (i32.load8_u (i32.add (local.get $offset) (i32.const 2))))
        (local.set $b3 (i32.load8_u (i32.add (local.get $offset) (i32.const 3))))
        (i32.store
          (i32.add (i32.const 64) (i32.mul (local.get $i) (i32.const 4)))
          (i32.or
            (i32.or (i32.shl (local.get $b0) (i32.const 24)) (i32.shl (local.get $b1) (i32.const 16)))
            (i32.or (i32.shl (local.get $b2) (i32.const 8)) (local.get $b3))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $init_loop)))

    ;; W[16..79]: same expansion
    (local.set $i (i32.const 16))
    (block $done
      (loop $expand
        (br_if $done (i32.ge_u (local.get $i) (i32.const 80)))
        (i32.store
          (i32.add (i32.const 64) (i32.mul (local.get $i) (i32.const 4)))
          (call $rotl
            (i32.xor
              (i32.xor
                (i32.load (i32.add (i32.const 64) (i32.mul (i32.sub (local.get $i) (i32.const 3)) (i32.const 4))))
                (i32.load (i32.add (i32.const 64) (i32.mul (i32.sub (local.get $i) (i32.const 8)) (i32.const 4)))))
              (i32.xor
                (i32.load (i32.add (i32.const 64) (i32.mul (i32.sub (local.get $i) (i32.const 14)) (i32.const 4))))
                (i32.load (i32.add (i32.const 64) (i32.mul (i32.sub (local.get $i) (i32.const 16)) (i32.const 4))))))
            (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $expand)))
  )

  ;; SHA1 using scalar schedule (for benchmarking comparison)
  (func $sha1_scalar (param $msg_ptr i32) (param $msg_len i32) (result i32)
    (local $padded_len i32)
    (local $num_blocks i32)
    (local $block_idx i32)
    (local $bit_len i32)
    (local $pad_start i32)

    (global.set $h0 (global.get $h0_init))
    (global.set $h1 (global.get $h1_init))
    (global.set $h2 (global.get $h2_init))
    (global.set $h3 (global.get $h3_init))
    (global.set $h4 (global.get $h4_init))

    (local.set $bit_len (i32.mul (local.get $msg_len) (i32.const 8)))
    (local.set $padded_len
      (i32.mul
        (i32.add
          (i32.div_u (i32.add (local.get $msg_len) (i32.const 8)) (i32.const 64))
          (i32.const 1))
        (i32.const 64)))

    (i32.store8 (i32.add (local.get $msg_ptr) (local.get $msg_len)) (i32.const 0x80))
    (local.set $pad_start (i32.add (local.get $msg_ptr) (i32.add (local.get $msg_len) (i32.const 1))))
    (block $pad_done
      (loop $pad_loop
        (br_if $pad_done (i32.ge_u (local.get $pad_start)
          (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 8)))))
        (i32.store8 (local.get $pad_start) (i32.const 0))
        (local.set $pad_start (i32.add (local.get $pad_start) (i32.const 1)))
        (br $pad_loop)))

    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 8))) (i32.const 0))
    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 7))) (i32.const 0))
    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 6))) (i32.const 0))
    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 5))) (i32.const 0))
    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 4)))
      (i32.shr_u (local.get $bit_len) (i32.const 24)))
    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 3)))
      (i32.and (i32.shr_u (local.get $bit_len) (i32.const 16)) (i32.const 0xFF)))
    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 2)))
      (i32.and (i32.shr_u (local.get $bit_len) (i32.const 8)) (i32.const 0xFF)))
    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 1)))
      (i32.and (local.get $bit_len) (i32.const 0xFF)))

    (local.set $num_blocks (i32.div_u (local.get $padded_len) (i32.const 64)))
    (local.set $block_idx (i32.const 0))
    (block $blocks_done
      (loop $blocks_loop
        (br_if $blocks_done (i32.ge_u (local.get $block_idx) (local.get $num_blocks)))
        (call $build_schedule_scalar
          (i32.add (local.get $msg_ptr) (i32.mul (local.get $block_idx) (i32.const 64))))
        (call $process_block)
        (local.set $block_idx (i32.add (local.get $block_idx) (i32.const 1)))
        (br $blocks_loop)))

    (i32.const 384)
  )

  ;; Bench scalar: 10K iterations
  (func (export "bench_scalar_10k") (result i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $iter
        (br_if $done (i32.ge_u (local.get $i) (i32.const 10000)))
        (drop (call $sha1_scalar (i32.const 2048) (i32.const 1024)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $iter)))
    (local.get $i)
  )

  ;; 1KB test data at offset 2048 (filled with 'A' = 0x41)
  (data (i32.const 2048) "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

  ;; Bench: hash 1KB data 10000 times
  (func (export "bench_10k") (result i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $iter
        (br_if $done (i32.ge_u (local.get $i) (i32.const 10000)))
        (drop (call $sha1 (i32.const 2048) (i32.const 1024)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $iter)))
    (local.get $i)
  )

  ;; Test: sha1("abc"), return first 4 bytes of hash as i32
  ;; Expected: 0xa9993e36 (big-endian first word)
  (func (export "test_abc") (result i32)
    (call $sha1 (i32.const 1024) (i32.const 3))
    drop
    ;; Read first 4 bytes of hash as big-endian i32
    (i32.or
      (i32.or
        (i32.shl (i32.load8_u (i32.const 384)) (i32.const 24))
        (i32.shl (i32.load8_u (i32.const 385)) (i32.const 16)))
      (i32.or
        (i32.shl (i32.load8_u (i32.const 386)) (i32.const 8))
        (i32.load8_u (i32.const 387))))
  )

  ;; rotl32(x, n) = (x << n) | (x >>> (32 - n))
  (func $rotl (param $x i32) (param $n i32) (result i32)
    local.get $x
    local.get $n
    i32.shl
    local.get $x
    i32.const 32
    local.get $n
    i32.sub
    i32.shr_u
    i32.or
  )

  ;; Build message schedule W[0..79] using SIMD for W[0..15] byte swap
  ;; and scalar for W[16..79]
  (func $build_schedule_simd (param $block_ptr i32)
    (local $i i32)
    (local $shuffle_mask v128)

    ;; Load shuffle mask for big-endian byte swap
    (local.set $shuffle_mask (v128.load (i32.const 448)))

    ;; W[0..3]: load 16 bytes, byte-swap with shuffle
    (v128.store (i32.const 64)
      (i8x16.swizzle
        (v128.load (local.get $block_ptr))
        (local.get $shuffle_mask)))

    ;; W[4..7]
    (v128.store (i32.const 80)
      (i8x16.swizzle
        (v128.load (i32.add (local.get $block_ptr) (i32.const 16)))
        (local.get $shuffle_mask)))

    ;; W[8..11]
    (v128.store (i32.const 96)
      (i8x16.swizzle
        (v128.load (i32.add (local.get $block_ptr) (i32.const 32)))
        (local.get $shuffle_mask)))

    ;; W[12..15]
    (v128.store (i32.const 112)
      (i8x16.swizzle
        (v128.load (i32.add (local.get $block_ptr) (i32.const 48)))
        (local.get $shuffle_mask)))

    ;; W[16..79]: scalar expansion
    ;; W[i] = rotl(W[i-3] ^ W[i-8] ^ W[i-14] ^ W[i-16], 1)
    (local.set $i (i32.const 16))
    (block $done
      (loop $expand
        (br_if $done (i32.ge_u (local.get $i) (i32.const 80)))
        (i32.store
          (i32.add (i32.const 64) (i32.mul (local.get $i) (i32.const 4)))
          (call $rotl
            (i32.xor
              (i32.xor
                (i32.load (i32.add (i32.const 64) (i32.mul (i32.sub (local.get $i) (i32.const 3)) (i32.const 4))))
                (i32.load (i32.add (i32.const 64) (i32.mul (i32.sub (local.get $i) (i32.const 8)) (i32.const 4)))))
              (i32.xor
                (i32.load (i32.add (i32.const 64) (i32.mul (i32.sub (local.get $i) (i32.const 14)) (i32.const 4))))
                (i32.load (i32.add (i32.const 64) (i32.mul (i32.sub (local.get $i) (i32.const 16)) (i32.const 4))))))
            (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $expand)))
  )

  ;; Process one block (80 rounds)
  (func $process_block
    (local $a i32) (local $b i32) (local $c i32) (local $d i32) (local $e i32)
    (local $f i32) (local $k i32) (local $temp i32)
    (local $i i32)

    (local.set $a (global.get $h0))
    (local.set $b (global.get $h1))
    (local.set $c (global.get $h2))
    (local.set $d (global.get $h3))
    (local.set $e (global.get $h4))

    (local.set $i (i32.const 0))
    (block $done
      (loop $round
        (br_if $done (i32.ge_u (local.get $i) (i32.const 80)))

        ;; Compute f and k based on round
        (if (i32.lt_u (local.get $i) (i32.const 20))
          (then
            ;; f = (b & c) ^ (~b & d), k = k0
            (local.set $f (i32.xor
              (i32.and (local.get $b) (local.get $c))
              (i32.and (i32.xor (local.get $b) (i32.const -1)) (local.get $d))))
            (local.set $k (global.get $k0)))
          (else
            (if (i32.lt_u (local.get $i) (i32.const 40))
              (then
                ;; f = b ^ c ^ d, k = k1
                (local.set $f (i32.xor (i32.xor (local.get $b) (local.get $c)) (local.get $d)))
                (local.set $k (global.get $k1)))
              (else
                (if (i32.lt_u (local.get $i) (i32.const 60))
                  (then
                    ;; f = (b & c) ^ (b & d) ^ (c & d), k = k2
                    (local.set $f (i32.xor (i32.xor
                      (i32.and (local.get $b) (local.get $c))
                      (i32.and (local.get $b) (local.get $d)))
                      (i32.and (local.get $c) (local.get $d))))
                    (local.set $k (global.get $k2)))
                  (else
                    ;; f = b ^ c ^ d, k = k3
                    (local.set $f (i32.xor (i32.xor (local.get $b) (local.get $c)) (local.get $d)))
                    (local.set $k (global.get $k3))))))))

        ;; temp = rotl(a,5) + f + e + k + W[i]
        (local.set $temp
          (i32.add
            (i32.add
              (i32.add
                (i32.add
                  (call $rotl (local.get $a) (i32.const 5))
                  (local.get $f))
                (local.get $e))
              (local.get $k))
            (i32.load (i32.add (i32.const 64) (i32.mul (local.get $i) (i32.const 4))))))

        ;; Rotate: e=d, d=c, c=rotl(b,30), b=a, a=temp
        (local.set $e (local.get $d))
        (local.set $d (local.get $c))
        (local.set $c (call $rotl (local.get $b) (i32.const 30)))
        (local.set $b (local.get $a))
        (local.set $a (local.get $temp))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $round)))

    ;; Add to hash
    (global.set $h0 (i32.add (global.get $h0) (local.get $a)))
    (global.set $h1 (i32.add (global.get $h1) (local.get $b)))
    (global.set $h2 (i32.add (global.get $h2) (local.get $c)))
    (global.set $h3 (i32.add (global.get $h3) (local.get $d)))
    (global.set $h4 (i32.add (global.get $h4) (local.get $e)))
  )

  ;; Hash a message already in memory at offset 0, length in bytes
  ;; Returns pointer to 20-byte hash at offset 384
  (func $sha1 (export "sha1") (param $msg_ptr i32) (param $msg_len i32) (result i32)
    (local $padded_len i32)
    (local $num_blocks i32)
    (local $block_idx i32)
    (local $bit_len i32)
    (local $pad_start i32)

    ;; Initialize hash
    (global.set $h0 (global.get $h0_init))
    (global.set $h1 (global.get $h1_init))
    (global.set $h2 (global.get $h2_init))
    (global.set $h3 (global.get $h3_init))
    (global.set $h4 (global.get $h4_init))

    ;; Padding: append 0x80, then zeros, then 8-byte big-endian bit length
    ;; Padded length = ((msg_len + 8) / 64 + 1) * 64
    (local.set $bit_len (i32.mul (local.get $msg_len) (i32.const 8)))
    (local.set $padded_len
      (i32.mul
        (i32.add
          (i32.div_u (i32.add (local.get $msg_len) (i32.const 8)) (i32.const 64))
          (i32.const 1))
        (i32.const 64)))

    ;; Write 0x80 after message
    (i32.store8 (i32.add (local.get $msg_ptr) (local.get $msg_len)) (i32.const 0x80))

    ;; Zero-fill padding
    (local.set $pad_start (i32.add (local.get $msg_ptr) (i32.add (local.get $msg_len) (i32.const 1))))
    (block $pad_done
      (loop $pad_loop
        (br_if $pad_done (i32.ge_u (local.get $pad_start)
          (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 8)))))
        (i32.store8 (local.get $pad_start) (i32.const 0))
        (local.set $pad_start (i32.add (local.get $pad_start) (i32.const 1)))
        (br $pad_loop)))

    ;; Write bit length as big-endian 64-bit at end (only lower 32 bits)
    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 8))) (i32.const 0))
    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 7))) (i32.const 0))
    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 6))) (i32.const 0))
    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 5))) (i32.const 0))
    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 4)))
      (i32.shr_u (local.get $bit_len) (i32.const 24)))
    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 3)))
      (i32.and (i32.shr_u (local.get $bit_len) (i32.const 16)) (i32.const 0xFF)))
    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 2)))
      (i32.and (i32.shr_u (local.get $bit_len) (i32.const 8)) (i32.const 0xFF)))
    (i32.store8 (i32.add (local.get $msg_ptr) (i32.sub (local.get $padded_len) (i32.const 1)))
      (i32.and (local.get $bit_len) (i32.const 0xFF)))

    ;; Process blocks
    (local.set $num_blocks (i32.div_u (local.get $padded_len) (i32.const 64)))
    (local.set $block_idx (i32.const 0))
    (block $blocks_done
      (loop $blocks_loop
        (br_if $blocks_done (i32.ge_u (local.get $block_idx) (local.get $num_blocks)))
        (call $build_schedule_simd
          (i32.add (local.get $msg_ptr) (i32.mul (local.get $block_idx) (i32.const 64))))
        (call $process_block)
        (local.set $block_idx (i32.add (local.get $block_idx) (i32.const 1)))
        (br $blocks_loop)))

    ;; Write hash to offset 384 (big-endian)
    (i32.store8 (i32.const 384) (i32.shr_u (global.get $h0) (i32.const 24)))
    (i32.store8 (i32.const 385) (i32.and (i32.shr_u (global.get $h0) (i32.const 16)) (i32.const 0xFF)))
    (i32.store8 (i32.const 386) (i32.and (i32.shr_u (global.get $h0) (i32.const 8)) (i32.const 0xFF)))
    (i32.store8 (i32.const 387) (i32.and (global.get $h0) (i32.const 0xFF)))

    (i32.store8 (i32.const 388) (i32.shr_u (global.get $h1) (i32.const 24)))
    (i32.store8 (i32.const 389) (i32.and (i32.shr_u (global.get $h1) (i32.const 16)) (i32.const 0xFF)))
    (i32.store8 (i32.const 390) (i32.and (i32.shr_u (global.get $h1) (i32.const 8)) (i32.const 0xFF)))
    (i32.store8 (i32.const 391) (i32.and (global.get $h1) (i32.const 0xFF)))

    (i32.store8 (i32.const 392) (i32.shr_u (global.get $h2) (i32.const 24)))
    (i32.store8 (i32.const 393) (i32.and (i32.shr_u (global.get $h2) (i32.const 16)) (i32.const 0xFF)))
    (i32.store8 (i32.const 394) (i32.and (i32.shr_u (global.get $h2) (i32.const 8)) (i32.const 0xFF)))
    (i32.store8 (i32.const 395) (i32.and (global.get $h2) (i32.const 0xFF)))

    (i32.store8 (i32.const 396) (i32.shr_u (global.get $h3) (i32.const 24)))
    (i32.store8 (i32.const 397) (i32.and (i32.shr_u (global.get $h3) (i32.const 16)) (i32.const 0xFF)))
    (i32.store8 (i32.const 398) (i32.and (i32.shr_u (global.get $h3) (i32.const 8)) (i32.const 0xFF)))
    (i32.store8 (i32.const 399) (i32.and (global.get $h3) (i32.const 0xFF)))

    (i32.store8 (i32.const 400) (i32.shr_u (global.get $h4) (i32.const 24)))
    (i32.store8 (i32.const 401) (i32.and (i32.shr_u (global.get $h4) (i32.const 16)) (i32.const 0xFF)))
    (i32.store8 (i32.const 402) (i32.and (i32.shr_u (global.get $h4) (i32.const 8)) (i32.const 0xFF)))
    (i32.store8 (i32.const 403) (i32.and (global.get $h4) (i32.const 0xFF)))

    (i32.const 384)
  )
)
