;; A self-contained module that exports a SHARED memory (a pthreads build's
;; shape). wasmtime exposes it as `Extern::SharedMemory`, not as a `Memory`,
;; so scripts/test_wasm_import_gate.sh runs shared_memory_main.vibex to prove
;; viberun still serves the memory accessors the binding offers for it.
(module
  (memory (export "mem") 1 1 shared)
  (data (i32.const 3) "\2a")
  (func (export "peek") (param i32) (result i32)
    (i32.load8_u (local.get 0))))
