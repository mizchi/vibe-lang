(module
  (type (;0;) (func (result i64)))
  (func (;0;) (type 0) (local i32 i32 i32 i32 i32)
    i32.const 8
    local.set 0
    local.get 0
    i32.const 262152
    i32.add
    local.set 2
    memory.size
    local.set 3
    local.get 2
    i32.const 65535
    i32.add
    i32.const 16
    i32.shr_u
    local.set 4
    local.get 3
    local.get 4
    i32.lt_s
    if
      local.get 4
      local.get 3
      i32.sub
      memory.grow
      drop
    end
    local.get 0
    local.set 1
    local.get 0
    i32.const 262152
    i32.add
    local.set 0
    local.get 1
    i32.const 5
    i32.store align=2 offset=0
    local.get 1
    i32.const 2
    i32.store align=2 offset=4
    local.get 1
    i64.const 4
    i32.wrap_i64
    i32.store align=2 offset=8
    local.get 1
    i64.const 8
    i32.wrap_i64
    i32.store align=2 offset=12
    local.get 1
    i64.extend_i32_u
    i64.const 1
    i64.or
    end
  )
  (memory (;0;) 1024)
  (export "_start" (func 0))
  (export "memory" (memory 0))
  (data (i32.const 0) "\0a\00\00\00\00\00\00\00")
)
