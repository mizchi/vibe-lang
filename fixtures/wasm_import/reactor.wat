;; A reactor: its `_initialize: () -> ()` must run before the first call, so
;; `value` answers 7 (scripts/test_wasm_import_gate.sh, init_main.vibex).
(module
  (global $v (mut i64) (i64.const 0))
  (func (export "_initialize") (global.set $v (i64.const 7)))
  (func (export "value") (result i64) (global.get $v)))
