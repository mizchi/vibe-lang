;; #1540 scope 1, completed: a guest that actually READS the request body.
;;
;; ../http_body_stream established that the body can REACH the guest as a
;; `stream<u8>` parameter, but its guest ignores the stream and answers a
;; constant -- it answers the composition question only, and its own README
;; says so. This probe answers the remaining one: what a guest has to do to
;; read that stream, and what the component has to look like around it.
;;
;; The pieces are individually measured elsewhere; what is new here is that
;; they have to hold TOGETHER on one export:
;;
;;   ../host_stream_value      stream.read's status encoding and the two
;;                             end-of-stream shapes
;;   ../async_string_lift      the canonopt set for an async lift whose
;;                             result is a string, and why memory + realloc
;;                             must live outside the guest instance
;;   ../http_body_stream       the acyclic adapter/guest composition
;;
;; MEASURED HERE (wasmtime 47.0.2 / wasm-tools 1.255.0 / wit-bindgen 0.54):
;;
;;   1. The adapter's import must be spelled `async func` in WIT.
;;      `import handler: func(..) -> string` produces a functype with
;;      async_: false, and `canon lift ... async` is rejected against it
;;      ("the `async` canonical option requires an async function type").
;;      Reading the body BLOCKS, so the handler MUST be async-lifted -- which
;;      makes `async func` a requirement on the adapter side, not a choice.
;;      wit-bindgen 0.54 accepts it and generates an awaitable import whose
;;      string params are OWNED (`String`, not `&str`).
;;
;;   2. The stream parameter arrives as one i32 handle, after the three
;;      strings' (ptr, len) pairs: the core function takes 7 i32 and returns
;;      NOTHING, since an async lift's result leaves through task.return.
;;
;; Diagnostics are returned as recognisable STRINGS rather than numbers: the
;; result of this export is a string, and a gate that greps the HTTP response
;; can then say which assumption broke instead of just "did not match".
(component
  ;; memory + realloc OUTSIDE the guest instance. `task.return` needs a
  ;; memory and the async lift needs both, and both canons are declared
  ;; before the guest instance exists -- the guest imports `[task-return]`,
  ;; so a guest-owned memory would be an instantiation cycle.
  (core module $memhost
    (memory (export "memory") 1)
    (global $bump (mut i32) (i32.const 1024))
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
      (local $p i32)
      (local.set $p (global.get $bump))
      (global.set $bump (i32.add (global.get $bump) (i32.const 256)))
      (local.get $p))
  )
  (core instance $mh (instantiate $memhost))
  (alias core export $mh "memory" (core memory $mem))
  (alias core export $mh "cabi_realloc" (core func $realloc))

  (type $sty (stream u8))
  (core func $sread (canon stream.read $sty async (memory $mem)))
  (core func $sdrop_r (canon stream.drop-readable $sty))
  (core func $ws_new (canon waitable-set.new))
  (core func $waitable_join (canon waitable.join))
  (core func $ws_wait (canon waitable-set.wait (memory $mem)))
  (core func $ws_drop (canon waitable-set.drop))
  (core func $tr (canon task.return (result string) (memory $mem) string-encoding=utf8))

  (core module $m
    (import "$root" "[async-lower][stream-read-0]body" (func $sread (param i32 i32 i32) (result i32)))
    (import "$root" "[stream-drop-readable-0]body" (func $sdrop_r (param i32)))
    (import "$root" "[waitable-set-new]" (func $ws_new (result i32)))
    (import "$root" "[waitable-join]" (func $waitable_join (param i32 i32)))
    (import "$root" "[waitable-set-wait]" (func $ws_wait (param i32 i32) (result i32)))
    (import "$root" "[waitable-set-drop]" (func $ws_drop (param i32)))
    (import "[export]$root" "[task-return]handler" (func $task_return (param i32 i32)))
    (import "env" "memory" (memory 1))

    ;; Written into the IMPORTED (memhost) memory at instantiation.
    ;;   64  "200\n\n" + up to 64 body bytes read from the stream
    ;;  300  diagnostics, each already carrying the status/header prefix
    ;;  512  waitable-set.wait payload[0] / [1]
    ;; The memhost's realloc bump starts at 1024, above all of these, so the
    ;; three string params it lowers cannot land on them.
    (data (i32.const 64) "200\0a\0a")
    (data (i32.const 300) "200\0a\0aERR-EVENT")
    (data (i32.const 320) "200\0a\0aERR-STATUS")
    (data (i32.const 340) "200\0a\0aERR-OVERRUN")

    ;; 3 strings flattened to (ptr, len) pairs + the stream handle. No
    ;; result: an async lift returns through task.return.
    (func (export "handler")
      (param $method_p i32) (param $method_n i32)
      (param $url_p i32) (param $url_n i32)
      (param $headers_p i32) (param $headers_n i32)
      (param $body i32)
      (local $st i32)
      (local $ws i32)
      (local $ev i32)
      (local $total i32)

      (block $done
        (loop $again
          ;; One byte at a time: the shape a byte-oriented reader needs, and
          ;; the worst case for status handling.
          (if (i32.ge_u (local.get $total) (i32.const 64))
            (then
              (call $task_return (i32.const 340) (i32.const 16))
              (return)
            )
          )
          (local.set $st
            (call $sread (local.get $body)
              (i32.add (i32.const 69) (local.get $total))
              (i32.const 1)))

          ;; BLOCKED: park until the producer delivers. UNJOIN before
          ;; dropping the set -- dropping a set that still has members traps
          ;; with "resource has children" (../host_stream_value).
          (if (i32.eq (local.get $st) (i32.const 0xffffffff))
            (then
              (local.set $ws (call $ws_new))
              (call $waitable_join (local.get $body) (local.get $ws))
              (local.set $ev (call $ws_wait (local.get $ws) (i32.const 512)))
              (call $waitable_join (local.get $body) (i32.const 0))
              (call $ws_drop (local.get $ws))
              (if (i32.ne (local.get $ev) (i32.const 2))
                (then
                  (call $task_return (i32.const 300) (i32.const 14))
                  (return)
                )
              )
              ;; payload[1] is the completion status; payload[0] is the
              ;; waitable index.
              (local.set $st (i32.load (i32.const 516)))
            )
          )

          ;; Nothing transferred = the end of the stream, reported inline by
          ;; the read that found the writer gone (code 1). Any other
          ;; zero-transfer code is an assumption that moved: say so loudly
          ;; rather than answer a truncated body as if it were complete.
          (if (i32.eqz (i32.shr_u (local.get $st) (i32.const 4)))
            (then
              (if (i32.ne (i32.and (local.get $st) (i32.const 0xf)) (i32.const 1))
                (then
                  (call $task_return (i32.const 320) (i32.const 15))
                  (return)
                )
              )
              (br $done)
            )
          )

          (local.set $total (i32.add (local.get $total) (i32.const 1)))
          ;; The end can also arrive INLINE with the final byte (amount 1,
          ;; code 1), and reading again after that notification traps.
          (br_if $done
            (i32.eq (i32.and (local.get $st) (i32.const 0xf)) (i32.const 1)))
          (br $again)
        )
      )

      (call $sdrop_r (local.get $body))
      ;; "200\n\n" + everything read: the response body IS the request body,
      ;; so a gate can assert the bytes round-tripped rather than that some
      ;; constant came back.
      (call $task_return (i32.const 64) (i32.add (i32.const 5) (local.get $total)))
    )
  )

  (core instance $gi (instantiate $m
    (with "$root" (instance
      (export "[async-lower][stream-read-0]body" (func $sread))
      (export "[stream-drop-readable-0]body" (func $sdrop_r))
      (export "[waitable-set-new]" (func $ws_new))
      (export "[waitable-join]" (func $waitable_join))
      (export "[waitable-set-wait]" (func $ws_wait))
      (export "[waitable-set-drop]" (func $ws_drop))
    ))
    (with "[export]$root" (instance
      (export "[task-return]handler" (func $tr))
    ))
    (with "env" (instance
      (export "memory" (memory $mem))
    ))
  ))

  (type $ft (func async
    (param "method" string) (param "url" string) (param "headers" string)
    (param "body" $sty) (result string)))
  (func (export "handler") (type $ft)
    (canon lift (core func $gi "handler") async (memory $mem) (realloc $realloc) string-encoding=utf8))
)
