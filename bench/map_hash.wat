(module
  ;; === Open-addressing hash Map (FNV-1a) ===
  ;; Memory: 0..64K = hash table, 64K+ = string heap
  ;; Hash table layout: [cap:i32 at 0] [len:i32 at 4]
  ;;   Buckets at offset 8: each bucket = [key_ptr:i32, val:i32, occupied:i32] = 12 bytes
  ;;   key_ptr=0 means empty

  (memory (export "memory") 10)
  (global $heap_ptr (mut i32) (i32.const 65536))

  (func $alloc_string (param $len i32) (result i32)
    (local $ptr i32)
    (local.set $ptr (global.get $heap_ptr))
    (i32.store (local.get $ptr) (local.get $len))
    (global.set $heap_ptr (i32.add (local.get $ptr) (i32.add (i32.const 4) (i32.mul (local.get $len) (i32.const 4)))))
    (local.get $ptr)
  )

  (func $string_set_char (param $ptr i32) (param $idx i32) (param $ch i32)
    (i32.store
      (i32.add (local.get $ptr) (i32.add (i32.const 4) (i32.mul (local.get $idx) (i32.const 4))))
      (local.get $ch))
  )

  (func $string_eq (param $a i32) (param $b i32) (result i32)
    (local $len_a i32) (local $len_b i32) (local $i i32)
    (if (i32.eq (local.get $a) (local.get $b)) (then (return (i32.const 1))))
    (local.set $len_a (i32.load (local.get $a)))
    (local.set $len_b (i32.load (local.get $b)))
    (if (i32.ne (local.get $len_a) (local.get $len_b)) (then (return (i32.const 0))))
    (local.set $i (i32.const 0))
    (block $done
      (loop $cmp
        (br_if $done (i32.ge_u (local.get $i) (local.get $len_a)))
        (if (i32.ne
              (i32.load (i32.add (local.get $a) (i32.add (i32.const 4) (i32.mul (local.get $i) (i32.const 4)))))
              (i32.load (i32.add (local.get $b) (i32.add (i32.const 4) (i32.mul (local.get $i) (i32.const 4))))))
          (then (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $cmp)))
    (i32.const 1)
  )

  ;; FNV-1a hash for string
  (func $string_hash (param $ptr i32) (result i32)
    (local $len i32) (local $h i32) (local $i i32) (local $ch i32)
    (local.set $len (i32.load (local.get $ptr)))
    (local.set $h (i32.const 0x811c9dc5)) ;; FNV offset basis
    (local.set $i (i32.const 0))
    (block $done
      (loop $hash_loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $ch (i32.load (i32.add (local.get $ptr) (i32.add (i32.const 4) (i32.mul (local.get $i) (i32.const 4))))))
        (local.set $h (i32.xor (local.get $h) (local.get $ch)))
        (local.set $h (i32.mul (local.get $h) (i32.const 0x01000193))) ;; FNV prime
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $hash_loop)))
    (local.get $h)
  )

  ;; Hash table at base address
  ;; [cap:i32][len:i32][bucket0: key:i32 val:i32 occ:i32][bucket1...]
  (func $ht_init (param $base i32) (param $cap i32)
    (local $i i32) (local $bucket_area i32)
    (i32.store (local.get $base) (local.get $cap))
    (i32.store (i32.add (local.get $base) (i32.const 4)) (i32.const 0))
    ;; zero all buckets
    (local.set $bucket_area (i32.mul (local.get $cap) (i32.const 12)))
    (memory.fill
      (i32.add (local.get $base) (i32.const 8))
      (i32.const 0)
      (local.get $bucket_area))
  )

  (func $ht_bucket_addr (param $base i32) (param $idx i32) (result i32)
    (i32.add (local.get $base) (i32.add (i32.const 8) (i32.mul (local.get $idx) (i32.const 12))))
  )

  (func $ht_set (param $base i32) (param $key i32) (param $val i32)
    (local $cap i32) (local $h i32) (local $idx i32) (local $bucket i32) (local $occ i32) (local $bkey i32)
    (local.set $cap (i32.load (local.get $base)))
    (local.set $h (call $string_hash (local.get $key)))
    ;; idx = h & (cap-1)  (cap must be power of 2)
    (local.set $idx (i32.and (local.get $h) (i32.sub (local.get $cap) (i32.const 1))))
    (block $done
      (loop $probe
        (local.set $bucket (call $ht_bucket_addr (local.get $base) (local.get $idx)))
        (local.set $occ (i32.load (i32.add (local.get $bucket) (i32.const 8))))
        ;; Empty bucket: insert
        (if (i32.eqz (local.get $occ))
          (then
            (i32.store (local.get $bucket) (local.get $key))
            (i32.store (i32.add (local.get $bucket) (i32.const 4)) (local.get $val))
            (i32.store (i32.add (local.get $bucket) (i32.const 8)) (i32.const 1))
            (i32.store (i32.add (local.get $base) (i32.const 4))
              (i32.add (i32.load (i32.add (local.get $base) (i32.const 4))) (i32.const 1)))
            (br $done)))
        ;; Occupied: check key match
        (local.set $bkey (i32.load (local.get $bucket)))
        (if (call $string_eq (local.get $bkey) (local.get $key))
          (then
            (i32.store (i32.add (local.get $bucket) (i32.const 4)) (local.get $val))
            (br $done)))
        ;; Linear probe
        (local.set $idx (i32.and
          (i32.add (local.get $idx) (i32.const 1))
          (i32.sub (local.get $cap) (i32.const 1))))
        (br $probe)))
  )

  (func $ht_get (param $base i32) (param $key i32) (result i32)
    (local $cap i32) (local $h i32) (local $idx i32) (local $bucket i32) (local $occ i32)
    (local.set $cap (i32.load (local.get $base)))
    (local.set $h (call $string_hash (local.get $key)))
    (local.set $idx (i32.and (local.get $h) (i32.sub (local.get $cap) (i32.const 1))))
    (block $done
      (loop $probe
        (local.set $bucket (call $ht_bucket_addr (local.get $base) (local.get $idx)))
        (local.set $occ (i32.load (i32.add (local.get $bucket) (i32.const 8))))
        (if (i32.eqz (local.get $occ))
          (then (return (i32.const -1)))) ;; not found
        (if (call $string_eq (i32.load (local.get $bucket)) (local.get $key))
          (then (return (i32.load (i32.add (local.get $bucket) (i32.const 4))))))
        (local.set $idx (i32.and
          (i32.add (local.get $idx) (i32.const 1))
          (i32.sub (local.get $cap) (i32.const 1))))
        (br $probe)))
    (unreachable)
  )

  (func $make_key (param $n i32) (result i32)
    (local $ptr i32) (local $d0 i32) (local $d1 i32) (local $d2 i32)
    (local.set $d2 (i32.rem_u (local.get $n) (i32.const 10)))
    (local.set $d1 (i32.rem_u (i32.div_u (local.get $n) (i32.const 10)) (i32.const 10)))
    (local.set $d0 (i32.rem_u (i32.div_u (local.get $n) (i32.const 100)) (i32.const 10)))
    (local.set $ptr (call $alloc_string (i32.const 4)))
    (call $string_set_char (local.get $ptr) (i32.const 0) (i32.const 107))
    (call $string_set_char (local.get $ptr) (i32.const 1) (i32.add (i32.const 48) (local.get $d0)))
    (call $string_set_char (local.get $ptr) (i32.const 2) (i32.add (i32.const 48) (local.get $d1)))
    (call $string_set_char (local.get $ptr) (i32.const 3) (i32.add (i32.const 48) (local.get $d2)))
    (local.get $ptr)
  )

  ;; Benchmark: insert N entries then lookup each
  (func (export "bench_hash") (param $n i32) (result i32)
    (local $base i32) (local $i i32) (local $sum i32)
    (local.set $base (i32.const 0))
    ;; Use cap=1024 (power of 2, >= 2*n for low collision)
    (call $ht_init (local.get $base) (i32.const 1024))
    (global.set $heap_ptr (i32.const 65536))
    ;; Insert
    (local.set $i (i32.const 0))
    (block $ins_done
      (loop $ins
        (br_if $ins_done (i32.ge_u (local.get $i) (local.get $n)))
        (call $ht_set (local.get $base) (call $make_key (local.get $i)) (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $ins)))
    ;; Lookup + sum
    (local.set $sum (i32.const 0))
    (local.set $i (i32.const 0))
    (block $get_done
      (loop $get_loop
        (br_if $get_done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $sum (i32.add (local.get $sum) (call $ht_get (local.get $base) (call $make_key (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $get_loop)))
    (local.get $sum)
  )
)
