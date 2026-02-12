(module
  (type (;0;) (func (result i32)))
  (func (;0;) (type 0)
    i32.const 7
    i32.const 2
    i32.shr_u
    if (result i32)
      i32.const 4
    else
      i32.const 8
    end
    end
  )
  (memory (;0;) 64)
  (export "run" (func 0))
  (export "memory" (memory 0))
)
