(module
  (type (;0;) (func (result i32)))
  (memory (;0;) 1)
  (export "run" (func 0))
  (export "memory" (memory 0))
  (func (;0;) (type 0) (result i32)
    (local i32 i32 i32 i32)
    i32.const 0
    local.set 0
    local.get 0
    local.set 2
    local.get 0
    i32.const 8
    i32.add
    local.set 0
    local.get 2
    i32.const 8
    i32.store
    local.get 2
    f32.const 0x1.8p+0 (;=1.5;)
    f32.store offset=4
    local.get 2
    i32.const 1
    i32.or
    local.set 1
    local.get 1
    local.set 3
    local.get 3
    i32.const 3
    i32.and
    i32.const 1
    i32.eq
    local.get 3
    local.get 3
    i32.const 3
    i32.and
    i32.sub
    i32.load
    i32.const 8
    i32.eq
    i32.and
    local.get 3
    local.get 3
    i32.const 3
    i32.and
    i32.sub
    f32.load offset=4
    f32.const 0x1.8p+0 (;=1.5;)
    f32.eq
    i32.and
    if (result i32) ;; label = @1
      i32.const 4
    else
      local.get 3
      i32.const 3
      i32.and
      i32.const 1
      i32.eq
      local.get 3
      local.get 3
      i32.const 3
      i32.and
      i32.sub
      i32.load
      i32.const 8
      i32.eq
      i32.and
      local.get 3
      local.get 3
      i32.const 3
      i32.and
      i32.sub
      f32.load offset=4
      f32.const 0x1.4p+1 (;=2.5;)
      f32.eq
      i32.and
      if (result i32) ;; label = @2
        i32.const 8
      else
        i32.const 0
      end
    end
  )
)
