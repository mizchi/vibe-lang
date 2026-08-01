;; ADR-0089 step 2 probe: SELF-CONTAINED future<u32> VALUE round-trip using
;; the literal `future.*` canonical built-ins -- the canon family the
;; wit-bindgen capture in this directory measured by name
;; (canon-imports-exports.wit-abi.txt) but which no probe had actually
;; EXECUTED from hand-authored code yet.
;;
;; Shape (single task, no host import, no spawn):
;;   1. future.new            -> packed i64 (readable + writable end handles)
;;   2. future.read  (async)  on the readable end -> BLOCKED (no writer yet)
;;   3. waitable.join(readable, ws)
;;   4. future.write (async)  of 42 from the write buffer -> completes
;;      EAGERLY, because a read is already pending (the runtime pairs the
;;      two pending copies and performs the copy immediately)
;;   5. waitable-set.wait     -> FUTURE_READ event on the readable end
;;      (the read that returned BLOCKED in step 2 has now completed)
;;   6. load the value from the read buffer, drop both ends + the set,
;;      task.return it
;;
;; This sidesteps the "self round-trip deadlocks" wall the M2c-3 stream
;; spike hit (docs/spec/wasi-p3-async.md §3.3): that probe used a BLOCKING
;; read with no producer. With the `async` canonopt on both copies, one
;; side parks as a waitable instead of parking the fiber, so a single task
;; can complete the rendezvous with itself.
;;
;; Encodings this probe pins (all diagnosed via distinctive task.return
;; values rather than traps, so a mismatch reports WHAT was seen):
;;   - future.new packs (writable << 32) | readable  (readable in LOW bits)
;;   - async future.read with no pending writer returns BLOCKED (0xffffffff)
;;   - async future.write with a pending reader returns COMPLETED eagerly
;;     (result code bits = 0, not BLOCKED)
;;   - the wait event is FUTURE_READ (= 4), payload[0] = readable end index
;;
;; Diagnostic return values (anything other than 42 is a failure, and says
;; which assumption broke):
;;   1000 + code   future.read did NOT block; code = its low result bits
;;   2015          future.write came back BLOCKED instead of completing
;;   3000 + ev     wait returned an unexpected event code ev
;;                 (expect ev=4 FUTURE_READ)
(component
  (core module $guest
    ;; Import names follow the wit-bindgen capture's convention
    ;; ([future-<op>-0]<introducing-func>) for documentation value; the
    ;; names are free-form here since this component authors both sides.
    (import "$root" "[future-new-0]make" (func $fnew (result i64)))
    (import "$root" "[async-lower][future-read-0]make" (func $fread (param i32 i32) (result i32)))
    (import "$root" "[async-lower][future-write-0]make" (func $fwrite (param i32 i32) (result i32)))
    (import "$root" "[future-drop-readable-0]make" (func $fdrop_r (param i32)))
    (import "$root" "[future-drop-writable-0]make" (func $fdrop_w (param i32)))
    (import "$root" "[waitable-set-new]" (func $ws_new (result i32)))
    (import "$root" "[waitable-join]" (func $waitable_join (param i32 i32)))
    (import "$root" "[waitable-set-wait]" (func $ws_wait (param i32 i32) (result i32)))
    (import "$root" "[waitable-set-drop]" (func $ws_drop (param i32)))
    (import "[export]$root" "[task-return]run" (func $task_return (param i32)))
    (import "env" "memory" (memory 1))

    ;; Memory layout (shared memhost page):
    ;;    0  read buffer (u32 landing slot for the future's value)
    ;;    4  write buffer (u32 source slot, pre-loaded with 42)
    ;;   16  waitable-set.wait payload[0] (which waitable fired)
    ;;   20  waitable-set.wait payload[1]
    (func (export "run")
      (local $packed i64)
      (local $readable i32)
      (local $writable i32)
      (local $st i32)
      (local $ws i32)
      (local $ev i32)

      (local.set $packed (call $fnew))
      (local.set $readable (i32.wrap_i64 (local.get $packed)))
      (local.set $writable (i32.wrap_i64 (i64.shr_u (local.get $packed) (i64.const 32))))

      ;; stage the value to send
      (i32.store (i32.const 4) (i32.const 42))

      ;; 1) read first: no writer has committed a value yet -> BLOCKED
      (local.set $st (call $fread (local.get $readable) (i32.const 0)))
      (if (i32.ne (local.get $st) (i32.const 0xffffffff))
        (then
          ;; read did not block -- report its low result bits
          (call $task_return
            (i32.add (i32.const 1000) (i32.and (local.get $st) (i32.const 0xf))))
          (return)
        )
      )

      ;; 2) register the pending read's waitable before writing
      (local.set $ws (call $ws_new))
      (call $waitable_join (local.get $readable) (local.get $ws))

      ;; 3) write: a read is pending, so the copy happens now and the write
      ;;    completes eagerly (anything except BLOCKED is acceptable here)
      (local.set $st (call $fwrite (local.get $writable) (i32.const 4)))
      (if (i32.eq (local.get $st) (i32.const 0xffffffff))
        (then
          (call $task_return (i32.const 2015))
          (return)
        )
      )

      ;; 4) collect the pending read's completion event
      (local.set $ev (call $ws_wait (local.get $ws) (i32.const 16)))
      (if (i32.ne (local.get $ev) (i32.const 4))
        (then
          ;; unexpected event code
          (call $task_return (i32.add (i32.const 3000) (local.get $ev)))
          (return)
        )
      )

      ;; 5) the value landed in the read buffer; tear down and return it.
      ;;    Drop the ends BEFORE the set: the readable end was joined into
      ;;    the set, and dropping a set that still has members traps with
      ;;    "resource has children" (same ordering rule the spawned-future
      ;;    emitter pinned for subtask.drop vs waitable-set.drop).
      (call $fdrop_r (local.get $readable))
      (call $fdrop_w (local.get $writable))
      (call $ws_drop (local.get $ws))
      (call $task_return (i32.load (i32.const 0)))
    )
  )

  (core module $memhost
    (memory (export "memory") 1)
  )
  (core instance $mem-inst (instantiate $memhost))

  (type $ft (future u32))
  (core func $core-fnew (canon future.new $ft))
  (core func $core-fread (canon future.read $ft async (memory $mem-inst "memory")))
  (core func $core-fwrite (canon future.write $ft async (memory $mem-inst "memory")))
  (core func $core-fdrop-r (canon future.drop-readable $ft))
  (core func $core-fdrop-w (canon future.drop-writable $ft))
  (core func $core-task-return (canon task.return (result u32)))
  (core func $core-ws-new (canon waitable-set.new))
  (core func $core-waitable-join (canon waitable.join))
  (core func $core-ws-wait (canon waitable-set.wait (memory $mem-inst "memory")))
  (core func $core-ws-drop (canon waitable-set.drop))

  (core instance $guest-inst (instantiate $guest
    (with "$root" (instance
      (export "[future-new-0]make" (func $core-fnew))
      (export "[async-lower][future-read-0]make" (func $core-fread))
      (export "[async-lower][future-write-0]make" (func $core-fwrite))
      (export "[future-drop-readable-0]make" (func $core-fdrop-r))
      (export "[future-drop-writable-0]make" (func $core-fdrop-w))
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
