(module
  (type (;0;) (func (result i32)))
  (func (;0;) (type 0) (local i32 i32 i32 i32 i32 i32)
    i32.const 0
    local.set 0
    local.get 0
    i32.const 16
    i32.add
    local.set 3
    memory.size
    local.set 4
    local.get 3
    i32.const 65535
    i32.add
    i32.const 16
    i32.shr_u
    local.set 5
    local.get 4
    local.get 5
    i32.lt_s
    if
      local.get 5
      local.get 4
      i32.sub
      memory.grow
      drop
    end
    local.get 0
    local.set 2
    local.get 0
    i32.const 16
    i32.add
    local.set 0
    local.get 2
    i32.const 3
    i32.store align=2 offset=0
    local.get 2
    i32.const 2
    i32.store align=2 offset=4
    local.get 2
    i32.const 4
    i32.store align=2 offset=8
    local.get 2
    i32.const 8
    i32.store align=2 offset=12
    local.get 2
    i32.const 1
    i32.or
    local.set 1
    local.get 1
    end
  )
  (memory (;0;) 64)
  (export "run" (func 0))
  (export "memory" (memory 0))
)
