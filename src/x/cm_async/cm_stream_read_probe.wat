;; M2c-3 feasibility blueprint: real `stream<u8>` canonical built-ins.
;;
;; M2c so far backs Stream[T] with an eager Array (String::to_bytes /
;; Stream::to_string / `for await` all materialise the bytes up front). M2c-3
;; replaces that with the *real* WASI 0.3 stream<u8>: a handler reads the
;; request body through `stream.read` and never holds the whole body in memory.
;; Before emitting that from the selfhost codegen we pin down, by hand, exactly
;; what wasmtime 45 accepts — mirroring the §3.1 task.return spike.
;;
;; Findings (wasmtime 45.0.0, x86_64 linux; wasm-tools 1.252):
;;
;;   1. The stream canonical built-ins parse + validate and EXECUTE at runtime.
;;      `stream.new` runs under the base M1b flags alone (this probe's `run`
;;      calls it and returns 42 when it yields a non-zero packed handle pair,
;;      proving the lowering runs, not just parses). `stream.read` /
;;      `stream.write`, however, require `-W component-model-more-async-builtins=y`
;;      (the 🚝 set): without it a module containing them fails to parse on
;;      wasmtime 45. (docs/spec earlier noted a `component-model-async-builtins`
;;      flag as unavailable in 45 — the actual flag is the `more-` variant.)
;;
;;   2. WAT forms accepted by wasm-tools 1.252:
;;        (core func $snew  (canon stream.new  $st))
;;        (core func $swrite (canon stream.write $st (memory $li "memory")))
;;        (core func $sread  (canon stream.read  $st (memory $li "memory")))
;;      `stream.new` lowers to `[] -> [i64]` (the packed readable|writable<<32
;;      end indices); read/write lower to `(param i32 i32 i32) -> i32`
;;      (handle, ptr, len) -> status.
;;
;;   3. The memory-needing canon (read/write) cannot reference the *same* core
;;      instance that imports them (instance <-> canon cycle). Break it with a
;;      separate libc memory module instantiated first, and point the canon at
;;      `(memory $li "memory")`. (See the commented round-trip below.)
;;
;;   4. A single-task self write->read DEADLOCKS: `stream.write` on a stream
;;      with no waiting reader blocks (stackful suspend), and the same task is
;;      the only would-be reader. So `stream.read` needs a CONCURRENT producer
;;      (a spawned subtask, or a host-provided readable end such as the HTTP
;;      request body). Wiring that producer is the next M2c-3 slice. The
;;      st2-style round-trip below instantiates and runs, then blocks — kept
;;      commented so this probe stays a `=> 42` smoke test.
;;
;; Run:
;;   wasm-tools parse cm_stream_read_probe.wat -o /tmp/p.wasm
;;   wasmtime run -W concurrency-support=y -W component-model-async=y \
;;     -W component-model-async-stackful=y -W component-model-more-async-builtins=y \
;;     --invoke "run()" /tmp/p.wasm
;;   => 42

(component
  ;; libc: provides the memory the stream.read/write canon reference. Instantiated
  ;; first so the canon lowerings can alias its export without a cycle.
  (core module $libc (memory (export "memory") 1))
  (core instance $li (instantiate $libc))

  (type $st (stream u8))
  ;; stream.new : [] -> [i64]  (packed readable | writable<<32)
  (core func $snew (canon stream.new $st))
  ;; result lift for the async export
  (core func $tr (canon task.return (result u32)))

  (core module $main
    (import "cm" "snew" (func $snew (result i64)))
    (import "cm" "task-return" (func $tr (param i32)))
    (func (export "run")
      (local $h i64)
      (local.set $h (call $snew))
      ;; 42 iff stream.new produced a non-zero packed handle pair (i.e. it ran)
      (call $tr (select
        (i32.const 42) (i32.const 0)
        (i64.ne (local.get $h) (i64.const 0)))))
  )
  (core instance $cm (instantiate $main
    (with "cm" (instance
      (export "snew" (func $snew))
      (export "task-return" (func $tr))))))

  (type $rt (func async (result u32)))
  (func $run (type $rt) (canon lift (core func $cm "run") async))
  (export "run" (func $run))

  ;; ---------------------------------------------------------------------------
  ;; Round-trip blueprint (finding #4): instantiates and runs under the flags
  ;; above, but blocks on the producer-less stream.write. Re-enable once a
  ;; concurrent producer (subtask spawn) exists.
  ;;
  ;; (core func $swrite (canon stream.write $st (memory $li "memory")))
  ;; (core func $sread  (canon stream.read  $st (memory $li "memory")))
  ;; ... in $main, importing libc.memory + cm.swrite/sread:
  ;;   (local.set $h (call $snew))
  ;;   (local.set $rd (i32.wrap_i64 (local.get $h)))
  ;;   (local.set $wr (i32.wrap_i64 (i64.shr_u (local.get $h) (i64.const 32))))
  ;;   (drop (call $swrite (local.get $wr) (i32.const 0) (i32.const 3)))   ;; BLOCKS
  ;;   (drop (call $sread  (local.get $rd) (i32.const 8) (i32.const 3)))
  ;; ---------------------------------------------------------------------------
)
