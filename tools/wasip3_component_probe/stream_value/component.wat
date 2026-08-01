;; ADR-0089 step 2 probe: SELF-CONTAINED stream<u8> round-trip using the
;; literal `stream.*` canonical built-ins -- the companion to
;; ../future_value/component.wat, applying the same discovery to streams:
;; the M2c-3 spike's "self round-trip deadlocks" wall
;; (docs/spec/wasi-p3-async.md §3.3) only applies to BLOCKING copies. With
;; the `async` canonopt on both sides, the first copy parks as a waitable
;; instead of parking the fiber, so a single task can rendezvous with
;; itself -- no host producer needed.
;;
;; Shape (single task, no host import, no subtask):
;;   1. stream.new            -> packed i64 (readable low 32, writable high)
;;   2. stream.read  (async)  1 element into buf 0 -> BLOCKED (no writer)
;;   3. waitable.join(readable, ws)
;;   4. stream.write (async)  1 element (the byte 42) from buf 4 ->
;;      completes EAGERLY against the pending read
;;   5. waitable-set.wait     -> STREAM_READ event (code 2) on the readable
;;   6. load the byte from buf 0, drop both ends + the set, task.return
;;
;; Unlike futures, stream.read/write take an element COUNT (core sig
;; (handle, ptr, n) -> status) and the completion status packs
;; (amount << 4) | code; this probe moves exactly 1 element so the packed
;; forms stay in the low bits.
;;
;; Diagnostic return values (anything but 42 is a failure that names the
;; broken assumption):
;;   1000 + code   stream.read did NOT block; code = its low result bits
;;   2015          stream.write came back BLOCKED instead of completing
;;   3000 + ev     wait returned an unexpected event code ev
;;                 (expect ev=2 STREAM_READ)
(component
  (core module $guest
    (import "$root" "[stream-new-0]pipe" (func $snew (result i64)))
    (import "$root" "[async-lower][stream-read-0]pipe" (func $sread (param i32 i32 i32) (result i32)))
    (import "$root" "[async-lower][stream-write-0]pipe" (func $swrite (param i32 i32 i32) (result i32)))
    (import "$root" "[stream-drop-readable-0]pipe" (func $sdrop_r (param i32)))
    (import "$root" "[stream-drop-writable-0]pipe" (func $sdrop_w (param i32)))
    (import "$root" "[waitable-set-new]" (func $ws_new (result i32)))
    (import "$root" "[waitable-join]" (func $waitable_join (param i32 i32)))
    (import "$root" "[waitable-set-wait]" (func $ws_wait (param i32 i32) (result i32)))
    (import "$root" "[waitable-set-drop]" (func $ws_drop (param i32)))
    (import "[export]$root" "[task-return]run" (func $task_return (param i32)))
    (import "env" "memory" (memory 1))

    ;; Memory layout (shared memhost page):
    ;;    0  read buffer (1-byte landing slot)
    ;;    4  write buffer (pre-loaded with the byte 42)
    ;;   16  waitable-set.wait payload area
    (func (export "run")
      (local $packed i64)
      (local $readable i32)
      (local $writable i32)
      (local $st i32)
      (local $ws i32)
      (local $ev i32)

      (local.set $packed (call $snew))
      (local.set $readable (i32.wrap_i64 (local.get $packed)))
      (local.set $writable (i32.wrap_i64 (i64.shr_u (local.get $packed) (i64.const 32))))

      ;; stage the byte to send
      (i32.store8 (i32.const 4) (i32.const 42))

      ;; 1) read 1 element first: no writer yet -> BLOCKED
      (local.set $st (call $sread (local.get $readable) (i32.const 0) (i32.const 1)))
      (if (i32.ne (local.get $st) (i32.const 0xffffffff))
        (then
          (call $task_return
            (i32.add (i32.const 1000) (i32.and (local.get $st) (i32.const 0xf))))
          (return)
        )
      )

      ;; 2) register the pending read's waitable before writing
      (local.set $ws (call $ws_new))
      (call $waitable_join (local.get $readable) (local.get $ws))

      ;; 3) write 1 element: a read is pending, so the copy happens now
      (local.set $st (call $swrite (local.get $writable) (i32.const 4) (i32.const 1)))
      (if (i32.eq (local.get $st) (i32.const 0xffffffff))
        (then
          (call $task_return (i32.const 2015))
          (return)
        )
      )

      ;; 4) collect the pending read's completion event (STREAM_READ = 2)
      (local.set $ev (call $ws_wait (local.get $ws) (i32.const 16)))
      (if (i32.ne (local.get $ev) (i32.const 2))
        (then
          (call $task_return (i32.add (i32.const 3000) (local.get $ev)))
          (return)
        )
      )

      ;; 5) the byte landed in the read buffer; tear down (ends before the
      ;;    set -- same "resource has children" ordering rule as futures)
      ;;    and return it.
      (call $sdrop_r (local.get $readable))
      (call $sdrop_w (local.get $writable))
      (call $ws_drop (local.get $ws))
      (call $task_return (i32.load8_u (i32.const 0)))
    )
  )

  (core module $memhost
    (memory (export "memory") 1)
  )
  (core instance $mem-inst (instantiate $memhost))

  (type $st (stream u8))
  (core func $core-snew (canon stream.new $st))
  (core func $core-sread (canon stream.read $st async (memory $mem-inst "memory")))
  (core func $core-swrite (canon stream.write $st async (memory $mem-inst "memory")))
  (core func $core-sdrop-r (canon stream.drop-readable $st))
  (core func $core-sdrop-w (canon stream.drop-writable $st))
  (core func $core-task-return (canon task.return (result u32)))
  (core func $core-ws-new (canon waitable-set.new))
  (core func $core-waitable-join (canon waitable.join))
  (core func $core-ws-wait (canon waitable-set.wait (memory $mem-inst "memory")))
  (core func $core-ws-drop (canon waitable-set.drop))

  (core instance $guest-inst (instantiate $guest
    (with "$root" (instance
      (export "[stream-new-0]pipe" (func $core-snew))
      (export "[async-lower][stream-read-0]pipe" (func $core-sread))
      (export "[async-lower][stream-write-0]pipe" (func $core-swrite))
      (export "[stream-drop-readable-0]pipe" (func $core-sdrop-r))
      (export "[stream-drop-writable-0]pipe" (func $core-sdrop-w))
      (export "[waitable-set-new]" (func $core-ws-new))
      (export "[waitable-join]" (func $core-waitable-join))
      (export "[waitable-set-wait]" (func $core-ws-wait))
      (export "[waitable-set-drop]" (func $core-ws-drop))
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
