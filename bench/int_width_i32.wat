(module
  (type (;0;) (func (result i32)))
  (memory (;0;) 1)
  (export "run" (func 0))
  (export "memory" (memory 0))

  ;; SHA-1-like round: 80 iterations of bitwise ops using i32
  (func (;0;) (type 0) (result i32)
    (local $a i32) (local $b i32) (local $c i32) (local $d i32) (local $e i32)
    (local $i i32) (local $w i32) (local $f i32) (local $temp i32)

    ;; Initialize with SHA-1 constants
    (local.set $a (i32.const 0x67452301))
    (local.set $b (i32.const 0xEFCDAB89))
    (local.set $c (i32.const 0x98BADCFE))
    (local.set $d (i32.const 0x10325476))
    (local.set $e (i32.const 0xC3D2E1F0))
    (local.set $i (i32.const 0))

    (block $break
      (loop $loop
        (br_if $break (i32.ge_u (local.get $i) (i32.const 80)))

        ;; w = (a ^ b ^ c ^ d) rotl 1
        (local.set $w
          (i32.rotl
            (i32.xor (i32.xor (local.get $a) (local.get $b))
                     (i32.xor (local.get $c) (local.get $d)))
            (i32.const 1)))

        ;; f = (b & c) ^ (~b & d)
        (local.set $f
          (i32.xor
            (i32.and (local.get $b) (local.get $c))
            (i32.and (i32.xor (local.get $b) (i32.const -1)) (local.get $d))))

        ;; temp = (a rotl 5) + f + e + k + w
        (local.set $temp
          (i32.add
            (i32.add
              (i32.add
                (i32.add
                  (i32.rotl (local.get $a) (i32.const 5))
                  (local.get $f))
                (local.get $e))
              (i32.const 0x5A827999))
            (local.get $w)))

        ;; e=d, d=c, c=b rotl 30, b=a, a=temp
        (local.set $e (local.get $d))
        (local.set $d (local.get $c))
        (local.set $c (i32.rotl (local.get $b) (i32.const 30)))
        (local.set $b (local.get $a))
        (local.set $a (local.get $temp))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
    (local.get $a)
  )
)
