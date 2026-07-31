;; M1b-3c-1c probe: does a SECOND GUEST COMPUTATION interleave with the
;; first's await points, on one stackful fiber?
;;
;; §3.8 left this open and Phase A's evidence pointed the wrong way
;; (wit_bindgen's spawn_local drags in a FuturesUnordered executor plus
;; context.get/set and waitable-set.poll). This probe tests the narrower,
;; concrete question the codegen actually has to answer:
;;
;;   Can the guest dispatch continuations BY COMPLETION ORDER, so that a
;;   second task's code runs in the MIDDLE of the first task's sequence of
;;   awaits -- with no second stack, no context.get/set, and no poll loop?
;;
;; The design makes interleaving impossible to fake:
;;
;;   task A   await get-after(300)  ->  await get-after(300)  ->  log 1
;;   task B   await get-after(100)  ->  log 2
;;
;; Both are started before either is waited on. B resolves at ~100ms, i.e.
;; strictly BETWEEN A's first await (~300ms) and its second (~600ms). So:
;;
;;   log = [2, 1]  ->  returns 21.  B's continuation ran while A was still
;;                     mid-sequence. That is interleaving.
;;   log = [1, 2]  ->  returns 12.  A ran to completion first: serial.
;;
;; and total elapsed must be ~600ms (A's two awaits), not ~700ms (A's two
;; plus B's one), confirming B overlapped rather than followed.
;;
;; A's state across its two awaits lives in a memory slot ($A_STATE), not on
;; a stack -- a hand-rolled state machine, which is exactly the shape a
;; CPS/suspend lowering (ADR-0076) generates. That is the point: it shows
;; the ABI side needs nothing new, and localizes the remaining work to the
;; guest-side state representation.
;;
;; Canon set: UNCHANGED from M1b-3c-1b/3c-3. In particular NO
;; waitable-set.poll and NO context.get/set -- `waitable-set.wait` already
;; reports WHICH waitable fired (payload[0]), which is all a completion-order
;; dispatcher needs.
;;
;; Memory layout (the shared memhost page):
;;    0  result slot, task A       32  log[0]
;;    4  result slot, task B       36  log[1]
;;   16  wait payload[0] = handle  40  A's state: 0 = first await pending,
;;   20  wait payload[1] = status         1 = second await pending
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
      (local $code i32)
      (local $sub_a i32)
      (local $sub_b i32)
      (local $ws i32)
      (local $pending i32)
      (local $event0 i32)
      (local $handle i32)
      (local $status i32)
      (local $logn i32)

      (local.set $ws (call $ws_new))
      (i32.store (i32.const 40) (i32.const 0))   ;; A: first await pending
      (local.set $logn (i32.const 0))

      ;; --- start A's FIRST await (300ms), results -> addr 0 ----------------
      (local.set $packed (call $get_after (i32.const 300) (i32.const 0)))
      (local.set $code (i32.and (local.get $packed) (i32.const 0xf)))
      (local.set $sub_a (i32.shr_u (local.get $packed) (i32.const 4)))
      (if (i32.eq (local.get $code) (i32.const 2))
        (then unreachable)   ;; a 300ms call must not complete eagerly
      )
      (call $waitable_join (local.get $sub_a) (local.get $ws))

      ;; --- start B (100ms), results -> addr 4 ------------------------------
      ;; Issued BEFORE waiting on A. This is what lets B resolve first.
      (local.set $packed (call $get_after (i32.const 100) (i32.const 4)))
      (local.set $code (i32.and (local.get $packed) (i32.const 0xf)))
      (local.set $sub_b (i32.shr_u (local.get $packed) (i32.const 4)))
      (if (i32.eq (local.get $code) (i32.const 2))
        (then unreachable)
      )
      (call $waitable_join (local.get $sub_b) (local.get $ws))

      (local.set $pending (i32.const 2))   ;; two logical TASKS outstanding

      ;; --- completion-order dispatch loop ----------------------------------
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
                  (if (i32.eq (local.get $handle) (local.get $sub_b))
                    (then
                      ;; ---- task B's continuation ----
                      (i32.store (i32.add (i32.const 32)
                                          (i32.mul (local.get $logn) (i32.const 4)))
                                 (i32.const 2))
                      (local.set $logn (i32.add (local.get $logn) (i32.const 1)))
                      (local.set $pending (i32.sub (local.get $pending) (i32.const 1)))
                    )
                    (else
                      ;; ---- task A's continuation ----
                      (if (i32.eqz (i32.load (i32.const 40)))
                        (then
                          ;; A was at its FIRST await: advance the state
                          ;; machine and issue the SECOND one. A stays
                          ;; outstanding -- $pending is untouched.
                          (i32.store (i32.const 40) (i32.const 1))
                          (local.set $packed
                            (call $get_after (i32.const 300) (i32.const 0)))
                          (local.set $sub_a
                            (i32.shr_u (local.get $packed) (i32.const 4)))
                          (if (i32.eq (i32.and (local.get $packed) (i32.const 0xf))
                                      (i32.const 2))
                            (then unreachable)
                          )
                          ;; join into the SAME set, mid-loop
                          (call $waitable_join (local.get $sub_a) (local.get $ws))
                        )
                        (else
                          ;; A was at its SECOND await: A is done
                          (i32.store (i32.add (i32.const 32)
                                              (i32.mul (local.get $logn) (i32.const 4)))
                                     (i32.const 1))
                          (local.set $logn (i32.add (local.get $logn) (i32.const 1)))
                          (local.set $pending
                            (i32.sub (local.get $pending) (i32.const 1)))
                        )
                      )
                    )
                  )
                  (br_if $all_done (i32.eqz (local.get $pending)))
                )
              )
            )
          )
          (br $retry)
        )
      )
      (call $ws_drop (local.get $ws))

      ;; log[0]*10 + log[1]: 21 = B then A (interleaved), 12 = A then B.
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
