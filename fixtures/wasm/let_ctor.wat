(module
  (type (;0;) (func (result i64)))
  (memory (;0;) 1024)
  (export "_start" (func $_start))
  (export "_vibe_run_tagged" (func $__vibe_run))
  (export "memory" (memory 0))
  (func $__vibe_run (;0;) (type 0) (result i64)
    (local i32 i64 i32 i32 i32 i32 i64 i64)
    i32.const 12
    local.tee 0
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
    if ;; label = @1
      local.get 5
      local.get 4
      i32.sub
      memory.grow
      drop
    end
    local.get 0
    local.tee 2
    i32.const 16
    i32.add
    local.set 0
    local.get 2
    i32.const 10
    i32.store
    local.get 2
    i32.const 1
    i32.store offset=4
    local.get 2
    i32.const 1
    i32.store offset=8
    local.get 2
    i64.const 168
    i32.wrap_i64
    i32.store offset=12
    local.get 2
    i64.extend_i32_u
    i64.const 1
    i64.or
    local.tee 1
    local.tee 6
    i64.const -4
    i64.and
    i32.wrap_i64
    i32.load offset=12
    i64.extend_i32_s
    local.set 7
    i64.const 0
  )
  (func $_start (;1;) (type 0) (result i64)
    (local i64)
    call $__vibe_run
    local.tee 0
    i64.const 2
    i64.shr_s
    local.get 0
    local.get 0
    i64.const 3
    i64.and
    i64.eqz
    select
  )
  (data (;0;) (i32.const 0) "\0a\00\00\00\00\00\00\00\00\00\00\00")
)
