(module
  (type (;0;) (func (result i32)))
  (memory (;0;) 1)
  (export "run" (func 0))
  (export "memory" (memory 0))
  (func (;0;) (type 0) (result i32)
    (local i32 i32)
    i32.const 8
    local.set 0
    local.get 0
    local.set 1
    local.get 1
    i32.const 4
    i32.eq
    if (result i32) ;; label = @1
      i32.const 400
    else
      local.get 1
      i32.const 8
      i32.eq
      if (result i32) ;; label = @2
        i32.const 400
      else
        local.get 1
        i32.const 12
        i32.eq
        if (result i32) ;; label = @3
          i32.const 400
        else
          i32.const 0
        end
      end
    end
  )
)
