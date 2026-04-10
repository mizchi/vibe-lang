(module
  (type (;0;) (func (result i64)))
  (memory (;0;) 1024)
  (export "_start" (func 1))
  (export "_vibe_run_tagged" (func 0))
  (export "memory" (memory 0))
  (func (;0;) (type 0) (result i64)
    i64.const 0
  )
  (func (;1;) (type 0) (result i64)
    (local i64)
    i64.const 0
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
