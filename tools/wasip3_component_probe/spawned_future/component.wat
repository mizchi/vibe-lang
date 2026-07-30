;; M1b-3c-1b probe (Phase B): "self-contained future via a spawned writer
;; subtask", hand-authored to the ABI shape Phase A empirically determined
;; is sufficient (see canon-imports-exports.wit-abi.txt in this directory):
;; under vibe's stackful (callback-less) codegen strategy, "spawn a writer,
;; then await it" needs NO canon built-ins beyond what stackful/component.wat
;; already proves (task.return, [async-lower]get-async, waitable-set.new/
;; .wait/.drop, waitable.join, subtask.drop) -- no future.*, no
;; context.get/set, no waitable-set.poll. The "spawn" is realized as an
;; ordinary internal wasm function call ($writer, invoked by $run) within the
;; SAME core module and the SAME stackful fiber -- not a second
;; Component-Model subtask.
;;
;; This is a deliberate structural refactor of stackful/component.wat (same
;; canon set, same host import, same retry-loop shape) split into two wasm
;; functions to concretely prove the refactor vibe's compiler needs --
;; compiling `Task::spawn(|| await(host_call()))` followed by
;; `await(that_task)` as a writer function called from the reader's body --
;; compiles and runs correctly with a genuinely non-ready wait (the host
;; driver suspends for 300ms, same as stackful/'s host).
(component
  (type $get-async-type (func async (result u32)))
  (import "get-async" (func $host-get-async (type $get-async-type)))

  (core module $guest
    (import "$root" "[async-lower]get-async" (func $get_async (param i32) (result i32)))
    (import "$root" "[waitable-set-new]" (func $ws_new (result i32)))
    (import "$root" "[waitable-join]" (func $waitable_join (param i32 i32)))
    (import "$root" "[waitable-set-wait]" (func $ws_wait (param i32 i32) (result i32)))
    (import "$root" "[waitable-set-drop]" (func $ws_drop (param i32)))
    (import "$root" "[subtask-drop]" (func $subtask_drop (param i32)))
    (import "[export]$root" "[task-return]run" (func $task_return (param i32)))
    (import "env" "memory" (memory 1))

    ;; $writer: the "spawned writer subtask" -- an ordinary internal wasm
    ;; function, not a second Component-Model subtask. It performs the real
    ;; async-lowered host call + waitable-set retry loop and returns the
    ;; resolved value to its caller ($run) directly on the wasm value stack,
    ;; exactly the way a normal (non-async) helper function would.
    (func $writer (result i32)
      (local $packed i32)
      (local $code i32)
      (local $subtask i32)
      (local $ws i32)
      (local $event0 i32)

      (local.set $packed (call $get_async (i32.const 0)))
      (local.set $code (i32.and (local.get $packed) (i32.const 0xf)))
      (local.set $subtask (i32.shr_u (local.get $packed) (i32.const 4)))

      (block $done
        (br_if $done (i32.eq (local.get $code) (i32.const 2)))

        (local.set $ws (call $ws_new))
        (call $waitable_join (local.get $subtask) (local.get $ws))

        (loop $retry
          (local.set $event0 (call $ws_wait (local.get $ws) (i32.const 8)))
          ;; event0 == 1 (EVENT_SUBTASK): payload[1] (addr 12) is this
          ;; subtask's new status code. Any other event0 is not ours to
          ;; interpret -- loop and wait again without touching $code.
          (if (i32.eq (local.get $event0) (i32.const 1))
            (then
              (local.set $code (i32.load (i32.const 12)))
              (br_if $done (i32.eq (local.get $code) (i32.const 2)))
            )
          )
          (br $retry)
        )
      )

      (call $subtask_drop (local.get $subtask))
      (i32.load (i32.const 0))
    )

    ;; $run: the reader / "self-contained future" consumer. It "spawns" the
    ;; writer (a plain call, immediately reached in program order -- under
    ;; the stackful ABI the whole call chain suspends together at
    ;; $ws_wait inside $writer, exactly as if $writer's blocking work were
    ;; interleaved with $run's own body) and awaits its result by simply
    ;; using the returned value once the call returns.
    (func (export "run")
      (call $task_return (call $writer))
    )
  )

  (core module $memhost
    (memory (export "memory") 1)
  )
  (core instance $mem-inst (instantiate $memhost))

  (core func $core-get-async (canon lower (func $host-get-async) async (memory $mem-inst "memory")))
  (core func $core-task-return (canon task.return (result u32)))
  (core func $core-ws-new (canon waitable-set.new))
  (core func $core-waitable-join (canon waitable.join))
  (core func $core-ws-wait (canon waitable-set.wait (memory $mem-inst "memory")))
  (core func $core-ws-drop (canon waitable-set.drop))
  (core func $core-subtask-drop (canon subtask.drop))

  (core instance $guest-inst (instantiate $guest
    (with "$root" (instance
      (export "[async-lower]get-async" (func $core-get-async))
      (export "[waitable-set-new]" (func $core-ws-new))
      (export "[waitable-join]" (func $core-waitable-join))
      (export "[waitable-set-wait]" (func $core-ws-wait))
      (export "[waitable-set-drop]" (func $core-ws-drop))
      (export "[subtask-drop]" (func $core-subtask-drop))
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
