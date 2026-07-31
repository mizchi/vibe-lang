;; NEGATIVE CONTROL for component.wat (M1b-3c-1c, #1230).
;;
;; Identical component -- same canon set, same host import, same two logical
;; tasks, same delays, same log encoding -- with ONE difference: task A is
;; awaited to completion BEFORE task B is even started. So nothing overlaps.
;;
;; It exists to show the interleaving probe's assertions actually
;; discriminate. Measured through runtime/viberun:
;;
;;   component.wat        21  in ~615ms   (B logged first; total = A's own
;;                                        2x300ms, so B overlapped)
;;   serial_control.wat   12  in ~714ms   (A logged first; total = 300+300+100)
;;
;; Both the value AND the wall-clock separate the two. A gate asserting only
;; "returns 21" would still be meaningful, but a gate asserting only "both
;; tasks completed" would pass on this file too.
(component
  (type $get-after-type (func async (param "ms" u32) (result u32)))
  (type $run-type (func async (result u32)))
  (import "get-after" (func $host-get-after (type $get-after-type)))

  (core module $guest
    (import "$root" "[async-lower]get-after" (func $get_after (param i32 i32) (result i32)))
    (import "$root" "[waitable-set-new]" (func $ws_new (result i32)))
    (import "$root" "[waitable-join]" (func $waitable_join (param i32 i32)))
    (import "$root" "[waitable-set-wait]" (func $ws_wait (param i32 i32) (result i32)))
    (import "$root" "[waitable-set-drop]" (func $ws_drop (param i32)))
    (import "$root" "[subtask-drop]" (func $subtask_drop (param i32)))
    (import "[export]$root" "[task-return]run" (func $task_return (param i32)))
    (import "env" "memory" (memory 1))

    (func $sched (result i32)
      (local $packed i32)
      (local $sub i32)
      (local $ws i32)
      (local $event0 i32)
      (local $logn i32)
      (local.set $ws (call $ws_new))
      (local.set $logn (i32.const 0))
      ;; A await 1
      (local.set $packed (call $get_after (i32.const 300) (i32.const 0)))
      (local.set $sub (i32.shr_u (local.get $packed) (i32.const 4)))
      (call $waitable_join (local.get $sub) (local.get $ws))
      (block $d1 (loop $r1
        (local.set $event0 (call $ws_wait (local.get $ws) (i32.const 16)))
        (br_if $d1 (i32.and (i32.eq (local.get $event0) (i32.const 1))
                            (i32.eq (i32.load (i32.const 20)) (i32.const 2))))
        (br $r1)))
      (call $subtask_drop (local.get $sub))
      ;; A await 2
      (local.set $packed (call $get_after (i32.const 300) (i32.const 0)))
      (local.set $sub (i32.shr_u (local.get $packed) (i32.const 4)))
      (call $waitable_join (local.get $sub) (local.get $ws))
      (block $d2 (loop $r2
        (local.set $event0 (call $ws_wait (local.get $ws) (i32.const 16)))
        (br_if $d2 (i32.and (i32.eq (local.get $event0) (i32.const 1))
                            (i32.eq (i32.load (i32.const 20)) (i32.const 2))))
        (br $r2)))
      (call $subtask_drop (local.get $sub))
      (i32.store (i32.const 32) (i32.const 1))
      ;; B, only now
      (local.set $packed (call $get_after (i32.const 100) (i32.const 4)))
      (local.set $sub (i32.shr_u (local.get $packed) (i32.const 4)))
      (call $waitable_join (local.get $sub) (local.get $ws))
      (block $d3 (loop $r3
        (local.set $event0 (call $ws_wait (local.get $ws) (i32.const 16)))
        (br_if $d3 (i32.and (i32.eq (local.get $event0) (i32.const 1))
                            (i32.eq (i32.load (i32.const 20)) (i32.const 2))))
        (br $r3)))
      (call $subtask_drop (local.get $sub))
      (i32.store (i32.const 36) (i32.const 2))
      (call $ws_drop (local.get $ws))
      (i32.add (i32.mul (i32.load (i32.const 32)) (i32.const 10))
               (i32.load (i32.const 36)))
    )

    (func (export "run")
      (call $task_return (call $sched))
    )
  )

  (core module $memhost
    (memory (export "memory") 1)
  )
  (core instance $mem-inst (instantiate $memhost))

  (core func $core-get-after (canon lower (func $host-get-after) async (memory $mem-inst "memory")))
  (core func $core-task-return (canon task.return (result u32)))
  (core func $core-ws-new (canon waitable-set.new))
  (core func $core-waitable-join (canon waitable.join))
  (core func $core-ws-wait (canon waitable-set.wait (memory $mem-inst "memory")))
  (core func $core-ws-drop (canon waitable-set.drop))
  (core func $core-subtask-drop (canon subtask.drop))

  (core instance $guest-inst (instantiate $guest
    (with "$root" (instance
      (export "[async-lower]get-after" (func $core-get-after))
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

  (func (export "run") (type $run-type)
    (canon lift (core func $guest-inst "run") async (memory $mem-inst "memory"))
  )
)
