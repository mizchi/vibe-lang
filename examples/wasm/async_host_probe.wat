;; Guest for the real async host (tools/async_host, bin vibe-real-async-host):
;; `run()` awaits the host async import `host.get_async`, which suspends the
;; guest fiber once and then yields 42. Proves real blocking await on wasmtime 45.
(module
  (import "host" "get_async" (func $get (result i64)))
  (func (export "run") (result i64) (call $get)))
