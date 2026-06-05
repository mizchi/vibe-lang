;; Minimal Component Model threading probe for Wasmtime's current builtins.
;;! component_model_async = true
;;! component_model_threading = true

(component
  (core module $libc
    (table (export "__indirect_function_table") 1 funcref))

  (core module $m
    (import "" "thread.new-indirect" (func $thread-new-indirect (param i32 i32) (result i32)))
    (import "" "thread.suspend-to-suspended" (func $thread-suspend-to-suspended (param i32) (result i32)))
    (import "" "thread.yield" (func $thread-yield (result i32)))
    (import "" "thread.unsuspend" (func $thread-unsuspend (param i32)))
    (import "" "thread.index" (func $thread-index (result i32)))
    (import "libc" "__indirect_function_table" (table $indirect-function-table 1 funcref))

    (global $g (mut i32) (i32.const 0))
    (global $main-thread-index (mut i32) (i32.const 0))

    (func $thread-start (param i32)
      (global.set $g (local.get 0))
      (call $thread-unsuspend (global.get $main-thread-index))
      (drop (call $thread-yield)))
    (export "thread-start" (func $thread-start))

    (elem (table $indirect-function-table) (i32.const 0) func $thread-start)

    (func (export "run") (result i32)
      (global.set $main-thread-index (call $thread-index))
      (drop
        (call $thread-suspend-to-suspended
          (call $thread-new-indirect (i32.const 0) (i32.const 7))))
      (global.get $g)))

  (core instance $libc (instantiate $libc))
  (core type $start-func-ty (func (param i32)))
  (alias core export $libc "__indirect_function_table" (core table $indirect-function-table))

  (core func $thread-new-indirect
    (canon thread.new-indirect $start-func-ty (table $indirect-function-table)))
  (core func $thread-suspend-to-suspended (canon thread.suspend-to-suspended))
  (core func $thread-yield (canon thread.yield))
  (core func $thread-unsuspend (canon thread.unsuspend))
  (core func $thread-index (canon thread.index))

  (core instance $i
    (instantiate $m
      (with "" (instance
        (export "thread.new-indirect" (func $thread-new-indirect))
        (export "thread.suspend-to-suspended" (func $thread-suspend-to-suspended))
        (export "thread.yield" (func $thread-yield))
        (export "thread.unsuspend" (func $thread-unsuspend))
        (export "thread.index" (func $thread-index))))
      (with "libc" (instance $libc))))

  (func (export "run") async (result u32) (canon lift (core func $i "run"))))

(assert_return (invoke "run") (u32.const 7))
