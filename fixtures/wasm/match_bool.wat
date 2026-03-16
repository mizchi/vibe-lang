(module
  (type (;0;) (func (result i64)))
  (func (;0;) (type 0) (local i64)
    i64.const 7
    local.set 0
    local.get 0
    i64.const 7
    i64.eq
    if (result i64)
      i64.const 4
    else
      i64.const 0
    end
    end
  )
  (memory (;0;) 1024)
  (export "_start" (func 0))
  (export "memory" (memory 0))
  (data (i32.const 0) "\0a\00\00\00\00\00\00\00")
)
