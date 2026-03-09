(module
  (type (;0;) (func (result i64)))
  (memory (;0;) 1024)
  (export "run" (func 0))
  (export "memory" (memory 0))
  (func (;0;) (type 0) (result i64)
    (local i32 i64)
    i32.const 16
    local.set 0
    i64.const 1
    local.tee 1
  )
  (data (;0;) (i32.const 0) "\01\00\00\00\05\00\00\00hello")
)
