;; M1b feasibility blueprint: minimal async-LIFTED component export.
;;
;; Unlike cm_async_probe.wat (which uses a *sync* `canon lift` and only checks
;; that the async runtime *flags* are accepted), this probe exercises a genuine
;; async-lifted export driven by the `task.return` canonical built-in — the
;; shape the selfhost codegen (docs/spec/wasi-p3-async.md, M1b) must emit.
;;
;; Findings (wasmtime 45.0.0, x86_64 linux), authored by hand-minimizing a
;; wit-bindgen `async func() -> u32` reference:
;;   * The lifted function's component type must be async: `(func async (result T))`.
;;   * In the callback-less ("stackful") form the core function returns NOTHING;
;;     the result is delivered solely via `task.return`. (A status-i32 return is
;;     the callback/stackless form and is rejected here.)
;;   * Requires `-W component-model-async-stackful=y` in addition to
;;     `-W concurrency-support=y -W component-model-async=y`.
;;
;; This stackful form lets the backend emit straight-line code (compute result,
;; call task.return, return) — no explicit stackless state-machine split — which
;; is the simplest path for the linear backend. (wit-bindgen instead emits the
;; callback/stackless form, which needs no stackful flag but a state machine.)
;;
;; Run:
;;   wasm-tools parse cm_async_lift_probe.wat -o /tmp/p.wasm
;;   wasmtime run -W concurrency-support=y -W component-model-async=y \
;;     -W component-model-async-stackful=y --invoke "run()" /tmp/p.wasm
;;   => 42

(component
  (core module $m
    ;; task.return is provided by the canonical ABI (lowered below) and takes
    ;; the lifted result (u32 -> i32 at the core level).
    (import "cm" "task-return" (func $task_return (param i32)))
    ;; Straight-line async body: compute 42, hand it to task.return, return void.
    (func (export "run")
      i32.const 42
      call $task_return
    )
    (memory (export "memory") 1)
  )
  ;; Lower the task.return canonical built-in for an export returning u32.
  (core func $tr (canon task.return (result u32)))
  (core instance $imports (export "task-return" (func $tr)))
  (core instance $i (instantiate $m (with "cm" (instance $imports))))
  ;; The export's component type is async.
  (type $rt (func async (result u32)))
  ;; Callback-less (stackful) async lift.
  (func $run (type $rt) (canon lift (core func $i "run") async))
  (export "run" (func $run))
)
