(module
  (type (;0;) (func (param i32) (result i64)))
  (type (;1;) (func (result i64)))
  (import "vibe" "path" (func (;0;) (type 0)))
  (func (;1;) (type 1)
    i64.const 9
    i64.const -4
    i64.and
    i32.wrap_i64
    call 0
    end
  )
  (memory (;0;) 1024)
  (export "run" (func 1))
  (export "memory" (memory 0))
  (data (i32.const 0) "\0a\00\00\00\00\00\00\00\01\00\00\00\06\00\00\00a/../b\00\00")
)
