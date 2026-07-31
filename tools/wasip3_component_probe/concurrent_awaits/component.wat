;; M1b-3c-3 probe: TWO host operations genuinely in flight at the same time.
;;
;; This is the concurrency question the roadmap (#1230) asks about, and it is
;; a DIFFERENT question from M1b-3c-1c's "interleaving spawn":
;;
;;   M1b-3c-1c  two GUEST computations running interleaved. A stackful fiber
;;              runs one call chain, so that needs either a second
;;              Component-Model task or a guest-side poll executor. Open.
;;
;;   this probe  ONE guest computation waiting on MULTIPLE host operations
;;              that are in flight simultaneously. No executor needed -- this
;;              is exactly what a waitable set with several joined subtasks
;;              is for. It is the `Promise.all` / `join!` shape.
;;
;; Structurally it is the spawned_future/ probe with the single call split
;; into "start both, then wait for both": the canon set is UNCHANGED
;; (task.return, [async-lower]get-async, waitable-set.new/.wait/.drop,
;; waitable.join, subtask.drop). Nothing new is imported -- the claim under
;; test is that the ALREADY-PROVEN canon set expresses real concurrency.
;;
;; Two independent assertions, both checkable from outside:
;;
;;   value    `run` returns the SUM of the two results (42 + 42 = 84), so a
;;            component that somehow completed only one call, or read one
;;            result slot twice, cannot pass. Each call gets its own result
;;            slot precisely so this discriminates.
;;
;;   timing   with a host that suspends 300ms per call, concurrent execution
;;            takes ~300ms and serial execution ~600ms. That 2x gap is the
;;            real proof of concurrency; the value check alone would pass
;;            just as well on a serial implementation.
;;
;; Memory layout (the $memhost page, shared by every canon `memory` option --
;; see the stackful/ probe's bug #2 on why identity, not just presence,
;; matters here):
;;    0  result slot for call A   (written by [async-lower]get-async)
;;    4  result slot for call B
;;   16  waitable-set.wait payload: [0] = waitable handle (WHICH subtask
;;       completed -- unused by the single-subtask probes, load-bearing here),
;;       [1] at 20 = that subtask's new status code
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

    ;; $both: start call A, start call B, THEN wait for both.
    ;;
    ;; The ordering is the entire point. Issuing both async-lowered calls
    ;; before waiting on either is what puts them in flight together; a
    ;; "start A, wait A, start B, wait B" shape uses the identical canon
    ;; built-ins and returns the identical value, but takes twice as long.
    (func $both (result i32)
      (local $packed_a i32)
      (local $packed_b i32)
      (local $code_a i32)
      (local $code_b i32)
      (local $sub_a i32)
      (local $sub_b i32)
      (local $ws i32)
      (local $pending i32)
      (local $event0 i32)
      (local $handle i32)
      (local $status i32)
      (local $has_ws i32)

      ;; --- start BOTH, without waiting on either ---------------------------
      (local.set $packed_a (call $get_async (i32.const 0)))
      (local.set $code_a (i32.and (local.get $packed_a) (i32.const 0xf)))
      (local.set $sub_a (i32.shr_u (local.get $packed_a) (i32.const 4)))

      (local.set $packed_b (call $get_async (i32.const 4)))
      (local.set $code_b (i32.and (local.get $packed_b) (i32.const 0xf)))
      (local.set $sub_b (i32.shr_u (local.get $packed_b) (i32.const 4)))

      ;; --- join whichever are still pending into one waitable set ----------
      ;; Either call may have completed eagerly (status RETURNED straight out
      ;; of the call), in which case it created no subtask and there is
      ;; nothing to join or drop -- the same eager path the spawned_future
      ;; probe got wrong until #1230 M1b-3c-2. Count only the ones that
      ;; actually blocked.
      (local.set $pending (i32.const 0))
      (if (i32.ne (local.get $code_a) (i32.const 2))
        (then (local.set $pending (i32.add (local.get $pending) (i32.const 1))))
      )
      (if (i32.ne (local.get $code_b) (i32.const 2))
        (then (local.set $pending (i32.add (local.get $pending) (i32.const 1))))
      )

      (if (i32.gt_u (local.get $pending) (i32.const 0))
        (then
          (local.set $ws (call $ws_new))
          (local.set $has_ws (i32.const 1))
          (if (i32.ne (local.get $code_a) (i32.const 2))
            (then (call $waitable_join (local.get $sub_a) (local.get $ws)))
          )
          (if (i32.ne (local.get $code_b) (i32.const 2))
            (then (call $waitable_join (local.get $sub_b) (local.get $ws)))
          )

          ;; --- one wait loop draining BOTH subtasks -------------------------
          ;; payload[0] (addr 16) says WHICH waitable produced the event, so
          ;; the same loop retires either subtask in whatever order the host
          ;; happens to resolve them.
          (block $all_done
            (loop $retry
              (local.set $event0 (call $ws_wait (local.get $ws) (i32.const 16)))
              (if (i32.eq (local.get $event0) (i32.const 1))
                (then
                  (local.set $handle (i32.load (i32.const 16)))
                  (local.set $status (i32.load (i32.const 20)))
                  (if (i32.eq (local.get $status) (i32.const 2))
                    (then
                      (call $subtask_drop (local.get $handle))
                      (local.set $pending (i32.sub (local.get $pending) (i32.const 1)))
                      (br_if $all_done (i32.eqz (local.get $pending)))
                    )
                  )
                )
              )
              (br $retry)
            )
          )
          (call $ws_drop (local.get $ws))
        )
      )

      ;; --- both results are now in memory; return their sum ----------------
      (i32.add (i32.load (i32.const 0)) (i32.load (i32.const 4)))
    )

    (func (export "run")
      (call $task_return (call $both))
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

  (func (export "run") (type $get-async-type)
    (canon lift (core func $guest-inst "run") async (memory $mem-inst "memory"))
  )
)
