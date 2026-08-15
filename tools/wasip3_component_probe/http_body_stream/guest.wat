;; #1540 shape (a) probe guest: export the handler the adapter imports, with the
;; request body arriving as a `stream<u8>` PARAMETER rather than a materialized
;; string. This guest ignores the stream and answers a constant, which is enough
;; to answer the composition question on its own.
(component
  (core module $m
    (memory (export "memory") 1)
    ;; The gate replaces the fixed-width suffix with a per-process token. This
    ;; proves curl reached the wasmtime process started by that gate invocation.
    ;; "200\n\nprobe-00000" -- the adapter's status/headers/body split
    (data (i32.const 16) "200\0a\0aprobe-00000")
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
      i32.const 128)
    ;; 3 strings (ptr,len) + 1 stream handle; the string result is returned as
    ;; a POINTER to its (ptr,len) pair, not through a retptr parameter.
    (func (export "handler")
      (param i32 i32 i32 i32 i32 i32 i32) (result i32)
      i32.const 64
      i32.const 16
      i32.store
      i32.const 64
      i32.const 16
      i32.store offset=4
      i32.const 64)
  )
  (core instance $i (instantiate $m))
  (func (export "handler")
    (param "method" string) (param "url" string) (param "headers" string)
    (param "body" (stream u8)) (result string)
    (canon lift (core func $i "handler")
      string-encoding=utf8
      (memory $i "memory")
      (realloc (func $i "cabi_realloc"))))
)
