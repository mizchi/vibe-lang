;; #1539 executable stdin lifecycle probe for `wasi:cli/stdin@0.3.0`.
;;
;; This preserves the ratified WIT's nominal `wasi:cli/types@0.3.0/error-code`
;; in the completion future. `drain` consumes exactly 10, 15, 17 then EOF and
;; awaits a successful completion (42); `drop` drops the readable stream then
;; awaits the same successful completion (43). Every unexpected status, event,
;; byte, EOF, or completion result takes a distinct diagnostic return path.
(component
  (type $types
    (instance
      (type $error-code (enum "io" "illegal-byte-sequence" "pipe"))
      (export "error-code" (type (eq $error-code)))
    )
  )
  (import "wasi:cli/types@0.3.0" (instance $types-import (type $types)))
  (alias export $types-import "error-code" (type $error-code))

  (type $stdin
    (instance
      (alias outer 1 $error-code (type $stdin-error-code))
      (type $stream (stream u8))
      (type $completion-result (result (error $stdin-error-code)))
      (type $completion (future $completion-result))
      (type $read-result (tuple $stream $completion))
      (export "read-via-stream" (func (result $read-result)))
    )
  )
  (import "wasi:cli/stdin@0.3.0" (instance $stdin-import (type $stdin)))
  (alias export $stdin-import "read-via-stream" (func $read-via-stream))

  (core module $guest
    ;; `read-via-stream` writes its two handles to the supplied return area.
    (import "$root" "read-via-stream" (func $stdin (param i32)))
    (import "$root" "[async-lower][stream-read-0]read-via-stream" (func $sread (param i32 i32 i32) (result i32)))
    (import "$root" "[stream-drop-readable-0]read-via-stream" (func $sdrop (param i32)))
    (import "$root" "[async-lower][future-read-1]read-via-stream" (func $fread (param i32 i32) (result i32)))
    (import "$root" "[future-drop-readable-1]read-via-stream" (func $fdrop (param i32)))
    (import "$root" "[waitable-set-new]" (func $ws-new (result i32)))
    (import "$root" "[waitable-join]" (func $waitable-join (param i32 i32)))
    (import "$root" "[waitable-set-wait]" (func $ws-wait (param i32 i32) (result i32)))
    (import "$root" "[waitable-set-drop]" (func $ws-drop (param i32)))
    (import "[export]$root" "[task-return]drain" (func $drain-return (param i32)))
    (import "[export]$root" "[task-return]drop" (func $drop-return (param i32)))
    (import "env" "memory" (memory 1))

    ;; Memory layout:
    ;;   0  one-byte stream.read landing slot
    ;;   8  read-via-stream tuple return area (stream, completion future)
    ;;  16  waitable-set.wait payload (waitable, completion status)
    ;;  32  future<result<_, error-code>> landing area (result tag, error)

    ;; Dispose both ends once no set owns either. The caller supplies its own
    ;; task-return function so both exported async tasks retain correct scope.
    (func $finish-drain (param $stream i32) (param $future i32) (param $code i32)
      (call $sdrop (local.get $stream))
      (call $fdrop (local.get $future))
      (call $drain-return (local.get $code))
    )
    (func $finish-after-drain (param $future i32) (param $code i32)
      (call $fdrop (local.get $future))
      (call $drain-return (local.get $code))
    )
    (func $finish-drop (param $future i32) (param $code i32)
      (call $fdrop (local.get $future))
      (call $drop-return (local.get $code))
    )

    ;; A stdin stream read commonly parks even when the shell has already
    ;; supplied a finite file. Its completion is therefore collected through
    ;; the stream's waitable (STREAM_READ = 2) before the status is checked.
    (func $read-one (param $stream i32) (result i32)
      (local $status i32)
      (local $set i32)
      (local $event i32)
      (local.set $status (call $sread (local.get $stream) (i32.const 0) (i32.const 1)))
      (if (i32.eq (local.get $status) (i32.const 0xffffffff))
        (then
          (local.set $set (call $ws-new))
          (call $waitable-join (local.get $stream) (local.get $set))
          (local.set $event (call $ws-wait (local.get $set) (i32.const 16)))
          (call $waitable-join (local.get $stream) (i32.const 0))
          (call $ws-drop (local.get $set))
          (if (i32.ne (local.get $event) (i32.const 2))
            (then (return (i32.add (i32.const 0xfffff000) (local.get $event)))))
          (local.set $status (i32.load (i32.const 20)))
        )
      )
      (local.get $status)
    )

    ;; Await a completion future after its stream end is no longer owned. It
    ;; permits only COMPLETED (0) or BLOCKED followed by FUTURE_READ (4); the
    ;; result landing area must contain the success discriminant (0).
    (func $await-drain (param $future i32)
      (local $status i32)
      (local $set i32)
      (local $event i32)
      (local.set $status (call $fread (local.get $future) (i32.const 32)))
      (if (i32.eq (local.get $status) (i32.const 0xffffffff))
        (then
          (local.set $set (call $ws-new))
          (call $waitable-join (local.get $future) (local.get $set))
          (local.set $event (call $ws-wait (local.get $set) (i32.const 16)))
          ;; Unjoin before dropping the set: a set with children traps.
          (call $waitable-join (local.get $future) (i32.const 0))
          (call $ws-drop (local.get $set))
          (if (i32.ne (local.get $event) (i32.const 4))
            (then (call $finish-after-drain (local.get $future) (i32.add (i32.const 3000) (local.get $event))) (return))
          )
          (local.set $status (i32.load (i32.const 20)))
        )
      )
      (if (i32.ne (local.get $status) (i32.const 0))
        (then (call $finish-after-drain (local.get $future) (i32.add (i32.const 4000) (local.get $status))) (return))
      )
      ;; `result<_, error-code>`: only tag 0 is success. A nonzero tag is an
      ;; error of the imported nominal type, never a representation stand-in.
      (if (i32.ne (i32.load (i32.const 32)) (i32.const 0))
        (then (call $finish-after-drain (local.get $future) (i32.add (i32.const 5000) (i32.load (i32.const 32)))) (return))
      )
      (call $fdrop (local.get $future))
      (call $drain-return (i32.const 42))
    )

    (func (export "drain")
      (local $stream i32)
      (local $future i32)
      (local $status i32)
      (call $stdin (i32.const 8))
      (local.set $stream (i32.load (i32.const 8)))
      (local.set $future (i32.load (i32.const 12)))

      (local.set $status (call $read-one (local.get $stream)))
      (if (i32.ne (local.get $status) (i32.const 16))
        (then (call $finish-drain (local.get $stream) (local.get $future) (i32.add (i32.const 100) (local.get $status))) (return)))
      (if (i32.ne (i32.load8_u (i32.const 0)) (i32.const 10))
        (then (call $finish-drain (local.get $stream) (local.get $future) (i32.const 200)) (return)))

      (local.set $status (call $read-one (local.get $stream)))
      (if (i32.ne (local.get $status) (i32.const 16))
        (then (call $finish-drain (local.get $stream) (local.get $future) (i32.add (i32.const 300) (local.get $status))) (return)))
      (if (i32.ne (i32.load8_u (i32.const 0)) (i32.const 15))
        (then (call $finish-drain (local.get $stream) (local.get $future) (i32.const 400)) (return)))

      (local.set $status (call $read-one (local.get $stream)))
      (if (i32.ne (local.get $status) (i32.const 16))
        (then (call $finish-drain (local.get $stream) (local.get $future) (i32.add (i32.const 500) (local.get $status))) (return)))
      (if (i32.ne (i32.load8_u (i32.const 0)) (i32.const 17))
        (then (call $finish-drain (local.get $stream) (local.get $future) (i32.const 600)) (return)))

      ;; A buffered stdin EOF is a separate zero-item CLOSED status: 1.
      (local.set $status (call $read-one (local.get $stream)))
      (if (i32.ne (local.get $status) (i32.const 1))
        (then (call $finish-drain (local.get $stream) (local.get $future) (i32.add (i32.const 700) (local.get $status))) (return)))
      (call $sdrop (local.get $stream))
      (call $await-drain (local.get $future))
    )

    (func (export "drop")
      (local $stream i32)
      (local $future i32)
      (local $status i32)
      (local $set i32)
      (local $event i32)
      (call $stdin (i32.const 8))
      (local.set $stream (i32.load (i32.const 8)))
      (local.set $future (i32.load (i32.const 12)))
      (call $sdrop (local.get $stream))
      (local.set $status (call $fread (local.get $future) (i32.const 32)))
      (if (i32.eq (local.get $status) (i32.const 0xffffffff))
        (then
          (local.set $set (call $ws-new))
          (call $waitable-join (local.get $future) (local.get $set))
          (local.set $event (call $ws-wait (local.get $set) (i32.const 16)))
          (call $waitable-join (local.get $future) (i32.const 0))
          (call $ws-drop (local.get $set))
          (if (i32.ne (local.get $event) (i32.const 4))
            (then (call $finish-drop (local.get $future) (i32.add (i32.const 8000) (local.get $event))) (return)))
          (local.set $status (i32.load (i32.const 20)))
        )
      )
      (if (i32.ne (local.get $status) (i32.const 0))
        (then (call $finish-drop (local.get $future) (i32.add (i32.const 9000) (local.get $status))) (return)))
      (if (i32.ne (i32.load (i32.const 32)) (i32.const 0))
        (then (call $finish-drop (local.get $future) (i32.add (i32.const 10000) (i32.load (i32.const 32)))) (return)))
      (call $fdrop (local.get $future))
      (call $drop-return (i32.const 43))
    )
  )

  (core module $memhost
    (memory (export "memory") 1)
  )
  (core instance $mem-inst (instantiate $memhost))

  ;; `read-via-stream` needs the same memory as its guest because its tuple is
  ;; returned indirectly. The literal stream/future operations are async.
  (core func $core-stdin (canon lower (func $read-via-stream) (memory $mem-inst "memory")))
  (type $stream (stream u8))
  (type $completion-result (result (error $error-code)))
  (type $completion (future $completion-result))
  (core func $core-sread (canon stream.read $stream async (memory $mem-inst "memory")))
  (core func $core-sdrop (canon stream.drop-readable $stream))
  (core func $core-fread (canon future.read $completion async (memory $mem-inst "memory")))
  (core func $core-fdrop (canon future.drop-readable $completion))
  (core func $core-ws-new (canon waitable-set.new))
  (core func $core-waitable-join (canon waitable.join))
  (core func $core-ws-wait (canon waitable-set.wait (memory $mem-inst "memory")))
  (core func $core-ws-drop (canon waitable-set.drop))
  (core func $core-drain-return (canon task.return (result u32)))
  (core func $core-drop-return (canon task.return (result u32)))

  (core instance $guest-inst (instantiate $guest
    (with "$root" (instance
      (export "read-via-stream" (func $core-stdin))
      (export "[async-lower][stream-read-0]read-via-stream" (func $core-sread))
      (export "[stream-drop-readable-0]read-via-stream" (func $core-sdrop))
      (export "[async-lower][future-read-1]read-via-stream" (func $core-fread))
      (export "[future-drop-readable-1]read-via-stream" (func $core-fdrop))
      (export "[waitable-set-new]" (func $core-ws-new))
      (export "[waitable-join]" (func $core-waitable-join))
      (export "[waitable-set-wait]" (func $core-ws-wait))
      (export "[waitable-set-drop]" (func $core-ws-drop))
    ))
    (with "[export]$root" (instance
      (export "[task-return]drain" (func $core-drain-return))
      (export "[task-return]drop" (func $core-drop-return))
    ))
    (with "env" (instance (export "memory" (memory $mem-inst "memory"))))
  ))

  (type $run-type (func async (result u32)))
  (func $drain (type $run-type) (canon lift (core func $guest-inst "drain") async))
  (func $drop (type $run-type) (canon lift (core func $guest-inst "drop") async))
  (export "drain" (func $drain))
  (export "drop" (func $drop))

  ;; Keep the preview-2 command export so `wasmtime run` instantiates this
  ;; component. The lifecycle lanes above are invoked explicitly by the gate.
  (core module $command-core
    (func (export "run") (result i32) (i32.const 0))
  )
  (core instance $command-core-instance (instantiate $command-core))
  (type $command-result (result))
  (type $command-run (func (result $command-result)))
  (func $command-run-func (type $command-run)
    (canon lift (core func $command-core-instance "run"))
  )
  (instance $command-instance (export "run" (func $command-run-func)))
  (export "wasi:cli/run@0.2.12" (instance $command-instance))
)
