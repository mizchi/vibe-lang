(module
  ;; === Linear-scan Map (current vibe approach) ===
  ;; Memory layout: 0..4=len, 4..4+8*cap=entries (key_ptr:i32, val:i32 pairs)
  ;; Strings stored after entries area

  (memory (export "memory") 10) ;; 640KB

  ;; Globals
  (global $heap_ptr (mut i32) (i32.const 65536)) ;; string heap starts at 64K

  ;; alloc_string: store length + chars, return ptr
  ;; string layout: [len:i32][char0:i32][char1:i32]...
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

  ;; string_eq: compare two string ptrs
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

  ;; Map base address
  ;; Layout: [len:i32] [cap:i32] [entry0_key:i32 entry0_val:i32] [entry1_key:i32 entry1_val:i32] ...
  ;; Base at address 0

  (func $map_init (param $base i32) (param $cap i32)
    (i32.store (local.get $base) (i32.const 0)) ;; len=0
    (i32.store (i32.add (local.get $base) (i32.const 4)) (local.get $cap))
  )

  (func $map_set (param $base i32) (param $key i32) (param $val i32)
    (local $len i32) (local $i i32) (local $entry_ptr i32)
    (local.set $len (i32.load (local.get $base)))
    ;; linear search for existing key
    (local.set $i (i32.const 0))
    (block $done
      (loop $search
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $entry_ptr
          (i32.add (local.get $base)
            (i32.add (i32.const 8) (i32.mul (local.get $i) (i32.const 8)))))
        (if (call $string_eq (i32.load (local.get $entry_ptr)) (local.get $key))
          (then
            (i32.store (i32.add (local.get $entry_ptr) (i32.const 4)) (local.get $val))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $search)))
    ;; not found: append
    (local.set $entry_ptr
      (i32.add (local.get $base)
        (i32.add (i32.const 8) (i32.mul (local.get $len) (i32.const 8)))))
    (i32.store (local.get $entry_ptr) (local.get $key))
    (i32.store (i32.add (local.get $entry_ptr) (i32.const 4)) (local.get $val))
    (i32.store (local.get $base) (i32.add (local.get $len) (i32.const 1)))
  )

  (func $map_get (param $base i32) (param $key i32) (result i32)
    (local $len i32) (local $i i32) (local $entry_ptr i32)
    (local.set $len (i32.load (local.get $base)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $search
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $entry_ptr
          (i32.add (local.get $base)
            (i32.add (i32.const 8) (i32.mul (local.get $i) (i32.const 8)))))
        (if (call $string_eq (i32.load (local.get $entry_ptr)) (local.get $key))
          (then
            (return (i32.load (i32.add (local.get $entry_ptr) (i32.const 4))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $search)))
    (i32.const -1) ;; not found sentinel
  )

  (func $map_has (param $base i32) (param $key i32) (result i32)
    (local $len i32) (local $i i32) (local $entry_ptr i32)
    (local.set $len (i32.load (local.get $base)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $search
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $entry_ptr
          (i32.add (local.get $base)
            (i32.add (i32.const 8) (i32.mul (local.get $i) (i32.const 8)))))
        (if (call $string_eq (i32.load (local.get $entry_ptr)) (local.get $key))
          (then (return (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $search)))
    (i32.const 0)
  )

  ;; make_key: creates string "key_NNN" for a given integer
  ;; Simple: store "k" + digit chars
  (func $make_key (param $n i32) (result i32)
    (local $ptr i32) (local $d0 i32) (local $d1 i32) (local $d2 i32)
    ;; 3-digit key: "k" + hundreds + tens + ones = length 4
    (local.set $d2 (i32.rem_u (local.get $n) (i32.const 10)))
    (local.set $d1 (i32.rem_u (i32.div_u (local.get $n) (i32.const 10)) (i32.const 10)))
    (local.set $d0 (i32.rem_u (i32.div_u (local.get $n) (i32.const 100)) (i32.const 10)))
    (local.set $ptr (call $alloc_string (i32.const 4)))
    (call $string_set_char (local.get $ptr) (i32.const 0) (i32.const 107)) ;; 'k'
    (call $string_set_char (local.get $ptr) (i32.const 1) (i32.add (i32.const 48) (local.get $d0)))
    (call $string_set_char (local.get $ptr) (i32.const 2) (i32.add (i32.const 48) (local.get $d1)))
    (call $string_set_char (local.get $ptr) (i32.const 3) (i32.add (i32.const 48) (local.get $d2)))
    (local.get $ptr)
  )

  ;; Benchmark: insert N entries, then lookup each
  (func (export "bench_linear") (param $n i32) (result i32)
    (local $map_base i32) (local $i i32) (local $key i32) (local $sum i32)
    (local.set $map_base (i32.const 0))
    (call $map_init (local.get $map_base) (i32.const 1024))
    ;; Reset heap for fresh strings
    (global.set $heap_ptr (i32.const 65536))
    ;; Insert n entries: key_i -> i
    (local.set $i (i32.const 0))
    (block $ins_done
      (loop $ins
        (br_if $ins_done (i32.ge_u (local.get $i) (local.get $n)))
        (call $map_set (local.get $map_base) (call $make_key (local.get $i)) (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $ins)))
    ;; Lookup each and sum values
    (local.set $sum (i32.const 0))
    (local.set $i (i32.const 0))
    (block $get_done
      (loop $get_loop
        (br_if $get_done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $sum (i32.add (local.get $sum) (call $map_get (local.get $map_base) (call $make_key (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $get_loop)))
    (local.get $sum)
  )
)
