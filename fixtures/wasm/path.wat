(module
  (type (;0;) (func (param i64) (result i64)))
  (type (;1;) (func (result i64)))
  (import "vibe" "path" (func (;0;) (type 0)))
  (func (;1;) (type 1) (local i32)
    i32.const 16
    local.set 0
    i64.const 1
    call 0
    end
  )
  (memory (;0;) 64)
  (export "run" (func 1))
  (export "memory" (memory 0))
  (data (i32.const 0) "\01\00\00\00\06\00\00\00a/../b")
)
