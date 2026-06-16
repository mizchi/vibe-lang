;; M1b-2 blueprint: two-module (trampoline) async-lifted export.
;;
;; The selfhost compiler already produces a core module whose entry `run` returns
;; the value directly (e.g. `() -> i64`). Rather than modify that core emission,
;; M1b-2 wraps it with a tiny async TRAMPOLINE module that calls the entry and
;; forwards its result to the `task.return` canonical built-in — mirroring how the
;; string-lift path composes a second core module. This keeps linked_compile.vibe
;; untouched.
;;
;; Verified to run on wasmtime 45 (x86_64 linux):
;;   wasm-tools parse cm_async_trampoline_probe.wat -o /tmp/t.wasm
;;   wasmtime run -W concurrency-support=y -W component-model-async=y \
;;     -W component-model-async-stackful=y --invoke "run()" /tmp/t.wasm
;;   => 42
;;
;; Trampoline core module byte template (result valtype = i64 = 0x7e for vibe Int):
;;   type:   [ ()->i64 , (i64)->() , ()->() ]
;;   import: ("main","run":0)  ("cm","task-return":1)
;;   func:   [type 2]   export "run"=func2   code: call 0; call 1; end
;;
;; Component core-func index space: task.return canon = 0; alias main."run" = 1;
;; alias tramp."run" = 2; async lift references core func 2.

(component
  ;; main: the normally-compiled entry (run : () -> i64).
  (core module $main
    (func (export "run") (result i64)
      i64.const 42)
    (memory (export "memory") 1)
  )
  ;; trampoline: call the entry, forward the result to task.return, return void.
  (core module $tramp
    (import "main" "run" (func $entry (result i64)))
    (import "cm" "task-return" (func $task_return (param i64)))
    (func (export "run")
      (call $task_return (call $entry)))
  )
  (core instance $mi (instantiate $main))
  (core func $tr (canon task.return (result s64)))
  (core instance $cm (export "task-return" (func $tr)))
  (alias core export $mi "run" (core func $entry))
  (core instance $env (export "run" (func $entry)))
  (core instance $ti (instantiate $tramp (with "main" (instance $env)) (with "cm" (instance $cm))))
  (type $rt (func async (result s64)))
  (func $run (type $rt) (canon lift (core func $ti "run") async))
  (export "run" (func $run))
)
