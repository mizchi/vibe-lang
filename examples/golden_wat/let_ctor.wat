(module
  (type (;0;) (func (result i64)))
  (memory (;0;) 64)
  (export "run" (func 0))
  (export "memory" (memory 0))
  (func (;0;) (type 0) (result i64)
    (local i32 i64 i32 i32 i32 i32 i64 i64)
    i32.const 0
    local.tee 0
    i32.const 12
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
    if ;; label = @1
      local.get 5
      local.get 4
      i32.sub
      memory.grow
      drop
    end
    local.get 0
    local.tee 2
    i32.const 12
    i32.add
    local.set 0
    local.get 2
    i32.const 10
    i32.store
    local.get 2
    i32.const 1
    i32.store offset=4
    local.get 2
    i64.const 168
    i32.wrap_i64
    i32.store offset=8
    local.get 2
    i64.extend_i32_u
    i64.const 1
    i64.or
    local.tee 1
    local.tee 6
    i64.const -4
    i64.and
    i32.wrap_i64
    i32.load offset=8
    i64.extend_i32_s
    local.tee 7
  )
)
