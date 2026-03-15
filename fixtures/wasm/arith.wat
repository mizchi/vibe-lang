(module
  (type (;0;) (func (param i64 i64 i32) (result i64)))
  (type (;1;) (func (result i64)))
  (func (;0;) (type 0)
    local.get 0
    local.get 1
    i64.add
    end
  )
  (func (;1;) (type 0)
    local.get 0
    local.get 1
    i64.sub
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
  (export "run" (func 2))
  (export "memory" (memory 0))
  (data (i32.const 0) "\0a\00\00\00\00\00\00\00")
)
