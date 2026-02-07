(module
  (type (;0;) (func (result i32)))
  (memory (;0;) 1)
  (export "run" (func 0))
  (export "memory" (memory 0))
  (func (;0;) (type 0) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32)
    i32.const 0
    local.set 0
    local.get 0
    local.set 2
    local.get 0
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
    i32.const 40
    i32.store offset=8
    local.get 2
    i32.const 1
    i32.or
    local.set 1
    local.get 1
    local.set 3
    local.get 3
    local.get 3
    i32.const 3
    i32.and
    i32.sub
    local.set 4
    local.get 3
    i32.const 3
    i32.and
    i32.const 1
    i32.eq
    local.get 4
    i32.load
    i32.const 10
    i32.eq
    i32.and
    local.get 4
    i32.load offset=4
    i32.const 1
    i32.eq
    i32.and
    if (result i32) ;; label = @1
      local.get 4
      i32.load offset=8
      local.set 5
      local.get 5
      local.set 6
      local.get 6
    else
      i32.const 0
    end
  )
)
