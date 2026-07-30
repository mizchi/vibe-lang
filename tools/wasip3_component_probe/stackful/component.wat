(component
  (type $get-async-type (func async (result u32)))
  (import "get-async" (func $host-get-async (type $get-async-type)))

  (core module $guest
    (import "$root" "[async-lower]get-async" (func $get_async (param i32) (result i32)))
    (import "$root" "[waitable-set-new]" (func $ws_new (result i32)))
    (import "$root" "[waitable-join]" (func $waitable_join (param i32 i32)))
    (import "$root" "[waitable-set-wait]" (func $ws_wait (param i32 i32) (result i32)))
    (import "$root" "[waitable-set-drop]" (func $ws_drop (param i32)))
    (import "$root" "[subtask-drop]" (func $subtask_drop (param i32)))
    (import "[export]$root" "[task-return]run" (func $task_return (param i32)))
    (import "env" "memory" (memory 1))

    (func (export "run")
      (local $packed i32)
      (local $code i32)
      (local $subtask i32)
      (local $ws i32)
      (local $event0 i32)

      (local.set $packed (call $get_async (i32.const 0)))
      (local.set $code (i32.and (local.get $packed) (i32.const 0xf)))
      (local.set $subtask (i32.shr_u (local.get $packed) (i32.const 4)))

      (block $done
        (br_if $done (i32.eq (local.get $code) (i32.const 2)))

        (local.set $ws (call $ws_new))
        (call $waitable_join (local.get $subtask) (local.get $ws))

        (loop $retry
          (local.set $event0 (call $ws_wait (local.get $ws) (i32.const 8)))
          ;; event0 == 1 (EVENT_SUBTASK): payload[1] (addr 12) is this
          ;; subtask's new status code. Any other event0 is not ours to
          ;; interpret -- loop and wait again without touching $code.
          (if (i32.eq (local.get $event0) (i32.const 1))
            (then
              (local.set $code (i32.load (i32.const 12)))
              (br_if $done (i32.eq (local.get $code) (i32.const 2)))
            )
          )
          (br $retry)
        )
      )

      (call $subtask_drop (local.get $subtask))
      (call $task_return (i32.load (i32.const 0)))
    )
  )

  (core module $memhost
    (memory (export "memory") 1)
  )
  (core instance $mem-inst (instantiate $memhost))

  (core func $core-get-async (canon lower (func $host-get-async) async (memory $mem-inst "memory")))
  (core func $core-task-return (canon task.return (result u32)))
  (core func $core-ws-new (canon waitable-set.new))
  (core func $core-waitable-join (canon waitable.join))
  (core func $core-ws-wait (canon waitable-set.wait (memory $mem-inst "memory")))
  (core func $core-ws-drop (canon waitable-set.drop))
  (core func $core-subtask-drop (canon subtask.drop))

  (core instance $guest-inst (instantiate $guest
    (with "$root" (instance
      (export "[async-lower]get-async" (func $core-get-async))
      (export "[waitable-set-new]" (func $core-ws-new))
      (export "[waitable-join]" (func $core-waitable-join))
      (export "[waitable-set-wait]" (func $core-ws-wait))
      (export "[waitable-set-drop]" (func $core-ws-drop))
      (export "[subtask-drop]" (func $core-subtask-drop))
    ))
    (with "[export]$root" (instance
      (export "[task-return]run" (func $core-task-return))
    ))
    (with "env" (instance
      (export "memory" (memory $mem-inst "memory"))
    ))
  ))

  (type $run-type (func async (result u32)))
  (func $run (type $run-type) (canon lift (core func $guest-inst "run") async))

  (export "run" (func $run))
)
