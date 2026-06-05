;;! threads = true
;;! component_model_async = true
;;! component_model_threading = true
;;! gc = true
;;! function_references = true
;;! shared_everything_threads = true

;; ComponentModelUnsafeOsThreads trampoline status probe.
;;
;; The canonical `thread.spawn-indirect` return value is a transient component
;; thread-table index, not a Vibe join handle. This probe intentionally drops
;; every spawn return value and models Vibe-level completion/status with
;; trampoline-owned shared memory plus wait/notify.

(component
  (core module $libc
    (memory (export "mem") 1 1 shared)
    (table (export "__indirect_function_table") shared 1 1 (ref null (shared func))))

  (core module $m
    (type $start-func-ty (shared (func (param i32))))
    (type $spawn-indirect-ty (shared (func (param i32 i32) (result i32))))
    (type $slot-addr-ty (shared (func (param i32 i32) (result i32))))
    (type $finish-ty (shared (func (param i32 i32 i32))))
    (type $wait-completed-ty (func (param i32) (result i32)))
    (type $run-ty (func (result i32)))
    (import "" "thread.spawn-indirect"
      (func $thread-spawn-indirect (type $spawn-indirect-ty)))
    (import "libc" "mem" (memory $mem 1 1 shared))
    (import "libc" "__indirect_function_table"
      (table $indirect-function-table shared 1 1 (ref null (shared func))))

    ;; Slot layout, addressed by the context argument:
    ;;   +0: state, 0 = empty, 1 = running, 2 = completed
    ;;   +4: terminal code, 0 = completed, 1 = cancelled, 2 = failed
    ;;   +8: result payload for completed
    ;;  +12: input
    ;;  +16: cancel request flag

    (func $slot-addr (type $slot-addr-ty)
      (i32.add (local.get 0) (local.get 1)))

    (func $finish (type $finish-ty)
      (i32.atomic.store
        (call $slot-addr (local.get 0) (i32.const 4))
        (local.get 1))
      (i32.atomic.store
        (call $slot-addr (local.get 0) (i32.const 8))
        (local.get 2))
      (i32.atomic.store
        (call $slot-addr (local.get 0) (i32.const 0))
        (i32.const 2))
      (drop (memory.atomic.notify
        (call $slot-addr (local.get 0) (i32.const 0))
        (i32.const 1))))

    (func $thread-trampoline (type $start-func-ty)
      (local $input i32)
      (i32.atomic.store
        (call $slot-addr (local.get 0) (i32.const 0))
        (i32.const 1))

      (if
        (i32.ne
          (i32.atomic.load (call $slot-addr (local.get 0) (i32.const 16)))
          (i32.const 0))
        (then
          (call $finish (local.get 0) (i32.const 1) (i32.const 0))
          (return)))

      (local.set $input
        (i32.atomic.load (call $slot-addr (local.get 0) (i32.const 12))))

      ;; Model a Vibe runtime error as a value. A real Wasm trap is not caught
      ;; here; traps still abort through the host/runtime path.
      (if (i32.eq (local.get $input) (i32.const 13))
        (then
          (call $finish (local.get 0) (i32.const 2) (i32.const 0))
          (return)))

      (call $finish
        (local.get 0)
        (i32.const 0)
        (i32.add
          (i32.mul (local.get $input) (local.get $input))
          (i32.const 7))))
    (export "thread-trampoline" (func $thread-trampoline))

    (elem (table $indirect-function-table) (i32.const 0)
      (ref null (shared func)) (ref.func $thread-trampoline))

    (func $wait-completed (type $wait-completed-ty)
      (local $state i32)
      (local $attempts i32)
      (loop $again
        (local.set $state
          (i32.atomic.load (call $slot-addr (local.get 0) (i32.const 0))))
        (if (i32.eq (local.get $state) (i32.const 2))
          (then
            (return (i32.const 1))))
        (if (i32.ge_u (local.get $attempts) (i32.const 200))
          (then
            (return (i32.const 0))))
        (drop (memory.atomic.wait32
          (call $slot-addr (local.get 0) (i32.const 0))
          (local.get $state)
          (i64.const 1000000)))
        (local.set $attempts (i32.add (local.get $attempts) (i32.const 1)))
        (br $again))
      (i32.const 0))

    (func (export "run") (type $run-ty)
      ;; slot 0: completed, input 11, result 128
      (i32.atomic.store (i32.const 0) (i32.const 0))
      (i32.atomic.store (i32.const 4) (i32.const 0))
      (i32.atomic.store (i32.const 8) (i32.const 0))
      (i32.atomic.store (i32.const 12) (i32.const 11))
      (i32.atomic.store (i32.const 16) (i32.const 0))

      ;; slot 1: failed-as-value, input 13
      (i32.atomic.store (i32.const 32) (i32.const 0))
      (i32.atomic.store (i32.const 36) (i32.const 0))
      (i32.atomic.store (i32.const 40) (i32.const 0))
      (i32.atomic.store (i32.const 44) (i32.const 13))
      (i32.atomic.store (i32.const 48) (i32.const 0))

      ;; slot 2: cooperatively cancelled before start
      (i32.atomic.store (i32.const 64) (i32.const 0))
      (i32.atomic.store (i32.const 68) (i32.const 0))
      (i32.atomic.store (i32.const 72) (i32.const 0))
      (i32.atomic.store (i32.const 76) (i32.const 17))
      (i32.atomic.store (i32.const 80) (i32.const 1))

      ;; The canonical spawn return values are intentionally ignored.
      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const 0)))
      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const 32)))
      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const 64)))

      (if (i32.eqz (call $wait-completed (i32.const 0)))
        (then
          (return (i32.const 0))))
      (if (i32.eqz (call $wait-completed (i32.const 32)))
        (then
          (return (i32.const 0))))
      (if (i32.eqz (call $wait-completed (i32.const 64)))
        (then
          (return (i32.const 0))))

      (i32.and
        (i32.and
          (i32.and
            (i32.eq (i32.atomic.load (i32.const 4)) (i32.const 0))
            (i32.eq (i32.atomic.load (i32.const 8)) (i32.const 128)))
          (i32.eq (i32.atomic.load (i32.const 36)) (i32.const 2)))
        (i32.eq (i32.atomic.load (i32.const 68)) (i32.const 1)))))

  (core instance $libc (instantiate $libc))
  (core type $start-func-ty (shared (func (param i32))))
  (alias core export $libc "mem" (core memory $mem))
  (alias core export $libc "__indirect_function_table" (core table $indirect-function-table))

  (core func $thread-spawn-indirect
    (canon thread.spawn-indirect $start-func-ty (table $indirect-function-table)))

  (core instance $i
    (instantiate $m
      (with "" (instance
        (export "thread.spawn-indirect" (func $thread-spawn-indirect))))
      (with "libc" (instance
        (export "mem" (memory $mem))
        (export "__indirect_function_table" (table $indirect-function-table))))))

  (func (export "run") async (result u32) (canon lift (core func $i "run"))))

(assert_return (invoke "run") (u32.const 1))
