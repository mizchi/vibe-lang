(module
  (type (;0;) (func (result i64)))
  (func (;0;) (type 0) (local i64)
    i64.const 4
    i64.const 8
    i64.add
    local.set 0
    local.get 0
    i64.const 4
    i64.sub
    end
  )
  (memory (;0;) 64)
  (export "run" (func 0))
  (export "memory" (memory 0))
)
