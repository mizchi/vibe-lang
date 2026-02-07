(module
  (type (;0;) (func (result i32)))
  (memory (;0;) 1)
  (export "run" (func 0))
  (export "memory" (memory 0))
  (func (;0;) (type 0) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32)
    i32.const 24
    local.set 0
    local.get 0
    local.set 2
    local.get 0
    i32.const 24
    i32.add
    local.set 0
    local.get 2
    i32.const 4
    i32.store
    local.get 2
    i32.const 2
    i32.store offset=4
    local.get 2
    i32.const 0
    i32.store offset=8
    local.get 2
    i32.const 40
    i32.store offset=12
    local.get 2
    i32.const 12
    i32.store offset=16
    local.get 2
    i32.const 80
    i32.store offset=20
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
    i32.const 4
    i32.eq
    i32.and
    local.get 4
    i32.load offset=4
    i32.const 2
    i32.eq
    i32.and
    if (result i32) ;; label = @1
      local.get 4
      i32.load offset=8
      i32.const 0
      i32.eq
      if (result i32) ;; label = @2
        local.get 4
        i32.load offset=12
        local.set 5
        local.get 5
        local.set 6
        local.get 4
        i32.load offset=16
        i32.const 12
        i32.eq
        if (result i32) ;; label = @3
          local.get 4
          i32.load offset=20
          local.set 7
          local.get 7
          local.set 8
          local.get 6
          local.get 8
          i32.add
        else
          i32.const 0
        end
      else
        i32.const 0
      end
    else
      i32.const 0
    end
  )
  (data (;0;) (i32.const 0) "\01\00\00\00\01\00\00\00x")
  (data (;1;) (i32.const 12) "\01\00\00\00\01\00\00\00y")
)
