;; #1540 follow-up probe: the canonical-option set for an ASYNC lift whose
;; params and result are STRINGS.
;;
;; The http_body_stream probe established that a request body can reach the
;; guest as a `stream<u8>` parameter, but its guest returns a constant through a
;; SYNC lift. A guest that actually reads the body suspends, so the handler has
;; to be async-lifted -- and a `string` result then comes back through
;; `task.return` rather than the lift's own return path. The emitters in
;; `component_codegen.vibe` are too narrow for that today:
;;
;;   emit_canon_lift_async_section  emits exactly one canonopt (async)
;;   emit_canon_task_return         emits none
;;
;; Both need widening, so this probe pins what wasmtime actually accepts and
;; what the bytes are, before either emitter is generalized.
;;
;; Measured with wasm-tools 1.255.0 / wasmtime 47.0.2. Three findings:
;;
;;   1. `task.return` CANNOT carry `realloc`:
;;        error: cannot specify `realloc` option on `task.return`
;;      It lifts the result OUT of guest memory, so it reads but never
;;      allocates. `memory` + `string-encoding` are the whole option set.
;;
;;   2. the `async` canonopt REQUIRES the component functype to be declared
;;      async as well:
;;        error: the `async` canonical option requires an async function type
;;      `(func (param ..) (result ..))` is rejected; `(func async (param ..)
;;      (result ..))` is accepted. `emit_comp_async_functype_section` already
;;      emits the async functype opcode (0x43) but hardcodes ZERO params, so it
;;      needs widening alongside the two canon emitters.
;;
;;   3. the async lift itself DOES take `memory` + `realloc` +
;;      `string-encoding`, all three.
;;
;; Exact bytes (`wasm-tools dump`), which are the target encoding:
;;
;;   task.return   09 00 73 02 03 00 00
;;                 09=task.return  00=result-form  73=string
;;                 02=option count  03 00=Memory(0)  00=UTF8
;;
;;   async lift    00 00 02 04 06 03 00 04 00 00 00
;;                 00=lift  00=core-func sort  02=core func idx
;;                 04=option count  06=Async  03 00=Memory(0)
;;                 04 00=Realloc(0)  00=UTF8  00=type idx
;;
;;   option codes  00=UTF8  03 <idx>=Memory  04 <idx>=Realloc  06=Async
;;
;; STATUS: the emitters have since been widened to produce exactly this, and
;; `comp_emit_async_string_component` (component_codegen.vibe) assembles the
;; whole component below from them -- validated and run by
;; `scripts/compiler_gate.sh` lane 40c4, which holds it to this probe's bar
;; (greet("bob") -> "hi"). This file stays as the HAND-WRITTEN reference: it is
;; what the emitter was measured against, and the byte sequences documented here
;; are what both the gate above and component_codegen_test.vibe assert.
;;
;; The structural constraint this probe also demonstrates: memory and realloc
;; must live OUTSIDE the guest instance. `task.return` needs them, the guest
;; imports `[task-return]`, so a guest-owned memory would be a cycle. That is
;; the same reason `comp_generate_memhost_module` exists -- but the memhost also
;; has to export `cabi_realloc` now, which today's one does not.
(component
  (core module $memhost
    (memory (export "memory") 1)
    (global $bump (mut i32) (i32.const 1024))
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
      (local $p i32)
      (local.set $p (global.get $bump))
      (global.set $bump (i32.add (global.get $bump) (i32.const 64)))
      (local.get $p))
  )
  (core instance $mh (instantiate $memhost))
  (alias core export $mh "memory" (core memory $mem))
  (alias core export $mh "cabi_realloc" (core func $realloc))

  (core module $m
    (import "[export]$root" "[task-return]greet" (func $task_return (param i32 i32)))
    (import "env" "memory" (memory 1))
    ;; Writes into the IMPORTED (memhost) memory at instantiation, which is what
    ;; makes the returned bytes observable to `task.return`'s lift.
    (data (i32.const 16) "hi")
    ;; The string param arrives flattened as (ptr, len) and the core function
    ;; returns NOTHING -- the result leaves through task.return.
    (func (export "greet") (param i32 i32)
      (call $task_return (i32.const 16) (i32.const 2)))
  )

  (type $ft (func async (param "name" string) (result string)))
  (core func $tr (canon task.return (result string) (memory $mem) string-encoding=utf8))
  (core instance $er (export "[task-return]greet" (func $tr)))
  (core instance $env (export "memory" (memory $mem)))
  (core instance $gi (instantiate $m (with "[export]$root" (instance $er)) (with "env" (instance $env))))
  (func (export "greet") (type $ft)
    (canon lift (core func $gi "greet") async (memory $mem) (realloc $realloc) string-encoding=utf8))
)
