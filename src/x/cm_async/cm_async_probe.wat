;; Minimal component for CM async probe.
;; Validates that concurrency-support + component-model-async flags work
;; on the host platform (including macOS aarch64).
;;
;; This component exports a simple "run" function that returns 42.
;; The point is not async behavior itself (which requires Rust host API),
;; but that the runtime *accepts* the async configuration without error.

(component
  (core module $m
    (func (export "run") (result i32)
      i32.const 42
    )
    (memory (export "memory") 1)
  )
  (core instance $i (instantiate $m))
  (func $run (result u32)
    (canon lift (core func $i "run"))
  )
  (export "run" (func $run))
)
