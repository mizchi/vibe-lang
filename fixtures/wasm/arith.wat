(module
  (type (;0;) (func (result i32)))
  (func (;0;) (type 0) (local i32)
    i32.const 4
    i32.const 8
    i32.add
    local.set 0
    local.get 0
    i32.const 4
    i32.sub
    end
  )
  (memory (;0;) 1)
  (export "run" (func 0))
  (export "memory" (memory 0))
)
