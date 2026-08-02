;; ADR-0089 Decision 3 probe (#1218): HOST-SUPPLIED stream<u8>, read to
;; END OF STREAM by the guest one byte at a time.
;;
;; ../host_future_value settled the host-supplied `future<u32>` half: the
;; guest reads, blocks, parks in waitable-set.wait, and the host producer
;; wakes it. A stream has one thing a future does not -- it ENDS -- and the
;; Decision 3 emitter cannot be written without knowing exactly how that end
;; is reported. `stream.read` returns a packed status whose low nibble is a
;; code and whose upper bits are the amount transferred, but which code means
;; "the writer is gone, there will be no more items" is a runtime fact, not
;; something to guess. That is what this probe measures.
;;
;; Host side: runtime/viberun's VIBE_ASYNC_STREAMS="body=b1|b2|b3" links
;; `body: func() -> stream<u8>` backed by wasmtime's own `Vec<u8>`
;; StreamProducer, so what is observed here is the RUNTIME's end-of-stream
;; behaviour rather than a hand-rolled producer's.
;;
;; Conventions reused from the sibling probes (all previously measured):
;;   - async-lowered call result packs (subtask << 4) | code, code 2 =
;;     RETURNED (spawned_future/component.wat)
;;   - stream.read async BLOCKED = 0xffffffff; completion packs
;;     (amount << 4) | code; STREAM_READ event = 2 (stream_value/component.wat)
;;   - drop joined ends BEFORE waitable-set.drop ("resource has children")
;;
;; The loop reads ONE byte at a time (the shape ByteStream::next needs, and
;; the worst case for status handling) and accumulates the sum. It returns:
;;
;;   sum                          all bytes were delivered and the end was
;;                                recognised (the success case)
;;   5000 + code                  the import did not complete eagerly
;;   6000 + n                     more than 64 iterations -- the end was
;;                                never recognised (would be an infinite
;;                                loop in a real reader)
;;   3000 + ev                    waitable-set.wait returned a non-STREAM_READ
;;                                event
;;   7000 + (status & 0xfff)      a zero-transfer status whose code is NOT
;;                                the measured CLOSED code -- low nibble =
;;                                the code, upper bits = the amount
;;
;; MEASURED (wasmtime 47.0.2, 2026-08-02, VIBE_ASYNC_STREAMS="body=10|15|17"):
;; three single-byte reads each transfer 1 item, and the FOURTH read comes
;; back with amount 0 / code 1. So end-of-stream is `(status >> 4) == 0 &&
;; (status & 0xf) == 1` -- there is no separate "closed" event to wait for,
;; the read that finds the writer gone reports it inline. Probe returns 42
;; (10 + 15 + 17), so the bytes really were delivered before that end.
(component
  (type $st (stream u8))
  ;; Same async-functype discipline as the host_future_value probe: the
  ;; `async` canonical-lower option validates only against an async function
  ;; type. WIT spelling stays `func() -> stream<u8>`.
  (type $get-stream-type (func async (result $st)))
  (import "body" (func $host-body (type $get-stream-type)))

  (core module $guest
    (import "$root" "[async-lower]body" (func $get_stream (param i32) (result i32)))
    (import "$root" "[async-lower][stream-read-0]body" (func $sread (param i32 i32 i32) (result i32)))
    (import "$root" "[stream-drop-readable-0]body" (func $sdrop_r (param i32)))
    (import "$root" "[waitable-set-new]" (func $ws_new (result i32)))
    (import "$root" "[waitable-join]" (func $waitable_join (param i32 i32)))
    (import "$root" "[waitable-set-wait]" (func $ws_wait (param i32 i32) (result i32)))
    (import "$root" "[waitable-set-drop]" (func $ws_drop (param i32)))
    (import "[export]$root" "[task-return]run" (func $task_return (param i32)))
    (import "env" "memory" (memory 1))

    ;; Memory layout (shared memhost page):
    ;;    0  1-byte read landing slot
    ;;    8  [async-lower]body results (u32 stream readable handle)
    ;;   16  waitable-set.wait payload[0] / [1]
    (func (export "run")
      (local $packed i32)
      (local $code i32)
      (local $str i32)
      (local $st i32)
      (local $ws i32)
      (local $ev i32)
      (local $sum i32)
      (local $iter i32)

      ;; 1) obtain the readable end. Creating the pair suspends nothing
      ;;    host-side, so this must complete eagerly.
      (local.set $packed (call $get_stream (i32.const 8)))
      (local.set $code (i32.and (local.get $packed) (i32.const 0xf)))
      (if (i32.ne (local.get $code) (i32.const 2))
        (then
          (call $task_return (i32.add (i32.const 5000) (local.get $code)))
          (return)
        )
      )
      (local.set $str (i32.load (i32.const 8)))

      ;; 2) read one byte at a time until the stream ends.
      (block $done
        (loop $again
          (local.set $iter (i32.add (local.get $iter) (i32.const 1)))
          (if (i32.gt_u (local.get $iter) (i32.const 64))
            (then
              (call $task_return (i32.add (i32.const 6000) (local.get $iter)))
              (return)
            )
          )
          (local.set $st (call $sread (local.get $str) (i32.const 0) (i32.const 1)))
          ;; BLOCKED -> park as a waitable until the producer delivers.
          (if (i32.eq (local.get $st) (i32.const 0xffffffff))
            (then
              (local.set $ws (call $ws_new))
              (call $waitable_join (local.get $str) (local.get $ws))
              (local.set $ev (call $ws_wait (local.get $ws) (i32.const 16)))
              (call $ws_drop (local.get $ws))
              (if (i32.ne (local.get $ev) (i32.const 2))
                (then
                  (call $task_return (i32.add (i32.const 3000) (local.get $ev)))
                  (return)
                )
              )
              ;; the completion status is payload[1]; payload[0] is the
              ;; waitable index.
              (local.set $st (i32.load (i32.const 20)))
            )
          )
          ;; A transfer of >= 1 item means a byte landed at mem[0].
          ;; A transfer of NOTHING is the end of the stream -- MEASURED
          ;; (wasmtime 47, Vec<u8> producer, 2026-08-02): the status comes
          ;; back as amount 0, code 1, i.e. raw 0x1. Treat code 1 as CLOSED
          ;; and finish with the sum; report anything else raw so a future
          ;; runtime change is a loud diagnostic rather than a wrong answer.
          (if (i32.eqz (i32.shr_u (local.get $st) (i32.const 4)))
            (then
              (if (i32.ne (i32.and (local.get $st) (i32.const 0xf)) (i32.const 1))
                (then
                  (call $task_return
                    (i32.add (i32.const 7000) (i32.and (local.get $st) (i32.const 0xfff))))
                  (return)
                )
              )
              (br $done)
            )
          )
          (local.set $sum
            (i32.add (local.get $sum) (i32.load8_u (i32.const 0))))
          (br $again)
        )
      )

      (call $sdrop_r (local.get $str))
      (call $task_return (local.get $sum))
    )
  )

  (core module $memhost
    (memory (export "memory") 1)
  )
  (core instance $mem-inst (instantiate $memhost))

  (core func $core-get-stream (canon lower (func $host-body) async (memory $mem-inst "memory")))
  (core func $core-sread (canon stream.read $st async (memory $mem-inst "memory")))
  (core func $core-sdrop-r (canon stream.drop-readable $st))
  (core func $core-task-return (canon task.return (result u32)))
  (core func $core-ws-new (canon waitable-set.new))
  (core func $core-waitable-join (canon waitable.join))
  (core func $core-ws-wait (canon waitable-set.wait (memory $mem-inst "memory")))
  (core func $core-ws-drop (canon waitable-set.drop))

  (core instance $guest-inst (instantiate $guest
    (with "$root" (instance
      (export "[async-lower]body" (func $core-get-stream))
      (export "[async-lower][stream-read-0]body" (func $core-sread))
      (export "[stream-drop-readable-0]body" (func $core-sdrop-r))
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
