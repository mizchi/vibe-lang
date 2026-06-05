;;! threads = true
;;! component_model_async = true
;;! component_model_threading = true
;;! gc = true
;;! function_references = true
;;! shared_everything_threads = true

;; Fork-local Vibe runtime ABI serial speedup baseline.
;;
;; This uses the same slot ABI as the parallel trampoline probe but executes the
;; CPU work sequentially in the parent component thread. It is the baseline for
;; the ABI-shaped OS-thread speedup probe.

(component
  (core module $libc
    (memory (export "mem") 1 1 shared)
    (table (export "__indirect_function_table") shared 1 1 (ref null (shared func))))

  (core module $m
    (type $start-func-ty (shared (func (param i32))))
    (type $spawn-indirect-ty (shared (func (param i32 i32) (result i32))))
    (type $slot-addr-ty (func (param i32 i32) (result i32)))
    (type $finish-ty (func (param i32 i32 i32)))
    (type $work-ty (func (param i32) (result i32)))
    (type $sum-payloads-ty (func (result i32)))
    (type $run-ty (func (result i32)))
    (import "" "thread.spawn-indirect"
      (func $thread-spawn-indirect (type $spawn-indirect-ty)))
    (import "libc" "mem" (memory $mem 1 1 shared))
    (import "libc" "__indirect_function_table"
      (table $indirect-function-table shared 1 1 (ref null (shared func))))

    ;; Slot layout:
    ;;   +0: state, 0 = empty, 1 = running, 2 = terminal
    ;;   +4: terminal code, 0 = completed, 1 = cancelled, 2 = failed
    ;;   +8: payload
    ;;  +12: input
    ;;  +16: cancel request flag
    ;;  +20: mode

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
        (i32.const 2)))

    (func $work (type $work-ty)
      (local $i i32)
      (local $x i32)
      (local.set $x (i32.add (local.get 0) (i32.const 1)))
      (loop $again
        (local.set $x
          (i32.add
            (i32.mul
              (local.get $x)
              (i32.const 1664525))
            (i32.const 1013904223)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br_if $again (i32.lt_u (local.get $i) (i32.const 50000000))))
      (local.get $x))

    (func $thread-start (type $start-func-ty)
      unreachable)
    (export "thread-start" (func $thread-start))

    (elem (table $indirect-function-table) (i32.const 0)
      (ref null (shared func)) (ref.func $thread-start))

    (func $init-slot (param $slot i32) (param $input i32)
      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const 0)) (i32.const 0))
      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const 4)) (i32.const 0))
      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const 8)) (i32.const 0))
      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const 12)) (local.get $input))
      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const 16)) (i32.const 0))
      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const 20)) (i32.const 0)))

    (func $sum-payloads (type $sum-payloads-ty)
      (i32.add
        (i32.add
          (i32.atomic.load (i32.const 8))
          (i32.atomic.load (i32.const 40)))
        (i32.add
          (i32.atomic.load (i32.const 72))
          (i32.atomic.load (i32.const 104)))))

    (func (export "serial") (type $run-ty)
      (call $init-slot (i32.const 0) (i32.const 0))
      (call $init-slot (i32.const 32) (i32.const 1))
      (call $init-slot (i32.const 64) (i32.const 2))
      (call $init-slot (i32.const 96) (i32.const 3))

      (call $finish (i32.const 0) (i32.const 0) (call $work (i32.const 0)))
      (call $finish (i32.const 32) (i32.const 0) (call $work (i32.const 1)))
      (call $finish (i32.const 64) (i32.const 0) (call $work (i32.const 2)))
      (call $finish (i32.const 96) (i32.const 0) (call $work (i32.const 3)))
      (call $sum-payloads)))

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

  (func (export "serial") async (result u32) (canon lift (core func $i "serial"))))

(assert_return (invoke "serial") (u32.const 1106140682))
