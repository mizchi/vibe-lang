(module
  (type (;0;) (func (result i64)))
  (func (;0;) (type 0)
    i64.const 7
    i64.const 2
    i64.shr_u
    i32.wrap_i64
    if (result i64)
      i64.const 4
    else
      i64.const 8
    end
    end
  )
  (memory (;0;) 1024)
  (export "run" (func 0))
  (export "memory" (memory 0))
)
