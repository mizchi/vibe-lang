;; M1b-3c-1b probe (Phase B): blocking await with the wait loop factored
;; into its own function, hand-authored to the ABI shape Phase A recovered
;; (see canon-imports-exports.wit-abi.txt in this directory). This shape
;; needs NO canon built-ins beyond what stackful/component.wat already
;; proves (task.return, [async-lower]get-async, waitable-set.new/.wait/
;; .drop, waitable.join, subtask.drop) -- no future.*, no context.get/set,
;; no waitable-set.poll.
;;
;; It is a deliberate structural refactor of stackful/component.wat (same
;; canon set, same host import, same retry-loop shape) split into two wasm
;; functions, to prove that the refactor vibe's compiler needs -- compiling
;; `Task::spawn(|| await(host_call()))` followed by `await(that_task)` as a
;; callee function invoked from the awaiting code -- compiles and runs
;; correctly against a genuinely non-ready wait (the host driver suspends
;; for 300ms, same as stackful/'s host).
;;
;; SCOPE (#1240 review): $writer is an ordinary internal wasm function that
;; $run calls SYNCHRONOUSLY -- not a second Component-Model task. Nothing
;; here runs concurrently with anything else, so this models `spawn f;
;; await t` ONLY in the degenerate case where no observable parent work
;; happens between the spawn and the join (there, the spawn is semantically
;; a no-op and compiles away to a direct call). It does NOT establish that
;; a real interleaving spawn needs no executor machinery -- Phase A's
;; evidence suggests it does. See canon-imports-exports.wit-abi.txt's
;; "IMPORTANT LIMIT ON THAT CONCLUSION" for the full argument.
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
      ;; #1240 review: records whether the BLOCKED path allocated a waitable
      ;; set, so the epilogue can drop it. Without this, every blocking call
      ;; leaks one canonical waitable-set handle. Note the drop must come
      ;; AFTER subtask.drop -- the subtask is waitable.join'ed into the set,
      ;; and dropping a set that still has children traps with
      ;; "resource has children" (observed live on wasmtime 47).
      (local $has_ws i32)

      (local.set $packed (call $get_async (i32.const 0)))
      (local.set $code (i32.and (local.get $packed) (i32.const 0xf)))
      (local.set $subtask (i32.shr_u (local.get $packed) (i32.const 4)))

      (block $done
        (br_if $done (i32.eq (local.get $code) (i32.const 2)))

        (local.set $ws (call $ws_new))
        (local.set $has_ws (i32.const 1))
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

      ;; #1230 M1b-3c-2: BOTH drops are guarded by $has_ws, because both
      ;; resources come into existence together on the blocked path. An
      ;; async-lowered call that completes EAGERLY (the `br_if $done` above,
      ;; status RETURNED straight out of the call) creates NO subtask -- the
      ;; handle bits of $packed are 0 -- and allocates no waitable set, so
      ;; dropping unconditionally traps with "unknown handle index 0". This
      ;; probe's own host always sleeps 300ms, so it only ever exercised the
      ;; blocked path; the trap showed up as soon as the same component was
      ;; driven through runtime/viberun with a zero-delay host import.
      (if (local.get $has_ws)
        (then
          (call $subtask_drop (local.get $subtask))
          (call $ws_drop (local.get $ws))
        )
      )
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
