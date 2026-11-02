;; An ordinary export that happens to be named `_initialize`, with another
;; signature: it is NOT the reactor initializer, so the linkers must not call
;; it with no arguments (which failed the whole link), and the program can
;; call it like any other export (init_main.vibex).
(module
  (func (export "_initialize") (param i64) (result i64)
    (i64.add (local.get 0) (i64.const 1)))
  (func (export "foo") (result i32) (i32.const 42)))
