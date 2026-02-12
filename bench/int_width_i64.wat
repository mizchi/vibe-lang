(module
  (type (;0;) (func (result i64)))
  (memory (;0;) 1)
  (export "run" (func 0))
  (export "memory" (memory 0))

  ;; SHA-1-like round: 80 iterations of bitwise ops using i64
  ;; Values masked to 32-bit to simulate u32-in-i64 approach
  (func (;0;) (type 0) (result i64)
    (local $a i64) (local $b i64) (local $c i64) (local $d i64) (local $e i64)
    (local $i i32) (local $w i64) (local $f i64) (local $temp i64)
    (local $mask i64)

    ;; 32-bit mask
    (local.set $mask (i64.const 0xFFFFFFFF))

    ;; Initialize with SHA-1 constants
    (local.set $a (i64.const 0x67452301))
    (local.set $b (i64.const 0xEFCDAB89))
    (local.set $c (i64.const 0x98BADCFE))
    (local.set $d (i64.const 0x10325476))
    (local.set $e (i64.const 0xC3D2E1F0))
    (local.set $i (i32.const 0))

    (block $break
      (loop $loop
        (br_if $break (i32.ge_u (local.get $i) (i32.const 80)))

        ;; w = ((a ^ b ^ c ^ d) << 1 | (a ^ b ^ c ^ d) >> 31) & mask
        (local.set $w
          (i64.and
            (i64.or
              (i64.shl
                (i64.xor (i64.xor (local.get $a) (local.get $b))
                         (i64.xor (local.get $c) (local.get $d)))
                (i64.const 1))
              (i64.shr_u
                (i64.xor (i64.xor (local.get $a) (local.get $b))
                         (i64.xor (local.get $c) (local.get $d)))
                (i64.const 31)))
            (local.get $mask)))

        ;; f = (b & c) ^ (~b & d)  (all masked)
        (local.set $f
          (i64.and
            (i64.xor
              (i64.and (local.get $b) (local.get $c))
              (i64.and (i64.xor (local.get $b) (local.get $mask)) (local.get $d)))
            (local.get $mask)))

        ;; temp = ((a<<5 | a>>27) + f + e + k + w) & mask
        (local.set $temp
          (i64.and
            (i64.add
              (i64.add
                (i64.add
                  (i64.add
                    (i64.and
                      (i64.or
                        (i64.shl (local.get $a) (i64.const 5))
                        (i64.shr_u (local.get $a) (i64.const 27)))
                      (local.get $mask))
                    (local.get $f))
                  (local.get $e))
                (i64.const 0x5A827999))
              (local.get $w))
            (local.get $mask)))

        ;; e=d, d=c, c=(b<<30|b>>2)&mask, b=a, a=temp
        (local.set $e (local.get $d))
        (local.set $d (local.get $c))
        (local.set $c (i64.and
          (i64.or
            (i64.shl (local.get $b) (i64.const 30))
            (i64.shr_u (local.get $b) (i64.const 2)))
          (local.get $mask)))
        (local.set $b (local.get $a))
        (local.set $a (local.get $temp))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
    (local.get $a)
  )
)
