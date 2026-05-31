;;! gc = true
;;! shared_everything_threads = true

(module
  (global $g (ref (shared i31)) (ref.i31_shared (i32.const 77)))
  (global $any (ref null (shared any)) (ref.i31_shared (i32.const 1234)))
  (table $t 1 1 (ref (shared i31)) (ref.i31_shared (i32.const 88)))

  (func (export "new") (param i32) (result (ref (shared i31)))
    local.get 0
    ref.i31_shared)

  (func (export "get_u") (param i32) (result i32)
    local.get 0
    ref.i31_shared
    i31.get_u)

  (func (export "get_s") (param i32) (result i32)
    local.get 0
    ref.i31_shared
    i31.get_s)

  (func (export "get_global") (result i32)
    global.get $g
    i31.get_u)

  (func (export "get_any") (result i32)
    global.get $any
    ref.cast (ref null (shared i31))
    i31.get_u)

  (func (export "get_table") (result i32)
    i32.const 0
    table.get $t
    i31.get_u)
)

(assert_return (invoke "new" (i32.const 1)) (ref.i31_shared))
(assert_return (invoke "get_u" (i32.const 100)) (i32.const 100))
(assert_return (invoke "get_u" (i32.const -1)) (i32.const 2147483647))
(assert_return (invoke "get_s" (i32.const -1)) (i32.const -1))
(assert_return (invoke "get_s" (i32.const 1073741824)) (i32.const -1073741824))
(assert_return (invoke "get_global") (i32.const 77))
(assert_return (invoke "get_any") (i32.const 1234))
(assert_return (invoke "get_table") (i32.const 88))
