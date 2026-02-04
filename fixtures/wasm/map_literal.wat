(module
  (type (;0;) (func (result i32)))
  (func (;0;) (type 0) (local i32 i32 i32)
    i32.const 12
    local.set 0
    local.get 0
    local.set 2
    local.get 0
    i32.const 16
    i32.add
    local.set 0
    local.get 2
    i32.const 6
    i32.store align=2 offset=0
    local.get 2
    i32.const 1
    i32.store align=2 offset=4
    local.get 2
    i32.const 0
    i32.store align=2 offset=8
    local.get 2
    i32.const 4
    i32.store align=2 offset=12
    local.get 2
    i32.const 1
    i32.or
    local.set 1
    local.get 1
    end
  )
  (memory (;0;) 1)
  (export "run" (func 0))
  (export "memory" (memory 0))
  (data (i32.const 0) "\01\00\00\00\01\00\00\00a")
)
