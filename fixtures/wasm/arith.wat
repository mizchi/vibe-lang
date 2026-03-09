(module
  (type (;0;) (func (param i64 i64 i32) (result i64)))
  (type (;1;) (func (result i64)))
  (func (;0;) (type 0) (local i32 i64 i64 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    global.get 0
    local.set 3
    local.get 0
    local.set 4
    local.get 1
    local.set 5
    local.get 4
    i64.const 3
    i64.and
    i32.wrap_i64
    local.set 6
    local.get 5
    i64.const 3
    i64.and
    i32.wrap_i64
    local.set 7
    local.get 6
    i32.const 1
    i32.eq
    local.get 7
    i32.const 1
    i32.eq
    i32.and
    if (result i64)
      local.get 4
      i64.const -4
      i64.and
      i32.wrap_i64
      local.set 8
      local.get 5
      i64.const -4
      i64.and
      i32.wrap_i64
      local.set 9
      local.get 8
      i32.load align=2 offset=0
      local.set 10
      local.get 9
      i32.load align=2 offset=0
      local.set 11
      local.get 10
      i32.const 8
      i32.eq
      local.get 11
      i32.const 8
      i32.eq
      i32.and
      if (result i64)
        local.get 3
        i32.const 8
        i32.add
        local.set 13
        memory.size
        local.set 14
        local.get 13
        i32.const 65535
        i32.add
        i32.const 16
        i32.shr_u
        local.set 15
        local.get 14
        local.get 15
        i32.lt_s
        if
          local.get 15
          local.get 14
          i32.sub
          memory.grow
          drop
        end
        local.get 3
        local.set 12
        local.get 3
        i32.const 8
        i32.add
        local.set 3
        local.get 12
        i32.const 8
        i32.store align=2 offset=0
        local.get 12
        local.get 8
        f32.load align=2 offset=4
        local.get 9
        f32.load align=2 offset=4
        f32.add
        f32.store align=2 offset=4
        local.get 12
        i64.extend_i32_u
        i64.const 1
        i64.or
      else
        local.get 10
        i32.const 9
        i32.eq
        local.get 11
        i32.const 9
        i32.eq
        i32.and
        if (result i64)
          local.get 3
          i32.const 12
          i32.add
          local.set 17
          memory.size
          local.set 18
          local.get 17
          i32.const 65535
          i32.add
          i32.const 16
          i32.shr_u
          local.set 19
          local.get 18
          local.get 19
          i32.lt_s
          if
            local.get 19
            local.get 18
            i32.sub
            memory.grow
            drop
          end
          local.get 3
          local.set 16
          local.get 3
          i32.const 12
          i32.add
          local.set 3
          local.get 16
          i32.const 9
          i32.store align=2 offset=0
          local.get 16
          local.get 8
          f64.load align=3 offset=4
          local.get 9
          f64.load align=3 offset=4
          f64.add
          f64.store align=3 offset=4
          local.get 16
          i64.extend_i32_u
          i64.const 1
          i64.or
        else
          unreachable
        end
      end
    else
      local.get 6
      i32.const 0
      i32.eq
      local.get 7
      i32.const 0
      i32.eq
      i32.and
      if (result i64)
        local.get 4
        local.get 5
        i64.add
      else
        unreachable
      end
    end
    local.get 3
    global.set 0
    end
  )
  (func (;1;) (type 0) (local i32 i64 i64 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    global.get 0
    local.set 3
    local.get 0
    local.set 4
    local.get 1
    local.set 5
    local.get 4
    i64.const 3
    i64.and
    i32.wrap_i64
    local.set 6
    local.get 5
    i64.const 3
    i64.and
    i32.wrap_i64
    local.set 7
    local.get 6
    i32.const 1
    i32.eq
    local.get 7
    i32.const 1
    i32.eq
    i32.and
    if (result i64)
      local.get 4
      i64.const -4
      i64.and
      i32.wrap_i64
      local.set 8
      local.get 5
      i64.const -4
      i64.and
      i32.wrap_i64
      local.set 9
      local.get 8
      i32.load align=2 offset=0
      local.set 10
      local.get 9
      i32.load align=2 offset=0
      local.set 11
      local.get 10
      i32.const 8
      i32.eq
      local.get 11
      i32.const 8
      i32.eq
      i32.and
      if (result i64)
        local.get 3
        i32.const 8
        i32.add
        local.set 13
        memory.size
        local.set 14
        local.get 13
        i32.const 65535
        i32.add
        i32.const 16
        i32.shr_u
        local.set 15
        local.get 14
        local.get 15
        i32.lt_s
        if
          local.get 15
          local.get 14
          i32.sub
          memory.grow
          drop
        end
        local.get 3
        local.set 12
        local.get 3
        i32.const 8
        i32.add
        local.set 3
        local.get 12
        i32.const 8
        i32.store align=2 offset=0
        local.get 12
        local.get 8
        f32.load align=2 offset=4
        local.get 9
        f32.load align=2 offset=4
        f32.sub
        f32.store align=2 offset=4
        local.get 12
        i64.extend_i32_u
        i64.const 1
        i64.or
      else
        local.get 10
        i32.const 9
        i32.eq
        local.get 11
        i32.const 9
        i32.eq
        i32.and
        if (result i64)
          local.get 3
          i32.const 12
          i32.add
          local.set 17
          memory.size
          local.set 18
          local.get 17
          i32.const 65535
          i32.add
          i32.const 16
          i32.shr_u
          local.set 19
          local.get 18
          local.get 19
          i32.lt_s
          if
            local.get 19
            local.get 18
            i32.sub
            memory.grow
            drop
          end
          local.get 3
          local.set 16
          local.get 3
          i32.const 12
          i32.add
          local.set 3
          local.get 16
          i32.const 9
          i32.store align=2 offset=0
          local.get 16
          local.get 8
          f64.load align=3 offset=4
          local.get 9
          f64.load align=3 offset=4
          f64.sub
          f64.store align=3 offset=4
          local.get 16
          i64.extend_i32_u
          i64.const 1
          i64.or
        else
          unreachable
        end
      end
    else
      local.get 6
      i32.const 0
      i32.eq
      local.get 7
      i32.const 0
      i32.eq
      i32.and
      if (result i64)
        local.get 4
        local.get 5
        i64.sub
      else
        unreachable
      end
    end
    local.get 3
    global.set 0
    end
  )
  (func (;2;) (type 1) (local i64)
    i64.const 4
    i64.const 8
    i32.const 0
    call 0
    local.set 0
    local.get 0
    i64.const 4
    i32.const 0
    call 1
    end
  )
  (memory (;0;) 1024)
  (global (;0;) (mut i32) i32.const 0)
  (export "run" (func 2))
  (export "memory" (memory 0))
  (export "__heap_ptr" (unknown 0))
)
