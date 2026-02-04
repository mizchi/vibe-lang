(module
  (type (;0;) (func (param i32) (result i32)))
  (type (;1;) (func (result i32)))
  (import "xsh" "path" (func (;0;) (type 0)))
  (func (;1;) (type 1)
    i32.const 1
    call 0
    end
  )
  (memory (;0;) 1)
  (export "run" (func 1))
  (export "memory" (memory 0))
  (data (i32.const 0) "\01\00\00\00\06\00\00\00a/../b")
)
