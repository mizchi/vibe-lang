(module
  (type (;0;) (func (param i32) (result i64)))
  (type (;1;) (func (result i64)))
  (import "vibe" "path" (func (;0;) (type 0)))
  (func (;1;) (type 1)
    i64.const 13
    i64.const -4
    i64.and
    i32.wrap_i64
    call 0
    end
  )
  (func (;2;) (type 1) (local i64)
    call 1
    local.set 0
    local.get 0
    i64.const 2
    i64.shr_s
    local.get 0
    local.get 0
    i64.const 3
    i64.and
    i64.eqz
    select
    end
  )
  (memory (;0;) 1024)
  (export "_start" (func 2))
  (export "_vibe_run_tagged" (func 1))
  (export "memory" (memory 0))
  (data (i32.const 0) "\0a\00\00\00\00\00\00\00\00\00\00\00\01\00\00\00\06\00\00\00a/../b\00\00")
)
