;; ADR-0089 Decision 2 / step 4 probe (#1218): HOST-SUPPLIED future<u32>
;; value, read by the guest against a producer that resolves only after a
;; genuine host-side timer suspend. This is the counterpart the
;; ../future_value probe deliberately deferred: there the guest authored
;; BOTH ends (single-task rendezvous, write eagerly satisfied a pending
;; read), so waitable-set.wait always had its event already queued. Here
;; the write end lives in the HOST (runtime/viberun's `get-future` import,
;; a wasmtime `FutureReader::new` producer sleeping ~300ms), so:
;;
;;   1. [async-lower]get-future     -> expect eager RETURNED (creating the
;;      future pair suspends nothing host-side); the future READABLE-end
;;      handle lands in the results buffer
;;   2. future.read (async)         -> BLOCKED (the producer's timer has
;;      not fired)
;;   3. waitable.join(fut, ws); waitable-set.wait -> the task genuinely
;;      SUSPENDS (the host event loop runs the timer) until the producer
;;      resolves; the completion arrives as a FUTURE_READ (= 4) event in
;;      completion order
;;   4. read buffer -> 42; drop the readable end + the set; task.return
;;
;; This is the `waitable-set.wait` backend of Decision 1's three-backend
;; split, measured end-to-end: park-as-waitable (steps 2-3) instead of
;; poll-retry, woken by host completion rather than by re-checking state.
;;
;; Conventions reused from the sibling probes (all previously measured):
;;   - async-lowered call result packs (subtask << 4) | code, code 2 =
;;     RETURNED (spawned_future/component.wat)
;;   - future.read async BLOCKED = 0xffffffff; wait payload[0] = the
;;     waitable index; FUTURE_READ event = 4 (future_value/component.wat)
;;   - drop joined ends BEFORE waitable-set.drop ("resource has children")
;;
;; Diagnostic task.return values (anything but 42 is a failure that names
;; the broken assumption):
;;   5000 + code   get-future did not complete eagerly (code = low bits)
;;   1000 + code   future.read did NOT block (code = its low result bits)
;;                 -- with a >= 1ms producer delay it must block
;;   3000 + ev     waitable-set.wait returned an unexpected event code
(component
  (type $ft (future u32))
  ;; NOTE: the component-level type must be `func async` -- the `async`
  ;; canonical-lower option validates only against an async function type
  ;; (measured: a sync `(func (result (future u32)))` fails wasm-tools
  ;; validation with "the `async` canonical option requires an async
  ;; function type"). The WIT-level spelling stays `func() -> future<u32>`;
  ;; async-ness here is the lowering discipline, not a WIT signature change.
  (type $get-future-type (func async (result $ft)))
  (import "get-future" (func $host-get-future (type $get-future-type)))

  (core module $guest
    ;; Import names follow the wit-bindgen capture convention from
    ;; ../future_value/canon-imports-exports.wit-abi.txt: future.* built-ins
    ;; are named [future-<op>-N]<introducing WIT function>.
    (import "$root" "[async-lower]get-future" (func $get_future (param i32) (result i32)))
    (import "$root" "[async-lower][future-read-0]get-future" (func $fread (param i32 i32) (result i32)))
    (import "$root" "[future-drop-readable-0]get-future" (func $fdrop_r (param i32)))
    (import "$root" "[waitable-set-new]" (func $ws_new (result i32)))
    (import "$root" "[waitable-join]" (func $waitable_join (param i32 i32)))
    (import "$root" "[waitable-set-wait]" (func $ws_wait (param i32 i32) (result i32)))
    (import "$root" "[waitable-set-drop]" (func $ws_drop (param i32)))
    (import "[export]$root" "[task-return]run" (func $task_return (param i32)))
    (import "env" "memory" (memory 1))

    ;; Memory layout (shared memhost page):
    ;;    0  read buffer (u32 landing slot for the future's value)
    ;;    8  [async-lower]get-future results (u32 future readable handle)
    ;;   16  waitable-set.wait payload[0] (which waitable fired)
    ;;   20  waitable-set.wait payload[1]
    (func (export "run")
      (local $packed i32)
      (local $code i32)
      (local $fut i32)
      (local $st i32)
      (local $ws i32)
      (local $ev i32)

      ;; 1) obtain the future handle from the host. Creating the pair
      ;;    suspends nothing host-side, so this must complete eagerly --
      ;;    a non-RETURNED status would mean the host import's shape
      ;;    changed (and there is no subtask-wait epilogue here to run).
      (local.set $packed (call $get_future (i32.const 8)))
      (local.set $code (i32.and (local.get $packed) (i32.const 0xf)))
      (if (i32.ne (local.get $code) (i32.const 2))
        (then
          (call $task_return (i32.add (i32.const 5000) (local.get $code)))
          (return)
        )
      )
      (local.set $fut (i32.load (i32.const 8)))

      ;; 2) read: the producer's timer has not fired -> BLOCKED
      (local.set $st (call $fread (local.get $fut) (i32.const 0)))
      (if (i32.ne (local.get $st) (i32.const 0xffffffff))
        (then
          (call $task_return
            (i32.add (i32.const 1000) (i32.and (local.get $st) (i32.const 0xf))))
          (return)
        )
      )

      ;; 3) park as a waitable: join the pending read into a set and wait.
      ;;    THIS is the suspension point -- the host runs its timer while
      ;;    the task sits here, and completion arrives in completion order.
      ;;    This task owns exactly one waitable, so the first event must be
      ;;    FUTURE_READ (= 4); anything else names a broken assumption.
      (local.set $ws (call $ws_new))
      (call $waitable_join (local.get $fut) (local.get $ws))
      (local.set $ev (call $ws_wait (local.get $ws) (i32.const 16)))
      (if (i32.ne (local.get $ev) (i32.const 4))
        (then
          (call $task_return (i32.add (i32.const 3000) (local.get $ev)))
          (return)
        )
      )

      ;; 4) the value landed in the read buffer; tear down and return it.
      ;;    Only the READABLE end is ours to drop -- the host owns the
      ;;    write side. Drop the joined end BEFORE the set.
      (call $fdrop_r (local.get $fut))
      (call $ws_drop (local.get $ws))
      (call $task_return (i32.load (i32.const 0)))
    )
  )

  (core module $memhost
    (memory (export "memory") 1)
  )
  (core instance $mem-inst (instantiate $memhost))

  (core func $core-get-future (canon lower (func $host-get-future) async (memory $mem-inst "memory")))
  (core func $core-fread (canon future.read $ft async (memory $mem-inst "memory")))
  (core func $core-fdrop-r (canon future.drop-readable $ft))
  (core func $core-task-return (canon task.return (result u32)))
  (core func $core-ws-new (canon waitable-set.new))
  (core func $core-waitable-join (canon waitable.join))
  (core func $core-ws-wait (canon waitable-set.wait (memory $mem-inst "memory")))
  (core func $core-ws-drop (canon waitable-set.drop))

  (core instance $guest-inst (instantiate $guest
    (with "$root" (instance
      (export "[async-lower]get-future" (func $core-get-future))
      (export "[async-lower][future-read-0]get-future" (func $core-fread))
      (export "[future-drop-readable-0]get-future" (func $core-fdrop-r))
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
