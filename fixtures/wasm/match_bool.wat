(module
  (type (;0;) (func (result i32)))
  (func (;0;) (type 0) (local i32)
    i32.const 7
    local.set 0
    local.get 0
    i32.const 7
    i32.eq
    if (result i32)
      i32.const 4
    else
      i32.const 0
    end
    end
  )
  (memory (;0;) 1)
  (export "run" (func 0))
  (export "memory" (memory 0))
)
